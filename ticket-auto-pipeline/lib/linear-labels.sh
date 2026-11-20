#!/usr/bin/env bash
# linear-labels.sh — check, and on request create, the labels the Linear board
# driver projects (workflow.json board_drivers.linear.projected_labels:
# needs-info, needs-adr, rejected, reviewed).
#
# lib/board-drivers/linear.sh never creates a label: an event whose mapping
# adds a label the team does not have is a permanent projection failure
# ("unknown label"). This is the one place that creates them ahead of time,
# called by env-check.sh once LINEAR_API_KEY is loaded.
#
# A label counts as present exactly when the driver would find it: a
# case-insensitive name match in get_team's label list.
#
# Functions (source the file; needs linear-api.sh's linear_graphql/get_team,
# sourced here behind a declare guard):
#   linear_labels_projected              names, one per line
#   linear_labels_resolve_team [REF]     team uuid. REF is a uuid, key or name;
#                                        empty → $LINEAR_TEAM_ID → the only
#                                        visible team. rc 1 unresolvable,
#                                        rc 4 teams query failed.
#   linear_labels_status TEAM_ID         "name<TAB>label-id" per projected
#                                        label (id empty when absent). rc 4 on
#                                        a failed fetch.
#   linear_labels_create TEAM_ID NAME    creates the label, prints its id.
#                                        rc 1 on failure.
#   linear_labels_drop_driver_cache TEAM_ID
#                                        removes the driver's cached team copy
#                                        so a new label is seen at once, not
#                                        after the 15-minute TTL.
#
# CLI: linear-labels.sh check|create [--team REF]
#   check  prints one "label:<name>|ok|<id>" or "label:<name>|missing|" line
#          each; exit 0 all present, 1 some missing, 4 Linear unreachable.
#   create creates every missing label; same output with "created" rows;
#          exit 0 all present afterwards, 1 a create failed, 4 unreachable.
# No set -e at file scope: env-check.sh sources this.

_LL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! declare -f linear_graphql >/dev/null 2>&1 || ! declare -f get_team >/dev/null 2>&1; then
  # linear-api.sh sets errexit at file scope; keep the caller's own setting.
  _ll_errexit=false
  [[ $- == *e* ]] && _ll_errexit=true
  # shellcheck source=linear-api.sh
  source "$_LL_DIR/linear-api.sh"
  $_ll_errexit || set +e
  unset _ll_errexit
fi

_ll_workflow_json() {
  local wf="$_LL_DIR/../skills/ticket-flow/workflow.json"
  [ -f "$wf" ] || wf="$HOME/.claude/skills/ticket-flow/workflow.json"
  echo "$wf"
}

linear_labels_projected() {
  local wf
  wf=$(_ll_workflow_json)
  if [ -f "$wf" ] && jq -e '.board_drivers.linear.projected_labels | type == "array"' "$wf" >/dev/null 2>&1; then
    jq -r '.board_drivers.linear.projected_labels[]' "$wf"
  else
    printf '%s\n' needs-info needs-adr rejected reviewed
  fi
}

linear_labels_resolve_team() {
  local want="${1:-${LINEAR_TEAM_ID:-}}" teams count id
  if [[ "$want" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]]; then
    echo "$want"
    return 0
  fi
  teams=$( (linear_graphql '{"query":"query { teams(first: 250) { nodes { id key name } } }"}') 2>/dev/null) || return 4
  echo "$teams" | jq -e '.data.teams.nodes | type == "array"' >/dev/null 2>&1 || return 4
  if [ -z "$want" ]; then
    count=$(echo "$teams" | jq '.data.teams.nodes | length')
    if [ "$count" -ne 1 ]; then
      echo "linear-labels: $count Linear teams visible — set LINEAR_TEAM_ID" >&2
      return 1
    fi
    echo "$teams" | jq -r '.data.teams.nodes[0].id'
    return 0
  fi
  id=$(echo "$teams" | jq -r --arg w "$want" \
    '[.data.teams.nodes[] | select((.key|ascii_downcase) == ($w|ascii_downcase) or (.name|ascii_downcase) == ($w|ascii_downcase))][0].id // empty')
  if [ -z "$id" ]; then
    echo "linear-labels: no Linear team matches '$want'" >&2
    return 1
  fi
  echo "$id"
}

