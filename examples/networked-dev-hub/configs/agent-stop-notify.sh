#!/bin/bash
# Stop hook: notify the coordinator when this agent finishes a task
# Only fires on worker machines with coordination enabled

SETTINGS_FILE="$CLAUDE_PROJECT_DIR/.claude/hub-agent.local.md"
[ ! -f "$SETTINGS_FILE" ] && exit 0

FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$SETTINGS_FILE")

# Check if coordination is enabled and this is a worker
ROLE=$(echo "$FRONTMATTER" | grep '^role:' | sed 's/role: *//')
[ "$ROLE" != "worker" ] && exit 0

AGENT_NAME=$(echo "$FRONTMATTER" | grep '^agent_name:' | sed 's/agent_name: *//')
COORDINATOR_SESSION=$(echo "$FRONTMATTER" | grep '^coordinator_session:' | sed 's/coordinator_session: *//')
COORDINATOR_HOST=$(echo "$FRONTMATTER" | grep '^coordinator_host:' | sed 's/coordinator_host: *//')

# Notify coordinator via SSH + tmux (if reachable)
if [ -n "$COORDINATOR_HOST" ] && [ -n "$COORDINATOR_SESSION" ]; then
  ssh -o ConnectTimeout=5 -o BatchMode=yes "$COORDINATOR_HOST" \
    "tmux send-keys -t '$COORDINATOR_SESSION' \
     'Agent $AGENT_NAME has completed its current task and is now idle.' Enter" \
    2>/dev/null
fi

# Push any uncommitted status updates
cd "$CLAUDE_PROJECT_DIR" || exit 0
if [ -n "$(git status --porcelain .claude/hub-status.md 2>/dev/null)" ]; then
  git add .claude/hub-status.md
  git commit -m "status($AGENT_NAME): task complete, agent idle" --quiet 2>/dev/null
  git push origin HEAD --quiet 2>/dev/null
fi
