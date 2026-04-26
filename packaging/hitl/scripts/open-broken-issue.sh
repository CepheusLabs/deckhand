#!/usr/bin/env bash
# open-broken-issue.sh — open or update the "HITL nightly broken"
# tracking issue. Idempotent: re-runs append a comment to the
# existing issue rather than spawning a new one each night.
#
# Requires gh CLI authenticated via $GH_TOKEN (set by the workflow).

set -euo pipefail

WORKFLOW_RUN_URL=""
while [ $# -gt 0 ]; do
    case "$1" in
        --workflow-run-url) WORKFLOW_RUN_URL="$2"; shift 2 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

: "${WORKFLOW_RUN_URL:?--workflow-run-url is required}"

TITLE="HITL nightly broken"

# Look for an open issue with the marker title. gh search returns
# issues across all repos when scope is unspecified; pin it to the
# current repo via $GITHUB_REPOSITORY.
existing=$(gh issue list \
    --state open \
    --search "$TITLE in:title" \
    --json number,title \
    --jq ".[] | select(.title == \"$TITLE\") | .number" \
    | head -n1)

today=$(date -u +%Y-%m-%d)

if [ -n "$existing" ]; then
    echo "appending failure comment to issue #$existing"
    gh issue comment "$existing" --body "Nightly HITL run on $today failed.

Workflow run: $WORKFLOW_RUN_URL"
else
    echo "no open tracking issue; opening one"
    gh issue create \
        --title "$TITLE" \
        --body "Tracking issue for HITL nightly failures. Each failed nightly run appends a comment.

Most recent failure: $today
Workflow run: $WORKFLOW_RUN_URL

Close this issue when the failures are resolved; the next failure
will open a new one." \
        --label hitl,bug
fi
