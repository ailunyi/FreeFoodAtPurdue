"""
Vector-based building matcher using Gemini embeddings.

Replaces the old rapidfuzz fallback with semantic similarity:
  Phase 1: O(1) exact match on abbr / full_name / aliases (dict lookup)
  Phase 2: Embed the query via Gemini, cosine-similarity against cached building vectors
"""

from __future__ import annotations

import hashlib
import logging
import os
from typing import Optional, Tuple

import google.generativeai as genai
import numpy as np

log = logging.getLogger(__name__)

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
_CACHE_PATH = os.path.join(BASE_DIR, "building_embeddings.npz")
_EMBED_MODEL = "models/gemini-embedding-001"
_BATCH_SIZE = 100
_SIMILARITY_THRESHOLD = 0.60


class BuildingMatcher:
    """Resolve a free-text building name to a known (full_name, abbr, lat, lng)."""

    def __init__(self, buildings: dict) -> None:
        """
        Args:
            buildings: {abbr: {full_name, lat, lng, aliases, ...}} — from load_buildings_from_db().
        """
        self._buildings = buildings

        # Phase-1 exact-match index: lowercase string -> abbr
        self._exact: dict[str, str] = {}
        # Phase-2 candidate list: parallel lists of (text, abbr)
        self._cand_texts: list[str] = []
        self._cand_abbrs: list[str] = []

        for abbr, info in buildings.items():
            keys = [abbr.lower(), info["full_name"].lower()]
            keys.extend(a.lower() for a in info.get("aliases", []))
            for k in keys:
                if k not in self._exact:
                    self._exact[k] = abbr

            for text in [info["full_name"]] + list(info.get("aliases", [])):
                self._cand_texts.append(text)
                self._cand_abbrs.append(abbr)

        self._embeddings: Optional[np.ndarray] = None
        self._index_ready = False
        self._embed_cache: dict[str, np.ndarray] = {}
        self._MAX_CACHE_SIZE = 256

    def load_index(self) -> None:
        """Load pre-built embeddings from disk. Raises RuntimeError if cache is missing or stale.
        Run build_embeddings.py to generate/update the cache."""
        if not self._cand_texts:
            log.warning("[matcher] no candidate texts — skipping index load")
            return

        if not os.path.exists(_CACHE_PATH):
            log.error(
                "[matcher] Embedding cache not found at %s. "
                "Vector search disabled. Run: python build_embeddings.py", _CACHE_PATH
            )
            return

        try:
            cached = np.load(_CACHE_PATH, allow_pickle=True)
        except Exception as e:
            log.error("[matcher] Failed to load embedding cache: %s. Vector search disabled.", e)
            return

        cache_hash = self._compute_hash()
        if cached["hash"].item() != cache_hash:
            log.error(
                "[matcher] Embedding cache is stale (buildings changed). "
                "Vector search disabled. Run: python build_embeddings.py"
            )
            return  # _index_ready remains False; exact-match still works

        self._embeddings = cached["vectors"]
        self._index_ready = True
        log.info("[matcher] loaded %d embeddings from cache", len(self._embeddings))

    def build_index(self, force_full: bool = False) -> None:
        """Embed candidate strings and save to disk cache.

        By default, performs an incremental update: loads the existing cache,
        identifies new/changed/removed candidate texts, and only embeds the
        diff.  Pass ``force_full=True`` to re-embed everything from scratch.
        """
        if not self._cand_texts:
            log.warning("[matcher] no candidate texts to embed")
            return

        # Try incremental update unless forced
        if not force_full and os.path.exists(_CACHE_PATH):
            try:
                cached = np.load(_CACHE_PATH, allow_pickle=True)
                old_texts = list(cached["texts"]) if "texts" in cached else []
                old_vecs = cached["vectors"] if "texts" in cached else None
                if old_vecs is not None and len(old_texts) == len(old_vecs):
                    return self._incremental_update(old_texts, old_vecs)
            except Exception as e:
                log.warning("[matcher] could not load cache for incremental update (%s), doing full rebuild", e)

        self._full_embed()

    def _full_embed(self) -> None:
        """Embed all candidate strings from scratch."""
        log.info("[matcher] full embed: %d candidate strings in batches of %d ...",
                 len(self._cand_texts), _BATCH_SIZE)

        all_vecs: list[list[float]] = []
        for i in range(0, len(self._cand_texts), _BATCH_SIZE):
            batch = self._cand_texts[i : i + _BATCH_SIZE]
            resp = genai.embed_content(model=_EMBED_MODEL, content=batch)
            all_vecs.extend(resp["embedding"])

        self._embeddings = np.array(all_vecs, dtype=np.float32)
        norms = np.linalg.norm(self._embeddings, axis=1, keepdims=True)
        norms[norms == 0] = 1.0
        self._embeddings /= norms

        self._save_cache()

    def _incremental_update(self, old_texts: list, old_vecs: np.ndarray) -> None:
        """Only embed new/changed candidates; reuse existing embeddings for unchanged ones."""
        old_map: dict[str, int] = {}
        for i, t in enumerate(old_texts):
            old_map[t] = i

        new_texts: list[str] = []  # texts that need embedding
        new_indices: list[int] = []  # their position in self._cand_texts
        reused = 0

        # Build the new embedding array, reusing old vectors where possible
        result_vecs = np.zeros((len(self._cand_texts), old_vecs.shape[1]), dtype=np.float32)

        for i, text in enumerate(self._cand_texts):
            if text in old_map:
                result_vecs[i] = old_vecs[old_map[text]]
                reused += 1
            else:
                new_texts.append(text)
                new_indices.append(i)

        removed = len(old_texts) - reused

        if not new_texts:
            log.info("[matcher] incremental: no changes detected (%d reused, %d removed)", reused, removed)
            self._embeddings = result_vecs
            self._save_cache()
            return

        log.info("[matcher] incremental: %d reused, %d new, %d removed — embedding %d texts",
                 reused, len(new_texts), removed, len(new_texts))

        # Embed only the new/changed texts
        new_vecs: list[list[float]] = []
        for i in range(0, len(new_texts), _BATCH_SIZE):
            batch = new_texts[i : i + _BATCH_SIZE]
            resp = genai.embed_content(model=_EMBED_MODEL, content=batch)
            new_vecs.extend(resp["embedding"])

        # Normalize and insert
        new_arr = np.array(new_vecs, dtype=np.float32)
        norms = np.linalg.norm(new_arr, axis=1, keepdims=True)
        norms[norms == 0] = 1.0
        new_arr /= norms

        for j, idx in enumerate(new_indices):
            result_vecs[idx] = new_arr[j]

        self._embeddings = result_vecs
        self._save_cache()

    def _save_cache(self) -> None:
        """Save embeddings, candidate texts, and hash to disk."""
        cache_hash = self._compute_hash()
        np.savez_compressed(
            _CACHE_PATH,
            vectors=self._embeddings,
            texts=np.array(self._cand_texts, dtype=object),
            hash=cache_hash,
        )
        self._index_ready = True
        log.info("[matcher] saved %d embeddings to %s", len(self._embeddings), _CACHE_PATH)

    def _query_scores(self, name: str) -> Optional[np.ndarray]:
        """Embed the query and return cosine similarity scores, or None on failure."""
        if not self._index_ready or self._embeddings is None:
            return None
        key = name.strip().lower()
        if key in self._embed_cache:
            return self._embed_cache[key]
        try:
            resp = genai.embed_content(model=_EMBED_MODEL, content=[name.strip()])
            q = np.array(resp["embedding"][0], dtype=np.float32)
            q /= np.linalg.norm(q) or 1.0
            scores = self._embeddings @ q
            if len(self._embed_cache) >= self._MAX_CACHE_SIZE:
                self._embed_cache.pop(next(iter(self._embed_cache)))
            self._embed_cache[key] = scores
            return scores
        except Exception as e:
            log.warning("[matcher] embedding query failed: %s", e)
            return None

    def match(self, name: Optional[str]) -> Tuple[Optional[str], Optional[str], Optional[float], Optional[float], float]:
        """Resolve a building name to (full_name, abbr, lat, lng, name_confidence).

        Returns (original_name, None, None, None, 0.0) if no match is found.
        Returns (None, None, None, None, 0.0) if name is falsy.
        """
        if not name:
            return None, None, None, None, 0.0

        name_lower = name.strip().lower()

        # Phase 1: exact match (O(1) dict lookup)
        abbr = self._exact.get(name_lower)
        if abbr is not None:
            info = self._buildings[abbr]
            return info["full_name"], abbr, info["lat"], info["lng"], 1.0

        # Phase 2: vector similarity
        scores = self._query_scores(name)
        if scores is not None:
            best_idx = int(np.argmax(scores))
            best_score = float(scores[best_idx])

            if best_score >= _SIMILARITY_THRESHOLD:
                abbr = self._cand_abbrs[best_idx]
                info = self._buildings[abbr]
                log.info("[matcher] vector match: %r -> %s (%s) score=%.3f",
                         name.strip(), info["full_name"], abbr, best_score)
                return info["full_name"], abbr, info["lat"], info["lng"], best_score
            else:
                log.info("[matcher] no vector match for %r (best=%.3f, text=%r)",
                         name.strip(), best_score, self._cand_texts[best_idx])

        return name.strip(), None, None, None, 0.0

    def _substring_matches(self, query_lower: str, top_n: int) -> list:
        """Return unique buildings whose name or aliases contain query_lower words.

        Results are ranked by how much of the building name the query covers,
        so "stewart cooperative" scores higher than just "stewart" for a query of "stewart cooperative".
        GPL-prefixed event/person entries are deprioritised.
        """
        words = set(query_lower.split())
        seen: set = set()
        results = []
        for text, abbr in zip(self._cand_texts, self._cand_abbrs):
            if abbr in seen:
                continue
            text_lower = text.lower()
            if any(w in text_lower for w in words):
                seen.add(abbr)
                info = self._buildings[abbr]
                # Score: fraction of query words found in the candidate name
                match_count = sum(1 for w in words if w in text_lower)
                word_score = match_count / max(len(words), 1)
                # Penalise GPL-prefixed entries (Google Places events/people, not real buildings)
                is_noise = abbr.startswith("GPL")
                results.append({
                    "abbr": abbr,
                    "full_name": info["full_name"],
                    "lat": info["lat"],
                    "lng": info["lng"],
                    "score": 1.0,
                    "_rank": (0 if not is_noise else 1, -word_score),
                })

        results.sort(key=lambda x: x["_rank"])
        for r in results:
            del r["_rank"]
        return results[:top_n]

    def match_candidates(
        self,
        name: Optional[str],
        top_n: int = 4,
        confident_threshold: float = 0.88,
        ambiguity_gap: float = 0.10,
    ) -> Tuple[Tuple, list, bool]:
        """Resolve a building name, detecting ambiguity when multiple buildings score similarly.

        Returns:
            best_result: (full_name, abbr, lat, lng, score) tuple — same as match()
            candidates: list of {abbr, full_name, lat, lng, score} for top unique buildings
            is_ambiguous: True when the user should be asked to pick
        """
        if not name:
            return (None, None, None, None, 0.0), [], False

        name_lower = name.strip().lower()

        # Check how many buildings share the query as a substring — if more than one, always ambiguous
        substr_matches = self._substring_matches(name_lower, top_n)
        if len(substr_matches) > 1:
            best = substr_matches[0]
            best_result = (best["full_name"], best["abbr"], best["lat"], best["lng"], best["score"])
            log.info("[matcher] substring ambiguity for %r: %s", name.strip(), [c["abbr"] for c in substr_matches])
            return best_result, substr_matches, True

        # Phase 1: single exact match — confident
        abbr = self._exact.get(name_lower)
        if abbr is not None:
            info = self._buildings[abbr]
            best = (info["full_name"], abbr, info["lat"], info["lng"], 1.0)
            return best, [{"abbr": abbr, "full_name": info["full_name"], "lat": info["lat"], "lng": info["lng"], "score": 1.0}], False

        # Phase 2: vector similarity
        scores = self._query_scores(name)
        if scores is None:
            return (name.strip(), None, None, None, 0.0), [], False

        best_score = float(np.max(scores))
        if best_score < _SIMILARITY_THRESHOLD:
            log.info("[matcher] no match for %r (best=%.3f)", name.strip(), best_score)
            return (name.strip(), None, None, None, 0.0), [], False

        # Collect top unique buildings by vector score
        order = np.argsort(scores)[::-1]
        seen_abbrs: set = set()
        candidates = []
        for idx in order:
            sc = float(scores[idx])
            if sc < _SIMILARITY_THRESHOLD:
                break
            a = self._cand_abbrs[idx]
            if a in seen_abbrs:
                continue
            seen_abbrs.add(a)
            info = self._buildings[a]
            candidates.append({"abbr": a, "full_name": info["full_name"], "lat": info["lat"], "lng": info["lng"], "score": sc})
            if len(candidates) >= top_n:
                break

        best_cand = candidates[0]
        best_result = (best_cand["full_name"], best_cand["abbr"], best_cand["lat"], best_cand["lng"], best_cand["score"])

        # Ambiguous if the winner isn't clearly ahead of its closest rival
        is_ambiguous = (
            best_cand["score"] < confident_threshold
            and len(candidates) >= 2
            and (candidates[0]["score"] - candidates[1]["score"]) < ambiguity_gap
        )

        log.info("[matcher] candidates for %r: %s (ambiguous=%s)",
                 name.strip(), [(c["abbr"], round(c["score"], 3)) for c in candidates], is_ambiguous)

        return best_result, candidates, is_ambiguous

    def _compute_hash(self) -> str:
        """Deterministic hash of the candidate list for cache invalidation."""
        h = hashlib.sha256()
        for t in self._cand_texts:
            h.update(t.encode())
        return h.hexdigest()[:16]
