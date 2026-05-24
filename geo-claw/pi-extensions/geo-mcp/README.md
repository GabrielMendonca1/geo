# geo-mcp pi extension

Exposes the Geo and Claw MCP bridges as pi tools so a `pi` subprocess can call
`mcp_geo_*` and `mcp_claw_*` tools mid-turn. Spawns each bridge as a long-lived
stdio child, performs the MCP handshake, registers every advertised tool, and
forwards calls over JSON-RPC.

## Install

```bash
bash install.sh
```

Symlinks this directory into `~/.pi/agent/extensions/geo-mcp`. Pi auto-discovers
it on next launch.

## Verify

Start pi and look for the registered tools (names prefixed `mcp_geo_` /
`mcp_claw_`). Bridge stderr is forwarded with `[geo-mcp:<label>]` prefixes.
Override binary locations with `GEO_MCP_BRIDGE_PATH` and
`GEO_CLAW_MCP_BRIDGE_PATH` if needed.
