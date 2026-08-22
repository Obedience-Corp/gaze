#!/usr/bin/env python3
"""Implement workflow/design/gaze-cameras/TEST.md. Matrix over `gaze list`."""

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

    def axis(key):
        if re.search(rf"{key}\s+n/a", text):
            return None
        mm = re.search(rf"{key}\s+(-?\d+)\s+\((-?\d+)[^\d]+(-?\d+)\)", text)
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


def cam_label(cam):
    return f"{cam['name']} ({cam['id']})"


def caps(cam):
    bits = ["see"]
    if cam["zoom"]:
        bits.append("zoom")
    if cam["pantilt"]:
        bits.append("pan/tilt")
    return " ".join(bits)


def announce(cam, what):
    print(f"#   {what:12}  {cam_label(cam)}", flush=True)


def move_target(cur, amin, amax):
    """TEST.md Move: one target, computed once."""
    span = amax - amin
    if span <= 0:
        return cur
    if cur <= amin:
        return min(amax, amin + max(span // 4, 1))
    if cur >= amax:
        return max(amin, amax - max(span // 4, 1))
    step = max(span // 50, 1)
    nearer_min = (cur - amin) <= (amax - cur)
    target = cur + step if nearer_min else cur - step
    if target > amax:
        target = amax
    if target < amin:
        target = amin
    return target


class Mcp:
    def __init__(self, env=None, extra=None):
        e = os.environ.copy()
        if env:
            e.update(env)
        cmd = [str(GAZE)]
        if extra:
            cmd.extend(extra)
        cmd.append("mcp")
        self.p = subprocess.Popen(
            cmd,
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
        self.assertIn("list", p.stderr)
        self.assertIn("see", p.stderr)
        self.assertIn("mcp", p.stderr)

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
            self.assertEqual(mcp.call("nope")["error"]["code"], -32601)
        finally:
            mcp.close()

    def test_list_exit_matches_rows(self):
        p = run(["list"])
        cams = list_cameras()
        if cams:
            self.assertEqual(p.returncode, 0, p.stderr)
        else:
            self.assertEqual(p.returncode, 1)
            self.assertIn("no UVC camera", p.stderr)


class Matrix(unittest.TestCase):
    """One walk: camera outer, columns inner. TEST.md."""

    @classmethod
    def setUpClass(cls):
        cls.cams = list_cameras()
        if not cls.cams:
            raise unittest.SkipTest("no UVC camera on the wire")
        print("\n# hardware plan:", flush=True)
        for i, cam in enumerate(cls.cams, 1):
            print(f"#   {i}. {cam_label(cam)}  [{caps(cam)}]", flush=True)

    def test_matrix(self):
        for cam in self.cams:
            self._status(cam)
            if cam["zoom"]:
                self._zoom(cam)
            else:
                announce(cam, "zoom skip")
            if cam["pantilt"]:
                self._axis(cam, "pan")
                self._axis(cam, "tilt")
            else:
                announce(cam, "pan skip")
                announce(cam, "tilt skip")
            self._see(cam)
            self._mcp_see(cam)
        self._see_frames_are_distinct()

    def _see_frames_are_distinct(self):
        blobs = []
        for cam in self.cams:
            path = Path("/tmp") / f"gaze-test-see-{cam['id'].replace(':', '-')}.jpg"
            if path.exists():
                blobs.append((cam, path.read_bytes()))
        if len(blobs) < 2:
            return
        with self.subTest(column="see-identity"):
            self.assertNotEqual(
                blobs[0][1],
                blobs[1][1],
                f"see frames collided: {cam_label(blobs[0][0])} vs {cam_label(blobs[1][0])}",
            )

    def _status(self, cam):
        with self.subTest(camera=cam_label(cam), column="status"):
            announce(cam, "status")
            p = run(["-d", cam["id"], "status"])
            self.assertEqual(p.returncode, 0, p.stderr)
            st = parse_status(p.stdout)
            self.assertEqual(st["id"], cam["id"], p.stdout)
            if cam["zoom"]:
                self.assertIsNotNone(st["zoom"], p.stdout)
            else:
                self.assertIn("zoom    n/a", p.stdout)
            if cam["pantilt"]:
                self.assertIsNotNone(st["pan"], p.stdout)
                self.assertIsNotNone(st["tilt"], p.stdout)
            else:
                self.assertIn("pan     n/a", p.stdout)

    def _zoom(self, cam):
        with self.subTest(camera=cam_label(cam), column="zoom"):
            announce(cam, "zoom")
            st = parse_status(run(["-d", cam["id"], "status"]).stdout)
            cur, zmin, zmax = st["zoom"]
            target = zmin + (zmax - zmin) // 2
            if target == cur:
                target = zmax if cur != zmax else zmin
            try:
                a = run(["-d", cam["id"], "zoom", str(target)])
                self.assertEqual(a.returncode, 0, a.stderr)
                z, _, _ = parse_line(a.stdout)
                self.assertEqual(z, target, a.stdout)
            finally:
                run(["-d", cam["id"], "zoom", str(cur)])

    def _axis(self, cam, axis):
        with self.subTest(camera=cam_label(cam), column=axis):
            announce(cam, axis)
            st = parse_status(run(["-d", cam["id"], "status"]).stdout)
            cur, amin, amax = st[axis]
            target = move_target(cur, amin, amax)
            try:
                moved = run(["-d", cam["id"], axis, str(target)])
                self.assertEqual(moved.returncode, 0, moved.stderr)
                z, p, t = parse_line(moved.stdout)
                got = p if axis == "pan" else t
                if got == cur:
                    time.sleep(0.2)
                    st2 = parse_status(run(["-d", cam["id"], "status"]).stdout)
                    got = st2[axis][0]
                self.assertNotEqual(
                    got,
                    cur,
                    f"{axis} advertised but SET did not change GET on {cam_label(cam)} "
                    f"(was {cur}, target {target}, got {got})",
                )
            finally:
                run(["-d", cam["id"], axis, str(cur)])

    def _see(self, cam):
        with self.subTest(camera=cam_label(cam), column="see"):
            announce(cam, "see")
            path = Path("/tmp") / f"gaze-test-see-{cam['id'].replace(':', '-')}.jpg"
            if path.exists():
                path.unlink()
            p = run(["-d", cam["id"], "see", str(path)], timeout=20)
            self.assertEqual(p.returncode, 0, p.stderr)
            data = path.read_bytes()
            self.assertGreater(len(data), 2000, f"jpeg too small ({len(data)})")
            self.assertEqual(data[:2], b"\xff\xd8")

    def _mcp_see(self, cam):
        with self.subTest(camera=cam_label(cam), column="mcp see"):
            announce(cam, "mcp see")
            mcp = Mcp(extra=["-d", cam["id"]])
            try:
                mcp.call(
                    "initialize",
                    {
                        "protocolVersion": "2025-03-26",
                        "capabilities": {},
                        "clientInfo": {"name": "test", "version": "0"},
                    },
                )
                mcp.send(
                    {"jsonrpc": "2.0", "method": "notifications/initialized"},
                    expect=False,
                )
                result = mcp.g("v", timeout=20)["result"]
                self.assertFalse(result.get("isError"), result)
                img = next(c for c in result["content"] if c["type"] == "image")
                raw = __import__("base64").b64decode(img["data"])
                self.assertEqual(raw[:2], b"\xff\xd8")
                self.assertGreater(len(raw), 2000)
            finally:
                mcp.close()


def print_detected(cams):
    print("# cameras detected:", flush=True)
    if not cams:
        print("#   (none)", flush=True)
        return
    for i, c in enumerate(cams, 1):
        print(f"#   {i}. {cam_label(c)}  [{caps(c)}]", flush=True)


if __name__ == "__main__":
    os.chdir(ROOT)
    parser = argparse.ArgumentParser()
    parser.add_argument("--require-hw", action="store_true")
    args, rest = parser.parse_known_args()
    cams = list_cameras()
    print_detected(cams)
    if args.require_hw and not cams:
        print("gaze test-hw: no UVC camera plugged in", file=sys.stderr)
        sys.exit(1)
    unittest.main(argv=[sys.argv[0], *rest], verbosity=2)
