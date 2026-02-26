# Networked Development Hub Architecture

A guide for connecting two LAN machines running Claude Code with mobile Claude
for monitoring — enabling shared codebases, cross-machine tools, multi-agent
coordination, and remote status visibility.

## Overview

```
                        ┌──────────────────────┐
                        │    GitHub / GitLab    │
                        │   (Source of Truth)   │
                        └──────────┬───────────┘
                                   │
                    ┌──────────────┼──────────────┐
                    │              │              │
           ┌───────▼───────┐      │     ┌────────▼──────┐
           │  MACHINE A    │◄─────┼────►│  MACHINE B    │
           │  (Desktop)    │   LAN│     │  (Laptop)     │
           │               │      │     │               │
           │ Claude Code   │      │     │ Claude Code   │
           │ MCP Server A  │◄─────┼────►│ MCP Server B  │
           │ Tools: DB,    │      │     │ Tools: Tests, │
           │   Build, GPU  │      │     │   Lint, Deploy│
           │               │      │     │               │
           │ Coordinator   │      │     │ Worker Agent  │
           │ (tmux session)│      │     │ (tmux session)│
           └───────┬───────┘      │     └───────┬───────┘
                   │              │             │
                   │    ┌─────────▼──────────┐  │
                   └───►│  Status Dashboard  │◄─┘
                        │  (HTTP endpoint)   │
                        └─────────┬──────────┘
                                  │
                        ┌─────────▼──────────┐
                        │   Mobile Claude    │
                        │   (Monitoring)     │
                        └────────────────────┘
```

## Architecture Layers

| Layer | Purpose | Mechanism |
|-------|---------|-----------|
| 1. Shared Foundation | Same codebase + config on both machines | Git + shared CLAUDE.md + .claude/ rules |
| 2. Cross-Machine Tools | Use tools on one machine from the other | MCP HTTP/WebSocket servers over LAN |
| 3. Multi-Agent Coordination | Parallel work with task assignment | multi-agent-swarm pattern + tmux |
| 4. Mobile Monitoring | Check progress from phone | Status MCP server + shared git state |

---

## Layer 1: Shared Foundation

Both machines clone the same repositories from a shared remote (GitHub, GitLab,
or a bare repo on the LAN). Project-level configuration is committed to git so
both machines always have the same context.

### What to commit (shared across machines)

```
your-project/
├── CLAUDE.md                          # Project memory & instructions
├── .claude/
│   └── rules/                         # Project-specific rules (committed)
│       ├── coding-standards.md
│       └── architecture-decisions.md
├── .mcp.json                          # MCP server definitions (see Layer 2)
└── .devcontainer/                     # Optional: containerized dev env
    └── devcontainer.json
```

### What stays local (per-machine, gitignored)

```
your-project/
└── .claude/
    ├── hub-agent.local.md             # This machine's agent identity/role
    └── *.local.json                   # Local hook configuration overrides
```

### SessionStart hook: auto-sync on session open

When Claude Code starts a session, a hook pulls the latest shared state and
identifies which machine is active. See `configs/hooks-session-sync.json`.

The hook script detects the machine identity from the hostname and exports it:

```bash
#!/bin/bash
# scripts/session-sync.sh
cd "$CLAUDE_PROJECT_DIR" || exit 1

# Pull latest shared state
git pull --rebase --quiet origin main 2>/dev/null || true

# Identify this machine
HOSTNAME=$(hostname)
echo "export HUB_MACHINE_ID=$HOSTNAME" >> "$CLAUDE_ENV_FILE"

# Load machine-specific role if defined
SETTINGS_FILE="$CLAUDE_PROJECT_DIR/.claude/hub-agent.local.md"
if [ -f "$SETTINGS_FILE" ]; then
  ROLE=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$SETTINGS_FILE" | \
         grep '^role:' | sed 's/role: *//')
  echo "export HUB_ROLE=$ROLE" >> "$CLAUDE_ENV_FILE"
fi
```

