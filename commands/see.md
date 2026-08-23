---
name: see
description: Snap a JPEG from the local UVC camera
allowed-tools:
  - "mcp__plugin_gaze_gaze__g"
---

Call the Gaze MCP tool `g` with `q` set to `v` (JPEG). `see` is the same verb.

Look at the returned image. Describe what is in frame. If the tool errors, quote the error verbatim.

If more than one camera is on the bus, do not guess. The pin is `GAZE_DEV=vid:pid` or `gaze -d vid:pid mcp`. `gaze list` is the source of truth.
