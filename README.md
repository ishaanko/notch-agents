# Notch Agents

An opensource, native macOS dynamic island for local AI coding agents.

Notch Agents watches agent sessions automatically with their current status, displays local rate-limit window, and jumps back to the originating terminal or app. Event data stays on the Mac and the hook bridge listens only on `127.0.0.1`.

The first public release is `v0.1.0`.

## Hook bridge

The bundled bridge reads a hook payload from stdin and forwards it to the local app:

```sh
printf '%s' '{"session_id":"demo","event":"tool-start","prompt":"Run tests"}' \
  | "Notch Agents.app/Contents/Helpers/notch-agents-bridge" --source codex
```

Permission and question requests keep the HTTP connection open until the user
responds in the notch. Ordinary lifecycle events return immediately. Passive
rollout, process, and database observers never create interaction forms because
they do not own a reply channel.

Hook installation preserves unrelated provider settings and makes a backup before changing an existing file. Codex’s required `[features] hooks = true` flag and OpenCode’s plugin registration are managed automatically.

## Build

Requires macOS 14 or newer and Xcode.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift build
./scripts/package-app.sh release
```
