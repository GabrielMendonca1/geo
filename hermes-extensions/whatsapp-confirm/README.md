# whatsapp-confirm

Blocks every agent-initiated WhatsApp send until Gabriel approves on Telegram.

## How it works

Registers two hermes plugin hooks:

- **`pre_gateway_dispatch`** — captures Gabriel's inbound Telegram messages from chat `5225262193` into an in-process queue. Returns `None` so normal gateway dispatch still sees the message.
- **`pre_tool_call`** — fires before every tool call. If `tool_name == "send_message"` and the `target` argument starts with `whatsapp:`, the hook:
  1. DMs Gabriel on Telegram with the recipient + a preview of the outbound message.
  2. Polls the queue for up to 30 s for a reply, sends a "5 s left" nudge at 25 s.
  3. On `Y` / `yes` / `ok` / `send` / `go` — returns `None` (lets the tool proceed).
  4. On `N` / `no` / `cancel` / `stop` — returns a block directive so the WhatsApp send never happens; the agent gets a denial message back.
  5. On timeout — same as `N`.

No tools registered. Pure hook plugin. Disabling the plugin re-enables silent WhatsApp sending.

## Install

```bash
bash install.sh
hermes plugins list | grep whatsapp-confirm
launchctl kickstart -k gui/$(id -u)/ai.hermes.gateway   # if gateway is running
```

## Notes

- Only `send_message` is intercepted. Other tools, and platforms other than WhatsApp, pass through unchanged.
- Uses the same in-process `send_message` registry entry to DM Telegram — no second TCP path, shares gateway state.
- The 30 s budget is the UX layer; if you need more time, just send `Y` whenever and approve the next attempt (the agent will retry on its own cadence after the deny message).
