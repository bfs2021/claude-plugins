#!/usr/bin/env bash
# test-corpus-privacy.sh — the corpus of real planner output sits in a public
# repository (seam-bash-derives slice 5). This gate fails on any file, or file
# name, under a `*/lib/tests/corpus/` directory that holds:
#   - a tracker issue id (WIL-<n>) or a linear.app URL
#   - a real initiative id (INIT-<ts>-<n> whose timestamp is not the scrub's
#     0000000000), in either case
#   - a home directory path (/home/<user>, /Users/<user>, -home-<user>-)
#   - the sandbox repository or owner name, or a private name
#   - a token-shaped string (sk-ant-, lin_api_, gh?_, github_pat_, glpat-,
#     xox?-, AKIA…, a JWT)
#   - an e-mail address outside conduit.test and example.{com,org,net}
# It then plants one leak of each kind in a copy of a clean file and checks
# that the scan reports every one, so a weakened pattern fails here too.
#
# scripts/corpus-scrub.sh is the tool that removes these; this is the check.
#
# Run: bash ticket-planner/lib/tests/test-corpus-privacy.sh
#   CORPUS_PRIVACY_DIRS="<dir> …" scans those directories instead.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"

PASS=0
FAIL=0
pass() {
  echo "  PASS $1"
  PASS=$((PASS + 1))
}
fail() {
  echo "  FAIL $1: $2"
  FAIL=$((FAIL + 1))
}

# One extended regex per leak kind (grep -E, case-insensitive). Kept in sync
# with scripts/corpus-scrub.sh's map.
CORPUS_DENY=(
  'tracker-id|\bWIL(-[0-9]+)?\b'
  'tracker-url|linear\.app/'
  'initiative-id|\binit-[1-9][0-9]{5,}-[0-9]+'
  'home-path|/home/[a-z0-9_]|/Users/[a-z0-9_]|-home-[a-z0-9_]+-'
  'private-name|\b(dexter|mortal|willard|rogueprocess[0-9]*)\b|dexter-sandbox|willard-pro'
  'token|sk-ant-|lin_api_|\bgh[pousr]_[a-z0-9]{6,}|github_pat_|glpat-|\bxox[abp]-|\bakia[0-9a-z]{16}\b|\beyj[a-z0-9_-]{10,}\.[a-z0-9_-]{10,}\.'
)
CORPUS_EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
CORPUS_EMAIL_ALLOW='@(conduit\.test|example\.(com|org|net))$'

# corpus_privacy_scan <dir> — print one `<kind>\t<file>[:<line>]\t<match>`
# per leak (contents and relative file names); rc 1 when any.
corpus_privacy_scan() {
  local dir="$1" entry kind re out="" hits
  for entry in "${CORPUS_DENY[@]}"; do
    kind="${entry%%|*}"
    re="${entry#*|}"
    hits=$(grep -rnoiIE "$re" "$dir" 2>/dev/null | sed "s/^/${kind}\t/")
    [ -n "$hits" ] && out="${out}${hits}"$'\n'
    hits=$(cd "$dir" && find . -mindepth 1 | grep -iE "$re" | sed "s/^/${kind}\tname\t/")
    [ -n "$hits" ] && out="${out}${hits}"$'\n'
  done
  hits=$(grep -rnoIE "$CORPUS_EMAIL_RE" "$dir" 2>/dev/null | grep -viE "$CORPUS_EMAIL_ALLOW" | sed "s/^/email\t/")
  [ -n "$hits" ] && out="${out}${hits}"$'\n'
  printf '%s' "$out"
  [ -z "$out" ]
}

echo "=== corpus privacy (seam-bash-derives) ==="

if [ -n "${CORPUS_PRIVACY_DIRS:-}" ]; then
  read -r -a DIRS <<<"$CORPUS_PRIVACY_DIRS"
else
  mapfile -t DIRS < <(find "$REPO_ROOT" -maxdepth 5 -name .git -prune -o -type d -path '*/lib/tests/corpus' -print | sort)
fi

echo "--- every corpus directory is clean ---"
if [ "${#DIRS[@]}" -eq 0 ]; then
  fail "a corpus directory exists" "none found under ${REPO_ROOT}"
fi
for d in "${DIRS[@]}"; do
  rel="${d#"${REPO_ROOT}"/}"
  if leaks=$(corpus_privacy_scan "$d"); then
    pass "${rel}: no private data ($(find "$d" -type f | wc -l) files)"
  else
    fail "${rel}: private data" "$(head -20 <<<"$leaks")"
  fi
done

# ── planted leaks: the scan must see each kind ──────────────────────────────
echo "--- a planted leak of each kind is reported ---"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/clean"
printf '%s\n' '2026-11-15T12:16:26Z|META|initiative-id|start|INIT-0000000000-0001' \
  'Sign in as jake@conduit.test or admin@example.com; repo app, owner owner, TKT-12.' \
  'Path ~/workspace/e2e-conduit/app and /home/ is not a user.' >"$WORK/clean/state.log"
if corpus_privacy_scan "$WORK/clean" >/dev/null; then
  pass "the scrub's own fakes and allowlisted e-mails pass"
else
  fail "the scrub's own fakes and allowlisted e-mails pass" "$(corpus_privacy_scan "$WORK/clean")"
fi

plant() {
  local name="$1" kind="$2" text="$3" d="$WORK/plant-$1"
  rm -rf "$d"
  cp -r "$WORK/clean" "$d"
  printf '%s\n' "$text" >>"$d/state.log"
  local out
  out=$(corpus_privacy_scan "$d")
  if grep -q "^${kind}"$'\t' <<<"$out"; then
    pass "planted ${name} is reported as ${kind}"
  else
    fail "planted ${name} is reported as ${kind}" "scan said: ${out:-nothing}"
  fi
}
plant tracker-id tracker-id 'blocked-by:WIL-131'
plant team-key tracker-id "cannot resolve Linear team (ref='WIL')"
plant tracker-url tracker-url 'see https://linear.app/acme/issue/TKT-1/x'
plant initiative-id initiative-id 'INIT-1794744986-6851 abandoned'
plant initiative-slug initiative-id 'specs/init-1794584184-3869-test-data-pack.md'
plant home-path home-path 'cd /home/alice/workspace'
plant mac-home home-path 'open /Users/alice/repo'
plant dash-home home-path '/tmp/claude-1000/-home-alice-workspace-x'
plant sandbox private-name 'git clone dexter-sandbox'
plant owner private-name 'github.com/willard-pro/x'
plant name private-name 'ran by Mortal on the host'
plant anthropic-key token 'ANTHROPIC_API_KEY=sk-ant-api03-abcdef'
plant linear-key token 'LINEAR_API_KEY=lin_api_abcdef123456'
plant github-pat token 'token ghp_abcdefghijkl1234'
plant jwt token 'Authorization: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJqYWtlIn0.abcdefghijklmn'
plant email email 'contact john.doe@gmail.com'
plant truncated-email email 'login as newauthor@conduit.te'

d="$WORK/plant-name"
rm -rf "$d"
cp -r "$WORK/clean" "$d"
mkdir -p "$d/WIL-120"
: >"$d/WIL-120/body.md"
if grep -q $'^tracker-id\tname' <<<"$(corpus_privacy_scan "$d")"; then
  pass "a tracker id in a file name is reported"
else
  fail "a tracker id in a file name is reported" "$(corpus_privacy_scan "$d")"
fi

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
