---
name: Agent Onboarding Guide
description: Instructions for any AI agent picking up work on the Vivacity project
---

# Agent Onboarding Guide

Welcome! This guide tells you everything you need to get productive on **Vivacity** quickly.

## Quick Orientation

| File | Purpose |
|------|---------|
| `.agents/PROJECT.md` | What the app is, tech stack, current status |
| `.agents/CODING_STANDARDS.md` | Swift/SwiftUI conventions to follow |
| `.agents/AGENT_GUIDE.md` | You are here — how to contribute |
| `PROJECT_PLAN.md` | Master plan with all tickets and their status |

## Step-by-Step: Picking Up Work

1. **Read `PROJECT.md`** to understand the app and check the current status table.
2. **Read `PROJECT_PLAN.md`** to see all tickets. Find the next one marked `⬜ TODO`.
3. **Read `CODING_STANDARDS.md`** before writing any code.
4. **Implement the ticket**, following the acceptance criteria listed.
5. **Update the ticket status** in `PROJECT_PLAN.md` to `✅ DONE` (or `🔧 IN PROGRESS` while working).
6. **Update the status table** in `PROJECT.md` to reflect the new milestone state.
7. **Build and verify** the app compiles and runs before marking done.

## Ticket Status Legend

| Emoji | Meaning |
|-------|---------|
| ⬜    | TODO — not started |
| 🔧    | IN PROGRESS — currently being worked on |
| ✅    | DONE — completed and verified |
| 🚫    | BLOCKED — cannot proceed, see notes |

## Important Rules

- **Never skip a ticket** — they are ordered by dependency. Complete them in sequence.
- **Always build** after changes: `xcodebuild -project Vivacity.xcodeproj -scheme Vivacity build`
- **Follow MVVM** — Views must not contain business logic.
- **Use structured concurrency** — `async`/`await`, not GCD/DispatchQueue.
- **Keep this documentation in sync** — update status after every ticket.

## Screenshots & Recordings

Use **[macosrec](https://github.com/xenodium/macosrec)** to take screenshots and record videos of the running app.

### 1. Find the window number

```bash
macosrec --list
```

Example output:

```
21902 Emacs
22024 Dock - Desktop Picture - Stone.png
44001 Vivacity
```

Look for the **Vivacity** window in the list and note its number.

### 2. Take a screenshot

```bash
macosrec --screenshot <window_number>
# Example: macosrec --screenshot 44001
# Saves to ~/Desktop/<timestamp>-Vivacity.png
```

### 3. Record a video

Start recording with `--record` and specify the format (`--gif` or `--mov`):

```bash
# Record as GIF
macosrec --record <window_number> --gif

# Record as MOV
macosrec --record <window_number> --mov
```

You can also use the app name instead of the window number:

```bash
macosrec --record Vivacity --gif
```

To **stop recording**, either:
- Send `SIGINT` (Ctrl+C) in the terminal, **or**
- Run `macosrec --save` from another terminal session.

> [!TIP]
> Use screenshots after completing UI-related tickets to visually verify the result. Attach them to walkthroughs or artifact documentation when relevant.

## Persona

Consider yourself a **senior native macOS/SwiftUI developer** with deep knowledge of:
- macOS system APIs (DiskArbitration, IOKit, POSIX file I/O)
- SwiftUI best practices and modern Swift concurrency
- File system internals and data recovery techniques
- Clean architecture and testable code design
