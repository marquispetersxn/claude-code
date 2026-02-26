#!/bin/bash
# PostToolUse hook: update the shared hub status file after significant actions
# This file is committed to git so mobile Claude can check it

STATUS_FILE="$CLAUDE_PROJECT_DIR/.claude/hub-status.md"
MACHINE_NAME="${HUB_AGENT_NAME:-$(hostname)}"
ROLE="${HUB_ROLE:-unknown}"
BRANCH=$(git -C "$CLAUDE_PROJECT_DIR" branch --show-current 2>/dev/null || echo "unknown")
LAST_COMMIT=$(git -C "$CLAUDE_PROJECT_DIR" log -1 --format='%s' 2>/dev/null || echo "n/a")
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Create or update the status file
# In a production setup, you'd parse the existing file and update only
# this machine's section. This simplified version overwrites.
mkdir -p "$(dirname "$STATUS_FILE")"
cat > "$STATUS_FILE" <<EOF
# Hub Status

**Last updated:** $TIMESTAMP

## $MACHINE_NAME ($ROLE)
- **Status:** active
- **Branch:** \`$BRANCH\`
- **Last commit:** "$LAST_COMMIT"
- **Machine:** $(hostname)
EOF

# Stage but don't commit yet — the Stop hook or next sync will commit
git -C "$CLAUDE_PROJECT_DIR" add "$STATUS_FILE" 2>/dev/null
