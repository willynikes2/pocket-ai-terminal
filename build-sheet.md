# Pocket AI Terminal — Production Build Sheet v1.0

> **Hand this file to Claude Code / Opus to build.**
> Goal: iOS app + FastAPI backend providing **one cloud PTY session** with **two renderers**:
> 1) **Thread Mode** (chronological chat-like blocks — the product differentiator)
> 2) **Terminal Mode** (native SwiftTerm rendering)
>
> BYO API keys. Upload files to workspace. GitHub workflows. Mobile-first.
> **Security-first architecture. No shortcuts on secrets, isolation, or transport.**

---

## 0) Product Summary

Pocket AI Terminal is a mobile-first AI coding runtime:

- Start/resume/sleep cloud sessions (containers)
- Live terminal connection (PTY over WebSocket)
- BYO API keys (Anthropic/OpenAI) — stored in iOS Keychain, injected via tmpfs
- File uploads into `/workspace/uploads`
- GitHub clone/commit/push in terminal
- **Dual UI**:
  - **Thread Mode** (DEFAULT): Output grouped into chronological message blocks. This is the product. It turns a terminal into a readable conversation.
  - **Terminal Mode**: Native SwiftTerm rendering for interactive/full-screen programs

### Design Inspirations

- **Warp Terminal** — Block-based terminal architecture. Each command+output is a discrete "block" with its own header, exit code indicator, and copy action. Sticky command headers pin at the top when output overflows the viewport. Red sidebar on non-zero exit codes.
- **Termius** — Touch-first mobile terminal. Space-bar-long-press for arrow key emulation (hold + drag to move cursor). Collapsible extended keyboard row (Ctrl, Tab, Esc, arrows). Per-session color themes for visual differentiation.
- **Blink Shell** — Gesture-rich iOS terminal. Horizontal swipe to switch sessions. Pinch to zoom. Mosh support for resilient connections.
- **VS Code Terminal** — Shell integration via OSC 633 sequences. Command detection, exit code decoration, scrolling between commands.

Thread Mode takes the Warp block concept and goes further — it's not just blocks in a terminal, it's a **message thread where commands are messages and output is replies**. Think iMessage but for your server.

---

## 1) Non-goals (v0.1/v0.2)

- No full IDE/Monaco editor
- No background agents / PR automation
- No team/multi-user workspaces
- No GPU
- No inbound port publishing
- No token-proxy billing (BYO keys only)
- No WKWebView (use SwiftTerm for Terminal Mode)
- No certificate pinning (use ATS + TLS 1.3 + HSTS instead)

---

## 2) Architecture

### 2.1 System Overview

```
┌─────────────────────────────────────────────────────┐
│  iOS App (SwiftUI)                                  │
│  ┌────────────┐  ┌─────────────────────────────┐    │
│  │ Thread     │  │ Terminal Mode                │    │
│  │ Mode       │  │ (SwiftTerm native)           │    │
│  │ (LazyV-    │  │                              │    │
│  │  Stack)    │  │                              │    │
│  └─────┬──────┘  └──────┬──────────────────────┘    │
│        │                │                           │
│        └──────┬─────────┘                           │
│               │                                     │
│       ┌───────▼──────┐                              │
│       │ Terminal      │  ← Single shared stream     │
│       │ Stream        │  ← OSC 133 parser           │
│       │ (WebSocket)   │  ← Block state machine      │
│       └───────┬──────┘                              │
│               │ WSS (binary framing)                │
│  ┌────────────┤                                     │
│  │ Keychain   │ (API keys, JWT refresh token)       │
│  └────────────┘                                     │
└───────────────┼─────────────────────────────────────┘
                │ TLS 1.3
┌───────────────▼─────────────────────────────────────┐
│  FastAPI Backend                                    │
│  ┌──────────┐  ┌──────────┐  ┌────────────────┐    │
│  │ Auth     │  │ Session  │  │ WS Relay       │    │
│  │ (JWT)    │  │ Manager  │  │ (PTY ↔ client) │    │
│  └──────────┘  └──────────┘  └────────────────┘    │
│                      │                              │
│              ┌───────▼──────┐                       │
│              │ Container    │                       │
│              │ Orchestrator │                       │
│              └───────┬──────┘                       │
└──────────────────────┼──────────────────────────────┘
                       │
┌──────────────────────▼──────────────────────────────┐
│  Runtime Container (gVisor sandbox)                 │
│  ┌────────────┐  ┌──────────┐  ┌────────────────┐  │
│  │ tmux       │  │ bash +   │  │ /workspace     │  │
│  │ (control   │  │ OSC 133  │  │ (persistent    │  │
│  │  mode)     │  │ hooks    │  │  volume)       │  │
│  └────────────┘  └──────────┘  └────────────────┘  │
│  ┌────────────────────────────────────┐             │
│  │ /run/secrets (tmpfs, noexec)       │             │
│  │  ANTHROPIC_API_KEY                 │             │
│  │  OPENAI_API_KEY                    │             │
│  └────────────────────────────────────┘             │
└─────────────────────────────────────────────────────┘
```

### 2.2 Backend (FastAPI)

Responsibilities:
- Auth (dev token first; Sign in with Apple later)
- Session lifecycle: create/resume/sleep/stop
- Container orchestration via Docker SDK (gVisor runtime)
- PTY ↔ WebSocket relay (binary framing)
- Upload endpoint with validation
- Pre-warmed container pool management
- Idle detection + auto-sleep scheduler

### 2.3 Runtime Container

- Base: `debian:bookworm-slim`
- Runtime: gVisor (`runsc`) — **not runc**
- Tools: bash, tmux, git, curl, node LTS, npm, python3
- Persistent volume at `/workspace`
- tmpfs at `/run/secrets` for API keys
- OSC 133 shell hooks auto-injected via `/etc/bash.bashrc`
- `pat` helper script at `/usr/local/bin/pat`
- Read-only root filesystem with tmpfs overlays for `/tmp`, `/var/tmp`

### 2.4 iOS App (SwiftUI)

- Sessions list
- Terminal screen with toggle: **Thread | Terminal**
- Terminal Mode uses **SwiftTerm** (native Swift VT100/xterm emulator) — NOT WKWebView
- Thread Mode uses SwiftUI `ScrollView` + `LazyVStack` rendering blocks
- Both modes share the same underlying WebSocket connection and `TerminalStream`
- Keychain storage for all secrets

---

## 3) Security Architecture

### 3.1 iOS Device Security

**Keychain Configuration:**
```swift
// BYO API keys — highest security, device-bound, passcode-required
let apiKeyQuery: [String: Any] = [
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: "com.pocket-ai-terminal.api-keys",
    kSecAttrAccessible: kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
    kSecValueData: keyData
]

// JWT refresh token — device-bound, available when unlocked
let refreshTokenQuery: [String: Any] = [
    kSecClass: kSecClassGenericPassword,
    kSecAttrService: "com.pocket-ai-terminal.refresh-token",
    kSecAttrAccessible: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
    kSecValueData: tokenData
]

// JWT access token — in-memory only, never persisted
var accessToken: String? // instance property, zeroed on dealloc
```

**Memory Hygiene:**
- Zero API key bytes after transmission: `keyData.resetBytes(in: 0..<keyData.count)`
- Never log, print, or include keys in crash reports
- Use `Data` (not `String`) for secrets — strings may be interned/cached

### 3.2 Transport Security

**WebSocket Authentication — Ticket-Based First-Message Pattern:**

1. iOS app authenticates via REST → obtains short-lived ticket (30-second TTL, single-use, cryptographically random)
2. App opens WSS connection to `wss://api.example.com/sessions/{id}/ws`
3. First message sent: `{ "type": "auth", "ticket": "<ticket>" }`
4. Backend validates ticket, binds session, invalidates ticket immediately
5. If ticket invalid/expired → close connection with code 4001

Why this pattern:
- Query-parameter tokens leak in access logs and referrer headers
- Cookie-based auth is vulnerable to CSWSH (Cross-Site WebSocket Hijacking)
- First-message auth keeps tokens out of URLs and avoids cookie dependencies

**WebSocket Hardening:**
```python
# FastAPI WebSocket handler
MAX_MESSAGE_SIZE = 65536  # 64KB
MAX_CONNECTIONS_PER_USER = 5
PING_INTERVAL = 30  # seconds
IDLE_TIMEOUT = 1800  # 30 minutes
```

**TLS Requirements:**
- TLS 1.3 minimum (iOS App Transport Security enforces this by default)
- HSTS header: `Strict-Transport-Security: max-age=31536000; includeSubDomains`
- DNS CAA records restricting certificate issuance
- No certificate pinning (Apple discourages it; ATS + CAA is sufficient)

### 3.3 JWT Token Architecture

