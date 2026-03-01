# Pocket AI Terminal

iOS app + FastAPI backend providing cloud PTY sessions with two renderers:
Thread Mode (chat-like blocks) and Terminal Mode (native SwiftTerm).

See @build-sheet.md for the full specification. Read it before starting any work.

## Architecture

- `backend/` — FastAPI (Python 3.11+), Docker SDK, WebSocket relay
- `ios/` — SwiftUI (iOS 17+), SwiftTerm, no WKWebView
- `backend/docker/` — Runtime container (Debian bookworm-slim, gVisor)

## Commands

### Backend
```bash
cd backend
pip install -r requirements.txt
uvicorn app.main:app --reload --port 8000    # dev server
pytest tests/ -v                              # run tests
docker build -t pat-runtime -f docker/Dockerfile.runtime docker/  # build container
docker-compose up                             # full stack
```

### iOS
```bash
cd ios
open PocketAITerminal.xcodeproj
# Build: Cmd+B, Run: Cmd+R in Xcode
# Tests: Cmd+U
```

## Code Standards

### Python (Backend)
- Python 3.11+, type hints on all functions
- Pydantic v2 for models, async/await throughout
- `ruff` for linting and formatting
- Never log API keys or secrets — mask with `***`
- Tests with pytest + httpx (AsyncClient for FastAPI)

### Swift (iOS)
- SwiftUI, iOS 17+ minimum deployment target
- Swift concurrency (async/await, not Combine for new code)
- SwiftTerm for terminal rendering — never WKWebView
- Keychain for all secrets — never UserDefaults
- No force unwraps (`!`) outside of tests

## Critical Rules

- **Security is non-negotiable.** Read build-sheet.md Section 3 before writing any auth, secrets, or container code.
- **API keys never touch disk on the server.** tmpfs only. See build-sheet.md Section 3.5.
- **Containers run with gVisor (runsc), --cap-drop=ALL, --read-only.** See build-sheet.md Section 3.4.
- **WebSocket uses binary framing** with single-byte type prefix. See build-sheet.md Section 4.
- **OSC 133 for shell integration**, not custom text markers. See build-sheet.md Section 6.
- **Thread Mode is the product differentiator.** It must feel like iMessage for your terminal. See build-sheet.md Section 17.
- **SwiftTerm, not xterm.js.** No WKWebView in this project.

## Workflow

1. Read build-sheet.md fully before starting a milestone
2. Implement one milestone at a time (M1 → M2 → ... → M12)
3. Run acceptance tests listed in build-sheet.md Section 13 before moving on
4. Commit after each passing milestone with message: `feat(M{N}): {description}`
5. If stuck on a design decision, refer to build-sheet.md — it has the answer

## Key Files

- `build-sheet.md` — Full project specification (the source of truth)
- `backend/app/terminal_ws.py` — WebSocket relay (binary framing protocol)
- `backend/app/security.py` — Key injection, rate limiting
- `backend/docker/shell-integration.bash` — OSC 133 hooks
- `ios/.../Services/TerminalStream.swift` — Shared WS stream for both renderers
- `ios/.../Services/OSC133Parser.swift` — Shell integration parser
- `ios/.../Services/BlockStateMachine.swift` — Terminal stream → thread blocks
