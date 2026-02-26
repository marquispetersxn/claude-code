#!/bin/bash
# SessionStart hook: pull latest state and identify this machine
# Runs every time a Claude Code session begins

cd "$CLAUDE_PROJECT_DIR" || exit 1

# Pull latest shared state (non-blocking on failure)
git pull --rebase --quiet origin main 2>/dev/null || true

# Identify this machine by hostname
HOSTNAME=$(hostname)
echo "export HUB_MACHINE_ID=$HOSTNAME" >> "$CLAUDE_ENV_FILE"

# Load machine-specific role and partner info from local settings
SETTINGS_FILE="$CLAUDE_PROJECT_DIR/.claude/hub-agent.local.md"
if [ -f "$SETTINGS_FILE" ]; then
  FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$SETTINGS_FILE")

  ROLE=$(echo "$FRONTMATTER" | grep '^role:' | sed 's/role: *//')
  AGENT_NAME=$(echo "$FRONTMATTER" | grep '^agent_name:' | sed 's/agent_name: *//')
  PARTNER_IP=$(echo "$FRONTMATTER" | grep '^partner_ip:' | sed 's/partner_ip: *//')
  PARTNER_PORT=$(echo "$FRONTMATTER" | grep '^partner_port:' | sed 's/partner_port: *//')

  echo "export HUB_ROLE=$ROLE" >> "$CLAUDE_ENV_FILE"
  echo "export HUB_AGENT_NAME=$AGENT_NAME" >> "$CLAUDE_ENV_FILE"
  echo "export HUB_PARTNER_IP=$PARTNER_IP" >> "$CLAUDE_ENV_FILE"
  echo "export HUB_PARTNER_PORT=$PARTNER_PORT" >> "$CLAUDE_ENV_FILE"
fi