```
Access Token:
  - Algorithm: RS256 (asymmetric — public key can be distributed)
  - Lifetime: 15 minutes
  - Claims: { sub, iat, exp, session_ids[] }
  - Storage: in-memory only on iOS

Refresh Token:
  - Lifetime: 30 days
  - Storage: iOS Keychain (device-bound)
  - Server stores: SHA-256 hash only (never plaintext)
  - Single-use: rotated on every refresh

Rotation Protocol:
  1. Client sends refresh token
  2. Server validates hash, checks not previously used
  3. Server issues new access + refresh token pair
  4. Server invalidates old refresh token hash
  5. If a previously-used refresh token appears → REVOKE ALL tokens for user
     (indicates token theft)
```

**In-Session Token Refresh:**
- Client proactively refreshes 5 minutes before access token expiry
- For active WebSocket: send `{ "type": "token_refresh", "refresh_token": "..." }` over existing connection
- Server responds with new access token over same connection
- No connection interruption

### 3.4 Container Hardening

**Docker Run Flags (Mandatory):**
```bash
docker run \
  --runtime=runsc \                           # gVisor sandbox
  --cap-drop=ALL \                            # Drop ALL Linux capabilities
  --cap-add=CHOWN --cap-add=SETUID --cap-add=SETGID \  # Add back minimum
  --security-opt=no-new-privileges \          # Prevent privilege escalation
  --read-only \                               # Read-only root filesystem
  --tmpfs /tmp:noexec,nosuid,size=100m \      # Writable tmp
  --tmpfs /var/tmp:noexec,nosuid,size=50m \   # Writable var/tmp
  --tmpfs /run/secrets:noexec,nosuid,size=1m \ # Secrets mount
  --memory=512m \                             # Memory limit
  --cpus=1.0 \                                # CPU limit (makes mining unprofitable)
  --pids-limit=256 \                          # Prevent fork bombs
  --ulimit nofile=1024:2048 \                 # File descriptor limits
  --user 1000:1000 \                          # Non-root user
  --network=pat-restricted \                  # Custom restricted network
  -v pat-workspace-${SESSION_ID}:/workspace \  # Persistent workspace
  pat-runtime:latest
```

**Seccomp Profile (custom, extends Docker default):**
Block these additional syscalls beyond Docker's default 44:
- `mount`, `umount2` — prevent filesystem manipulation
- `ptrace` — prevent process tracing/debugging
- `kexec_load` — prevent kernel replacement
- `reboot` — prevent container reboot
- `swapon`, `swapoff` — prevent swap manipulation

**Network Egress Whitelisting (Primary Abuse Prevention):**
```bash
# Docker network with iptables rules
# ONLY allow outbound to:
- api.anthropic.com (443)
- api.openai.com (443)
- github.com (443)
- registry.npmjs.org (443)
- pypi.org (443)
- deb.debian.org (80, 443)
- DNS (53, UDP)
# DENY all other outbound traffic
```

This single measure prevents: cryptocurrency mining (must reach mining pools), data exfiltration to arbitrary endpoints, spam/abuse, and most malicious use patterns.

**CRITICAL — Never do these:**
- Never mount `/var/run/docker.sock` into containers
- Never use `docker run -e API_KEY=value` (visible in `docker inspect`, process tables, crash dumps)
- Never use `--build-arg` for secrets (visible in image history)
- Never use `--privileged`
- Never give containers `NET_ADMIN`, `SYS_ADMIN`, or `SYS_PTRACE`

### 3.5 BYO API Key Injection (Secrets Flow)

```
iOS Keychain → WSS first message → Backend memory →
  tmpfs /run/secrets/ANTHROPIC_API_KEY → Container reads file →
  Backend zeros its memory copy → Container stop destroys tmpfs
```

**Implementation:**
```python
# Backend: inject key into container tmpfs
async def inject_api_key(container_id: str, key_name: str, key_value: str):
    try:
        # Write to container's tmpfs mount
        exec_result = container.exec_run(
            f"sh -c 'printf \"%s\" \"$KEY\" > /run/secrets/{key_name} && chmod 400 /run/secrets/{key_name}'",
            environment={"KEY": key_value},
            user="root"
        )
        # Container .bashrc sources keys:
        # export ANTHROPIC_API_KEY=$(cat /run/secrets/ANTHROPIC_API_KEY 2>/dev/null)
    finally:
        # Zero the key in Python memory
        key_bytes = bytearray(key_value.encode())
        for i in range(len(key_bytes)):
            key_bytes[i] = 0
```

### 3.6 File Upload Security

```python
# Layered validation
ALLOWED_EXTENSIONS = {'.py', '.js', '.ts', '.json', '.yaml', '.yml', '.toml',
                      '.md', '.txt', '.sh', '.css', '.html', '.csv', '.xml',
                      '.rs', '.go', '.java', '.c', '.cpp', '.h', '.rb',
                      '.png', '.jpg', '.jpeg', '.gif', '.svg', '.pdf', '.zip'}
MAX_FILE_SIZE = 50 * 1024 * 1024  # 50MB
MAX_FILES_PER_UPLOAD = 10

async def validate_upload(file: UploadFile):
    # 1. Extension allowlist
    ext = Path(file.filename).suffix.lower()
    if ext not in ALLOWED_EXTENSIONS:
        raise HTTPException(400, f"File type {ext} not allowed")

    # 2. Size check
    content = await file.read()
    if len(content) > MAX_FILE_SIZE:
        raise HTTPException(400, "File too large")

    # 3. Path traversal prevention
    safe_name = Path(file.filename).name  # strip directory components
    target = Path(f"/workspace/uploads/{safe_name}")
    resolved = target.resolve()
    if not str(resolved).startswith("/workspace/uploads/"):
        raise HTTPException(400, "Invalid filename")

    # 4. Magic byte verification for binary files
    if ext in {'.png', '.jpg', '.jpeg', '.gif', '.pdf', '.zip'}:
        verify_magic_bytes(content, ext)

    return safe_name, content
```

### 3.7 Rate Limiting & Abuse Controls

```python
# Per-user limits
SESSION_LIMITS = {
    "max_concurrent_sessions": 3,
    "max_session_duration_hours": 6,
    "idle_timeout_minutes": 10,
    "max_uploads_per_hour": 50,
    "max_upload_bytes_per_hour": 500 * 1024 * 1024,  # 500MB
    "max_ws_messages_per_second": 100,
    "max_ws_connections": 5,
}

# Container resource limits
CONTAINER_LIMITS = {
    "cpus": 1.0,         # Makes mining unprofitable
    "memory": "512m",    # Prevents memory abuse
    "pids_limit": 256,   # Prevents fork bombs
    "disk_quota": "5g",  # Workspace volume limit
}
```

---

## 4) WebSocket Transport Protocol

### 4.1 Binary Framing

Single-byte type prefix + payload. Terminal I/O is raw binary; metadata is JSON.

**Client → Server:**
| Byte | Type | Payload |
|------|------|---------|
| `0x00` | AUTH | JSON: `{ "ticket": "..." }` |
| `0x01` | STDIN | Raw bytes (terminal input) |
| `0x02` | RESIZE | JSON: `{ "cols": 80, "rows": 24 }` |
| `0x03` | PING | Empty |
| `0x04` | TOKEN_REFRESH | JSON: `{ "refresh_token": "..." }` |

**Server → Client:**
| Byte | Type | Payload |
|------|------|---------|
| `0x80` | STDOUT | Raw bytes (terminal output) |
| `0x81` | SESSION_INFO | JSON: `{ "state": "active", "session_id": "..." }` |
| `0x82` | PONG | Empty |
| `0x83` | TOKEN_REFRESHED | JSON: `{ "access_token": "..." }` |
| `0x84` | ERROR | JSON: `{ "code": "...", "message": "..." }` |

### 4.2 Reconnection Strategy

```
1. Client disconnects (network loss, app backgrounded)
2. tmux session stays alive in container
3. Client reconnects with exponential backoff:
   1s → 2s → 4s → 8s → max 30s
4. Sends AUTH message with fresh ticket
5. Backend reattaches to tmux session
6. Backend replays last 100 lines via: tmux capture-pane -p -S -100
7. Client receives replay + live stream resumes
8. If 3 consecutive pongs missed → mark disconnected
9. tmux session survives for 30-minute grace period
```

### 4.3 Compression

- Enable `permessage-deflate` for messages > 128 bytes
- Skip compression for small keystrokes (latency > bandwidth savings)

---

## 5) Terminal Rendering — Dual Mode

### 5.1 Terminal Mode (SwiftTerm — Native)

**Why SwiftTerm, not xterm.js in WKWebView:**
- xterm.js has documented iOS issues: `term.onData` fires inconsistently, Smart Keyboard arrow keys unreliable, WKWebView user-agent detection breaks
- WKWebView runs in a separate process — adds async latency per keystroke
- iOS 15/17 introduced GPU rendering regressions and crashes in WKWebView
- SwiftTerm: pure Swift, CoreText/Metal rendering, native UIKit keyboard integration, no process boundary

