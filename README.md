<h1 align="center">gaze</h1>

<p align="center"><b>Native PTZ. No vendor app.</b></p>

<p align="center">USB Video Class on the wire. The gimbal finally listens.</p>

## Install

macOS. Quit the camera's official controller first.

```bash
just build
./gaze status
./gaze center
./gaze zoom 200
./gaze track on
```

## Commands

| | |
|--|--|
| `gaze status` | name, zoom, pan, tilt, mode |
| `gaze center` | pan 0, tilt 0, default zoom |
| `gaze zoom 200` | absolute, or `+20` / `-20` |
| `gaze pan` / `gaze tilt` | same, native UVC units |
| `gaze track on\|off` | writes Insta360 mode XU (Link 2 GET_CUR is stale) |
| `gaze deskview` / `overhead` / `whiteboard` | same |
| `gaze normal` | mode XU off |

v1 talks to any UVC camera that exposes a Camera Terminal with zoom / pan-tilt. **PTZ is proven on Link 2.** Vendor AI modes use the community XU map (unit 9 selector 2). OBSBOT is next.

## License

Apache 2.0.

PTZ uses USB Video Class 1.1 Camera Terminal controls (`CT_ZOOM_ABSOLUTE`, `CT_PANTILT_ABSOLUTE`). Insta360 mode bytes on XU unit 9 selector 2 are the community-documented map (normal / track / whiteboard / overhead / deskview), confirmed on a Link 2.

macOS USB uses IOKit `DeviceRequest` on the device node — no exclusive interface grab, so FaceTime can keep the stream.
