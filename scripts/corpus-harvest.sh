#!/usr/bin/env bash
# corpus-harvest.sh — select, from the dispatch rehearsal folder, only what
# the corpus replay tests read (seam-bash-derives slice 5), and write it
# UNSCRUBBED to a local tree outside the repository. Then run
# scripts/corpus-scrub.sh on that tree to get the files that are committed.
#
# Usage: scripts/corpus-harvest.sh <rehearsal-dir> <raw-out-dir>
#   <raw-out-dir> must not exist yet. Keep it outside REPOS_ROOT and outside
#   any checkout (the local unscrubbed replay; /ticket-planner doctor refuses a
#   REPOS_ROOT that holds a corpus-raw/MANIFEST.tsv).
#
# Per iteration:
#   s<NN>-run/state.log     the planner state log (iteration 02: the copy taken
#                           at its first Crosscheck)
#   s<NN>-run/specs/*.md    the spec set at Crosscheck, each cut to its slug
#                           heading, ## Title and the test-data synth marker
#                           (all carve scope reads); none for iteration 03,
#                           which kept no spec set
#   s<NN>-draft/<slug>/{scan,audit}-result.txt, dor-result.json
#                           every draft-readiness evaluator result and the
#                           deterministic result the audit is checked against
#                           (iterations 04-09; iteration 06's diagnostic rescan
#                           of project-scaffold as <slug> project-scaffold-diag)
# Left out on purpose: prompts, grill work dirs, telemetry, .hold files,
# negative-control and tainted runs (iteration 05b tainted-run, F46), ticket
# bodies, draft bodies, Crosscheck output and the before-fix copies — no
# replay test reads them yet.
#
# Exit: 0 written; 1 a source file is missing; 2 usage.
set -uo pipefail

[ "$#" -eq 2 ] || {
  echo "usage: corpus-harvest.sh <rehearsal-dir> <raw-out-dir>" >&2
  exit 2
}
R="$1"
OUT="$2"
[ -d "$R" ] || {
  echo "corpus-harvest: not a directory: $R" >&2
  exit 2
}
[ -e "$OUT" ] && {
  echo "corpus-harvest: already exists: $OUT" >&2
  exit 2
}
mkdir -p "$OUT" || exit 1

MARKER='<!-- planner:testdata-synth v1 -->'

# reduce_spec <src> <dst> — slug heading, ## Title and its first line, and
# the synth marker when the spec carries it.
reduce_spec() {
  local src="$1" dst="$2" slug title
  slug=$(basename "$src" .md)
  title=$(awk '/^## Title[[:space:]]*$/ { on = 1; next } on && NF { print; exit }' "$src" | tr -d '\r')
  {
    printf '# %s\n' "$slug"
    grep -qF -- "$MARKER" "$src" && printf '\n%s\n' "$MARKER"
    [ -n "$title" ] && printf '\n## Title\n\n%s\n' "$title"
  } >"$dst"
}

# run <id> <state-log> [<specs-dir>]
run() {
  local log="$2" specs="${3:-}" d="$OUT/$1-run" f
  [ -f "$R/$log" ] || {
    echo "corpus-harvest: missing $R/$log" >&2
    exit 1
  }
  mkdir -p "$d"
  cp "$R/$log" "$d/state.log"
  [ -n "$specs" ] || return 0
  mkdir -p "$d/specs"
  for f in "$R/$specs"/*.md; do
    [ "$(basename "$f")" = INDEX.md ] && continue
    reduce_spec "$f" "$d/specs/$(basename "$f")"
  done
}

# draft <id> <draft-readiness-dir>
draft() {
  local src="$R/$2" d="$OUT/$1-draft" s f
  for s in "$src"/*/; do
    s=$(basename "$s")
    ls "$src/$s"/*-result.txt >/dev/null 2>&1 || continue
    mkdir -p "$d/$s"
    for f in scan-result.txt audit-result.txt dor-result.json; do
      [ -f "$src/$s/$f" ] && cp "$src/$s/$f" "$d/$s/$f"
    done
  done
}

run s01 iter-01/planner/state.log iter-01/planner/artifacts/specs
run s02 iter-02/planner/state-at-crosscheck-1.log iter-02/planner/artifacts-at-crosscheck-1/specs
run s03 iter-03/state.log
run s04 iter-04/state.log
# Iteration 04 kept no spec directory: its draft directories name the specs.
mkdir -p "$OUT/s04-run/specs"
for s in "$R"/iter-04/draft-readiness/*/; do
  [ -f "$s/body.md" ] || continue
  printf '# %s\n' "$(basename "$s")" >"$OUT/s04-run/specs/$(basename "$s").md"
done
run s05 iter-05/state.log iter-05/specs-final
run s05b iter-05b/state.log iter-05b/specs-final
run s06 iter-06/state.log iter-06/specs-final
run s07 iter-07/state.log iter-07/artifacts-at-crosscheck/specs
run s08 iter-08/state.log iter-08/artifacts-at-crosscheck/specs
run s09 iter-09/state.log iter-09/artifacts-at-crosscheck/specs
run s10 iter-10/state.log iter-10/artifacts-at-crosscheck/specs

draft s04 iter-04/draft-readiness
draft s05 iter-05/draft-readiness
draft s05b iter-05b/draft-readiness
draft s06 iter-06/draft-readiness
mkdir -p "$OUT/s06-draft/project-scaffold-diag"
cp "$R/iter-06/diag-scaffold/scan-result.txt" "$R/iter-06/diag-scaffold/audit-result.txt" \
  "$R/iter-06/diag-scaffold/dor-result.json" "$OUT/s06-draft/project-scaffold-diag/" || exit 1
draft s07 iter-07/draft-readiness
draft s08 iter-08/draft-readiness
draft s09 iter-09/draft-readiness

echo "corpus-harvest: $(find "$OUT" -type f | wc -l) file(s), $(du -sb "$OUT" | cut -f1) bytes in ${OUT}"
