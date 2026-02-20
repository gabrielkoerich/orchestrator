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
TOTAL=$(db_scalar "SELECT COUNT(*) FROM tasks;")
_count() { db_scalar "SELECT COUNT(*) FROM tasks WHERE status = '$1';"; }
{
  printf 'STATUS\tQTY\n'
  for s in new routed in_progress blocked done needs_review; do
    printf '%s\t%s\n' "$s" "$(_count "$s")"
  done
  printf '────────\t───\n'
  printf 'total\t%s\n' "$TOTAL"
} | column -t -s $'\t'

# --- Recently completed tasks ---
section "Completed since $(echo "$SINCE_ISO" | sed 's/T/ /;s/Z//')"
DONE_RECENT=$(db "SELECT id, COALESCE(agent,'?'), COALESCE(agent_model,''), title
  FROM tasks WHERE status = 'done' AND updated_at >= '$SINCE_ISO'
  ORDER BY updated_at DESC;")
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
IN_PROGRESS=$(db "SELECT id, COALESCE(agent,'?'), COALESCE(agent_model,''), attempts, title
  FROM tasks WHERE status = 'in_progress'
  ORDER BY updated_at DESC;")
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
NEEDS_REVIEW=$(db "SELECT id, COALESCE(agent,'?'), attempts, COALESCE(SUBSTR(last_error,1,60),''), title
  FROM tasks WHERE status = 'needs_review'
  ORDER BY updated_at DESC LIMIT 10;")
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
QUEUED=$(db "SELECT id, COALESCE(agent,'?'), title
  FROM tasks WHERE status IN ('new','routed')
  ORDER BY id LIMIT 10;")
if [ -n "$QUEUED" ]; then
  {
    printf 'ID\tAGENT\tTITLE\n'
    printf '%s\n' "$QUEUED"
  } | column -t -s $'\t'
else
  echo "(none)"
fi

# --- Recent history events ---
section "Recent Activity"
RECENT_HISTORY=$(db "SELECT h.task_id, h.status, SUBSTR(h.note,1,80), h.ts
  FROM task_history h
  WHERE h.ts >= '$SINCE_ISO'
  ORDER BY h.ts DESC LIMIT 15;")
if [ -n "$RECENT_HISTORY" ]; then
  {
    printf 'TASK\tSTATUS\tNOTE\tTIME\n'
    printf '%s\n' "$RECENT_HISTORY"
  } | column -t -s $'\t'
else
  echo "(none)"
fi

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
