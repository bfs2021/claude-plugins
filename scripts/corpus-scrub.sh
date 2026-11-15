#!/usr/bin/env bash
# corpus-scrub.sh — copy real planner output into a corpus tree with every
# private token replaced by one deterministic token map (seam-bash-derives
# slice 5). The corpus lives in a public repository, so this runs on every
# harvest, before anything is copied under ticket-planner/lib/tests/corpus/.
#
# Usage: scripts/corpus-scrub.sh <src-dir> <dst-dir>
#   <src-dir>  unscrubbed tree (a local harvest, outside the repository)
#   <dst-dir>  must not exist yet, or be empty
#
# The map, applied to file contents and to relative file names alike:
#   1. Values replaced by a fake derived from sha256("corpus-scrub-v1:<kind>:<value>"),
#      so the same value always gets the same fake, in every file and every run:
#        INIT-<ts>-<n> / init-<ts>-<n>   → INIT-0000000000-<4 digits> (case kept)
#        UUIDs                           → a fake UUID
#        40-hex commit shas              → a fake 40-hex value
#        e-mails outside conduit.test and example.{com,org,net} → redacted@example.com
#   2. Fixed rewrites, in this order:
#        token-shaped strings (sk-ant-, lin_api_, gh?_, github_pat_, glpat-,
#        xox?-, AKIA…, JWTs)                     → REDACTED-TOKEN
#        linear.app URLs                         → https://tracker.example/issue
#        <owner>/<sandbox>, <sandbox>, <owner>   → owner/app, app, owner
#        /home/<user>, /Users/<user>             → ~
#        -home-<user>- (dash-encoded paths)      → -homedir-
#        <KEY>-<n> tracker ids, a bare <KEY>       → TKT-<n>, TKT
#        private names (whole words, any case)   → user
#
# Then scripts/corpus-rehash.sh <dst-dir> recomputes BODY_HASH and
# revise.r<N>.sha, which the rewrite invalidated.
#
# Env (defaults are the rehearsal sandbox's values; override for another one):
#   CORPUS_SCRUB_TRACKER_KEYS  space-separated tracker keys (default "WIL")
#   CORPUS_SCRUB_OWNER         repository owner (default "willard-pro")
#   CORPUS_SCRUB_SANDBOX       sandbox repository name (default "dexter-sandbox")
#   CORPUS_SCRUB_NAMES         private names, whole words (default "dexter mortal willard")
#
# A scrub is not a privacy check: test-corpus-privacy.sh is, and runs in CI.
# Read what you harvest; leave out a file you cannot confidently scrub.
#
# Exit: 0 written; 1 refused (binary file, symlink, unsafe name, fake
# collision, write failure); 2 usage.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SALT="corpus-scrub-v1"
TRACKER_KEYS="${CORPUS_SCRUB_TRACKER_KEYS:-WIL}"
OWNER="${CORPUS_SCRUB_OWNER:-willard-pro}"
SANDBOX="${CORPUS_SCRUB_SANDBOX:-dexter-sandbox}"
NAMES="${CORPUS_SCRUB_NAMES:-dexter mortal willard}"
EMAIL_ALLOW='@(conduit\.test|example\.(com|org|net))$'

usage() {
  echo "usage: corpus-scrub.sh <src-dir> <dst-dir>" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
SRC="$1"
DST="$2"
[ -d "$SRC" ] || {
  echo "corpus-scrub: not a directory: $SRC" >&2
  exit 2
}
if [ -e "$DST" ] && [ -n "$(find "$DST" -mindepth 1 -print -quit 2>/dev/null)" ]; then
  echo "corpus-scrub: destination exists and is not empty: $DST" >&2
  exit 2
fi
SRC=$(cd "$SRC" && pwd)

# _fake <kind> <value> — the deterministic fake for one value.
_fake() {
  local h
  h=$(printf '%s:%s:%s' "$SALT" "$1" "$2" | sha256sum | cut -c1-64)
  case "$1" in
  init) printf '%04d' $((16#${h:0:8} % 10000)) ;;
  uuid) printf '%s-%s-%s-%s-%s' "${h:0:8}" "${h:8:4}" "${h:12:4}" "${h:16:4}" "${h:20:12}" ;;
  sha1) printf '%s' "${h:0:40}" ;;
  esac
}

# _lit <text> — escape a literal for an ERE pattern.
_lit() { printf '%s' "$1" | sed -e 's/[][\.*^$+?(){}|/#]/\\&/g'; }

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
FILES="$WORK/files"
SCRIPT="$WORK/map.sed"

# Every regular file, NUL-delimited, sorted. Symlinks and odd names refused.
(cd "$SRC" && find . -mindepth 1 \( -type l -o \( ! -type f ! -type d \) \) -print) >"$WORK/bad"
if [ -s "$WORK/bad" ]; then
  echo "corpus-scrub: refusing symlinks or special files:" >&2
  sed 's/^/  /' "$WORK/bad" >&2
  exit 1
fi
(cd "$SRC" && find . -type f -print0 | sort -z) >"$FILES"
bad_name=0
while IFS= read -r -d '' f; do
  case "$f" in *$'\n'* | *$'\r'*) bad_name=1 ;; esac
  if [ -s "$SRC/$f" ] && ! grep -Iq . "$SRC/$f"; then
    echo "corpus-scrub: refusing binary file: ${f#./}" >&2
    bad_name=1
  fi
