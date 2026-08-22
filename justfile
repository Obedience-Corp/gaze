set dotenv-load := false

default:
    @just --list --justfile {{source_file()}}

# Build the gaze CLI (macOS)
build:
    clang -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
        -framework Foundation -framework IOKit \
        -framework AVFoundation -framework CoreMedia -framework CoreVideo \
        -framework CoreImage -framework ImageIO -framework CoreGraphics \
        -framework CoreServices \
        -o gaze src/uvc_macos.m src/see_macos.m src/cmd.c src/mcp.c src/main.m

# Run status
status: build
    ./gaze status

# Center gimbal and reset zoom
center: build
    ./gaze center

# JPEG from the sensor (turns the camera on)
see: build
    ./gaze see see.jpg

# Stdio MCP (one tool; q=v returns a JPEG)
mcp: build
    ./gaze mcp

# Protocol + hardware tests. Hardware cases skip if no camera.
test: build
    python3 tests/test_gaze.py

# Rebuild CLI stills + GIF for the README
docs:
    python3 scripts/render-cli.py
