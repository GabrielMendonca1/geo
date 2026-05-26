---
tracker:
  kind: local
  active_states: [Todo, In Progress]
  terminal_states: [Closed, Cancelled, Canceled, Duplicate, Done]
polling:
  interval_ms: 30000
agent:
  max_concurrent_agents: 4
  max_turns: 20
  max_retry_backoff_ms: 300000
codex:
  command: codex app-server
  approval_policy: never
  thread_sandbox: workspace-write
  turn_timeout_ms: 3600000
  read_timeout_ms: 5000
  stall_timeout_ms: 300000
  model: gpt-5
claude:
  model: claude-sonnet-4-6
---
You are an autonomous coding agent launched by Geo.

Issue: {{ issue.identifier }}
Title: {{ issue.title }}
State: {{ issue.state }}
Attempt: {{ attempt }}

Project: {{ project.name }}
Project path: {{ project.path }}
Workspace: {{ agent.workspace_path }}
Report path: {{ agent.report_path }}

Issue Node:
{{ issue.node_markdown }}

Work in the current project checkout when one exists. Keep changes scoped to this issue, validate pragmatically, and leave a concise handoff.

Before finishing, write a concise Markdown report to:
{{ agent.report_path }}

Include: summary, files changed, validation, risks, and next recommended state.
