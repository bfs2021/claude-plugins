#!/usr/bin/env bash
# ── grill.sh ──────────────────────────────────────────────────────────────────
# Single entry point for the /grill-me skill (F68). Sourcing this one file
# defines every function SKILL.md calls: profile, input, score, render, seal
# and hold. Sourcing only grill-hold.sh left grill_profile_load, grill_score,
# grill_render and grill_seal_generate undefined, and a headless agent then
# computed the score or wrote the seal itself.
#
# Siblings resolve from this file's own directory, so it works from the
# plugin's lib/ and from the synced ~/.claude/skills/lib/ alike, whatever the
# working directory. grill-telemetry.sh is not sourced: the libs run it as a
# separate process.
#
# Like the libs it loads, this turns on `set -euo pipefail` in the caller.
# ───────────────────────────────────────────────────────────────────────────────

_grill_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _grill_lib in grill-profile grill-input grill-score grill-render grill-seal grill-hold; do
  if [ ! -f "${_grill_lib_dir}/${_grill_lib}.sh" ]; then
    echo "grill.sh: ${_grill_lib_dir}/${_grill_lib}.sh not found" >&2
    unset _grill_lib _grill_lib_dir
    return 1 2>/dev/null || exit 1
  fi
  # shellcheck source=/dev/null
  . "${_grill_lib_dir}/${_grill_lib}.sh"
done
unset _grill_lib _grill_lib_dir
