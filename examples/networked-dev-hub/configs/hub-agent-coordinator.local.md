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

Place this file at `.claude/hub-agent.local.md` on the coordinator machine.
Make sure `.claude/*.local.md` is in your `.gitignore`.
