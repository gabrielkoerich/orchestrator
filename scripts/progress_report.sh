#!/usr/bin/env bash
# progress_report.sh — Generate a progress report across all projects.
# Used by the monitoring job to give visibility into what's happening.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
source "$(dirname "$0")/output.sh"

# Report period (default: last 60 minutes)
SINCE_MINUTES=${REPORT_SINCE_MINUTES:-60}
SINCE_ISO=$(date -u -v-${SINCE_MINUTES}M +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null \
  || date -u -d "$SINCE_MINUTES minutes ago" +"%Y-%m-%dT%H:%M:%SZ")

echo "=== Progress Report (last ${SINCE_MINUTES}m) ==="
echo "Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
echo ""

# --- Task Status Summary (global) ---
section "Task Status (all projects)"
TOTAL=$(db_total_task_count)
{
  printf 'STATUS\tQTY\n'
  for s in new routed in_progress blocked done needs_review; do
    printf '%s\t%s\n' "$s" "$(db_status_count "$s")"
  done
  printf '────────\t───\n'
  printf 'total\t%s\n' "$TOTAL"
} | column -t -s $'\t'

ALL_TASKS=$(_bd_json list -n 0 --all 2>/dev/null || echo '[]')

# --- Recently completed tasks ---
section "Completed since $(echo "$SINCE_ISO" | sed 's/T/ /;s/Z//')"
DONE_RECENT=$(printf '%s' "$ALL_TASKS" | jq -r --arg since "$SINCE_ISO" \
  '.[] | select(.status == "done" and .updated_at >= $since) | [.id, (.metadata.agent // "?"), (.metadata.agent_model // ""), .title] | @tsv' 2>/dev/null || true)
if [ -n "$DONE_RECENT" ]; then
  {
    printf 'ID\tAGENT\tMODEL\tTITLE\n'
    printf '%s\n' "$DONE_RECENT"
  } | column -t -s $'\t'
else
  echo "(none)"
fi

# --- Currently in progress ---
section "In Progress"
IN_PROGRESS=$(printf '%s' "$ALL_TASKS" | jq -r \
  '.[] | select(.status == "in_progress") | [.id, (.metadata.agent // "?"), (.metadata.agent_model // ""), (.metadata.attempts // "0"), .title] | @tsv' 2>/dev/null || true)
if [ -n "$IN_PROGRESS" ]; then
  {
    printf 'ID\tAGENT\tMODEL\tATT\tTITLE\n'
    printf '%s\n' "$IN_PROGRESS"
  } | column -t -s $'\t'
else
  echo "(none)"
fi

# --- Needs review ---
section "Needs Review"
NEEDS_REVIEW=$(printf '%s' "$ALL_TASKS" | jq -r \
  '.[] | select(.status == "needs_review") | [.id, (.metadata.agent // "?"), (.metadata.attempts // "0"), (.metadata.last_error // "" | .[:60]), .title] | @tsv' 2>/dev/null | head -10 || true)
if [ -n "$NEEDS_REVIEW" ]; then
  {
    printf 'ID\tAGENT\tATT\tLAST_ERROR\tTITLE\n'
    printf '%s\n' "$NEEDS_REVIEW"
  } | column -t -s $'\t'
else
  echo "(none)"
fi

# --- Tasks queued ---
section "Queued (new/routed)"
QUEUED=$(printf '%s' "$ALL_TASKS" | jq -r \
  '.[] | select(.status == "new" or .status == "routed") | [.id, (.metadata.agent // "?"), .title] | @tsv' 2>/dev/null | head -10 || true)
if [ -n "$QUEUED" ]; then
  {
    printf 'ID\tAGENT\tTITLE\n'
    printf '%s\n' "$QUEUED"
  } | column -t -s $'\t'
else
  echo "(none)"
fi

# --- Recent activity from comments ---
section "Recent Activity"
# Scan recent tasks for comments (beads comments replace task_history)
echo "(check individual task comments for activity log)"

# --- PR Status (check all projects with repos) ---
section "Open PRs"
PROJECTS=$(db_task_projects 2>/dev/null || true)
if [ -n "$PROJECTS" ]; then
  while IFS= read -r pdir; do
    [ -n "$pdir" ] || continue
    [ -d "$pdir" ] || continue
    REPO=""
    if [ -d "$pdir/.git" ] || is_bare_repo "$pdir" 2>/dev/null; then
      REPO=$(cd "$pdir" && gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)
    fi
    [ -z "$REPO" ] && continue

    PR_LIST=$(gh pr list --repo "$REPO" --state open --json number,title,headRefName,statusCheckRollup --limit 10 2>/dev/null || true)
    [ -z "$PR_LIST" ] || [ "$PR_LIST" = "[]" ] && continue

    PNAME=$(basename "$pdir" .git)
    echo ""
    echo "  $PNAME ($REPO):"
    printf '%s' "$PR_LIST" | jq -r '.[] | "    #\(.number) [\(.statusCheckRollup | map(.state) | if length == 0 then "?" elif all(. == "SUCCESS") then "CI:pass" elif any(. == "FAILURE") then "CI:fail" else "CI:pending" end)] \(.title)"' 2>/dev/null || true
  done <<< "$PROJECTS"
fi

# --- Permission Denials ---
DENIAL_LOG="${STATE_DIR}/permission-denials.log"
if [ -f "$DENIAL_LOG" ]; then
  RECENT_DENIALS=$(awk -v since="$SINCE_ISO" '$1 >= since' "$DENIAL_LOG" 2>/dev/null | wc -l | tr -d ' ')
  if [ "$RECENT_DENIALS" -gt 0 ]; then
    section "Permission Denials (${RECENT_DENIALS} recent)"
    awk -v since="$SINCE_ISO" '$1 >= since' "$DENIAL_LOG" | tail -5
  fi
fi

echo ""
echo "=== End Report ==="