done <"$FILES"
[ "$bad_name" -eq 0 ] || exit 1

# All text the map is computed from: contents plus relative names.
ALL="$WORK/all"
{
  while IFS= read -r -d '' f; do
    cat "$SRC/$f"
    printf '\n%s\n' "${f#./}"
  done <"$FILES"
} >"$ALL"

: >"$SCRIPT"
declare -A seen_init=()
collide=0
# INIT ids: one fake per <ts>-<n>, case kept. Already-fake ids are left alone.
while IFS= read -r id; do
  [ -n "$id" ] || continue
  num="${id#*-}"
  case "$num" in 0000000000-*) continue ;; esac
  fake=$(_fake init "$num")
  if [ -n "${seen_init[$fake]:-}" ] && [ "${seen_init[$fake]}" != "$num" ]; then
    echo "corpus-scrub: fake collision for two initiative ids (${seen_init[$fake]}, ${num})" >&2
    collide=1
  fi
  seen_init[$fake]="$num"
  printf 's/\\bINIT-%s\\b/INIT-0000000000-%s/g\n' "$(_lit "$num")" "$fake" >>"$SCRIPT"
  printf 's/\\binit-%s\\b/init-0000000000-%s/g\n' "$(_lit "$num")" "$fake" >>"$SCRIPT"
done < <(grep -ohiE '\binit-[0-9]{6,}-[0-9]+\b' "$ALL" | tr '[:upper:]' '[:lower:]' | sort -u)
[ "$collide" -eq 0 ] || exit 1

while IFS= read -r v; do
  [ -n "$v" ] || continue
  printf 's/%s/%s/g\n' "$(_lit "$v")" "$(_fake uuid "$(tr '[:upper:]' '[:lower:]' <<<"$v")")" >>"$SCRIPT"
done < <(grep -ohE '\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b' "$ALL" | sort -u)

while IFS= read -r v; do
  [ -n "$v" ] || continue
  [ "$v" = "0000000000000000000000000000000000000000" ] && continue
  printf 's/\\b%s\\b/%s/g\n' "$v" "$(_fake sha1 "$v")" >>"$SCRIPT"
done < <(grep -ohE '\b[0-9a-f]{40}\b' "$ALL" | sort -u)

while IFS= read -r v; do
  [ -n "$v" ] || continue
  printf 's/%s/redacted@example.com/g\n' "$(_lit "$v")" >>"$SCRIPT"
done < <(grep -ohE '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$ALL" | sort -u | grep -viE "$EMAIL_ALLOW")

{
  echo 's/(sk-ant-|lin_api_|gh[pousr]_|github_pat_|glpat-|xox[abp]-)[A-Za-z0-9_-]{6,}/REDACTED-TOKEN/g'
  echo 's/AKIA[0-9A-Z]{16}/REDACTED-TOKEN/g'
  echo 's/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/REDACTED-TOKEN/g'
  echo 's#https?://linear\.app/[^] )>"'"'"'`]*#https://tracker.example/issue#g'
  printf 's/%s\\/%s/owner\\/app/g\n' "$(_lit "$OWNER")" "$(_lit "$SANDBOX")"
  printf 's/%s/app/g\n' "$(_lit "$SANDBOX")"
  printf 's/%s/APP/g\n' "$(_lit "$(tr '[:lower:]-' '[:upper:]_' <<<"$SANDBOX")")"
  printf 's/%s/app/g\n' "$(_lit "$(tr '-' '_' <<<"$SANDBOX")")"
  printf 's/%s/owner/g\n' "$(_lit "$OWNER")"
  echo 's#/home/[A-Za-z0-9_.-]+#~#g'
  echo 's#/Users/[A-Za-z0-9_.-]+#~#g'
  echo 's/-home-[A-Za-z0-9_.]+-/-homedir-/g'
  for k in $TRACKER_KEYS; do
    printf 's/\\b%s-([0-9]+)\\b/TKT-\\1/g\n' "$(_lit "$k")"
    printf 's/\\b%s\\b/TKT/g\n' "$(_lit "$k")"
  done
  for n in $NAMES; do
    printf 's/\\b%s\\b/user/gI\n' "$(_lit "$n")"
  done
} >>"$SCRIPT"

mkdir -p "$DST" || exit 1
DST=$(cd "$DST" && pwd)
declare -A dst_seen=()
while IFS= read -r -d '' f; do
  rel="${f#./}"
  out=$(printf '%s' "$rel" | sed -E -f "$SCRIPT")
  case "$out" in /* | ../* | */../* | *..) out="" ;; esac
  if [ -z "$out" ] || [ -n "${dst_seen[$out]:-}" ]; then
    echo "corpus-scrub: unsafe or colliding name after the map: ${rel}" >&2
    exit 1
  fi
  dst_seen[$out]=1
  mkdir -p "$(dirname "$DST/$out")" || exit 1
  sed -E -f "$SCRIPT" "$SRC/$f" >"$DST/$out" || exit 1
done <"$FILES"

bash "$HERE/corpus-rehash.sh" "$DST" || exit 1
echo "corpus-scrub: $(tr -cd '\0' <"$FILES" | wc -c) file(s) written to ${DST}"
