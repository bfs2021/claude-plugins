#!/usr/bin/env bash
# Tests for scripts/corpus-scrub.sh and scripts/corpus-rehash.sh
# (seam-bash-derives slice 5) on a small synthetic tree shaped like a
# rehearsal harvest: the token map, determinism, renamed paths, the rehash,
# and the refusals. The scrubbed tree must also pass test-corpus-privacy.sh.
set -uo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRUB="$ROOT/scripts/corpus-scrub.sh"
PRIVACY="$ROOT/ticket-planner/lib/tests/test-corpus-privacy.sh"
PASS=0
FAIL=0
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
# Synthetic private tokens: the real ones live only in a local, uncommitted
# names file. Scrub and privacy test both read this one.
export CORPUS_PRIVATE_NAMES_FILE="$TMP/names"
printf '%s\n' '# synthetic' 'owner acme-corp' 'sandbox zorblax-sandbox' 'tracker ZRB' 'name zorblax' \
  'path ~/zorb/space/ ~/work/' >"$CORPUS_PRIVATE_NAMES_FILE"

ok() {
  PASS=$((PASS + 1))
  echo "  PASS: $1"
}
bad() {
  FAIL=$((FAIL + 1))
  echo "  FAIL: $1"
}

# shellcheck source=/dev/null
source "$ROOT/ticket-auto-pipeline/lib/dor-check.sh"

echo "=== corpus-scrub / corpus-rehash ==="

# ── a raw tree with one of every private token ──────────────────────────────
RAW="$TMP/raw"
D="$RAW/iter-05/draft-readiness/init-1794584184-3869-test-data-pack"
mkdir -p "$D" "$RAW/iter-05/specs"
cat >"$RAW/iter-05/state.log" <<'EOF'
2026-11-13T10:00:00Z|META|initiative-id|start|INIT-1794584184-3869
2026-11-13T10:00:01Z|META|discovery|repo-ref|zorblax-sandbox@main@0123456789abcdef0123456789abcdef01234567
2026-11-13T10:00:02Z|Specify|synthesize|start|Writing specs in /home/alice/zorb/space/e2e-conduit/zorblax-sandbox
2026-11-13T10:00:03Z|META|ticketgen|step|Created ZRB-131 (8f14e45f-ceea-467a-9575-6a2fba8f6b17) https://linear.app/acme/issue/ZRB-131/x
2026-11-13T10:00:04Z|META|note|done|cloned github.com/acme-corp/zorblax-sandbox as ZORBLAX_SANDBOX; scratch /tmp/c/-home-alice-zorb-space-x
2026-11-13T10:00:05Z|META|note|done|key sk-ant-api03-abcdefgh lin_api_abcdefgh1234; mail ops.person@gmail.com, jake@conduit.test, admin@example.com
2026-11-13T10:00:06Z|META|note|done|team ref='ZRB'; run by Zorblax; sibling init-1794584184-3869-test-data-pack; commit 0123456789abcdef0123456789abcdef01234567
EOF
printf '# init-1794584184-3869-test-data-pack\n\nSeeds jake@conduit.test for ZRB-131 in zorblax-sandbox.\n' >"$D/body.md"
RAW_HASH=$(_dor_body_hash "$(cat "$D/body.md")")
printf '=== DOR_SEMANTIC_SCAN ===\nSCHEMA_VERSION: 1\nTICKET: DRAFT-init-1794584184-3869-test-data-pack\nBODY_HASH: %s\nPARAPHRASE: Seed data.\n=== END DOR_SEMANTIC_SCAN ===\n' "$RAW_HASH" >"$D/scan-result.txt"
printf '{"version":1,"kind":"scan","ticket":"DRAFT-x","body_hash":"%s","attempt":1,"result_file":"scan-result.txt"}\n' "$RAW_HASH" >"$D/scan-result.request.json"
printf 'RESOLVED 1 — in zorblax-sandbox\n' >"$D/revise.r1.md"
sha256sum <"$D/revise.r1.md" | cut -d' ' -f1 >"$D/revise.r1.sha"
mkdir -p "$RAW/iter-06/orphan"
printf '=== DOR_SEMANTIC_AUDIT ===\nBODY_HASH: %s\n=== END DOR_SEMANTIC_AUDIT ===\n' "$RAW_HASH" >"$RAW/iter-06/orphan/audit-result.txt"

