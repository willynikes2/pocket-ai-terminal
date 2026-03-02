#!/bin/bash
# /usr/local/bin/pat — PAT helper commands

case "${1:-help}" in
    start)
        if ! tmux has-session -t pat 2>/dev/null; then
            tmux new-session -d -s pat -c /workspace
            echo "Session created."
        else
            echo "Session already exists."
        fi
        ;;
    doctor)
        echo "=== PAT Doctor ==="
        echo "Node: $(node --version 2>/dev/null || echo 'not installed')"
        echo "npm: $(npm --version 2>/dev/null || echo 'not installed')"
        echo "Python: $(python3 --version 2>/dev/null || echo 'not installed')"
        echo "Git: $(git --version 2>/dev/null || echo 'not installed')"
        echo "tmux: $(tmux -V 2>/dev/null || echo 'not installed')"
        echo "Claude Code: $(claude --version 2>/dev/null || echo 'not installed')"
        echo "Workspace: $(du -sh /workspace 2>/dev/null | cut -f1)"
        echo "API Key: $([ -f /run/secrets/ANTHROPIC_API_KEY ] && echo 'set' || echo 'not set')"
        ;;
    claude)
        shift
        if ! command -v claude &>/dev/null; then
            echo "Installing Claude Code..."
            npm install -g @anthropic-ai/claude-code
        fi
        if [ ! -f /run/secrets/ANTHROPIC_API_KEY ]; then
            echo "Error: ANTHROPIC_API_KEY not set. Configure your key in the app settings."
            exit 1
        fi
        claude "$@"
        ;;
    claude-stream)
        shift
        if ! command -v claude &>/dev/null; then
            echo "Installing Claude Code..."
            npm install -g @anthropic-ai/claude-code
        fi
        if [ ! -f /run/secrets/ANTHROPIC_API_KEY ]; then
            echo "Error: ANTHROPIC_API_KEY not set. Configure your key in the app settings."
            exit 1
        fi
        # Explicit stream-json mode for Thread Mode integration
        claude --output-format stream-json --input-format stream-json "$@"
        ;;
    openai)
        echo "OpenAI CLI integration: not yet implemented."
        echo "You can use the API directly — OPENAI_API_KEY is available in your environment."
        ;;
    help|*)
        echo "Usage: pat <command>"
        echo ""
        echo "Commands:"
        echo "  start          Ensure tmux session exists"
        echo "  doctor         Check environment and versions"
        echo "  claude [args]  Run Claude Code"
        echo "  claude-stream  Run Claude Code in stream-json mode"
        echo "  openai         OpenAI CLI (not yet implemented)"
        echo "  help           Show this help"
        ;;
esac
