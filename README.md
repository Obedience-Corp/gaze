<h1 align="center">gaze</h1>

<p align="center">
  <img src="docs/hero-insta360-link2.jpg" width="720" alt="Insta360 Link 2 PTZ webcam and Insta360 Link 2C">
</p>

<p align="center"><b>Give your agents eyes.</b></p>

<p align="center">Native PTZ. No vendor app.</p>

<p align="center">
  USB Video Class on the wire. Pan, tilt, and zoom for
  <b>Insta360</b>, <b>OBSBOT</b>, <b>Logitech</b>, <b>Elgato</b>,
  <b>Yealink</b>, <b>AVer</b>, and any UVC camera that exposes the Camera Terminal.
</p>

<p align="center">
  <img src="docs/cli.gif" width="640" alt="gaze status, center, and zoom on an Insta360 Link 2">
</p>

## Cameras

Gaze talks USB Video Class 1.1 Camera Terminal controls (`CT_ZOOM_ABSOLUTE`, `CT_PANTILT_ABSOLUTE`). If `gaze status` prints zoom / pan / tilt ranges, it will move that camera. Vendor AI tracking is a separate XU.

<table align="center">
  <tr>
    <td align="center" width="220">
      <img src="docs/insta360-link2.png" width="200" alt="Insta360 Link 2 PTZ 4K webcam"><br>
      <b>Insta360</b><br>Link · Link 2 · Link 2 Pro · Link 2C
    </td>
    <td align="center" width="220">
      <img src="docs/obsbot-tiny3.png" width="200" alt="OBSBOT Tiny 3 PTZ 4K webcam"><br>
      <b>OBSBOT</b><br>Tiny · Tiny 2 · Tiny 3 · Tiny SE
    </td>
    <td align="center" width="220">
      <img src="docs/logitech-rally.png" width="200" alt="Logitech Rally PTZ conference camera"><br>
      <b>Logitech</b><br>Rally · Rally Bar · Meetup · PTZ Pro
    </td>
  </tr>
  <tr>
    <td align="center" width="220">
      <img src="docs/logitech-brio.png" width="200" alt="Logitech Brio 4K webcam"><br>
      <b>Logitech</b><br>Brio · MX Brio · C920 · StreamCam
    </td>
    <td align="center" width="220">
      <img src="docs/elgato-facecam-pro.jpg" width="200" alt="Elgato Facecam Pro webcam"><br>
      <b>Elgato</b><br>Facecam · Facecam Pro · Facecam 4K
    </td>
    <td align="center" width="220">
      <img src="docs/yealink-uvc86.png" width="200" alt="Yealink UVC86 PTZ conference camera"><br>
      <b>Yealink</b><br>UVC30 · UVC34 · UVC84 · UVC86
    </td>
  </tr>
</table>

| Brand | Models | Status |
| --- | --- | --- |
| **Insta360** | Link, Link 2, Link 2 Pro, Link 2C | **PTZ proven on Link 2** (`2e1a:4c04`) |
| **OBSBOT** | Tiny, Tiny SE, Tiny 2, Tiny 2 Lite, Tiny 3, Tiny 3 Lite | UVC PTZ. Next lab device. |
| **Logitech** | Rally, Rally Bar, Meetup, PTZ Pro 2 | UVC PTZ if the Camera Terminal has pan/tilt |
| **Logitech** | Brio, MX Brio, C920, C922, C930e, StreamCam | UVC zoom / exposure. No gimbal. |
| **Elgato** | Facecam, Facecam Pro, Facecam 4K, Facecam Neo, Facecam MK.2 | UVC. No gimbal. |
| **Yealink** | UVC30, UVC34, UVC84, UVC86 | Conference PTZ over UVC |
| **AVer** | CAM340+, CAM520 Pro, CAM550, CAM570 | Conference PTZ over UVC |
| **Poly** | Studio P15, Studio USB, EagleEye Cube | UVC where the terminal exists |
| **Anker** | Work, PowerConf C200 | UVC. C200 is not a gimbal. |
| **Razer** | Kiyo, Kiyo Pro, Kiyo Pro Ultra | UVC. No gimbal. |
| **PTZOptics**, **HuddleCamHD**, **Tenveo**, **NexiGo** | USB UVC SKUs | If they expose CT zoom / pan-tilt |

Quit the vendor controller first. Insta360 Webcam, OBSBOT Center, Logitech Tune, Elgato Camera Hub, Yealink USB Connect, AVer PTZApp.

## Install

macOS. `just` + clang.

```bash
just build
./gaze status
./gaze center
./gaze zoom 200
```

## MCP

The camera is the tool. One verb. One-line replies. After a move you already have state — do not call `s` again.

```json
{
  "mcpServers": {
    "gaze": {
      "command": "/absolute/path/to/gaze",
      "args": ["mcp"]
    }
  }
}
```

| q | |
|--|--|
| `s` | status |
| `c` | center |
| `z 200` / `z +20` | zoom |
| `p N` / `t N` | pan / tilt |

Reply: `2e1a:4c04 z=200 p=0 t=0`

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

FaceTime can keep the stream. Gaze uses IOKit `DeviceRequest` on the device node, no exclusive interface grab.

## License

Apache 2.0.

PTZ uses USB Video Class 1.1 Camera Terminal controls. Insta360 mode bytes on XU unit 9 selector 2 are the community-documented map (normal / track / whiteboard / overhead / deskview), confirmed on a Link 2.

Product photos: [Insta360](https://store.insta360.com/product/link-2) Link 2 / Link 2C, [OBSBOT](https://www.obsbot.com/store/products/tiny-3-series) Tiny 3, [Logitech](https://www.logitech.com/en-us/products/video-conferencing/conference-cameras/rally-ultra-hd-ptz-camera.html) Rally and [Brio](https://www.logitech.com/en-us/products/webcams/brio-4k-hdr-webcam.960-001105.html), [Elgato](https://www.elgato.com/us/en/p/facecam-pro) Facecam Pro, [Yealink](https://www.yealink.com/en/product-detail/compatible-camera-uvc86) UVC86.

---

Built with [Festival](https://fest.build)