**SwiftTerm Integration:**
```swift
import SwiftTerm

class TerminalModeView: UIViewRepresentable {
    let terminalStream: TerminalStream

    func makeUIView(context: Context) -> TerminalView {
        let tv = TerminalView(frame: .zero)
        tv.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        tv.nativeForegroundColor = .white
        tv.nativeBackgroundColor = UIColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0)

        // Connect to shared stream
        tv.terminalDelegate = context.coordinator
        terminalStream.onOutput = { data in
            tv.feed(byteArray: [UInt8](data))
        }
        return tv
    }

    // Coordinator handles resize events, sends input to WebSocket
    class Coordinator: TerminalViewDelegate {
        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            terminalStream.sendInput(Data(data))
        }
        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            terminalStream.sendResize(cols: newCols, rows: newRows)
        }
    }
}
```

**Features:**
- Full ANSI color (8, 256, 24-bit truecolor)
- Cursor positioning, alternate screen buffer
- Copy/paste via iOS system clipboard
- Pinch-to-zoom font size
- Extended keyboard row: Ctrl, Tab, Esc, arrow keys (collapsible)
- Termius-style space-bar-long-press for arrow emulation

### 5.2 Thread Mode (Chat-like — THE DIFFERENTIATOR)

See Section 17 for full rendering contract.

### 5.3 Mode Toggle

- Segmented control at top of session view: **Thread** | **Terminal**
- Default: **Thread** (this is the product differentiator)
- Switching does NOT restart session, does NOT create new container
- Switching only changes which renderer consumes the shared `TerminalStream`
- Both renderers can maintain independent state from the same stream
- Thread Mode accumulates block history; Terminal Mode maintains screen buffer via SwiftTerm

### 5.4 Extended Keyboard Row (Both Modes)

```swift
ToolbarItemGroup(placement: .keyboard) {
    HStack(spacing: 12) {
        KeyButton("Ctrl") { sendControlModifier() }
        KeyButton("Tab") { sendTab() }
        KeyButton("Esc") { sendEscape() }
        KeyButton("↑") { sendArrow(.up) }
        KeyButton("↓") { sendArrow(.down) }
        KeyButton("←") { sendArrow(.left) }
        KeyButton("→") { sendArrow(.right) }
        Spacer()
        KeyButton("⌨") { toggleKeyboardDismiss() }
    }
}
```

---

## 6) OSC 133 Shell Integration (Command Boundary Detection)

### 6.1 Protocol

OSC 133 is the FinalTerm/iTerm2 protocol adopted by VS Code, kitty, WezTerm, and Windows Terminal. It uses escape sequences to mark semantic zones in terminal output:

| Sequence | Meaning |
|----------|---------|
| `\x1b]133;A\x07` | Start of prompt |
| `\x1b]133;B\x07` | End of prompt, start of command input |
| `\x1b]133;C\x07` | Command executed, output follows |
| `\x1b]133;D;{exit_code}\x07` | Command finished, with exit code |

### 6.2 Shell Hooks (Injected via `/etc/bash.bashrc`)

```bash
# OSC 133 Shell Integration for PAT Thread Mode
# Injected into container's /etc/bash.bashrc

__pat_prompt_command() {
    local exit_code=$?
    # Mark end of previous command output + start of new prompt
    printf '\e]133;D;%s\a' "$exit_code"
    printf '\e]133;A\a'
}

# Set PROMPT_COMMAND to emit D (with exit code) and A at each prompt
PROMPT_COMMAND='__pat_prompt_command'

# PS1 ends with B marker (end of prompt, user input begins)
PS1='\[\e]133;B\a\]PAT \w> '

# PS0 emits C just before command output appears (Bash 4.4+)
PS0='\[\e]133;C\a\]'
```

### 6.3 Zsh Hooks (if zsh is installed)

```zsh
__pat_precmd() {
    local exit_code=$?
    printf '\e]133;D;%s\a' "$exit_code"
    printf '\e]133;A\a'
}

__pat_preexec() {
    printf '\e]133;C\a'
}

precmd_functions+=(__pat_precmd)
preexec_functions+=(__pat_preexec)
PS1='%{\e]133;B\a%}PAT %~> '
```

### 6.4 Why OSC 133 Instead of Custom Markers

The original build sheet used `__PAT_PROMPT__` and `__PAT_EXIT__$?__PAT_END__` as custom text markers. OSC 133 is superior because:

- **Industry standard** — identical to what VS Code, iTerm2, kitty, WezTerm, and Windows Terminal use
- **Invisible** — escape sequences don't appear in terminal output (custom text markers would show up in piped output, logs, etc.)
- **Exit code built-in** — `D;{code}` carries the exit code natively
- **No command wrapping needed** — the client doesn't need to modify the user's command before sending it. Shell hooks handle everything transparently
- **Works with sub-shells and scripts** — hooks fire at every prompt, not just for explicitly wrapped commands
- **Future-compatible** — VS Code's OSC 633 extends this with command text (`E`) and nonce (`F`) sequences

### 6.5 Fallback for Custom Markers (Backward Compatibility)

If OSC 133 hooks fail to load (e.g., custom .bashrc overrides PS1), the client can fall back to the original marker strategy:

```bash
# Fallback: client wraps command before sending
ACTUAL_COMMAND="{user_input}; echo __PAT_EXIT__\$?__PAT_END__"
```

Thread Mode parser should check for OSC 133 sequences first, then fall back to `__PAT_EXIT__` markers.

---

## 7) Runtime Container Spec

### 7.1 Dockerfile.runtime

```dockerfile
FROM debian:bookworm-slim

# Security: create non-root user
RUN groupadd -g 1000 pat && useradd -u 1000 -g pat -m -s /bin/bash pat

# Install system deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    bash tmux git curl ca-certificates openssh-client \
    python3 python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js LTS
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Create workspace
RUN mkdir -p /workspace/uploads && chown -R pat:pat /workspace

# Create secrets mount point
RUN mkdir -p /run/secrets && chown pat:pat /run/secrets

# Copy shell integration hooks
COPY shell-integration.bash /etc/profile.d/pat-shell-integration.sh
COPY pat.sh /usr/local/bin/pat
RUN chmod +x /usr/local/bin/pat

# Inject OSC 133 hooks into global bashrc
RUN cat /etc/profile.d/pat-shell-integration.sh >> /etc/bash.bashrc

# Container .bashrc sources secrets from tmpfs
RUN echo 'export ANTHROPIC_API_KEY=$(cat /run/secrets/ANTHROPIC_API_KEY 2>/dev/null)' >> /home/pat/.bashrc \
    && echo 'export OPENAI_API_KEY=$(cat /run/secrets/OPENAI_API_KEY 2>/dev/null)' >> /home/pat/.bashrc

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER pat
WORKDIR /workspace
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
```

### 7.2 entrypoint.sh

```bash
#!/bin/bash
set -e

# Ensure tmux session exists
if ! tmux has-session -t pat 2>/dev/null; then
    tmux new-session -d -s pat -c /workspace \
        -x "${COLUMNS:-80}" -y "${LINES:-24}"
    # Configure tmux for cloud terminal use
    tmux set -g escape-time 0         # Zero escape delay
    tmux set -g status off             # iOS provides the chrome
    tmux set -g allow-passthrough on   # Let OSC sequences through
    tmux set -g history-limit 10000    # Scrollback
    tmux set -g mouse off              # iOS handles touch
fi

# Keep container alive
exec sleep infinity
```

### 7.3 pat.sh (Helper Script)

```bash
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
        if ! command -v claude &>/dev/null; then
            echo "Installing Claude Code..."
            npm install -g @anthropic-ai/claude-code
        fi
        if [ ! -f /run/secrets/ANTHROPIC_API_KEY ]; then
            echo "Error: ANTHROPIC_API_KEY not set. Configure your key in the app settings."
            exit 1
        fi
        # Run Claude Code with stream-json for programmatic integration
        # The --output-format flag enables NDJSON typed events
        claude "$@"
        ;;
    claude-stream)
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
```

### 7.4 Pre-warmed Container Pool

```python
# Backend: maintain 5 ready-to-assign containers
POOL_SIZE = 5
POOL_REFILL_INTERVAL = 30  # seconds

class ContainerPool:
    def __init__(self):
        self.available: list[str] = []
        self.assigned: dict[str, str] = {}  # session_id -> container_id

    async def initialize(self):
        """Pre-create POOL_SIZE containers with tmux ready."""
        for _ in range(POOL_SIZE):
            container = await self._create_warm_container()
            self.available.append(container.id)

    async def assign(self, session_id: str) -> str:
        """Assign a pre-warmed container. Near-instant."""
        if not self.available:
            # Cold fallback — user waits ~1-2s
            container = await self._create_warm_container()
            container_id = container.id
        else:
            container_id = self.available.pop(0)

        self.assigned[session_id] = container_id

        # Refill pool asynchronously
        asyncio.create_task(self._refill_pool())

        return container_id

    async def _create_warm_container(self):
        """Create container with tmux pre-started."""
        container = docker_client.containers.run(
            "pat-runtime:latest",
            detach=True,
            runtime="runsc",
            # ... all security flags from Section 3.4 ...
        )
        # Wait for tmux to be ready
        await self._wait_for_tmux(container)
        return container
```

