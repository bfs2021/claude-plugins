#!/usr/bin/env bash
# corpus-rehash.sh — recompute the hashes a corpus scrub invalidates
# (seam-bash-derives slice 5). Rewriting a draft body (an initiative id in a
# sibling slug, a tracker id) changes its hash, so every recorded copy of that
# hash is recomputed here with the pipeline's own functions, never patched by
# hand:
#
#   BODY_HASH: lines of *-result*.txt next to a body.md
#       → ticket-auto-pipeline's _dor_body_hash "$(cat body.md)", the value
#         dor_semantic_prompt records for the body the agent read
#   body_hash of *.request.json next to a body.md → the same value
#   revise.r<N>.sha next to revise.r<N>.md
#       → sha256sum of the revise file, as planner_draft_revise_finish writes it
#
# A result file with no body.md beside it keeps its hash and is counted as
# "kept" in the summary: there is nothing to recompute it from.
#
# Usage: scripts/corpus-rehash.sh <dir>
# Exit: 0 done; 1 a hash could not be computed or written; 2 usage.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[ "$#" -eq 1 ] && [ -d "$1" ] || {
  echo "usage: corpus-rehash.sh <dir>" >&2
  exit 2
}
DIR="$1"

# shellcheck source=/dev/null
source "$ROOT/ticket-auto-pipeline/lib/dor-check.sh" || exit 1
declare -F _dor_body_hash >/dev/null || {
  echo "corpus-rehash: _dor_body_hash not found in dor-check.sh" >&2
  exit 1
}

n_body=0
n_kept=0
n_req=0
n_sha=0
while IFS= read -r -d '' f; do
  d=$(dirname "$f")
  if [ ! -f "$d/body.md" ]; then
    grep -q '^[[:space:]]*BODY_HASH[[:space:]]*:' "$f" && n_kept=$((n_kept + 1))
    continue
  fi
  grep -q '^[[:space:]]*BODY_HASH[[:space:]]*:' "$f" || continue
  h=$(_dor_body_hash "$(cat "$d/body.md")")
  [ -n "$h" ] || exit 1
  sed -E -i "s/^([[:space:]]*BODY_HASH[[:space:]]*:[[:space:]]*)sha256:[0-9a-fA-F]*/\1${h}/" "$f" || exit 1
  n_body=$((n_body + 1))
done < <(find "$DIR" -type f -name '*-result*.txt' -print0 | sort -z)

while IFS= read -r -d '' f; do
  d=$(dirname "$f")
  [ -f "$d/body.md" ] || continue
  h=$(_dor_body_hash "$(cat "$d/body.md")")
  [ -n "$h" ] || exit 1
  jq -e 'type == "object" and has("body_hash")' "$f" >/dev/null 2>&1 || continue
  jq --arg h "$h" '.body_hash = $h' "$f" >"$f.tmp" && mv "$f.tmp" "$f" || exit 1
  n_req=$((n_req + 1))
done < <(find "$DIR" -type f -name '*.request.json' -print0 | sort -z)

while IFS= read -r -d '' f; do
  md="${f%.sha}.md"
  [ -f "$md" ] || continue
  sha256sum <"$md" | cut -d' ' -f1 >"$f" || exit 1
  n_sha=$((n_sha + 1))
done < <(find "$DIR" -type f -name 'revise.r*.sha' -print0 | sort -z)

echo "corpus-rehash: BODY_HASH ${n_body} recomputed, ${n_kept} kept (no body.md); request ${n_req}; revise sha ${n_sha}"
