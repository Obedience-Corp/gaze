#!/usr/bin/env python3
"""Protocol + hardware tests. Run via `just test`. Do not ask an agent to try it."""

import json
import os
import re
import select
import subprocess
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAZE = ROOT / "bin" / "gaze"
OUT = Path("/tmp/gaze-test-see.jpg")


def run(args, timeout=12):
    return subprocess.run(
        [str(GAZE), *args],
        cwd=ROOT,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


class Mcp:
    def __init__(self):
        self.p = subprocess.Popen(
            [str(GAZE), "mcp"],
            cwd=ROOT,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
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


def parse_line(text):
    m = re.search(r"z=(\d+)\s+p=(-?\d+)\s+t=(-?\d+)", text)
    if not m:
        raise AssertionError(f"no z/p/t in {text!r}")
    return int(m.group(1)), int(m.group(2)), int(m.group(3))


class Protocol(unittest.TestCase):
    def test_help(self):
        p = run(["-h"])
        self.assertEqual(p.returncode, 0)
        self.assertIn("mcp", p.stderr)
        self.assertIn("see", p.stderr)

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
            ping = mcp.call("ping")
            self.assertIn("result", ping)
            listed = mcp.call("tools/list")
            tools = listed["result"]["tools"]
            self.assertEqual(len(tools), 1)
            self.assertEqual(tools[0]["name"], "g")
            self.assertIn("v", tools[0]["description"])
            bad = mcp.call("nope")
            self.assertEqual(bad["error"]["code"], -32601)
        finally:
            mcp.close()


class Hardware(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        p = run(["status"], timeout=8)
        if p.returncode != 0:
            raise unittest.SkipTest(f"no camera: {p.stderr.strip() or p.stdout.strip()}")
        cls.have = p.stdout

    def test_zoom_roundtrip(self):
        a = run(["zoom", "200"])
        self.assertEqual(a.returncode, 0, a.stderr)
        z, _, _ = parse_line(a.stdout)
        self.assertEqual(z, 200)
        b = run(["zoom", "100"])
        self.assertEqual(b.returncode, 0, b.stderr)
        z, _, _ = parse_line(b.stdout)
        self.assertEqual(z, 100)

    def test_pan_moves_then_restores(self):
        cur = run(["status"])
        self.assertEqual(cur.returncode, 0, cur.stderr)
        m = re.search(r"pan\s+(-?\d+)", cur.stdout)
        self.assertTrue(m, cur.stdout)
        p0 = int(m.group(1))
        target = p0 + 72000
        if target > 500000:
            target = p0 - 72000
        try:
            moved = run(["pan", str(target)])
            self.assertEqual(moved.returncode, 0, moved.stderr)
            _, p1, _ = parse_line(moved.stdout)
            self.assertGreater(abs(p1 - p0), 10000, f"gimbal did not pan: {p0} -> {p1}")
        finally:
            run(["pan", str(p0)])

    def test_see_writes_jpeg(self):
        if OUT.exists():
            OUT.unlink()
        p = run(["see", str(OUT)], timeout=20)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertTrue(OUT.exists(), "see did not write a file")
        data = OUT.read_bytes()
        self.assertGreater(len(data), 2000, f"jpeg too small ({len(data)}) — sensor likely off")
        self.assertEqual(data[:2], b"\xff\xd8", "not a JPEG")

    def test_mcp_see_returns_image(self):
        mcp = Mcp()
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
            self.assertFalse(result.get("isError"))
            kinds = [c["type"] for c in result["content"]]
            self.assertIn("text", kinds)
            self.assertIn("image", kinds)
            img = next(c for c in result["content"] if c["type"] == "image")
            self.assertEqual(img["mimeType"], "image/jpeg")
            raw = __import__("base64").b64decode(img["data"])
            self.assertEqual(raw[:2], b"\xff\xd8")
            self.assertGreater(len(raw), 2000)
            text = next(c["text"] for c in result["content"] if c["type"] == "text")
            parse_line(text)
        finally:
            mcp.close()


if __name__ == "__main__":
    os.chdir(ROOT)
    unittest.main(verbosity=2)
