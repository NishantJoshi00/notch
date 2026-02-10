# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
# Build release binary
swift build -c release

# Install
cp .build/release/Notch /Applications/

# Generate Xcode project (requires xcodegen)
xcodegen
```

No test suite exists yet. No external dependencies — pure Swift + system frameworks.

## Architecture

Notch is a macOS menu bar AI assistant that lives in the notch area. ~3,800 LOC of Swift, targeting macOS 13.0+, built with AppKit (not SwiftUI).

### Three layers

**UI** — `InputBarWindow` (floating window animating from notch), `NotchInputBar` (input field), `ChatHistoryView` (messages), `CameraPreviewView`

**Application** — `AppDelegate` is the central coordinator: manages the Claude API client, tool orchestration, and conversation loop. `NotchMind` is the autonomous background agent. `NotchScheduler` handles time-based thought triggers. `SystemEventMonitor` detects wake/idle/unlock.

**Tools** — Plugin architecture via `NotchTool` protocol. Each tool implements `name`, `description`, `inputSchema`, and `execute(input:completion:)` with `ToolResult` return types (`.text()`, `.image()`, `.error()`).

### Dual-mode prompt system

System prompt = Soul + Capability (composable). `NotchSoul.prompt` is the invariant personality. `NotchCapability.conversation` adds interactive tools/behavior. `NotchCapability.mind()` adds autonomous tools/behavior. All prompts defined in `ThoughtModels.swift`.

### The Mind (autonomous agent)

Runs between user interactions, triggered by scheduler, system events, or the "caring cycle" (45-90min randomized). Has shared tools plus mind-only tools (`send_message`, `stay_silent`). Implements thought coalescing — batches triggers within 0.5s windows.

### Tool sandboxing

- Text editor: restricted to `~/AIspace/`
- Memory: stored in `~/.notch/memories/`
- Scheduler: stored in `~/.notch/scheduler/`
- Sessions: `~/Library/Application Support/Notch/sessions/`

### Key runtime behaviors

- API key stored in UserDefaults (`AnthropicAPIKey`)
- Extended thinking auto-enabled via keyword detection in `AppDelegate`
- Context management: auto-clears tool uses at 100K tokens (keeps last 3, excludes memory)
- Conversation persistence: last 50 messages saved/restored
- Activation: double-tap right Option key
- Uses Claude Haiku 4.5 model

### Tool architecture

- **Shared**: memory, camera, text editor, scheduler
- **Conversation-only**: `end_conversation`
- **Mind-only**: `send_message`, `stay_silent`

## Voice

Notch has a specific personality defined in `ThoughtModels.swift` — direct, minimal, never narrates actions. Any prompt changes must preserve this character. The `lore/` directory contains backstory context.
