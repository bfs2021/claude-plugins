#!/usr/bin/env bash
# ── grill-seal.sh ─────────────────────────────────────────────────────────────
# Intent seal generation and verification for the grill-me readiness gate.
#
# Hash canonicalisation: every byte from offset 0 up to and including the
# newline terminating the line immediately preceding the `**Content-Hash:**`
# line. Consequently all other seal fields (Readiness, Recommendation, etc.)
# fall inside the hashed region.
#
# The Content-Hash line MUST be the last non-empty line of the file.
# Trailing whitespace after the hash line is ignored by verification.
#
# Exports:
#   grill_seal_generate  <doc-path> <work-dir>
#     Appends an ## Intent Seal block whose Profile, Readiness, Recommendation
#     and Rounds come from <work-dir>/result.json, never from arguments.
#     Refuses, writing nothing, when result.json is missing, unparseable, out
#     of contract or behind assessment.json's round, or the file is sealed.
#
# The seal is tamper-evident, not cryptographically signed: the hash is plain
# unkeyed SHA-256, so anyone can re-seal an edited file.
#
#   grill_seal_verify  <doc-path>
#     Exit 0 VALID, 2 missing/unreadable, 3 NO_SEAL, 4 MISMATCH.
#     Emits GRILL_SEAL_STATUS, GRILL_READINESS, GRILL_RECOMMENDATION,
#     GRILL_PROFILE, GRILL_GENERATED as KEY=value on stdout.
# ───────────────────────────────────────────────────────────────────────────────

set -euo pipefail

# Run telemetry (#631, lib/grill-telemetry.sh): silent, best effort, never
# changes a return code. Inactive outside a Claude Code session.
_grill_telemetry_call() {
  [ -n "${CLAUDE_CODE_SESSION_ID:-}" ] || return 0
  local t
  t="$(dirname "${BASH_SOURCE[0]}")/grill-telemetry.sh"
  [ -f "$t" ] && bash "$t" "$@" >/dev/null 2>&1 || true
  return 0
}