linear_labels_status() {
  local team_id="$1" team_json name lid
  team_json=$( (get_team "$team_id") 2>/dev/null) || return 4
  echo "$team_json" | jq -e '.labels | type == "array"' >/dev/null 2>&1 || return 4
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    lid=$(echo "$team_json" | jq -r --arg n "$name" \
      '[.labels[] | select(.name | ascii_downcase == ($n | ascii_downcase)) | .id][0] // empty')
    printf '%s\t%s\n' "$name" "$lid"
  done < <(linear_labels_projected)
}

linear_labels_create() {
  local team_id="$1" name="$2" payload resp id
  [ -n "$team_id" ] && [ -n "$name" ] || return 1
  payload=$(jq -nc --arg name "$name" --arg teamId "$team_id" '{
    query: "mutation($input: IssueLabelCreateInput!) { issueLabelCreate(input: $input) { success issueLabel { id name } } }",
    variables: {input: {name: $name, teamId: $teamId}}
  }')
  resp=$( (linear_graphql "$payload") 2>/dev/null) || {
    echo "linear-labels: issueLabelCreate failed for '$name'" >&2
    return 1
  }
  id=$(echo "$resp" | jq -r '.data.issueLabelCreate.issueLabel.id // empty' 2>/dev/null)
  if [ -z "$id" ]; then
    echo "linear-labels: issueLabelCreate returned no id for '$name'" >&2
    return 1
  fi
  echo "$id"
}

linear_labels_drop_driver_cache() {
  local team_id="$1" dir
  if declare -f ticket_log_dir_or >/dev/null 2>&1; then
    dir=$(ticket_log_dir_or "${FLEET_PIPELINE_LOG_DIR:-./logs}" 2>/dev/null)
  else
    dir="${FLEET_PIPELINE_LOG_DIR:-./logs}"
  fi
  [ -n "$dir" ] && rm -f -- "$dir/.linear-team-${team_id}.json" 2>/dev/null
  return 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _ll_mode="${1:-}"
  shift || true
  _ll_team=""
  while [ $# -gt 0 ]; do
    case "$1" in
    --team)
      _ll_team="${2:-}"
      shift 2 || true
      ;;
    --team=*)
      _ll_team="${1#*=}"
      shift
      ;;
    *)
      echo "linear-labels: unexpected argument: $1" >&2
      exit 2
      ;;
    esac
  done
  case "$_ll_mode" in
  check | create) ;;
  *)
    echo "usage: linear-labels.sh check|create [--team REF]" >&2
    exit 2
    ;;
  esac
  [ -f "$_LL_DIR/log-dir.sh" ] && source "$_LL_DIR/log-dir.sh"
  _ll_rc=0
  _ll_tid=$(linear_labels_resolve_team "$_ll_team") || _ll_rc=$?
  [ "$_ll_rc" -eq 0 ] || exit "$_ll_rc"
  _ll_rc=0
  _ll_rows=$(linear_labels_status "$_ll_tid") || _ll_rc=$?
  [ "$_ll_rc" -eq 0 ] || exit 4
  _ll_exit=0 _ll_made=false
  while IFS=$'\t' read -r _ll_name _ll_id; do
    if [ -n "$_ll_id" ]; then
      echo "label:${_ll_name}|ok|${_ll_id}"
    elif [ "$_ll_mode" = create ] && _ll_id=$(linear_labels_create "$_ll_tid" "$_ll_name"); then
      echo "label:${_ll_name}|created|${_ll_id}"
      _ll_made=true
    else
      echo "label:${_ll_name}|missing|"
      _ll_exit=1
    fi
  done <<<"$_ll_rows"
  $_ll_made && linear_labels_drop_driver_cache "$_ll_tid"
  exit "$_ll_exit"
fi