---

## 8) Session Lifecycle & APIs

### 8.1 Auth

```
POST /auth/dev-token
  → { "token": "<dev_token>" }
  ← { "access_token": "<jwt>", "refresh_token": "<token>", "expires_in": 900 }

POST /auth/refresh
  → { "refresh_token": "<token>" }
  ← { "access_token": "<jwt>", "refresh_token": "<new_token>", "expires_in": 900 }
```

### 8.2 Sessions

```
GET /sessions
  ← [{ "session_id": "...", "status": "active|sleeping|stopped", "created_at": "...", "last_active": "..." }]

POST /sessions
  → { "provider": "anthropic"|"openai", "api_key": "<encrypted>", "repo_url"?: "..." }
  ← { "session_id": "...", "status": "active", "ws_ticket": "<ticket>" }

POST /sessions/{id}/resume
  ← { "status": "active", "ws_ticket": "<ticket>" }

POST /sessions/{id}/sleep
  ← { "status": "sleeping" }

DELETE /sessions/{id}
  ← { "status": "deleted" }
```

### 8.3 Upload

```
POST /sessions/{id}/upload  (multipart/form-data)
  → file(s)
  ← { "uploaded": [{ "name": "file.py", "path": "/workspace/uploads/file.py", "size": 1234 }] }
```

### 8.4 WebSocket

```
WSS /sessions/{id}/ws
  → First message: { "type": "auth", "ticket": "<ticket>" }
  ← Binary framing per Section 4.1
```

---

## 9) File Upload (Mobile Killer Feature)

### iOS

- `UIDocumentPickerViewController` for file selection
- Multi-file selection enabled
- Progress indicator during upload
- Toast notification: `✅ Uploaded file.py → /workspace/uploads/file.py`

### Thread Mode Integration

After upload completes, append a system block:

```json
{
    "id": "uuid",
    "type": "meta",
    "category": "system",
    "command": null,
    "content": "Uploaded file.py → /workspace/uploads/file.py (2.4 KB)",
    "exit_code": null,
    "timestamp": "2025-01-15T10:30:00Z"
}
```

---

## 10) Abuse & Cost Controls

| Control | Value | Rationale |
|---------|-------|-----------|
| CPU per container | 1.0 vCPU | Makes mining unprofitable |
| Memory per container | 512MB | Prevents memory abuse |
| PIDs per container | 256 | Prevents fork bombs |
| Disk per workspace | 5GB | Storage cost control |
| No privileged mode | Always | Prevents host escape |
| No published ports | Always | Prevents hosting abuse |
| Auto-sleep | 10 min idle | Resource reclamation |
| Max session duration | 6 hours | Cost cap |
| Max concurrent sessions | 3 per user | Resource fairness |
| Network egress | Allowlist only | Prevents mining, exfil, spam |

### Idle Management (Three-Tier)

```
Tier 1 — Pause (10 min no input/output):
  docker pause → resumes in ~1s, frees CPU, retains memory
  Send warning to client 2 minutes before

Tier 2 — Stop (2 hours paused):
  docker stop → resumes in 2-5s, frees CPU + memory
  tmux session lost but workspace persists

Tier 3 — Archive (24+ hours stopped):
  Snapshot workspace volume, remove container
  Restore on next session create (10-30s)
```

---

## 11) Repo Structure

```
pocket-ai-terminal/
├── backend/
│   ├── app/
│   │   ├── main.py                  # FastAPI app, CORS, lifespan
│   │   ├── auth.py                  # JWT, dev-token, refresh rotation
│   │   ├── sessions.py              # Session CRUD endpoints
│   │   ├── docker_ctl.py            # Container orchestration, pool mgmt
│   │   ├── terminal_ws.py           # WebSocket relay, binary framing
│   │   ├── uploads.py               # File upload with validation
│   │   ├── models.py                # Pydantic models
│   │   ├── security.py              # Key injection, rate limiting
│   │   ├── notifications.py         # APNs push notifications
│   │   └── config.py                # Environment config
│   ├── docker/
│   │   ├── Dockerfile.runtime       # Container image
│   │   ├── entrypoint.sh            # tmux bootstrap
│   │   ├── pat.sh                   # Helper script
│   │   ├── shell-integration.bash   # OSC 133 hooks
│   │   └── seccomp-profile.json     # Custom seccomp rules
│   ├── docker-compose.yml
│   ├── requirements.txt
│   └── README.md
├── ios/
│   ├── PocketAITerminal/
│   │   ├── PocketAITerminalApp.swift
│   │   ├── Views/
│   │   │   ├── OnboardingView.swift
│   │   │   ├── SessionsView.swift
│   │   │   ├── TerminalContainerView.swift    # Thread|Terminal toggle
│   │   │   ├── ThreadTerminalView.swift       # SwiftUI blocks (LazyVStack)
│   │   │   ├── TerminalModeView.swift         # SwiftTerm wrapper
│   │   │   ├── SettingsView.swift
│   │   │   └── Components/
│   │   │       ├── CommandBlockView.swift      # Single command+output block
│   │   │       ├── ErrorBlockView.swift        # Error block with actions
│   │   │       ├── AIResponseBlockView.swift   # Claude output block
│   │   │       ├── SystemBlockView.swift       # Upload/meta notifications
│   │   │       ├── DiffPreviewView.swift       # Inline diff rendering
│   │   │       ├── InputBarView.swift          # Bottom command input
│   │   │       ├── ExtendedKeyboardView.swift  # Ctrl/Tab/Esc/arrows
│   │   │       ├── PredictionChipsView.swift   # Frequency-based command chips
│   │   │       ├── CommandHistoryView.swift     # Full-screen searchable history
│   │   │       ├── SnippetLibraryView.swift     # User-defined quick commands
│   │   │       └── WaitingForInputView.swift    # Pulsing Claude input block
│   │   ├── Services/
│   │   │   ├── APIClient.swift                # REST client
│   │   │   ├── KeychainService.swift          # Secure key storage
│   │   │   ├── TerminalStream.swift           # WS connection + binary framing
│   │   │   ├── OSC133Parser.swift             # Shell integration parser
│   │   │   ├── BlockStateMachine.swift        # Stream → blocks state machine
│   │   │   ├── ANSIParser.swift               # ANSI → AttributedString
│   │   │   ├── AuthManager.swift              # JWT lifecycle + refresh
│   │   │   ├── PredictionEngine.swift         # Command frequency + suggestions
│   │   │   ├── ClaudeInputDetector.swift      # Detect Claude waiting for input
│   │   │   └── NotificationManager.swift      # APNs registration + handling
│   │   ├── Models/
│   │   │   ├── Session.swift
│   │   │   ├── ThreadBlock.swift              # Block data model
│   │   │   ├── CommandRecord.swift            # Prediction data (Core Data)
│   │   │   ├── Snippet.swift                  # User-defined quick commands
│   │   │   └── AppState.swift
│   │   └── Package.swift                      # SwiftTerm dependency
│   └── PocketAITerminal.xcodeproj
└── docs/
    ├── SECURITY.md
    ├── ARCHITECTURE.md
    └── API.md
```

---

## 12) Implementation Milestones

### M1 — Backend: Container Spawn + WebSocket Relay
- FastAPI skeleton with auth (dev-token)
- Docker SDK: spawn gVisor container with security flags
- PTY created via tmux in container
- WebSocket endpoint with binary framing
- Acceptance: connect via `wscat`, type `pwd`, see `/workspace`

### M2 — iOS: SwiftTerm Terminal Mode
- Sessions list calling backend
- `TerminalModeView` wrapping SwiftTerm
- Connect to `ws_url`, send keystrokes, see output
- Extended keyboard row (Ctrl, Tab, Esc, arrows)
- Acceptance: run `ls`, `vim`, `htop` — all render correctly

### M3 — OSC 133 Shell Integration
- Shell hooks installed in container
- `OSC133Parser` in iOS parses escape sequences from stream
- `BlockStateMachine` accumulates blocks with command, output, exit code
- Acceptance: run command, parser correctly identifies prompt/command/output/exit boundaries

### M4 — Thread Mode Blocks
- `ThreadTerminalView` with `LazyVStack`
- `CommandBlockView` renders command + output
- `ErrorBlockView` renders non-zero exits with red accent
- System block for meta events
- Bottom input bar with send button
- Acceptance: run `ls` → command block appears. Run `false` → error block appears.

### M5 — Mode Toggle (Thread ↔ Terminal)
- `TerminalContainerView` with segmented control
- Shared `TerminalStream` feeds both renderers
- Switching preserves session state
- Acceptance: type in Thread Mode, switch to Terminal, see same session

