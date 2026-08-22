set dotenv-load := false

bin := "bin/gaze"

default:
    @just --list --justfile {{source_file()}}

# Build the gaze CLI (macOS)
build:
    mkdir -p bin
    clang -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
        -framework Foundation -framework IOKit \
        -framework AVFoundation -framework CoreMedia -framework CoreVideo \
        -framework CoreImage -framework ImageIO -framework CoreGraphics \
        -framework CoreServices \
        -o {{bin}} src/uvc_macos.m src/see_macos.m src/json.c src/cmd.c src/mcp.c src/main.m

# Run status
status: build
    ./{{bin}} status

# Center gimbal and reset zoom
center: build
    ./{{bin}} center

# JPEG from the sensor (turns the camera on)
see: build
    ./{{bin}} see see.jpg

# Stdio MCP (one tool; q=v returns a JPEG)
mcp: build
    ./{{bin}} mcp

# List UVC cameras and what they actually expose
list: build
    ./{{bin}} list

# Camera-free protocol tests (CI).
test-protocol: build
    python3 tests/test_protocol.py

# Protocol always. Hardware follows the plugged-in camera (skip if none).
test: test-protocol
    python3 tests/test_gaze.py

# Same hardware matrix, but fail if no UVC camera is on the wire.
test-hw: build
    python3 tests/test_gaze.py --require-hw

# gitignored binary
dist: build
    strip {{bin}}
    ./{{bin}} --version

# Rebuild CLI stills + GIF for the README
docs:
    python3 scripts/render-cli.py
