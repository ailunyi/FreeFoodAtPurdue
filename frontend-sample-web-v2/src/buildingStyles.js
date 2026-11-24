// Per-building polygon colors (ported verbatim from the original site).
// Keyed by building abbreviation; falls back to `_` for unknown buildings.
// `f` = fill, `s` = stroke. Group comments preserved for orientation.

export const BLDG_STYLE = {
  // Engineering / CS — blue-grey
  WALC: { f: '#c4dcf0', s: '#7aaed0' }, LWSN: { f: '#cac8e8', s: '#8888c4' },
  MSEE: { f: '#c4d4e8', s: '#7aa4c4' }, ARMS: { f: '#c4d4e0', s: '#84a4c0' },
  WTHR: { f: '#ccd0e0', s: '#8c98b8' }, CIVL: { f: '#c8d0e0', s: '#849cb8' },
  KNOY: { f: '#c4d0d8', s: '#84a0b0' }, MEEN: { f: '#c4d4e0', s: '#84a4c0' },
  EE:   { f: '#c8d4e8', s: '#88acd0' }, FRNY: { f: '#c8d0e4', s: '#88a0c0' },
  ME:   { f: '#c8d0dc', s: '#88a0b8' }, WANG: { f: '#c4cce4', s: '#8498c0' },
  BHEE: { f: '#c8d4e0', s: '#84a4c0' }, YONG: { f: '#ccd4e0', s: '#8ca4c0' },
  HAAS: { f: '#d4d8e4', s: '#9098b8' }, BIND: { f: '#ccd8e8', s: '#88a8c8' },
  BIDC: { f: '#d0d8e8', s: '#88a0c4' }, BIRK: { f: '#ccd8e8', s: '#8898c4' },
  HOCK: { f: '#c8d4ec', s: '#8098cc' }, GRIS: { f: '#c8d0e4', s: '#88a0c0' },
  POTR: { f: '#c8d0e0', s: '#88a0b8' }, MJIS: { f: '#c8dce8', s: '#80a8c8' },
  LYLE: { f: '#cce0e8', s: '#88b0c8' }, DRUG: { f: '#ccd8ec', s: '#88a8cc' },

  // Science — green-grey
  PHYS: { f: '#cce0cc', s: '#88b488' }, MATH: { f: '#d0e4cc', s: '#8cb88c' },
  BCHM: { f: '#c8e0c4', s: '#84b480' }, LSPS: { f: '#cce0cc', s: '#88b488' },
  CHAS: { f: '#cce4cc', s: '#88bc88' }, HANS: { f: '#c8e0c8', s: '#84b484' },

  // Humanities / Social — warm tan
  BRNG: { f: '#f0dcc8', s: '#c0987c' }, LILY: { f: '#f0d8c4', s: '#c09070' },
  KRAN: { f: '#e4d8c4', s: '#b4a47c' }, ELLT: { f: '#ecd8c4', s: '#bc9870' },
  BALY: { f: '#e8d4c4', s: '#bc9c74' }, RAWL: { f: '#e8d8c8', s: '#b8a07c' },
  MRRT: { f: '#e8d8c4', s: '#b8a07c' }, PSYC: { f: '#e8d8c8', s: '#b4a07c' },
  MANN: { f: '#e8d4c4', s: '#bc9c74' }, SC:   { f: '#e4d8c4', s: '#b4a07c' },
  HOVD: { f: '#e8d4c0', s: '#bc9878' }, UNIV: { f: '#ead8c4', s: '#bca070' },
  STON: { f: '#e4d8c4', s: '#b4a07c' },

  // Union / Dining
  PMU:  { f: '#ead8c4', s: '#bca470' }, PMUC: { f: '#ecd8c4', s: '#bca470' },
  STEW: { f: '#ecd8be', s: '#bc9c6c' }, FORD: { f: '#e8d4c0', s: '#b89870' },
  WDCT: { f: '#e8d4c0', s: '#b89870' },

  // Recreation / Athletics — green
  CREC: { f: '#bce0cc', s: '#68b484' }, TREC: { f: '#c8e4cc', s: '#78b888' },
  MACK: { f: '#d4ccbe', s: '#a49478' }, STDM: { f: '#d0c8bc', s: '#a09078' },
  AQUA: { f: '#c0d8e8', s: '#70a8cc' }, MOLL: { f: '#c8d8e0', s: '#80a8b8' },
  LAMB: { f: '#ccd8d0', s: '#84a894' }, SCHW: { f: '#c8dcd0', s: '#78a890' },

  // Residential — light cream
  CARY: { f: '#e4dcc8', s: '#b0a07c' }, HILL: { f: '#e4dcc8', s: '#b0a07c' },
  HARR: { f: '#e4dcc8', s: '#b0a07c' }, ERHT: { f: '#e4dcc8', s: '#b0a07c' },
  TARK: { f: '#e4dcc8', s: '#b0a07c' }, MRDH: { f: '#e4dcc8', s: '#b0a07c' },
  MRDS: { f: '#e4dcc8', s: '#b0a07c' }, MCUT: { f: '#e4dcc8', s: '#b0a07c' },
  SHRV: { f: '#e4dcc8', s: '#b0a07c' }, SHLY: { f: '#e4dcc8', s: '#b0a07c' },
  WILY: { f: '#e4dcc8', s: '#b0a07c' }, WOOD: { f: '#e4dcc8', s: '#b0a07c' },
  WARN: { f: '#e4dcc8', s: '#b0a07c' }, MTHW: { f: '#e4dcc8', s: '#b0a07c' },
  HCRS: { f: '#e4dcc8', s: '#b0a07c' }, HCRN: { f: '#e4dcc8', s: '#b0a07c' },

  // Library
  HIKS: { f: '#d0e0d4', s: '#8cb498' },

  // Health
  PUSH: { f: '#e4ccd8', s: '#b48898' }, JNSN: { f: '#e0ccd8', s: '#b08898' },

  // Agricultural — green
  ABE:  { f: '#d8e4cc', s: '#98b47c' }, AGAD: { f: '#d4e0cc', s: '#94b07c' },
  ADDL: { f: '#d4e0c8', s: '#90b07c' }, CRTN: { f: '#d4e4c8', s: '#94b478' },
  NLSN: { f: '#d4e0cc', s: '#94b07c' }, WSLR: { f: '#d0e0cc', s: '#90b07c' },
  PFEN: { f: '#d4e0cc', s: '#94b07c' },

  // Cultural centers — lavender
  BCC:  { f: '#dcc8d8', s: '#a888a0' }, AACC: { f: '#dcc8d8', s: '#a888a0' },
  NACC: { f: '#dcc8d8', s: '#a888a0' }, LCCP: { f: '#dcc8d8', s: '#a888a0' },

  // Discovery Park — steel blue
  ADPA: { f: '#ccd8e8', s: '#8498c4' }, ADPB: { f: '#ccd8e8', s: '#8498c4' },
  ADPC: { f: '#ccd8e8', s: '#8498c4' }, CONT: { f: '#ccd8e8', s: '#8498c4' },
  CONV: { f: '#ccd8e8', s: '#8498c4' }, DLR:  { f: '#ccd8e8', s: '#8498c4' },
  DSAI: { f: '#ccd8e8', s: '#8498c4' }, MRGN: { f: '#ccd8e8', s: '#8498c4' },
  KRCH: { f: '#ccd8e8', s: '#8498c4' }, DAUC: { f: '#ccd8e8', s: '#8498c4' },

  // Default — neutral parchment
  _: { f: '#dcd8cc', s: '#acaa9a' },
};

export function bldgStyle(abbr) {
  return BLDG_STYLE[abbr] || BLDG_STYLE._;
}