### M6 — File Uploads
- iOS `UIDocumentPickerViewController`
- Backend upload endpoint with validation
- Files appear in `/workspace/uploads`
- Thread Mode shows system block for upload
- Acceptance: upload `test.py`, run `cat /workspace/uploads/test.py`

### M7 — Secrets Injection + Keychain
- iOS Keychain storage for API keys
- Key sent in session create, injected via tmpfs
- Keys never logged, never persisted at rest
- Acceptance: `pat doctor` shows "API Key: set", `echo $ANTHROPIC_API_KEY` works

### M8 — Claude Code Integration
- `pat claude` launches Claude Code in container
- Thread Mode detects Claude output via `stream-json` NDJSON
- AI response blocks rendered with distinct styling
- Diff preview for file changes (collapsed by default)
- Acceptance: `pat claude "explain this codebase"` → AI blocks appear

### M9 — Session Sleep/Resume + Idle Detection
- Auto-pause after 10 min idle
- Auto-stop after 2 hours paused
- Resume reconnects to tmux
- Scrollback replay on reconnect (last 100 lines)
- Acceptance: sleep session, resume, tmux history intact

### M10 — Pre-warmed Pool + Performance
- Container pool of 5 warm instances
- Session creation < 500ms
- WebSocket latency < 50ms for keystrokes
- Acceptance: create session, time-to-first-prompt < 1 second

### M11 — Predictive Command Bar (v0.2)
- CommandRecord collection from v0.1 (data model ready on day one)
- Frequency-based prediction chips above input bar
- Prefix filtering as user types
- Command history (swipe up on input bar)
- Snippet library (save/recall custom commands)
- Acceptance: run `git status` 5 times, it appears as top chip suggestion

### M12 — Push Notifications + Claude Input Alerts
- APNs device token registration
- Claude input detection (pattern matching + idle heuristic)
- Push notification when Claude asks a question (actionable: Y/N/Reply from lock screen)
- Push notification when long-running command (>30s) completes
- In-app toast banner for background session alerts
- Thread Mode pulsing "waiting for input" block UI
- Notification settings screen
- Acceptance: run `pat claude`, Claude asks y/n, lock phone, receive push, tap "Yes" from lock screen, Claude continues

---

## 13) Acceptance Tests

- [ ] Create session, connect in Terminal Mode, run `pwd` → `/workspace`
- [ ] Switch to Thread Mode, run `ls` → command block + output block
- [ ] Run `true` → Done block appears (✓ exit 0)
- [ ] Run `false` → Error block appears (✗ exit 1)
- [ ] Run multi-line output command → output grouped in single block
- [ ] Upload file → visible in `/workspace/uploads` and system block added
- [ ] `pat doctor` → all tools report versions
- [ ] `pat claude "hello"` → AI response blocks appear in Thread Mode
- [ ] Switch modes during active stream without dropping session
- [ ] Sleep/resume restores tmux + history
- [ ] API key not visible in `docker inspect` or container env
- [ ] Network egress blocked to non-allowlisted domains
- [ ] Fork bomb (`:(){ :|:& };:`) stopped by PID limit
- [ ] 512MB memory limit enforced
- [ ] Idle session pauses after 10 minutes
- [ ] Reconnect after network drop replays scrollback
- [ ] OSC 133 sequences correctly parsed into blocks
- [ ] vim/nano triggers "Open in Terminal Mode" prompt in Thread Mode
- [ ] File upload rejects `.exe`, path traversal attempts, oversized files
- [ ] Predictive chips show most-used commands after 5+ runs
- [ ] Typing prefix filters prediction chips in real-time
- [ ] Command history persists across app restarts
- [ ] Claude question triggers push notification when app backgrounded
- [ ] Y/N response from lock screen notification sends input to session
- [ ] Long-running command (>30s) triggers completion notification
- [ ] In-app toast appears when Claude waits in a background session
- [ ] CommandRecord data collected from first command (even before prediction UI ships)

---

## 14) Claude Prompts (Run in Order)

### Prompt 1 — Backend: FastAPI + Docker + WebSocket Relay

```
Build the FastAPI backend for Pocket AI Terminal. Implement:

1. POST /auth/dev-token → JWT (RS256, 15-min access, 30-day refresh with rotation)
2. POST /sessions, GET /sessions, POST /sessions/{id}/resume, POST /sessions/{id}/sleep, DELETE /sessions/{id}
3. Spawn runtime containers using Docker SDK with gVisor runtime (runsc). Apply ALL security flags: --cap-drop=ALL, --cap-add=CHOWN/SETUID/SETGID, --security-opt=no-new-privileges, --read-only, --memory=512m, --cpus=1.0, --pids-limit=256, --user=1000:1000, restricted network egress
4. WS /sessions/{id}/ws with binary framing protocol (single-byte type prefix)
5. Ticket-based WebSocket authentication (30-second TTL, single-use)
6. API key injection into container tmpfs at /run/secrets/ — zero memory after injection
7. Pre-warmed container pool (5 instances)
8. In-memory session registry

Use: FastAPI, docker-py, python-jose (RS256 JWT), uvicorn
Provide: Complete runnable code, docker-compose.yml, requirements.txt
```

### Prompt 2 — Runtime Container: Dockerfile + tmux + OSC 133 Hooks

```
Build the PAT runtime container. Implement:

1. Dockerfile.runtime based on debian:bookworm-slim
2. Install: bash, tmux, git, curl, node 20 LTS, npm, python3, claude-code
3. Non-root user (uid 1000) with /workspace as home
4. entrypoint.sh: create tmux session "pat" in /workspace with optimized settings (escape-time 0, status off, allow-passthrough on, history-limit 10000)
5. OSC 133 shell integration hooks in /etc/bash.bashrc:
   - PROMPT_COMMAND emits D;exit_code and A
   - PS1 ends with B marker
   - PS0 emits C before output
6. /usr/local/bin/pat helper with: start, doctor, claude, claude-stream, help
7. .bashrc sources API keys from /run/secrets/ tmpfs
8. Custom seccomp profile blocking mount, ptrace, kexec_load, reboot

Test: Build image, run container, verify OSC 133 sequences appear in output, verify tmux persistence across detach/reattach
```

### Prompt 3 — iOS: SwiftTerm Terminal Mode + Sessions List

```
Create the SwiftUI iOS app structure. Implement:

1. SessionsView: list of sessions from GET /sessions, create new session button
2. TerminalContainerView: holds Thread|Terminal segmented control toggle
3. TerminalModeView: SwiftTerm (not WKWebView) wrapped in UIViewRepresentable
4. TerminalStream service: WebSocket connection using URLSessionWebSocketTask with binary framing (single-byte type prefix), ticket-based auth, exponential backoff reconnection
5. KeychainService: store/retrieve API keys with kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
6. AuthManager: JWT lifecycle with proactive refresh
7. Extended keyboard row: Ctrl, Tab, Esc, arrow keys via ToolbarItemGroup

Dependencies: SwiftTerm (SPM), no WKWebView
Target: iOS 17+, SwiftUI
Provide: Complete Xcode project structure
```

### Prompt 4 — iOS: Thread Mode + OSC 133 Parser + Block State Machine

```
Add Thread Mode to the iOS app. Implement:

1. OSC133Parser: state machine that processes raw terminal bytes, detects \x1b]133;{A|B|C|D;code}\x07 sequences, and emits typed events (PromptStart, PromptEnd, CommandStart, CommandEnd(exitCode))
2. BlockStateMachine: consumes OSC133Parser events + raw output to produce ThreadBlock items following the schema:
   { id, type (user|output|error|meta), category (system|git|claude), command, content, exit_code, timestamp }
3. ANSIParser: converts ANSI escape sequences to AttributedString for SwiftUI rendering (SGR codes: 8-color, 256-color, 24-bit truecolor)
4. ThreadTerminalView: ScrollView + LazyVStack with .defaultScrollAnchor(.bottom)
5. Block views: CommandBlockView, ErrorBlockView, SystemBlockView
6. InputBarView: bottom fixed bar with monospace TextField, Send button, quick actions (Upload, Start Claude, Git status)
7. Interactive program detection: when alternate screen buffer activated (CSI ?1049h), show "Open in Terminal Mode" button
8. Fallback: if OSC 133 not detected, fall back to __PAT_EXIT__/__PAT_END__ text markers

Shared TerminalStream feeds both renderers. Mode toggle in TerminalContainerView.
```

### Prompt 5 — iOS: File Upload + Claude Code AI Blocks

```
Add file upload and Claude Code integration. Implement:

1. UIDocumentPickerViewController integration for multi-file selection
2. Upload via multipart POST to /sessions/{id}/upload with progress indicator
3. Toast notification on upload completion
4. System block in Thread Mode for upload events
5. Claude Code detection: when command starts with "claude" or "pat claude":
   - Parse output as AI response blocks with distinct styling (different background, AI icon)
   - Detect diff output (diff --git, @@, +++, ---) and render in collapsible DiffPreviewView
   - For pat claude-stream: parse NDJSON events (text, tool_use, tool_result) into typed AI blocks
6. Block actions: Copy output, Ask AI (pre-fill "explain this error: ..." with block content), Save to file

Ensure API keys are zeroed from memory after transmission.
```

