#!/bin/sh
# SessionStart: silent when gaze is on PATH. Speak only if the plugin cannot see.
if command -v gaze >/dev/null 2>&1; then
  exit 0
fi
printf '%s\n' \
  'gaze is not on PATH. This plugin starts `gaze mcp`; it does not bundle the binary.' \
  'macOS: brew tap Obedience-Corp/tap && brew install gaze'
exit 0
