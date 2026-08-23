---
name: gaze
description: >
  Control a local UVC webcam (pan/tilt/zoom) and take a JPEG for the agent.
  Use when the user mentions a webcam, PTZ, gimbal, Insta360 Link, OBSBOT,
  Studio Display camera, "look at my desk", or Gaze MCP.
---

# Gaze

Local USB Video Class. No vendor app. The JPEG and the gimbal are the same `vid:pid`.

## Install

```bash
brew tap Obedience-Corp/tap
brew install gaze
gaze list
```

## MCP

Pin the camera when more than one is on the bus:

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

`2e1a:4c04` is Insta360 Link 2. `05ac:1114` is Apple Studio Display. Run `gaze list` if unsure. `GAZE_DEV` is the same pin.

One tool: `g`. Argument `q`.

| q | |
|--|--|
| `v` | JPEG from that vid:pid. Turns the sensor on. |
| `s` | status line only |
| `c` | center |
| `z 200` / `z +20` | zoom |
| `p N` / `t N` | pan / tilt |

Moves return `2e1a:4c04 z=200 p=0 t=0`. Do not call `s` after a move. Call `v` when you need to look.

If two cameras are plugged in, never rely on the default. Pass `-d vid:pid`.
