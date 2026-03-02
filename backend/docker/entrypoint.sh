#!/bin/bash
set -e

# Ensure tmux session exists
if ! tmux has-session -t pat 2>/dev/null; then
    tmux new-session -d -s pat -c /workspace \
        -x "${COLUMNS:-80}" -y "${LINES:-24}"
    # Configure tmux for cloud terminal use
    tmux set -g escape-time 0         # Zero escape delay for responsiveness
    tmux set -g status off             # iOS provides the chrome
    tmux set -g allow-passthrough on   # Let OSC sequences through
    tmux set -g history-limit 10000    # Scrollback
    tmux set -g mouse off              # iOS handles touch
fi

# Keep container alive
exec sleep infinity
