unit RsmTags;

// Named constants for the Delphi `.rsm` (Remote Symbol Map) byte tags
// reverse-engineered for Athens 36 Win64. Centralising them here keeps the
// magic out of the body of every parser pass and makes additions (new dcc64
// record kinds) a single-line edit. See RSM_FORMAT_NOTES.md and
// RSM_RECORD_TYPES.md for the structural meaning of each tag.

interface

const
  // Symbol-section category prefix. Always followed by a sub-tag.
  TAG_SYM_CATEGORY     = $63;

  // Sub-tags that follow TAG_SYM_CATEGORY (`63 XX ...`).
  SUBTAG_GLOBAL_VAR    = $20;   // 63 20 -- global variable
  SUBTAG_PROCEDURE     = $28;   // 63 28 -- top-level procedure
  SUBTAG_USES_CLAUSE   = $35;   // 63 35 -- inner uses-clause unit ref
  SUBTAG_PER_UNIT_REF  = $64;   // 63 64 -- per-unit imports sub-record
  SUBTAG_EH            = $9E;   // 63 9E -- exception-handling record

  // Local / parameter variable tags (no $63 prefix; appear standalone
  // between procedure header and the next $63 marker).
  TAG_LOCAL_VAR        = $20;
  TAG_LOCAL_CONSTPARAM = $21;
  TAG_LOCAL_VARPARAM   = $22;
  TAG_LOCAL_OUTPARAM   = $23;

  // Class-section tags (in the trailing class-decl section of the RSM).
  TAG_CLASS_DECL       = $2A;
  TAG_CLASS_FIELD      = $2C;
  TAG_CLASS_METHOD     = $2E;
  TAG_CLASS_PROPERTY   = $31;

  // Imports area tags.
  TAG_UNIT_REF_GLOBAL  = $65;   // EXE-main module's System reference
  TAG_UNIT_REF_PER_UNIT= $64;   // per-unit System reference
  TAG_TYPE_REF         = $66;
  TAG_FUNC_REF         = $67;
  TAG_TYPE_REF_ALT     = $68;
  TAG_TYPE_ALIAS       = $6E;
  TAG_UNIT_PATH        = $70;

  // Type-marker bytes after a local-var name.
  TYPEREF_MARKER       = $66;
  TYPEREF_MARKER_MAIN  = $46;
  TYPEREF_MARKER_CONST = $62;

  // Class-member record interior bytes.
  TAG_FIELD_HASH_PREFIX  = $9C; // followed by $09 (1-byte typeId) or $01 (2-byte)
  TAG_METHOD_HASH_PREFIX = $E2;
  TAG_PROP_HASH_PREFIX   = $80; // after FE 0F 00 00 00 marker
  TAG_HASH_ANCHOR        = $08; // ... $08 hashLo hashHi $FF
  TAG_RECORD_TERMINATOR  = $FF;

  // Constants record.
  TAG_NAMED_CONST      = $25;

  // Type declaration variant fillers (filler[0] at +N+0 of a $2A record).
  VARIANT_A_FILLER     = $20;  // suffix $1E at +N+7, advance N+10
  VARIANT_B_FILLER     = $40;  // $00 at +N+5, advance N+8
  VARIANT_C_FILLER     = $20;  // suffix $1F at +N+7, advance N+10
  VARIANT_D_FILLER     = $A8;  // variable trailer, advance N+7 (conservative)
  VARIANT_E_FILLER_1   = $20;  // no $1E/$1F suffix, advance N+10
  VARIANT_E_FILLER_2   = $40;
  VARIANT_F_FILLER     = $18;  // type-alias, variable trailer
  VARIANT_A_SUFFIX     = $1E;
  VARIANT_C_SUFFIX     = $1F;

  // 8-byte TTypeInfo prefix that anchors embedded TypeInfo records.
  TYPEINFO_PREFIX_BYTE = $08;

implementation

end.
