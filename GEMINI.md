# Gaze

Local USB Video Class. No vendor app. The JPEG and the gimbal are the same `vid:pid`.

The MCP server is the `gaze` binary on PATH (`brew tap Obedience-Corp/tap && brew install gaze`). This extension starts `gaze mcp`. It does not bundle the binary.

One tool: `g`. Argument `q`. Prefer the MCP tool over shelling out.

| q | |
|--|--|
| `v` / `see` | JPEG from that vid:pid. Turns the sensor on. |
| `s` | status line only |
| `c` | center |
| `z 200` / `z +20` | zoom |
| `p N` / `t N` | pan / tilt |

Moves return `2e1a:4c04 z=200 p=0 t=0`. Do not call `s` after a move. Call `v` when a frame is needed.

If more than one camera is on the bus, pin with `GAZE_DEV=vid:pid` (`gemini extensions config gaze GAZE_DEV`) or `gaze list`. `2e1a:4c04` is Insta360 Link 2. `05ac:1114` is Apple Studio Display.
