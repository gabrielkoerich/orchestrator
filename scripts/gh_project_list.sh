#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_yq

require_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "gh is required but not found in PATH." >&2
    exit 1
  fi
}

require_gh

ORG=${1:-}
USER=${2:-}

if [ -z "$ORG" ] && [ -z "$USER" ]; then
  echo "Usage: gh_project_list.sh <org> [user]" >&2
  echo "Examples:" >&2
  echo "  just gh-project-list org=YOUR_ORG" >&2
  echo "  just gh-project-list user=YOUR_USER" >&2
  exit 1
fi

if [ -n "$ORG" ]; then
  gh api graphql -f query='query($org:String!){ organization(login:$org){ projectsV2(first:100){ nodes{ id number title } } } }' -f org="$ORG" \
    | yq -r '.data.organization.projectsV2.nodes[] | [.number, .title, .id] | @tsv' | column -t -s $'\t'
  exit 0
fi

gh api graphql -f query='query($user:String!){ user(login:$user){ projectsV2(first:100){ nodes{ id number title } } } }' -f user="$USER" \
  | yq -r '.data.user.projectsV2.nodes[] | [.number, .title, .id] | @tsv' | column -t -s $'\t'
