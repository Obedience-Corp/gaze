---
name: gaze
description: >
  This skill should be used when the user asks to "look at my desk", "see the
  camera", "pan the webcam", "tilt", "zoom the camera", "PTZ", "give agents
  eyes", or mentions Gaze, Insta360 Link, OBSBOT, Studio Display camera,
  Elgato Facecam, Logitech Brio / Rally, or a UVC gimbal. Control a local
  UVC webcam and take a JPEG for the agent.
---

# Gaze

Local USB Video Class. No vendor app. The JPEG and the gimbal are the same `vid:pid`.

The binary is the MCP server. Install it first; plugins only wire `gaze mcp` into the agent.

```bash
brew tap Obedience-Corp/tap
brew install gaze
gaze list
```

## Plugin

| Agent | |
|--|--|
| Claude Code | `/plugin marketplace add Obedience-Corp/gaze` then `/plugin install gaze@gaze` |
| Grok | `grok plugin marketplace add Obedience-Corp/gaze` then `grok plugin install gaze --trust` |
| Codex | `codex plugin marketplace add Obedience-Corp/gaze` |
| Cursor | Agent Plugin at repo root (`plugin.json` + `mcp.json`). Local: `ln -s "$(pwd)" ~/.cursor/plugins/local/gaze` |

Drop-in MCP snippets live in `clients/`.

## MCP

One tool: `g`. Argument `q`. Prefer the MCP tool over shelling out.

Pin the camera when more than one is on the bus (`GAZE_DEV` or `gaze -d vid:pid mcp`):

```json
{
  "mcpServers": {
    "gaze": {
      "command": "gaze",
      "args": ["-d", "2e1a:4c04", "mcp"]
    }
  }
}
```

`2e1a:4c04` is Insta360 Link 2. `05ac:1114` is Apple Studio Display. Run `gaze list` if unsure.

| q | |
|--|--|
| `v` / `see` | JPEG from that vid:pid. Turns the sensor on. |
| `s` | status line only |
| `c` | center |
| `z 200` / `z +20` | zoom |
| `p N` / `t N` | pan / tilt |

Moves return `2e1a:4c04 z=200 p=0 t=0`. Do not call `s` after a move. Call `v` when a frame is needed.

If two cameras are plugged in, never rely on the default. Pass `-d vid:pid`.
