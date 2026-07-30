# Notch Agents

An opensource, native macOS dynamic island for local AI coding agents.

Notch Agents watches agent sessions and shows their current status. It also shows local rate-limit windows and can open the related terminal or app. Event data stays on the Mac. The hook bridge listens only on `127.0.0.1`.

The latest release is [**Notch Agents v0.1.1**](https://github.com/ishaanko/notch-agents/releases/tag/v0.1.1).

## Use

- Press Control–Option–N to show or hide the notch.
- Use the menu bar item to open a current session, show all sessions, mute sounds, or open Settings.
- Use the arrow buttons in the notch to move between current sessions.

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

Hook installation keeps other provider settings. It makes a backup before it changes a file. Notch Agents manages the required Codex `[features] hooks = true` flag and the OpenCode plug-in entry.

## Build

The build requires macOS 14 or later and Xcode.

```sh
./script/build_and_run.sh --verify
```

This command stops the current development build, builds a new app bundle, starts it, and verifies that the process is active.

To make a release archive, run:

```sh
./scripts/package-app.sh release
```