OUT="$TMP/out"
if bash "$SCRUB" "$RAW" "$OUT" >"$TMP/scrub.log" 2>&1; then
  ok "scrub exits 0"
else
  bad "scrub exits 0 ($(cat "$TMP/scrub.log"))"
fi
LOG="$OUT/iter-05/state.log"
DD=$(find "$OUT" -type d -name 'init-0000000000-*-test-data-pack')

# ── the map ─────────────────────────────────────────────────────────────────
fake=$(grep -o 'INIT-0000000000-[0-9]\{4\}' "$LOG" | head -1)
if [ -n "$fake" ] && grep -q "sibling init-0000000000-${fake##*-}-test-data-pack" "$LOG"; then
  ok "INIT ids get one fake, case kept ($fake)"
else
  bad "INIT ids get one fake, case kept: $(grep -io 'init-[0-9-]*' "$LOG" | sort -u | tr '\n' ' ')"
fi
if [ -n "$DD" ] && [ "$(basename "$DD")" = "init-0000000000-${fake##*-}-test-data-pack" ]; then
  ok "a directory name gets the same fake as the text"
else
  bad "a directory name gets the same fake as the text: $(find "$OUT" -type d | tr '\n' ' ')"
fi
if grep -q 'Created TKT-131 ' "$LOG" && ! grep -q 'ZRB-' "$LOG"; then
  ok "tracker ids become TKT-<n>"
else
  bad "tracker ids become TKT-<n>"
fi
if grep -q 'https://tracker.example/issue' "$LOG" && ! grep -q 'linear.app' "$LOG"; then
  ok "linear.app URLs are replaced"
else
  bad "linear.app URLs are replaced"
fi
if grep -q 'Writing specs in ~/work/e2e-conduit/app$' "$LOG" && grep -q '/tmp/c/-homedir-work-x' "$LOG"; then
  ok "home paths become ~ and -homedir-, a listed prefix becomes ~/work/; the sandbox becomes app"
else
  bad "home paths become ~ and -homedir-, a listed prefix becomes ~/work/; the sandbox becomes app: $(sed -n '3p;5p' "$LOG")"
fi
if grep -q 'github.com/owner/app as APP' "$LOG" && grep -q 'repo-ref|app@main@' "$LOG"; then
  ok "owner/sandbox, upper-case sandbox and repo-ref are mapped"
else
  bad "owner/sandbox, upper-case sandbox and repo-ref are mapped: $(sed -n '2p;5p' "$LOG")"
fi
if grep -q "team ref='TKT'; run by user;" "$LOG"; then
  ok "a private name becomes user, any case; a bare tracker key becomes TKT"
else
  bad "a private name becomes user, any case: $(sed -n '7p' "$LOG")"
fi
if grep -q 'key REDACTED-TOKEN REDACTED-TOKEN;' "$LOG"; then
  ok "token-shaped strings are redacted"
else
  bad "token-shaped strings are redacted: $(sed -n '6p' "$LOG")"
fi
if grep -q 'mail redacted@example.com, jake@conduit.test, admin@example.com' "$LOG"; then
  ok "only e-mails outside the allowlist are replaced"
else
  bad "only e-mails outside the allowlist are replaced: $(sed -n '6p' "$LOG")"
fi
sha_a=$(sed -n '2s/.*@main@//p' "$LOG")
sha_b=$(sed -n '7s/.*commit //p' "$LOG")
if [ "$sha_a" = "$sha_b" ] && [ "$sha_a" != "0123456789abcdef0123456789abcdef01234567" ] && [[ "$sha_a" =~ ^[0-9a-f]{40}$ ]] &&
  ! grep -q '8f14e45f-ceea' "$LOG" && grep -qE '\([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\)' "$LOG"; then
  ok "commit shas and UUIDs get consistent fakes"
else
  bad "commit shas and UUIDs get consistent fakes: $sha_a / $sha_b"
fi

# ── rehash ──────────────────────────────────────────────────────────────────
want=$(_dor_body_hash "$(cat "$DD/body.md")")
if [ "$want" != "$RAW_HASH" ] && grep -qxF "BODY_HASH: $want" "$DD/scan-result.txt"; then
  ok "BODY_HASH is recomputed from the scrubbed body with _dor_body_hash"
else
  bad "BODY_HASH is recomputed: want $want, got $(grep BODY_HASH "$DD/scan-result.txt")"