### Machine identity file

Each machine has a `.claude/hub-agent.local.md` (gitignored) that declares its
role in the hub:

**Machine A** (`.claude/hub-agent.local.md`):
```markdown
---
role: coordinator
machine_name: desktop
agent_name: alpha
capabilities: ["gpu", "database", "build-server"]
partner_ip: 192.168.1.101
partner_port: 8100
---

# Machine A — Coordinator
This is the primary development machine with GPU and database access.
Acts as the coordinator for multi-agent tasks.
```

**Machine B** (`.claude/hub-agent.local.md`):
```markdown
---
role: worker
machine_name: laptop
agent_name: beta
capabilities: ["testing", "linting", "deployment"]
partner_ip: 192.168.1.100
partner_port: 8100
---

# Machine B — Worker
Secondary machine focused on testing and deployment.
Reports status to the coordinator on Machine A.
```

---

## Layer 2: Cross-Machine MCP Servers

Each machine runs a lightweight HTTP MCP server that exposes its local tools to
the other machine on the LAN. Claude Code on Machine A can invoke tools running
on Machine B and vice versa.

### How it works

```
Machine A (192.168.1.100)              Machine B (192.168.1.101)
┌──────────────────────┐               ┌──────────────────────┐
│ Claude Code          │               │ Claude Code          │
│                      │               │                      │
│ .mcp.json:           │               │ .mcp.json:           │
│  local-db (stdio)    │               │  local-tests (stdio) │
│  remote-B (http) ────┼──────────────►│  mcp-server :8100    │
│  mcp-server :8100 ◄──┼───────────── │  remote-A (http) ────│
│                      │               │                      │
└──────────────────────┘               └──────────────────────┘
```

### Project .mcp.json (committed, uses env vars for portability)

Both machines share this `.mcp.json`. The env vars resolve differently on each:

```json
{
  "local-tools": {
    "command": "node",
    "args": ["${CLAUDE_PLUGIN_ROOT}/servers/local-tools.mjs"]
  },
  "partner-machine": {
    "type": "http",
    "url": "http://${HUB_PARTNER_IP}:${HUB_PARTNER_PORT}/mcp",
    "headers": {
      "Authorization": "Bearer ${HUB_SHARED_SECRET}",
      "X-Machine-ID": "${HUB_MACHINE_ID}"
    }
  }
}
```

The `HUB_PARTNER_IP` and `HUB_PARTNER_PORT` are set by the SessionStart hook
reading from `hub-agent.local.md`, and `HUB_SHARED_SECRET` is a pre-shared
token set in each machine's shell profile.

### Writing an MCP server for your tools

Each machine runs a simple HTTP MCP server. You can use any MCP SDK (the
TypeScript SDK is most common). Here is the minimal shape:

```javascript
// servers/local-tools.mjs
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";

const server = new McpServer({ name: "local-tools", version: "1.0.0" });

// Register tools that expose this machine's capabilities
server.tool("run_tests", { path: z.string() }, async ({ path }) => {
  // Run tests locally and return results
});

server.tool("query_db", { sql: z.string() }, async ({ sql }) => {
  // Query local database
});

server.tool("gpu_inference", { model: z.string(), input: z.string() }, async (args) => {
  // Run inference on local GPU
});

const transport = new StdioServerTransport();
await server.connect(transport);
```

For HTTP access over LAN, wrap it with an HTTP transport or run a separate HTTP
server that proxies to the stdio process. The MCP TypeScript SDK supports
`SSEServerTransport` and `StreamableHTTPServerTransport` out of the box.

### Security considerations for LAN

- Use a **pre-shared secret** (`HUB_SHARED_SECRET`) in the `Authorization`
  header. Generate one with `openssl rand -hex 32` and add it to each
  machine's `~/.bashrc` or `~/.zshrc`
