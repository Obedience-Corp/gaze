---
name: gaze
description: PTZ or snap the local UVC camera
argument-hint: "[v|s|c|z N|p N|t N]"
allowed-tools:
  - "mcp__plugin_gaze_gaze__g"
---

Call the Gaze MCP tool `g`. If `$ARGUMENTS` is empty, use `q=v`. Otherwise set `q` to `$ARGUMENTS`.

Compact verbs:

| q | |
|--|--|
| `v` / `see` | JPEG from that vid:pid. Turns the sensor on. |
| `s` | status line only |
| `c` | center |
| `z 200` / `z +20` | zoom |
| `p N` / `t N` | pan / tilt |

Moves return one line (`2e1a:4c04 z=200 p=0 t=0`). Do not call `s` after a move. Call `v` when a frame is needed.
