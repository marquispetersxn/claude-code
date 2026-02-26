---
role: worker
machine_name: laptop
agent_name: beta
capabilities: ["testing", "linting", "deployment"]
partner_ip: 192.168.1.100
partner_port: 8100
coordinator_session: coordinator
coordinator_host: 192.168.1.100
---

# Machine B — Worker

Secondary machine focused on testing and deployment.
Reports status to the coordinator on Machine A when tasks complete.

Place this file at `.claude/hub-agent.local.md` on the worker machine.
Make sure `.claude/*.local.md` is in your `.gitignore`.
