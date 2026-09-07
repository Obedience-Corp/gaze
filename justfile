set dotenv-load := false

bin := "bin/gaze"
os := `uname -s`

default:
    @just --list --justfile {{source_file()}}

# Build the gaze CLI (macOS IOKit/AVFoundation, Linux V4L2)
build:
    mkdir -p bin
    just _build-{{os}}

_build-Darwin:
    clang -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
        -framework Foundation -framework IOKit \
        -framework AVFoundation -framework CoreMedia -framework CoreVideo \
        -framework CoreImage -framework ImageIO -framework CoreGraphics \
        -framework CoreServices \
        -o {{bin}} src/uvc_parse.c src/uvc_macos.m src/see_macos.m src/json.c src/cmd.c src/mcp.c src/main.m

_build-Linux:
    cc -std=c11 -D_GNU_SOURCE -O2 -Wall -Wextra -Werror -Wno-unused-parameter -Wno-format-truncation \
        -o {{bin}} src/uvc_parse.c src/uvc_linux.c src/see_linux.c src/json.c src/cmd.c src/mcp.c \
        -x c src/main.m -ljpeg

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
    python3 tests/test_plugins.py

# Protocol always. Hardware follows the plugged-in camera (skip if none).
test: test-protocol
    python3 tests/test_gaze.py

# Same hardware matrix, but fail if no UVC camera is on the wire.
test-hw: build
    python3 tests/test_gaze.py --require-hw

prefix := env_var_or_default("PREFIX", home_directory() + "/.local")

# Install the binary onto PATH (default: ~/.local/bin)
install: dist
    mkdir -p {{prefix}}/bin
    install -m 0755 {{bin}} {{prefix}}/bin/gaze
    @echo "installed {{prefix}}/bin/gaze"

# gitignored binary
dist: build
    strip {{bin}}
    ./{{bin}} --version

# Rebuild CLI stills + GIF for the README
docs:
    python3 scripts/render-cli.py