### Prompt 6 — Predictive Command Bar + Push Notifications

```
Add predictive commands and push notifications to Pocket AI Terminal. Implement:

1. CommandRecord data model (Core Data): collect command, prefix, exitCode, cwd, timestamp, outputLength, durationMs from every command execution starting v0.1
2. Frequency-based prediction engine: rank commands by count * recency_weight (decays over 30 days), show top 5 as tappable chips above input bar
3. Prefix filtering: as user types, filter chips to matching commands in real-time
4. Command history view: swipe up on input bar for full-screen searchable history (persists across app restarts)
5. Snippet library: save/recall user-defined quick commands with {{placeholder}} support

6. APNs integration: device token registration endpoint (POST /users/device-token)
7. Claude input detection: ClaudeInputDetector that pattern-matches known question formats ((y/n), Allow?, etc.) + idle heuristic (>5s no output with question-like last line)
8. Push notifications via APNs:
   - CLAUDE_INPUT category: actionable with Yes/No/Reply actions from lock screen
   - COMMAND_COMPLETE category: for commands >30s
   - interruption-level: time-sensitive for Claude questions
9. Thread Mode "waiting for input" block: pulsing border, Y/N quick-response buttons, status indicator
10. In-app toast banners for background session alerts
11. Notification settings screen with granular toggles

Backend: APNs client (aioapns or similar), device token storage, notification dispatch on Claude input detection
iOS: UNUserNotificationCenter categories, actionable notifications, notification handling that sends terminal input
```

---

## 15) Notes

- Default mode: **Thread** — this is the product differentiator
- Traditional terminal must exist for interactive tools (vim, less, htop)
- Keep v0.2 minimal and shippable: Thread + Terminal + Upload + Claude
- SwiftTerm over WKWebView — avoids all iOS WebView pain points
- OSC 133 over custom markers — industry standard, invisible, no command wrapping
- gVisor over plain Docker — meaningful isolation without Firecracker complexity
- Network egress allowlist is the #1 anti-abuse measure
- Never persist API keys at rest on the server — tmpfs only

---

## 16) Future (v0.3+)

- Sign in with Apple (replace dev-token auth)
- Stripe subscription integration
- GitHub OAuth for private repo cloning
- Firecracker microVMs (replace gVisor at scale)
- CRIU checkpoint/restore for instant session resume
- Context-aware command predictions (Tier 2 — project type, git state, recent output)
- AI-powered command predictions (Tier 3 — lightweight model for next-command suggestion)
- Multiple AI providers (OpenAI, Google, local)
- iPad split-view with Thread Mode + file browser
- Team workspaces
- Background agents / PR automation

---

## 17) Thread Mode (Chronological) Rendering Contract

### Philosophy

Thread Mode is:

- **Strictly chronological** — every block appears in timeline order
- **Session == Message Thread** — one session is one conversation
- **Real shell commands** — no fake AI orchestration
- **Real shell output** — no simulated actions
- **No lies** — if a command failed, it shows as failed

Each command becomes a grouped message block in timeline order. The terminal stream is the source of truth. Thread Mode is a lens, not an interpreter.

### 17.1 Message Data Model

Every thread item follows this schema:

```json
{
    "id": "uuid",
    "type": "user | output | error | meta",
    "category": "system | git | claude",
    "command": "string (only for type: user)",
    "content": "string (stdout/stderr — ANSI parsed to AttributedString for display)",
    "exit_code": 0,
    "timestamp": "ISO 8601 string"
}
```

**Type definitions:**
- `user` — A command the user submitted. `command` field is populated.
- `output` — Standard output from a command (exit_code == 0).
- `error` — Output from a failed command (exit_code != 0) or detected stderr.
- `meta` — System event: upload notification, session event, mode switch.

**Category definitions:**
- `system` — Default. Regular shell commands, uploads, session events.
- `git` — Commands starting with `git`. Enables future git-aware rendering.
- `claude` — Commands starting with `claude` or `pat claude`. Triggers AI block rendering.

### 17.2 Block Rendering Rules

**Command Block (type: user)**
```
┌─────────────────────────────────────┐
│ > ls -la /workspace                 │
│   10:30 AM                          │
└─────────────────────────────────────┘
```
- Monospace font, slightly brighter background
- Chevron (>) prefix
- Timestamp in subtle secondary text
- Tap to copy command

**Output Block (type: output, exit_code == 0)**
```
┌─────────────────────────────────────┐
│ total 24                            │
│ drwxr-xr-x 3 pat pat 4096 ...      │
│ -rw-r--r-- 1 pat pat  512 ...      │
│                              ✓ 0    │
└─────────────────────────────────────┘
```
- Monospace font, ANSI colors preserved via `AttributedString`
- Green checkmark + exit code in bottom-right
- Collapse if > 50 lines (show first 20 + "Show N more lines")
- Actions on long-press: Copy | Save to File

**Done Block (no output, exit_code == 0)**
```
┌─────────────────────────────────────┐
│ ✓ Done (exit 0)                     │
└─────────────────────────────────────┘
```
- Subtle system bubble, muted colors
- Only shown when command produces zero stdout/stderr

**Error Block (type: error, exit_code != 0)**
```
┌─── ⚠ ──────────────────────────────┐
│ bash: command not found: foo        │
│                              ✗ 127  │
│  ┌──────┐ ┌────────┐ ┌──────┐      │
│  │ Copy │ │ Ask AI │ │ Save │      │
│  └──────┘ └────────┘ └──────┘      │
└─────────────────────────────────────┘
```
- Red/orange left border or accent
- Red ✗ + exit code
- Collapse if > 20 lines
- Action buttons: Copy | Ask AI | Save
- "Ask AI" pre-fills: `pat claude "Explain this error and suggest a fix: [first 500 chars of output]"`

**System/Meta Block (type: meta)**
```
┌─────────────────────────────────────┐
│ 📎 Uploaded config.yaml →           │
│    /workspace/uploads/config.yaml   │
│    (2.4 KB)                         │
└─────────────────────────────────────┘
```
- Centered, muted styling
- Used for: uploads, session events, mode switches, warnings

**AI Response Block (category: claude)**
```
┌─── 🤖 Claude ───────────────────────┐
│ I'll help you refactor that module.  │
│ Here are the changes I made:         │
│                                      │
│ ┌── diff ──────────────────────┐     │
│ │ - old_function()             │     │
│ │ + new_function()             │     │
│ └──────────────────────────────┘     │
│                                      │
│  ┌──────┐ ┌──────────┐              │
│  │ Copy │ │ View Diff │              │
│  └──────┘ └──────────┘              │
└──────────────────────────────────────┘
```
- Distinct background color (subtle blue/purple tint)
- AI icon + "Claude" label in header
- Markdown rendering for AI text output
- Diff blocks: collapsed by default, syntax-highlighted
- If using `stream-json`: map NDJSON event types to sub-components
  - `text` → markdown paragraph
  - `tool_use` → action card (file path + operation)
  - `tool_result` → collapsible output panel

### 17.3 Block State Machine

```
States:
  IDLE          → waiting for command
  COMMAND_SENT  → user submitted, waiting for output
  RECEIVING     → accumulating output between C and D markers
  COMPLETE      → block finalized with exit code

Transitions (OSC 133):
  IDLE + B marker       → record prompt end, ready for input
  IDLE + user submits   → create user block, → COMMAND_SENT
  COMMAND_SENT + C marker → → RECEIVING
  RECEIVING + output bytes → append to current block content
  RECEIVING + D;code marker → finalize block, set exit_code, → IDLE

Transitions (Fallback markers):
  IDLE + Enter pressed  → create user block, → COMMAND_SENT
  COMMAND_SENT + __PAT_EXIT__N__PAT_END__ → finalize, extract N as exit_code, → IDLE

Edge Cases:
  - Alternate screen buffer (CSI ?1049h) during RECEIVING:
    → Show "Interactive program running — Open in Terminal Mode" placeholder
    → When alternate screen exits (CSI ?1049l), resume RECEIVING
  - No D marker after 60 seconds:
    → Show "Still running..." indicator on block
    → Allow manual "Stop" action (sends Ctrl+C)
  - Multi-line commands (PS2 prompts between B and C):
    → Accumulate all input as the full command text
  - Partial escape sequence at chunk boundary:
    → Buffer incomplete sequences until next chunk arrives
```

### 17.4 Input Bar Specification

