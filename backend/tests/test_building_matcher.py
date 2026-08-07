"""Tests for building_matcher.py exact matching and no-embeddings fallback.

Vector similarity requires the Gemini embedding cache, so these tests cover
the phases that work without it: exact lookup and substring candidates.
"""

import pytest

from building_matcher import BuildingMatcher

BUILDINGS = {
    "WALC": {
        "full_name": "Wilmeth Active Learning Center",
        "lat": 40.4275, "lng": -86.9132,
        "aliases": ["the walc", "active learning center"],
    },
    "LWSN": {
        "full_name": "Lawson Computer Science Building",
        "lat": 40.4249, "lng": -86.9130,
        "aliases": [],
    },
    "STEW": {
        "full_name": "Stewart Center",
        "lat": 40.425, "lng": -86.912,
        "aliases": [],
    },
}


@pytest.fixture()
def matcher():
    return BuildingMatcher(BUILDINGS)


def test_exact_match_on_abbreviation(matcher):
    full_name, abbr, lat, lng, conf = matcher.match("walc")
    assert (full_name, abbr, conf) == ("Wilmeth Active Learning Center", "WALC", 1.0)
    assert (lat, lng) == (40.4275, -86.9132)


def test_exact_match_on_full_name_and_alias(matcher):
    assert matcher.match("Lawson Computer Science Building")[1] == "LWSN"
    assert matcher.match("the walc")[1] == "WALC"


def test_no_match_returns_original_name_without_coords(matcher):
    full_name, abbr, lat, lng, conf = matcher.match("some unknown place")
    assert full_name == "some unknown place"
    assert abbr is None and lat is None and lng is None and conf == 0.0


def test_falsy_name_returns_all_none(matcher):
    assert matcher.match(None) == (None, None, None, None, 0.0)
    assert matcher.match("") == (None, None, None, None, 0.0)


def test_match_candidates_exact_is_confident(matcher):
    best, candidates, ambiguous = matcher.match_candidates("walc")
    assert best[1] == "WALC"
    assert ambiguous is False
    assert len(candidates) == 1


def test_match_candidates_substring_ambiguity(matcher):
    # "center" appears in both Wilmeth Active Learning Center and Stewart Center.
    best, candidates, ambiguous = matcher.match_candidates("center")
    assert ambiguous is True
    abbrs = {c["abbr"] for c in candidates}
    assert {"WALC", "STEW"} <= abbrs
