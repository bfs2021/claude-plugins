#!/usr/bin/env bash
# test-planner-testdata-rewording.sh — rewording (metamorphic) tests for the
# implied-test-data matcher (_planner_testdata_implied_match), from the
# dispatch-rehearsal block audit. Each criterion is a valid wording a planner
# could write. The verdict must follow the meaning, not the wording:
#   none   — needs nothing to exist first (doc text, commands, status codes,
#            field names, UI copy). A `strong` verdict here is a false positive.
#   strong — needs a record to exist first. Anything else is a miss.
#   known  — a documented false positive (strong although no data is needed).
#            Kept so a fix shows up as a failing "known" line to move to none.
# The criteria that stopped rehearsal runs (F28, F39, F48) are in the none set.
# Prints the false-positive and miss counts.
#
# Run: bash ticket-planner/lib/tests/test-planner-testdata-rewording.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${SCRIPT_DIR}/.."

source "${LIB_DIR}/planner-state.sh"
source "${LIB_DIR}/planner-crosscheck-propagation.sh"
source "${LIB_DIR}/planner-crosscheck-testdata.sh"

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

_tier() { _planner_testdata_implied_match "$1" "" | cut -d$'\037' -f1; }

echo "=== implied test data: rewordings ==="

fp=0 miss=0 n_none=0 n_strong=0
while IFS='|' read -r want crit; do
  [ -n "$want" ] || continue
  case "$want" in \#*) continue ;; esac
  got=$(_tier "$crit")
  case "$want" in
  none)
    n_none=$((n_none + 1))
    if [ "$got" = "strong" ]; then
      fp=$((fp + 1))
      fail "no data needed: $crit" "got strong"
    else
      pass "no data needed ($got): $crit"
    fi
    ;;
  strong)
    n_strong=$((n_strong + 1))
    if [ "$got" = "strong" ]; then
      pass "data needed: $crit"
    else
      miss=$((miss + 1))
      fail "data needed: $crit" "got $got"
    fi
    ;;
  known)
    if [ "$got" = "strong" ]; then
      pass "known false positive (warns): $crit"
    else
      fail "known false positive is fixed — move it to none: $crit" "got $got"
    fi
    ;;
  esac
done <<'CORPUS'
# Document text: what a file says or does not say (F28, F39, F48 and rewordings).
none|A case-insensitive search of the committed `README.md` for `calculator` returns 0 matches.
none|`grep -ri calculator README.md` prints nothing.
none|Running `grep -c calculator README.md` prints `0`.
none|The `README.md` no longer mentions `calculator`.
none|`README.md` does not contain the word `calculator` in any letter case.
none|No line of `README.md` contains `calculator`.
none|`dexter-sandbox/CLAUDE.md` does not contain the text `intentionally empty at the start`
none|The README states that `conduit-dev-secret` is for local use only.
none|The README explains how to start the backend with `npm start`.
none|`.gitignore` lists `node_modules/`.
none|The `package.json` in `backend/` has a `test` script that runs `node --test`.
# Commands, exit codes, status codes, ports, routes.
none|`CLAUDE.md` is unchanged: `git diff --quiet CLAUDE.md` exits 0.
none|`npm test` in `backend/` exits with code 0.
none|After `npm start`, `GET /api/no-such-route` returns status 404.
none|A `GET` request to port 5173 for `/editor` returns the same HTML as `/`.
none|Sign-up with a password of 7 characters returns 422.
# Field names, UI copy, values typed in the test itself.
none|Submitting the sign-up form with an empty `username` shows "username cannot be blank".
none|A blank `email` returns 422.
none|The header shows a "New Article" link when signed in.
none|The editor page has fields `title`, `description` and `body`.
none|Publishing an article titled `My first post` navigates to `/article/my-first-post`.
# Documented false positive: a query parameter's name read as a record.
known|The list endpoint caps `limit` at 100.
# Real data: a named or seeded record, existing state, counts of records.
strong|Signing in with email `jake@example.com` and password `jakejake` redirects to `/`.
strong|The home page lists the seeded article `welcome-to-conduit`.
strong|Given an existing article by `jake`, the article page shows his username.
strong|When there are 3 articles, the home page shows 3 entries.
strong|Signing in as the seeded user `jake` shows the signed-in header.
strong|`GET /api/articles/welcome-to-conduit` returns the seeded article.
strong|The profile page of `jane` lists her 2 articles.
strong|The `welcome-post` article is listed on the home page
CORPUS

echo ""
echo "false positives: ${fp}/${n_none}, misses: ${miss}/${n_strong}"
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