```
┌──────────────────────────────────────────┐
│ ┌──┐                            ┌──────┐ │
│ │📎│  $ command here...         │  ▶︎  │ │
│ └──┘                            └──────┘ │
│ ┌──────┐ ┌─────────┐ ┌──────────────┐   │
│ │Upload│ │Claude ▶ │ │git status    │   │
│ └──────┘ └─────────┘ └──────────────┘   │
└──────────────────────────────────────────┘
```

- Monospace `TextField` with `.lineLimit(1...5)` for multi-line
- Paperclip icon: triggers file upload picker
- Send button (▶): submits command
- Quick action chips (scrollable horizontal):
  - **Upload** — open file picker
  - **Claude ▶** — pre-fill `pat claude ""`
  - **git status** — submit immediately
  - **git diff** — submit immediately
  - **pat doctor** — submit immediately
- Enter key submits (Shift+Enter for newline on external keyboard)
- Command history: swipe up on input bar or dedicated history button

### 17.5 Claude Heuristics

When the submitted command starts with `claude` or `pat claude`:

1. Set block category to `claude`
2. Monitor output for AI patterns:
   - Lines starting with `>` (assistant thinking)
   - Diff markers: `diff --git`, `@@`, `+++`, `---`
   - Tool use indicators: `Reading file:`, `Writing file:`, `Running:`
3. Render with AI styling (distinct background, icon)
4. Auto-collapse diff previews
5. If using `pat claude-stream` (NDJSON mode):
   - Parse each JSON line as a typed event
   - Route to appropriate sub-renderer

**Do not over-engineer these heuristics.** Thread Mode must work perfectly for non-Claude commands. Claude detection is an enhancement, not a requirement. If heuristics fail, the output renders as a normal block — this is acceptable.

### 17.6 Interactive Program Detection

When the terminal stream contains alternate screen buffer activation:
- `CSI ?1049h` — alternate screen ON (vim, less, top, htop, nano)
- `CSI ?1049l` — alternate screen OFF

In Thread Mode, replace block content with:
```
┌─────────────────────────────────────┐
│ 🖥 Interactive program running       │
│ (vim, less, or similar)              │
│                                      │
│  ┌─────────────────────────────┐     │
│  │   Open in Terminal Mode →    │     │
│  └─────────────────────────────┘     │
└─────────────────────────────────────┘
```

Also heuristically detect by command prefix: `vim`, `vi`, `nano`, `less`, `more`, `top`, `htop`, `man`.

---

## 18) Predictive Command Bar (Smart Autocomplete)

### Philosophy

Typing on a phone is slow. The predictive command bar turns the input area into a **command palette that learns from your usage**. Think iOS keyboard predictions, but for shell commands. Not v1 — but designed now so the data model supports it from day one.

### 18.1 Three Tiers of Predictions

**Tier 1 — Frequency-Based (v0.2, ship first)**
Track every command the user runs per session. Rank by frequency + recency (weighted score). Show top 3-5 as tappable chips above the input bar.

```swift
struct CommandFrequency: Codable {
    let command: String
    let count: Int
    let lastUsed: Date
    var score: Double { Double(count) * recencyWeight }
    var recencyWeight: Double {
        let hoursSince = Date().timeIntervalSince(lastUsed) / 3600
        return max(0.1, 1.0 - (hoursSince / 720)) // decays over 30 days
    }
}
```

Storage: local SQLite or Core Data on device, per-user. Never sent to backend.

Prediction chips appear as the user types — filter by prefix match:
```
User types: "git"
┌───────────────────────────────────────────┐
│ [git status] [git diff] [git push origin] │
└───────────────────────────────────────────┘
│ $ git|                              [▶]   │
```

**Tier 2 — Context-Aware Suggestions (v0.3)**
Use the current working directory, recent output, and git state to suggest relevant commands:

- After `git diff` → suggest `git add .`, `git commit -m ""`
- After a failed build → suggest the build command again, or `cat` on the error file
- In a Node project (`package.json` exists) → suggest `npm install`, `npm run dev`
- After `cd` into a directory → suggest `ls`, `cat README.md`

Context signals:
```json
{
    "last_command": "git diff",
    "last_exit_code": 0,
    "cwd": "/workspace/my-project",
    "detected_project": "node",
    "git_status": "dirty",
    "recent_commands": ["npm install", "npm run build"]
}
```

**Tier 3 — AI-Powered Predictions (v0.4+)**
Send recent command history + context to a lightweight model for next-command prediction. This is where it gets magical — the app starts anticipating your workflow.

### 18.2 Command History (Persistent, Searchable)

```swift
struct CommandHistory: Codable {
    let sessionId: String
    let command: String
    let exitCode: Int
    let timestamp: Date
    let cwd: String?
}
```

- Swipe up on input bar → full-screen searchable history
- Search filters by prefix, substring, or regex
- History persists across app restarts (local only)
- Option to clear history per session or globally

### 18.3 Snippet Library (User-Defined Quick Commands)

Users can save custom snippets accessible from the input bar:

```
┌──────────────────────────────────────────────┐
│ 📌 Snippets                                  │
│ ┌──────────────────┐ ┌────────────────────┐  │
│ │ Deploy Prod      │ │ DB Backup          │  │
│ │ git push && ...  │ │ pg_dump -U ...     │  │
│ └──────────────────┘ └────────────────────┘  │
└──────────────────────────────────────────────┘
```

- Create from input bar long-press → "Save as Snippet"
- Create from any command block → long-press → "Save as Snippet"
- Snippets support `{{placeholder}}` variables that prompt before execution
- Stored locally in Core Data (no sensitive data in snippets)

### 18.4 Data Model for Predictions

```swift
// Collected from day one even if prediction UI ships later
struct CommandRecord: Codable {
    let id: UUID
    let sessionId: String
    let command: String        // full command text
    let commandPrefix: String  // first word (git, npm, pat, etc.)
    let exitCode: Int
    let cwd: String?
    let timestamp: Date
    let outputLength: Int      // bytes of output (useful for context)
    let durationMs: Int?       // how long command ran
}
```

**Start collecting `CommandRecord` from v0.1.** The prediction UI can ship later, but the data is there from the start.

### 18.5 UI Integration with Input Bar

```
Default state (no typing):
┌──────────────────────────────────────────┐
│ [git status] [pat claude] [npm run dev]  │  ← frequency chips
│ ┌──┐                            ┌──────┐ │
│ │📎│  $ ...                     │  ▶︎  │ │
│ └──┘                            └──────┘ │
│ [Upload] [Claude ▶] [Snippets 📌]        │  ← quick actions
└──────────────────────────────────────────┘

Typing state (prefix filtering):
┌──────────────────────────────────────────┐
│ [git status] [git diff] [git push]       │  ← filtered by "git"
│ ┌──┐                            ┌──────┐ │
│ │📎│  $ git|                    │  ▶︎  │ │
│ └──┘                            └──────┘ │
└──────────────────────────────────────────┘

Tap chip → fills input bar and auto-submits
(unless it contains {{placeholders}} — then fill + focus cursor on first placeholder)
```

---

## 19) Push Notifications & Claude Code Interaction Alerts

### Philosophy

When Claude Code asks a question or needs user input, the user might be doing something else on their phone. These moments are **high-value interruptions** — the AI is blocked waiting for you. Treat them like incoming text messages: badge, banner, sound (if enabled). This turns an async coding workflow into a responsive conversation.

### 19.1 Notification Triggers

| Event | Priority | Notification |
|-------|----------|-------------|
| Claude asks a question / needs input | **High** | Banner + badge + sound |
| Claude finished a long task | Medium | Banner + badge |
| Command finished (long-running, >30s) | Medium | Banner + badge |
| Session about to sleep (2 min warning) | Low | Silent banner |
| Session slept | Low | Badge only |
| Upload completed | Low | Silent banner |

### 19.2 Claude Code Input Detection

Claude Code signals it's waiting for user input in several ways. Detect these in the terminal stream:

**Pattern 1 — stream-json mode (`pat claude-stream`):**
NDJSON events include `tool_result` events that require user confirmation. Events with `"subtype": "input_request"` indicate Claude is waiting.

**Pattern 2 — Terminal-based detection (regular `pat claude`):**
Claude Code prints prompts like:
- `Do you want to proceed? (y/n)`
- `Allow this action? [Y/n]`
- Lines ending with `? ` followed by cursor waiting (no newline)
- The permission prompt: `Claude wants to [action]. Allow? (y/n/always)`

Detection heuristic:
```swift
struct ClaudeInputDetector {
    static let patterns: [String] = [
        "(y/n)", "(Y/n)", "[Y/n]", "[y/N]",
        "Allow?", "Proceed?", "Continue?",
        "? (yes/no)", "Enter your", "Type your",
        "What would you like", "How should I",
    ]

    func isWaitingForInput(lastLine: String) -> Bool {
        for pattern in Self.patterns {
            if lastLine.contains(pattern) { return true }
        }
        // Heuristic: line ends with "? " or ": " with no following newline
        if lastLine.hasSuffix("? ") || lastLine.hasSuffix(": ") {
            return true
        }
        return false
    }
}
```