# ── grill_seal_generate ───────────────────────────────────────────────────────
# grill_seal_generate <doc-path> <work-dir>
# Seal values are read from <work-dir>/result.json (grill_score's output, after
# any grill_seal_with_gaps_prepare downgrade), never passed in: the agent copies
# nothing into the seal. Generated is stamped here (UTC). Every check runs
# before the document is touched, so a refusal leaves it byte for byte as it
# was. Exit 1 refused (bad call, already sealed, result.json unusable or
# behind assessment.json's round), 2 document not found.
grill_seal_generate() {
  if [ "$#" -ne 2 ]; then
    echo "grill-seal: usage: grill_seal_generate <doc-path> <work-dir> — readiness, recommendation, round and profile come from <work-dir>/result.json, never from arguments; nothing sealed" >&2
    return 1
  fi
  local doc_path="$1" work_dir="$2"
  local result="${work_dir}/result.json"

  if [ ! -f "$doc_path" ]; then
    echo "grill-seal: document not found: ${doc_path}" >&2
    return 2
  fi

  # Refuse to seal an already-sealed file
  if grep -q '^## Intent Seal$' "$doc_path" 2>/dev/null; then
    echo "grill-seal: document already contains an Intent Seal — refusing to double-seal" >&2
    return 1
  fi

  if ! command -v jq >/dev/null 2>&1; then
    echo "grill-seal: jq not available — cannot read ${result}; nothing sealed" >&2
    return 1
  fi
  if [ ! -f "$result" ]; then
    echo "grill-seal: no score: ${result} not found — run grill_score first; nothing sealed" >&2
    return 1
  fi
  local fields=""
  # shellcheck disable=SC2016 # jq program, not shell
  fields=$(jq -r '
      if type == "object"
        and (.profile | type == "string") and (.profile | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$"))
        and (.readiness | type == "number") and (.readiness | floor == .) and .readiness >= 0 and .readiness <= 100
        and (.recommendation | IN("ready", "proceed-with-warnings", "do-not-proceed"))
        and (.round | type == "number") and (.round | floor == .) and .round >= 1
      then [.profile, (.readiness | tostring), .recommendation, (.round | tostring)] | join(" ")
      else empty end' "$result" 2>/dev/null) || fields=""
  if [ -z "$fields" ]; then
    echo "grill-seal: ${result} is unparseable or out of contract (profile id, integer readiness 0-100, known recommendation, round >= 1); nothing sealed" >&2
    return 1
  fi
  local profile readiness recommendation rounds generated
  read -r profile readiness recommendation rounds <<<"$fields"

  # A result.json from an earlier round than the assessment is stale: the
  # agent re-assessed but did not re-score.
  local assessment="${work_dir}/assessment.json" a_round=""
  if [ -f "$assessment" ]; then
    a_round=$(jq -r '.round // 1' "$assessment" 2>/dev/null) || a_round=""
    if [ "$a_round" != "$rounds" ]; then
      echo "grill-seal: ${result} is from round ${rounds} but assessment.json is at round ${a_round:-?} — re-score before sealing; nothing sealed" >&2
      return 1
    fi
  fi
  generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Ensure file ends with exactly one newline
  sed -i -e :a -e '/^\n*$/{$d;N;ba' -e '}' "$doc_path" 2>/dev/null || true
  # Simpler: ensure there's a trailing newline by appending one, then clean up
  # Actually, let's ensure the file ends with a single newline for clean canonicalization.
  # We'll append the seal to the file as-is, then hash.

  # Append the seal block (without Content-Hash first, to compute the hash)
  local seal_block
  seal_block=$(
    cat <<EOF

## Intent Seal

**Grill-Version:** 0.1.0
**Profile:** ${profile}
**Readiness:** ${readiness}
**Recommendation:** ${recommendation}
**Rounds:** ${rounds}
**Generated:** ${generated}
**Content-Hash:**
EOF
  )

  # Write seal placeholder
  printf '%s' "$seal_block" >>"$doc_path"

  # Compute hash over bytes 0 through the newline before Content-Hash
  # The hash input is everything up to and including the newline that
  # terminates the line immediately before **Content-Hash:**.
  # Since Content-Hash is the last line with empty value, we hash up to
  # the newline ending the `**Generated:**` line.
  local hash_input end_byte
  # Find the byte offset of "**Content-Hash:**"
  local ch_line_num
  ch_line_num=$(grep -n '^\*\*Content-Hash:\*\*$' "$doc_path" | tail -1 | cut -d: -f1)

  if [ -z "$ch_line_num" ]; then
    echo "grill-seal: failed to locate Content-Hash line" >&2
    return 1
  fi

  # Hash everything up to and including the line before Content-Hash
  local prev_line=$((ch_line_num - 1))
  # Get byte count through the end of the previous line
  end_byte=$(head -n "$prev_line" "$doc_path" | wc -c)

  # Compute SHA-256
  local hash_val
  hash_val=$(head -c "$end_byte" "$doc_path" | sha256sum | cut -d' ' -f1)

  # Replace the placeholder Content-Hash line with the actual hash
  local tmp="${doc_path}.tmp.$$"
  sed "s/^\*\*Content-Hash:\*\*$/**Content-Hash:** sha256:${hash_val}/" "$doc_path" >"$tmp"
  mv "$tmp" "$doc_path"

  echo "grill-seal: seal generated for ${doc_path} (readiness=${readiness}, rec=${recommendation})" >&2
  _grill_telemetry_call sealed "$doc_path"
  return 0
}

# ── grill_seal_verify ─────────────────────────────────────────────────────────
grill_seal_verify() {
  local doc_path="$1"

  # Exit 2: missing or unreadable file
  if [ ! -f "$doc_path" ]; then
    echo "grill-seal: file not found: ${doc_path}" >&2
    return 2
  fi
  if [ ! -r "$doc_path" ]; then
    echo "grill-seal: file not readable: ${doc_path}" >&2
    return 2
  fi

  # Locate the Content-Hash line
  local ch_line
  ch_line=$(grep -n '^\*\*Content-Hash:\*\* sha256:[a-f0-9]\{64\}$' "$doc_path" | tail -1)

  # Exit 3: no valid seal
  if [ -z "$ch_line" ]; then
    # Check if there's any Intent Seal block at all
    if grep -q '^## Intent Seal$' "$doc_path" 2>/dev/null; then
      echo "grill-seal: Intent Seal present but Content-Hash is malformed" >&2
    else
      echo "grill-seal: no Intent Seal block found" >&2
    fi
    echo "GRILL_SEAL_STATUS=NO_SEAL"
    return 3
  fi

  local ch_line_num
  ch_line_num=$(echo "$ch_line" | cut -d: -f1)

  # Extract recorded hash
  local recorded_hash
  recorded_hash=$(echo "$ch_line" | sed 's/.*sha256://')

  # The hash covers bytes 0 through the newline terminating the line BEFORE Content-Hash
  local prev_line=$((ch_line_num - 1))
  local end_byte
  end_byte=$(head -n "$prev_line" "$doc_path" | wc -c)

  # Recompute
  local computed_hash
  computed_hash=$(head -c "$end_byte" "$doc_path" | sha256sum | cut -d' ' -f1)

  if [ "$computed_hash" != "$recorded_hash" ]; then
    echo "GRILL_SEAL_STATUS=MISMATCH"
    return 4
  fi

  # Extract metadata from seal — seal block is at end of file, scan from ## Intent Seal to EOF
  local seal_readiness seal_rec seal_profile seal_generated
  seal_readiness=$(sed -n '/^## Intent Seal$/,$s/^\*\*Readiness:\*\* //p' "$doc_path" | head -1)
  seal_rec=$(sed -n '/^## Intent Seal$/,$s/^\*\*Recommendation:\*\* //p' "$doc_path" | head -1)
  seal_profile=$(sed -n '/^## Intent Seal$/,$s/^\*\*Profile:\*\* //p' "$doc_path" | head -1)
  seal_generated=$(sed -n '/^## Intent Seal$/,$s/^\*\*Generated:\*\* //p' "$doc_path" | head -1)

  echo "GRILL_SEAL_STATUS=VALID"
  echo "GRILL_READINESS=${seal_readiness}"
  echo "GRILL_RECOMMENDATION=${seal_rec}"
  echo "GRILL_PROFILE=${seal_profile}"
  echo "GRILL_GENERATED=${seal_generated}"

  return 0
}

# If executed directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ $# -lt 2 ]; then
    echo "Usage:" >&2
    echo "  grill-seal.sh generate <doc> <work-dir>" >&2
    echo "  grill-seal.sh verify <doc>" >&2
    exit 1
  fi

  case "$1" in
  generate)
    shift
    grill_seal_generate "$@"
    ;;
  verify)
    shift
    grill_seal_verify "$@"
    ;;
  *)
    echo "grill-seal: unknown command '$1' — use generate or verify" >&2
    exit 1
    ;;
  esac
fi
