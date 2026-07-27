# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-07-27

### Added

- Native macOS notch interface for monitoring local AI coding agents.
- Automatic agent discovery, lifecycle activity, completion states, and terminal/app jumping.
- Connector-backed approval and question flows with keyboard shortcuts, multi-select, free text, and descriptive option tooltips.
- Local Codex usage-window monitoring and configurable agent integrations.
- Settings for followed agents, appearance, motion, sounds, models, updates, and activity history.

### Changed

- Balanced 60 Hz animation defaults, paused hidden timelines, cached artwork and process metadata, and coalesced local polling.
- Compact activity summaries now distinguish active tasks, approvals, questions, failures, and idle state.

### Security

- Agent events and reply traffic remain local to the Mac through a loopback-only bridge.
- Passive observations never create reply forms without a verified response channel.

[Unreleased]: https://github.com/ishaanko/notch-agents/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ishaanko/notch-agents/releases/tag/v0.1.0