fi
if [ "$(jq -r .body_hash "$DD/scan-result.request.json")" = "$want" ]; then
  ok "a spawn request's body_hash is recomputed"
else
  bad "a spawn request's body_hash is recomputed: $(cat "$DD/scan-result.request.json")"
fi
if [ "$(cat "$DD/revise.r1.sha")" = "$(sha256sum <"$DD/revise.r1.md" | cut -d' ' -f1)" ] && grep -q 'in app$' "$DD/revise.r1.md"; then
  ok "revise.r<N>.sha matches the scrubbed revise file"
else
  bad "revise.r<N>.sha matches the scrubbed revise file"
fi
if grep -qxF "BODY_HASH: $RAW_HASH" "$OUT/iter-06/orphan/audit-result.txt" && grep -q '1 kept' "$TMP/scrub.log"; then
  ok "a result with no body.md keeps its hash and is counted as kept"
else
  bad "a result with no body.md keeps its hash: $(cat "$TMP/scrub.log")"
fi

# ── determinism and privacy ─────────────────────────────────────────────────
bash "$SCRUB" "$RAW" "$TMP/out2" >/dev/null 2>&1
if diff -r "$OUT" "$TMP/out2" >/dev/null; then
  ok "two scrubs of the same tree are byte-identical"
else
  bad "two scrubs of the same tree are byte-identical: $(diff -r "$OUT" "$TMP/out2" | head -5)"
fi
if CORPUS_PRIVACY_DIRS="$OUT" bash "$PRIVACY" >"$TMP/priv.log" 2>&1; then
  ok "the scrubbed tree passes test-corpus-privacy.sh"
else
  bad "the scrubbed tree passes test-corpus-privacy.sh: $(grep FAIL "$TMP/priv.log" | head -5)"
fi
if ! CORPUS_PRIVACY_DIRS="$RAW" bash "$PRIVACY" >/dev/null 2>&1; then
  ok "the raw tree fails test-corpus-privacy.sh"
else
  bad "the raw tree fails test-corpus-privacy.sh"
fi

# ── no names file: only the generic rules ──────────────────────────────────
if CORPUS_PRIVATE_NAMES_FILE="$TMP/absent" bash "$SCRUB" "$RAW" "$TMP/out-generic" >"$TMP/generic.log" 2>&1 &&
  grep -q 'no private names file' "$TMP/generic.log" &&
  grep -q 'run by Zorblax' "$TMP/out-generic/iter-05/state.log" &&
  grep -q 'Writing specs in ~/zorb/space/' "$TMP/out-generic/iter-05/state.log"; then
  ok "without a names file the scrub says so and applies only the generic rules"
else
  bad "without a names file the scrub says so and applies only the generic rules: $(cat "$TMP/generic.log")"
fi
if ! CORPUS_PRIVACY_DIRS="$TMP/out-generic" bash "$PRIVACY" >/dev/null 2>&1; then
  ok "names the scrub did not know are still caught by the privacy test's names file"
else
  bad "names the scrub did not know are still caught by the privacy test's names file"
fi
printf 'nickname x\n' >"$TMP/bad-names"
rc=0
CORPUS_PRIVATE_NAMES_FILE="$TMP/bad-names" bash "$SCRUB" "$RAW" "$TMP/out-bad" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "an unknown kind in the names file is refused (rc 2)" || bad "an unknown kind in the names file is refused (rc $rc)"

# ── refusals ────────────────────────────────────────────────────────────────
rc=0
bash "$SCRUB" "$RAW" "$OUT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "a non-empty destination is refused (rc 2)" || bad "a non-empty destination is refused (rc $rc)"
cp -r "$RAW" "$TMP/raw-bin"
printf '\x00\x01\x02binary' >"$TMP/raw-bin/blob.bin"
rc=0
bash "$SCRUB" "$TMP/raw-bin" "$TMP/out-bin" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && ok "a binary file is refused (rc 1)" || bad "a binary file is refused (rc $rc)"
cp -r "$RAW" "$TMP/raw-link"
ln -s /etc/hostname "$TMP/raw-link/link.txt"
rc=0
bash "$SCRUB" "$TMP/raw-link" "$TMP/out-link" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] && ok "a symlink is refused (rc 1)" || bad "a symlink is refused (rc $rc)"
rc=0
bash "$SCRUB" "$RAW" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] && ok "usage error is rc 2" || bad "usage error is rc 2 (rc $rc)"

echo ""
echo "=== $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ]