- Bind the MCP server to the **LAN interface only** (not `0.0.0.0`)
- For stronger isolation, use a `headersHelper` script that rotates tokens:
  ```json
  {
    "partner-machine": {
      "type": "http",
      "url": "http://${HUB_PARTNER_IP}:${HUB_PARTNER_PORT}/mcp",
      "headersHelper": "${CLAUDE_PLUGIN_ROOT}/scripts/get-hub-headers.sh"
    }
  }
  ```

---

## Layer 3: Multi-Agent Coordination

When you want both machines working on the same project simultaneously — e.g.,
Machine A handles backend changes while Machine B runs tests and linting — use
the multi-agent-swarm pattern.

### Coordination model

```
Machine A (Coordinator)                Machine B (Worker)
┌──────────────────────┐               ┌──────────────────────┐
│ tmux: coordinator    │               │ tmux: worker-beta    │
│                      │  assign task  │                      │
│ "Implement auth API" ├──────────────►│ "Run test suite &    │
│                      │               │  fix failures"       │
│                      │  notify done  │                      │
│                      │◄──────────────┤ "Tests pass, PR #42" │
│                      │               │                      │
└──────────────────────┘               └──────────────────────┘
    Coordination via:
    1. Git (push/pull task state)
    2. tmux send-keys (LAN SSH)
    3. Shared settings files
```

### Task assignment file (committed to git)

```markdown
<!-- .claude/tasks/current-sprint.md -->
# Sprint Tasks

## Task 1: Implement JWT auth
- **Assigned to:** alpha (Machine A)
- **Status:** in_progress
- **Branch:** feature/jwt-auth
- **Dependencies:** none

## Task 2: Integration test suite
- **Assigned to:** beta (Machine B)
- **Status:** waiting
- **Branch:** feature/jwt-auth
- **Dependencies:** [Task 1]

## Task 3: Update API docs
- **Assigned to:** alpha (Machine A)
- **Status:** pending
- **Dependencies:** [Task 1, Task 2]
```

### Agent settings file (per-machine, gitignored)

On Machine B, the `.claude/hub-agent.local.md` includes coordination details:

```markdown
---
agent_name: beta
task_number: 2
coordinator_session: coordinator
coordinator_host: 192.168.1.100
enabled: true
dependencies: ["Task 1"]
---

# Current Assignment
Run the integration test suite against the JWT auth implementation.
Report results back to the coordinator.
```

### Stop hook: notify coordinator when done

When Claude Code on Machine B finishes (the `Stop` event fires), a hook
notifies Machine A's coordinator session via SSH + tmux:

```bash
#!/bin/bash
# scripts/agent-stop-notify.sh

SETTINGS_FILE="$CLAUDE_PROJECT_DIR/.claude/hub-agent.local.md"
[ ! -f "$SETTINGS_FILE" ] && exit 0

FRONTMATTER=$(sed -n '/^---$/,/^---$/{ /^---$/d; p; }' "$SETTINGS_FILE")
ENABLED=$(echo "$FRONTMATTER" | grep '^enabled:' | sed 's/enabled: *//')
[ "$ENABLED" != "true" ] && exit 0

AGENT_NAME=$(echo "$FRONTMATTER" | grep '^agent_name:' | sed 's/agent_name: *//')
COORDINATOR_SESSION=$(echo "$FRONTMATTER" | grep '^coordinator_session:' | sed 's/coordinator_session: *//')
COORDINATOR_HOST=$(echo "$FRONTMATTER" | grep '^coordinator_host:' | sed 's/coordinator_host: *//')
TASK_NUMBER=$(echo "$FRONTMATTER" | grep '^task_number:' | sed 's/task_number: *//')

# Notify coordinator via SSH + tmux
ssh "$COORDINATOR_HOST" \
  "tmux send-keys -t '$COORDINATOR_SESSION' \
   'Agent $AGENT_NAME completed task $TASK_NUMBER and is idle.' Enter" \
  2>/dev/null

# Also update git-tracked status
cd "$CLAUDE_PROJECT_DIR" || exit 0
git add -A && git commit -m "agent($AGENT_NAME): task $TASK_NUMBER complete" --quiet 2>/dev/null
git push origin HEAD --quiet 2>/dev/null
```

