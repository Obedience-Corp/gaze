#!/usr/bin/env python3
"""Plugin manifests wire `gaze mcp`. No camera, no network."""

import json
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def load_json(rel):
    p = ROOT / rel
    with p.open(encoding="utf-8") as f:
        return json.load(f)


class Plugins(unittest.TestCase):
    def test_agent_plugin_manifest(self):
        m = load_json("plugin.json")
        self.assertEqual(m["name"], "gaze")
        self.assertEqual(m["version"], "0.2.0")
        self.assertIn("agent-plugins.org", m["$schema"])
        self.assertEqual(m["license"], "Apache-2.0")

    def test_claude_plugin_and_marketplace(self):
        m = load_json(".claude-plugin/plugin.json")
        self.assertEqual(m["name"], "gaze")
        market = load_json(".claude-plugin/marketplace.json")
        self.assertEqual(market["name"], "gaze")
        plug = market["plugins"][0]
        self.assertEqual(plug["name"], "gaze")
        self.assertEqual(plug["source"], "./")

    def test_grok_marketplace(self):
        market = load_json(".grok-plugin/marketplace.json")
        self.assertEqual(market["name"], "gaze")
        self.assertEqual(market["plugins"][0]["source"], "./")

    def test_codex_plugin_and_marketplace(self):
        m = load_json(".codex-plugin/plugin.json")
        self.assertEqual(m["name"], "gaze")
        self.assertEqual(m["mcpServers"], "./.mcp.json")
        market = load_json(".agents/plugins/marketplace.json")
        src = market["plugins"][0]["source"]
        self.assertEqual(src["path"], "./")

    def test_cursor_plugin(self):
        m = load_json(".cursor-plugin/plugin.json")
        self.assertEqual(m["name"], "gaze")

    def test_gemini_extension(self):
        m = load_json("gemini-extension.json")
        self.assertEqual(m["name"], "gaze")
        self.assertEqual(m["version"], "0.2.0")
        self.assertEqual(m["contextFileName"], "GEMINI.md")
        srv = m["mcpServers"]["gaze"]
        self.assertEqual(srv["command"], "gaze")
        self.assertEqual(srv["args"], ["mcp"])
        env_vars = {s["envVar"] for s in m["settings"]}
        self.assertIn("GAZE_DEV", env_vars)
        self.assertTrue((ROOT / "GEMINI.md").is_file())
        see = (ROOT / "commands/see.toml").read_text(encoding="utf-8")
        gaze = (ROOT / "commands/gaze.toml").read_text(encoding="utf-8")
        self.assertIn("q=v", see)
        self.assertIn("{{args}}", gaze)
        raw = (ROOT / "gemini-extension.json").read_text(encoding="utf-8")
        self.assertNotIn("npx", raw)

    def test_mcp_stdio_is_gaze_binary(self):
        agent = load_json("mcp.json")
        srv = agent["mcpServers"]["gaze"]
        self.assertEqual(srv["type"], "stdio")
        self.assertEqual(srv["command"], "gaze")
        self.assertEqual(srv["args"], ["mcp"])
        claude = load_json(".mcp.json")
        srv2 = claude["mcpServers"]["gaze"]
        self.assertEqual(srv2["command"], "gaze")
        self.assertEqual(srv2["args"], ["mcp"])

    def test_client_snippets_run_gaze_mcp(self):
        for rel, key in (
            ("clients/claude-desktop.json", "mcpServers"),
            ("clients/cursor.json", "mcpServers"),
            ("clients/windsurf.json", "mcpServers"),
            ("clients/cline.json", "mcpServers"),
            ("clients/gemini.json", "mcpServers"),
        ):
            blob = load_json(rel)
            srv = blob[key]["gaze"]
            self.assertEqual(srv["command"], "gaze", rel)
            self.assertEqual(srv["args"], ["mcp"], rel)
        vs = load_json("clients/vscode.json")
        self.assertEqual(vs["servers"]["gaze"]["command"], "gaze")
        self.assertEqual(vs["servers"]["gaze"]["args"], ["mcp"])

    def test_toml_snippets(self):
        for rel in ("clients/codex.toml", "clients/grok.toml"):
            text = (ROOT / rel).read_text(encoding="utf-8")
            self.assertIn('command = "gaze"', text)
            self.assertIn('args = ["mcp"]', text)

    def test_continue_yaml(self):
        text = (ROOT / "clients/continue.yaml").read_text(encoding="utf-8")
        self.assertIn("command: gaze", text)
        self.assertIn("- mcp", text)

    def test_skill_frontmatter(self):
        text = (ROOT / "skills/gaze/SKILL.md").read_text(encoding="utf-8")
        self.assertTrue(text.startswith("---\n"))
        self.assertIn("name: gaze", text)
        self.assertIn("This skill should be used when", text)
        self.assertIn("q", text)
        self.assertIn("brew install gaze", text)

    def test_commands_exist(self):
        see = (ROOT / "commands/see.md").read_text(encoding="utf-8")
        gaze = (ROOT / "commands/gaze.md").read_text(encoding="utf-8")
        self.assertIn("q", see)
        self.assertIn("mcp__plugin_gaze_gaze__g", see)
        self.assertIn("$ARGUMENTS", gaze)

    def test_hook_script(self):
        script = ROOT / "hooks/check-gaze.sh"
        self.assertTrue(script.is_file())
        self.assertTrue(script.stat().st_mode & 0o111, "check-gaze.sh must be executable")
        text = script.read_text(encoding="utf-8")
        self.assertIn("brew install gaze", text)
        hooks = load_json("hooks/hooks.json")
        cmd = hooks["hooks"]["SessionStart"][0]["hooks"][0]["command"]
        self.assertIn("CLAUDE_PLUGIN_ROOT", cmd)
        self.assertIn("check-gaze.sh", cmd)

    def test_no_npm_wrapper(self):
        """The MCP server is the C binary. Do not ship an npx shim."""
        for rel in ("mcp.json", ".mcp.json", "clients/cursor.json", "gemini-extension.json"):
            raw = (ROOT / rel).read_text(encoding="utf-8")
            self.assertNotIn("npx", raw)
            self.assertNotIn("npm", raw)


if __name__ == "__main__":
    unittest.main(verbosity=2)
