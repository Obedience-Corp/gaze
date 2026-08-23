#!/usr/bin/env python3
"""Camera-free MCP/CLI protocol tests. CI runs these."""

import json
import os
import select
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
GAZE = ROOT / "bin" / "gaze"


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

    def send(self, raw, expect=True, timeout=5):
        if isinstance(raw, dict):
            raw = json.dumps(raw)
        self.p.stdin.write(raw + "\n")
        self.p.stdin.flush()
        if not expect:
            return None
        r, _, _ = select.select([self.p.stdout], [], [], timeout)
        if not r:
            raise TimeoutError(raw[:80])
        line = self.p.stdout.readline()
        if not line.strip():
            raise RuntimeError("empty MCP reply")
        return json.loads(line)

    def call(self, method, params=None):
        self._id += 1
        msg = {"jsonrpc": "2.0", "id": self._id, "method": method}
        if params is not None:
            msg["params"] = params
        return self.send(msg)


class Protocol(unittest.TestCase):
    def test_version(self):
        p = subprocess.run([str(GAZE), "--version"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0)
        self.assertIn("0.2.0", p.stdout)

    def test_handshake_and_nested_call(self):
        mcp = Mcp()
        try:
            m = mcp.call(
                "initialize",
                {
                    "protocolVersion": "2025-03-26",
                    "capabilities": {},
                    "clientInfo": {"name": "protocol-test", "version": "0"},
                },
            )
            self.assertEqual(m["result"]["serverInfo"]["name"], "gaze")
            self.assertEqual(m["result"]["serverInfo"]["version"], "0.2.0")
            mcp.send({"jsonrpc": "2.0", "method": "notifications/initialized"}, expect=False)
            self.assertIn("result", mcp.call("ping"))
            tools = mcp.call("tools/list")["result"]["tools"]
            self.assertEqual(tools[0]["name"], "g")
            nested = mcp.send(
                {
                    "jsonrpc": "2.0",
                    "id": 99,
                    "method": "tools/call",
                    "params": {
                        "name": "explode",
                        "arguments": {"q": "this-must-not-be-a-strstr-false-positive"},
                    },
                }
            )
            self.assertEqual(nested["id"], 99)
            self.assertTrue(nested["result"].get("isError"))
            self.assertEqual(nested["result"]["content"][0]["text"], "unknown tool")
            spaced = mcp.send(
                '{"jsonrpc" : "2.0", "id" : 100, "method" : "tools/call", '
                '"params" : { "name" : "g", "arguments" : { "q" : "not-a-verb" } } }'
            )
            self.assertEqual(spaced["id"], 100)
            self.assertTrue(spaced["result"].get("isError"))
            bad = mcp.call("nope")
            self.assertEqual(bad["error"]["code"], -32601)
            junk = mcp.send("{not json")
            self.assertEqual(junk["error"]["code"], -32700)
        finally:
            mcp.close()

    def test_notification_has_no_reply(self):
        mcp = Mcp()
        try:
            mcp.call("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}})
            mcp.send({"jsonrpc": "2.0", "method": "notifications/initialized"}, expect=False)
            pong = mcp.call("ping")
            self.assertEqual(pong["result"], {})
        finally:
            mcp.close()


if __name__ == "__main__":
    os.chdir(ROOT)
    unittest.main(verbosity=2)