### Hook configuration

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/session-sync.sh",
            "timeout": 15
          }
        ]
      }
    ],
    "Stop": [
      {
        "matcher": "*",
        "hooks": [
          {
            "type": "command",
            "command": "bash ${CLAUDE_PLUGIN_ROOT}/scripts/agent-stop-notify.sh",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
```

### SSH setup for cross-machine tmux

For the tmux notification pattern to work across machines, set up passwordless
SSH between them:

```bash
# On Machine B, generate a key and copy to Machine A
ssh-keygen -t ed25519 -f ~/.ssh/hub_key -N ""
ssh-copy-id -i ~/.ssh/hub_key.pub user@192.168.1.100

# Add to ~/.ssh/config for convenience
# Host hub-coordinator
#     HostName 192.168.1.100
#     User your-username
#     IdentityFile ~/.ssh/hub_key
```

---

## Layer 4: Mobile Monitoring

The mobile Claude app doesn't run Claude Code, but you can give it visibility
into your hub's status through several approaches.

### Option A: Git-based status (simplest)

Both machines commit status updates to a shared file. When you open Claude on
mobile, ask it to check the repo:

```markdown
<!-- .claude/hub-status.md — auto-updated by hooks -->
# Hub Status

**Last updated:** 2026-02-26T14:30:00Z

## Machine A (desktop / alpha)
- **Status:** active
- **Current task:** Implementing JWT auth (Task 1)
- **Branch:** feature/jwt-auth
- **Last commit:** "Add token validation middleware"

## Machine B (laptop / beta)
- **Status:** idle
- **Current task:** Waiting for Task 1
- **Branch:** main
- **Last commit:** n/a
```

A PostToolUse hook updates this file after significant actions (commits, test
runs, etc.):

```bash
#!/bin/bash
# scripts/update-hub-status.sh
STATUS_FILE="$CLAUDE_PROJECT_DIR/.claude/hub-status.md"
MACHINE_NAME=$(hostname)
BRANCH=$(git -C "$CLAUDE_PROJECT_DIR" branch --show-current 2>/dev/null)
LAST_COMMIT=$(git -C "$CLAUDE_PROJECT_DIR" log -1 --format='%s' 2>/dev/null)
TIMESTAMP=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Update the status file (simplified — a real implementation would
# parse and update only this machine's section)
cat > "$STATUS_FILE" <<EOF
# Hub Status
**Last updated:** $TIMESTAMP

## $MACHINE_NAME
- **Status:** active
- **Branch:** $BRANCH
- **Last commit:** "$LAST_COMMIT"
EOF

cd "$CLAUDE_PROJECT_DIR"
git add .claude/hub-status.md
git commit -m "status($MACHINE_NAME): update hub status" --quiet 2>/dev/null
git push origin HEAD --quiet 2>/dev/null
```

Then from mobile Claude, you can say: *"Check the hub status in my project repo
at github.com/user/project — look at .claude/hub-status.md"*

### Option B: GitHub Issues / PR comments as a dashboard

Use hooks to post status updates as comments on a tracking GitHub issue:

```bash
#!/bin/bash
# scripts/post-status-to-github.sh
AGENT_NAME="${HUB_MACHINE_ID:-$(hostname)}"
ISSUE_NUMBER="1"  # Dedicated status tracking issue
REPO="your-user/your-project"

gh issue comment "$ISSUE_NUMBER" -R "$REPO" \
  --body "**[$AGENT_NAME]** $(date -u +%H:%M) — Working on branch \`$(git branch --show-current)\`. Last action: $1"
```

Mobile Claude can then check: *"What's the latest on issue #1 in my project?"*

### Option C: Shared Claude Project (conversational bridge)

Create a **Claude Project** (at claude.ai) and add both machines' CLAUDE.md as
project knowledge. When you open Claude on mobile within that project, it has
the same context as your dev machines. You can:

- Ask Claude to review the latest commits
- Give high-level instructions that you'll pick up on the machines
- Use it as a shared notebook for architecture decisions

This doesn't require any infrastructure — just the same Claude account on all
devices.

---

## Quick-Start Setup Checklist

### Prerequisites
- [ ] Both machines on the same LAN
- [ ] Git repo with shared remote (GitHub/GitLab)
- [ ] Claude Code installed on both machines
- [ ] SSH access between machines (for tmux coordination)
- [ ] Node.js installed (for MCP servers)

### Step 1: Shared Foundation
- [ ] Commit `CLAUDE.md` and `.claude/rules/` to your project
- [ ] Add `.claude/*.local.md` and `.claude/*.local.json` to `.gitignore`
- [ ] Create `.claude/hub-agent.local.md` on each machine with its role

### Step 2: Cross-Machine MCP Servers
- [ ] Generate a shared secret: `openssl rand -hex 32`
- [ ] Add `HUB_SHARED_SECRET` to each machine's shell profile
- [ ] Write your MCP server (or use an existing one)
- [ ] Start the MCP server on each machine
- [ ] Add `.mcp.json` to the project (committed)
- [ ] Add `HUB_PARTNER_IP` / `HUB_PARTNER_PORT` to each machine's shell profile
- [ ] Test: run Claude Code and verify partner tools appear

### Step 3: Multi-Agent Coordination
- [ ] Set up passwordless SSH between machines
- [ ] Start named tmux sessions on each machine (`tmux new -s coordinator`)
- [ ] Create the hook scripts (`session-sync.sh`, `agent-stop-notify.sh`)
- [ ] Configure hooks in `hooks.json` or `.claude/settings.json`
- [ ] Create task files in `.claude/tasks/`
- [ ] Test: start Claude Code on Machine B, let it finish, verify Machine A gets notified

### Step 4: Mobile Monitoring
- [ ] Choose your monitoring approach (git status file, GitHub Issues, or Claude Project)
- [ ] Set up the corresponding hooks
- [ ] Test: trigger a status update, check from mobile Claude

---

## File Reference

| File | Location | Committed? | Purpose |
|------|----------|-----------|---------|
| `CLAUDE.md` | Project root | Yes | Shared project memory |
| `.mcp.json` | Project root | Yes | MCP server definitions |
| `.claude/rules/*.md` | `.claude/rules/` | Yes | Coding standards & rules |
| `.claude/tasks/*.md` | `.claude/tasks/` | Yes | Task assignments |
| `.claude/hub-status.md` | `.claude/` | Yes | Status dashboard |
| `.claude/hub-agent.local.md` | `.claude/` | No | Machine identity & role |
| `hooks/hooks.json` | Plugin root | Yes | Hook configuration |
| `scripts/session-sync.sh` | Plugin/project | Yes | SessionStart sync script |
| `scripts/agent-stop-notify.sh` | Plugin/project | Yes | Stop notification script |
| `scripts/update-hub-status.sh` | Plugin/project | Yes | Status update script |
| `servers/local-tools.mjs` | Plugin/project | Yes | MCP server for local tools |

---

## Topology Variants

### Variant A: Symmetric peers (default above)
Both machines are equal peers that can coordinate. Either can be the coordinator.

### Variant B: Desktop as server, laptop as client
Machine A runs all MCP servers and the coordinator. Machine B is a thin client
that connects to Machine A for everything. Simpler setup, but Machine A must be
online.

### Variant C: Shared NFS/SMB workspace
Mount a shared network drive on both machines so they literally work on the same
files. Eliminates git sync but introduces file locking concerns. Best paired
with dev containers to avoid tool version conflicts.

### Variant D: Central dev container
Both machines connect to a single dev container (local Docker or cloud). Claude
Code runs inside the container. Both machines use VS Code Remote or SSH to
access it. The simplest option if you don't need independent local tools.
