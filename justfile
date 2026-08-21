set dotenv-load := false

default:
    @just --list --justfile {{source_file()}}

# Build the gaze CLI (macOS)
build:
    clang -fobjc-arc -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
        -framework Foundation -framework IOKit \
        -o gaze src/uvc_macos.m src/cmd.c src/mcp.c src/main.m

# Run status
status: build
    ./gaze status

# Center gimbal and reset zoom
center: build
    ./gaze center

# Stdio MCP (one tool, one-line replies)
mcp: build
    ./gaze mcp
