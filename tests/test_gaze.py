#!/usr/bin/env python3
"""Protocol tests always. Hardware tests follow whatever UVC camera is on the wire.

Gimbal cases skip when the device has no pan/tilt. Zoom cases skip when it has
no zoom. `just test-hw` refuses to pass if nothing is plugged in.

Do not ask an agent to try it. Run `just test`.
"""

import argparse
import json
import os
import re
import select
import subprocess
import sys
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAZE = ROOT / "bin" / "gaze"
OUT = Path("/tmp/gaze-test-see.jpg")


def run(args, timeout=12, env=None):
    e = os.environ.copy()
    if env:
        e.update(env)
    return subprocess.run(
        [str(GAZE), *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=timeout,
        env=e,
    )


def list_cameras():
    p = run(["list"], timeout=8)
    cams = []
    if p.returncode != 0:
        return cams
    for line in p.stdout.splitlines():
        m = re.match(
            r"([0-9a-fA-F]{4}):([0-9a-fA-F]{4})\s+zoom=(\d)\s+pantilt=(\d)\s+(.*)$",
            line,
        )
        if not m:
            continue
        cams.append(
            {
                "id": f"{m.group(1).lower()}:{m.group(2).lower()}",
                "zoom": m.group(3) == "1",
                "pantilt": m.group(4) == "1",
                "name": m.group(5).strip(),
            }
        )
    return cams


def parse_status(text):
    out = {"raw": text}
    first = text.splitlines()[0] if text.splitlines() else ""
    m = re.search(r"([0-9a-fA-F]{4}):([0-9a-fA-F]{4})", first)
    out["id"] = f"{m.group(1).lower()}:{m.group(2).lower()}" if m else ""
    out["name"] = first.rsplit("  ", 1)[0].strip() if "  " in first else first

    def axis(key):
        mm = re.search(rf"{key}\s+n/a", text)
        if mm:
            return None
        mm = re.search(rf"{key}\s+(-?\d+)\s+\((-?-?\d+)[^\d]+(-?\d+)\)", text)
        if not mm:
            return None
        return int(mm.group(1)), int(mm.group(2)), int(mm.group(3))

    out["zoom"] = axis("zoom")
    out["pan"] = axis("pan")
    out["tilt"] = axis("tilt")
    return out


def parse_line(text):
    m = re.search(r"z=(\d+)\s+p=(-?\d+)\s+t=(-?\d+)", text)
    if not m:
        raise AssertionError(f"no z/p/t in {text!r}")
    return int(m.group(1)), int(m.group(2)), int(m.group(3))


class Mcp:
    def __init__(self, env=None):
        e = os.environ.copy()
        if env:
            e.update(env)
        self.p = subprocess.Popen(
            [str(GAZE), "mcp"],
            cwd=ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
            env=e,
        )
        self._id = 0

    def close(self):
        if self.p.stdin:
            self.p.stdin.close()
        try:
            self.p.wait(timeout=2)
        except subprocess.TimeoutExpired:
            self.p.kill()
        if self.p.stdout:
            self.p.stdout.close()
        if self.p.stderr:
            self.p.stderr.close()

    def send(self, obj, expect=True, timeout=15):
        self.p.stdin.write(json.dumps(obj, separators=(",", ":")) + "\n")
        self.p.stdin.flush()
        if not expect:
            return None
        r, _, _ = select.select([self.p.stdout], [], [], timeout)
        if not r:
            raise TimeoutError(obj.get("method"))
        raw = self.p.stdout.readline()
        if not raw.strip():
            raise RuntimeError("empty MCP reply")
        return json.loads(raw)

    def call(self, method, params=None, timeout=15):
        self._id += 1
        msg = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            msg["params"] = params
        return self.send(msg, timeout=timeout)

    def g(self, q, timeout=15):
        return self.call(
            "tools/call", {"name": "g", "arguments": {"q": q}}, timeout=timeout
        )


class Protocol(unittest.TestCase):
    def test_help(self):
        p = run(["-h"])
        self.assertEqual(p.returncode, 0)
        self.assertIn("mcp", p.stderr)
        self.assertIn("see", p.stderr)
        self.assertIn("list", p.stderr)

    def test_mcp_handshake(self):
        mcp = Mcp()
        try:
            m = mcp.call(
                "initialize",
                {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {"name": "test", "version": "0"},
                },
            )
            self.assertEqual(m["result"]["serverInfo"]["name"], "gaze")
            mcp.send({"jsonrpc": "2.0", "method": "notifications/initialized"}, expect=False)
            time.sleep(0.05)
            self.assertIn("result", mcp.call("ping"))
            tools = mcp.call("tools/list")["result"]["tools"]
            self.assertEqual(len(tools), 1)
            self.assertEqual(tools[0]["name"], "g")
            bad = mcp.call("nope")
            self.assertEqual(bad["error"]["code"], -32601)
        finally:
            mcp.close()

    def test_list_is_honest_when_empty_or_not(self):
        p = run(["list"])
        cams = list_cameras()
        if cams:
            self.assertEqual(p.returncode, 0, p.stderr)
            self.assertGreater(len(cams), 0)
        else:
            self.assertEqual(p.returncode, 1)
            self.assertIn("no UVC camera", p.stderr)


def skip_no_cam():
    cams = list_cameras()
    if not cams:
        raise unittest.SkipTest("no UVC camera on the wire")
    return cams


class AnyUVC(unittest.TestCase):
    """JPEG + status on whatever UVC camera is present (gimbal or not)."""

    @classmethod
    def setUpClass(cls):
        cls.cams = skip_no_cam()
        cls.dev = cls.cams[0]
        print(
            f"\n# AnyUVC using {cls.dev['id']} {cls.dev['name']} "
            f"zoom={int(cls.dev['zoom'])} pantilt={int(cls.dev['pantilt'])}",
            flush=True,
        )

    def test_status_names_the_device(self):
        p = run(["-d", self.dev["id"], "status"])
        self.assertEqual(p.returncode, 0, p.stderr)
        st = parse_status(p.stdout)
        self.assertEqual(st["id"], self.dev["id"])
        if self.dev["zoom"]:
            self.assertIsNotNone(st["zoom"])
        else:
            self.assertIn("zoom    n/a", p.stdout)
        if self.dev["pantilt"]:
            self.assertIsNotNone(st["pan"])
            self.assertIsNotNone(st["tilt"])
        else:
            self.assertIn("pan     n/a", p.stdout)

    def test_see_writes_jpeg(self):
        if OUT.exists():
            OUT.unlink()
        p = run(["-d", self.dev["id"], "see", str(OUT)], timeout=20)
        self.assertEqual(p.returncode, 0, p.stderr)
        data = OUT.read_bytes()
        self.assertGreater(len(data), 2000, f"jpeg too small ({len(data)})")
        self.assertEqual(data[:2], b"\xff\xd8")

    def test_mcp_see_returns_image(self):
        mcp = Mcp(env={"GAZE_DEV": self.dev["id"]})
        try:
            mcp.call(
                "initialize",
                {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {"name": "test", "version": "0"},
                },
            )
            mcp.send({"jsonrpc": "2.0", "method": "notifications/initialized"}, expect=False)
            m = mcp.g("v", timeout=20)
            result = m["result"]
            self.assertFalse(result.get("isError"), result)
            kinds = [c["type"] for c in result["content"]]
            self.assertIn("image", kinds)
            img = next(c for c in result["content"] if c["type"] == "image")
            raw = __import__("base64").b64decode(img["data"])
            self.assertEqual(raw[:2], b"\xff\xd8")
            self.assertGreater(len(raw), 2000)
        finally:
            mcp.close()


class Zoom(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cams = [c for c in skip_no_cam() if c["zoom"]]
        if not cams:
            raise unittest.SkipTest("no UVC zoom on any plugged-in camera")
        cls.dev = cams[0]
        print(f"\n# Zoom using {cls.dev['id']} {cls.dev['name']}", flush=True)

    def test_zoom_roundtrip_uses_this_camera_range(self):
        st = parse_status(run(["-d", self.dev["id"], "status"]).stdout)
        cur, zmin, zmax = st["zoom"]
        target = zmin + (zmax - zmin) // 2
        if target == cur:
            target = zmax if cur != zmax else zmin
        try:
            a = run(["-d", self.dev["id"], "zoom", str(target)])
            self.assertEqual(a.returncode, 0, a.stderr)
            z, _, _ = parse_line(a.stdout)
            self.assertEqual(z, target, a.stdout)
        finally:
            run(["-d", self.dev["id"], "zoom", str(cur)])


class Gimbal(unittest.TestCase):
    """Mechanical or digital pan/tilt. Skips on clip-on webcams with no CT pan/tilt."""

    @classmethod
    def setUpClass(cls):
        cams = [c for c in skip_no_cam() if c["pantilt"]]
        if not cams:
            raise unittest.SkipTest("no UVC pan/tilt on any plugged-in camera")
        cls.dev = cams[0]
        print(f"\n# Gimbal using {cls.dev['id']} {cls.dev['name']}", flush=True)

    def _status(self):
        p = run(["-d", self.dev["id"], "status"])
        self.assertEqual(p.returncode, 0, p.stderr)
        return parse_status(p.stdout)

    def _nudge(self, axis, cur, amin, amax):
        span = amax - amin
        delta = max(span // 50, 1)
        target = cur + delta
        if target > amax:
            target = cur - delta
        if target < amin:
            target = amin + (span // 4 if span else 0)
        return target

    def test_pan_moves_then_restores(self):
        st = self._status()
        cur, pmin, pmax = st["pan"]
        target = self._nudge("pan", cur, pmin, pmax)
        try:
            moved = run(["-d", self.dev["id"], "pan", str(target)])
            self.assertEqual(moved.returncode, 0, moved.stderr)
            _, p1, _ = parse_line(moved.stdout)
            self.assertNotEqual(p1, cur, f"pan did not move on {self.dev['id']}: {cur}")
        finally:
            run(["-d", self.dev["id"], "pan", str(cur)])

    def test_tilt_moves_then_restores(self):
        st = self._status()
        cur, tmin, tmax = st["tilt"]
        target = self._nudge("tilt", cur, tmin, tmax)
        try:
            moved = run(["-d", self.dev["id"], "tilt", str(target)])
            self.assertEqual(moved.returncode, 0, moved.stderr)
            _, _, t1 = parse_line(moved.stdout)
            self.assertNotEqual(t1, cur, f"tilt did not move on {self.dev['id']}: {cur}")
        finally:
            run(["-d", self.dev["id"], "tilt", str(cur)])


if __name__ == "__main__":
    os.chdir(ROOT)
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--require-hw",
        action="store_true",
        help="fail if no UVC camera is plugged in (just test-hw)",
    )
    args, rest = parser.parse_known_args()
    cams = list_cameras()
    print("# UVC cameras:", flush=True)
    if not cams:
        print("#   (none)", flush=True)
    for c in cams:
        print(
            f"#   {c['id']}  {c['name']}  zoom={int(c['zoom'])} pantilt={int(c['pantilt'])}",
            flush=True,
        )
    if args.require_hw and not cams:
        print("gaze test-hw: no UVC camera plugged in", file=sys.stderr)
        sys.exit(1)
    unittest.main(argv=[sys.argv[0], *rest], verbosity=2)