**Pattern 3 — Idle output detection:**
If a claude-category block has been in `RECEIVING` state for >5 seconds with no new output, and the last line matches a question pattern → treat as waiting for input.

### 19.3 Thread Mode UI for Claude Questions

When Claude asks a question, the block gets special treatment:

```
┌─── 🤖 Claude ── WAITING FOR INPUT ──────┐
│ I found 3 files that need updating.      │
│ Do you want me to proceed with the       │
│ changes? (y/n)                           │
│                                          │
│  ┌─────┐  ┌──────┐  ┌─────────────┐     │
│  │  Y  │  │  N   │  │ Type reply  │     │
│  └─────┘  └──────┘  └─────────────┘     │
│                                          │
│  ⏳ Claude is waiting for your response  │
└──────────────────────────────────────────┘
```

- **Pulsing border** or subtle animation to draw attention
- **Quick response buttons**: Y / N for yes/no questions, extracted from the prompt pattern
- **"Type reply"** button focuses the input bar for free-form response
- **Status indicator**: "⏳ Claude is waiting for your response"
- Input bar auto-focuses when this block appears (if app is in foreground)

### 19.4 Push Notification Implementation (APNs)

**Backend — Send Push:**
```python
async def send_claude_waiting_notification(
    user_id: str, session_id: str, question: str
):
    payload = {
        "aps": {
            "alert": {
                "title": "Claude needs your input",
                "body": truncate(question, 100),
                "sound": "default"
            },
            "badge": 1,
            "category": "CLAUDE_INPUT",
            "thread-id": f"session-{session_id}",
            "interruption-level": "time-sensitive"  # breaks through Focus
        },
        "session_id": session_id,
        "block_id": block_id
    }
    await apns_client.send(payload, device_token)
```

**iOS — Actionable Notifications (Respond from Lock Screen):**
```swift
// Register notification actions
let yesAction = UNNotificationAction(
    identifier: "CLAUDE_YES", title: "Yes", options: []
)
let noAction = UNNotificationAction(
    identifier: "CLAUDE_NO", title: "No", options: []
)
let replyAction = UNTextInputNotificationAction(
    identifier: "CLAUDE_REPLY", title: "Reply", options: [],
    textInputButtonTitle: "Send",
    textInputPlaceholder: "Type your response..."
)

let claudeCategory = UNNotificationCategory(
    identifier: "CLAUDE_INPUT",
    actions: [yesAction, noAction, replyAction],
    intentIdentifiers: [], options: .customDismissAction
)
UNUserNotificationCenter.current().setNotificationCategories([claudeCategory])
```

**Handle notification response:**
```swift
func userNotificationCenter(_ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse) async {
    let sessionId = response.notification.request.content
        .userInfo["session_id"] as? String

    switch response.actionIdentifier {
    case "CLAUDE_YES":
        await terminalStream.sendInput("y\n", session: sessionId)
    case "CLAUDE_NO":
        await terminalStream.sendInput("n\n", session: sessionId)
    case "CLAUDE_REPLY":
        if let text = (response as? UNTextInputNotificationResponse)?.userText {
            await terminalStream.sendInput(text + "\n", session: sessionId)
        }
    default:
        navigateToSession(sessionId)  // open app to session
    }
}
```

### 19.5 In-App Alerts (App Foregrounded, Different Screen)

If the user has multiple sessions or is on the sessions list:
- **Toast banner** at top: "🤖 Claude is waiting for input in Session X"
- Tap banner → navigate to that session's Thread Mode
- Badge the session in sessions list with pulsing indicator

### 19.6 Long-Running Command Notifications

Any command running longer than 30 seconds notifies when complete:

```python
if command_duration > 30:
    send_notification(
        title=f"Command finished {'✓' if exit_code == 0 else '✗'}",
        body=truncate(command, 80),
        priority="medium",
        category="COMMAND_COMPLETE"
    )
```

Kick off a build, switch to another app, get a text-like notification when it's done. Mobile-first.

### 19.7 Notification Settings

```
Settings > Notifications
├── Claude Questions        [ON]  ← default ON, high priority
├── Command Completed       [ON]  ← only for commands >30s
├── Session Warnings        [ON]  ← sleep/idle warnings
├── Sound                   [ON]
└── Notification Preview    [Show question text / Hide]
```

### 19.8 Device Token Registration

```python
POST /users/device-token
  → { "device_token": "<apns_token>", "platform": "ios" }
  ← { "status": "registered" }
```

Backend tracks which sessions belong to which users. When Claude input detected → look up user → send push.

---

## 20) Design System (Thread Mode)

### Color Palette

```swift
enum PATColors {
    // Backgrounds
    static let sessionBg = Color(hex: "#0D1117")      // GitHub dark-style
    static let commandBg = Color(hex: "#161B22")       // Slightly lighter
    static let outputBg = Color(hex: "#0D1117")        // Same as session
    static let errorBg = Color(hex: "#1A0E0E")         // Dark red tint
    static let aiBg = Color(hex: "#0E1525")            // Dark blue tint
    static let metaBg = Color(hex: "#12151A")          // Subtle distinct
    static let inputBarBg = Color(hex: "#161B22")      // Matches command

    // Accents
    static let success = Color(hex: "#3FB950")         // Green checkmark
    static let error = Color(hex: "#F85149")           // Red error
    static let aiAccent = Color(hex: "#A371F7")        // Purple for AI
    static let prompt = Color(hex: "#8B949E")          // Muted prompt text
    static let command = Color(hex: "#E6EDF3")         // Bright command text

    // Borders
    static let blockBorder = Color(hex: "#21262D")     // Subtle separator
    static let errorBorder = Color(hex: "#F85149").opacity(0.5)
}
```

### Typography

```swift
enum PATFonts {
    static let mono = Font.system(.body, design: .monospaced)
    static let monoSmall = Font.system(.footnote, design: .monospaced)
    static let monoBold = Font.system(.body, design: .monospaced).bold()
    static let timestamp = Font.system(.caption2, design: .monospaced)
}
```

### Spacing & Layout

- Block vertical spacing: 4pt
- Block internal padding: 12pt horizontal, 8pt vertical
- Block corner radius: 8pt
- Input bar height: 44pt minimum, expands to 120pt max
- Extended keyboard row height: 36pt
- Minimum touch target: 44x44pt (Apple HIG)

---

## 21) SwiftTerm Integration Notes

### Package Dependency

```swift
// Package.swift or Xcode SPM
dependencies: [
    .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.0.0")
]
```

### Key Integration Points

1. **Feed data**: `terminalView.feed(byteArray: [UInt8](data))` — raw bytes from WebSocket
2. **Capture input**: `TerminalViewDelegate.send(source:data:)` — keystrokes to WebSocket
3. **Resize**: `TerminalViewDelegate.sizeChanged(source:newCols:newRows:)` — send resize message
4. **Font**: `terminalView.font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)`
5. **Colors**: Configure via `terminalView.nativeForegroundColor` and `nativeBackgroundColor`

### Shared Stream Architecture

```swift
class TerminalStream: ObservableObject {
    private var webSocket: URLSessionWebSocketTask?
    private var osc133Parser = OSC133Parser()

    // Terminal Mode consumes raw bytes
    var onRawOutput: ((Data) -> Void)?

    // Thread Mode consumes parsed blocks
    @Published var blocks: [ThreadBlock] = []

    func handleOutput(_ data: Data) {
        // Always forward raw bytes to Terminal Mode
        onRawOutput?(data)

        // Parse through OSC 133 for Thread Mode
        let events = osc133Parser.process(data)
        blockStateMachine.process(events)
    }

    func sendInput(_ data: Data) {
        // Prefix with STDIN type byte (0x01) and send
        var message = Data([0x01])
        message.append(data)
        webSocket?.send(.data(message)) { _ in }
    }

    func sendResize(cols: Int, rows: Int) {
        let json = #"{"cols":\#(cols),"rows":\#(rows)}"#
        var message = Data([0x02])
        message.append(json.data(using: .utf8)!)
        webSocket?.send(.data(message)) { _ in }
    }
}
```

---

## 22) Deployment Considerations

### Backend

- Deploy behind a reverse proxy (nginx/Caddy) with TLS termination
- WebSocket timeout: set proxy `proxy_read_timeout 3600s` for long-lived connections
- Run uvicorn with `--workers 4` minimum
- Docker daemon configured with gVisor: `sudo runsc install && systemctl restart docker`
- Set up Docker network with iptables egress rules per Section 3.4
- Log rotation: rotate backend logs, never log API keys
- Health check: `GET /health` returns container pool status

### iOS

- Target: iOS 17+
- SwiftTerm via SPM
- App Transport Security: default (enforces TLS 1.3)
- Background execution: register for `UIBackgroundTaskIdentifier` to maintain WS during brief backgrounds
- Push notification: notify when long-running command completes (future)

---
