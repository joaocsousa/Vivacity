---
name: Vivacity — macOS File Recovery App
description: Project context and status for AI agents working on the Vivacity codebase
---

# Vivacity — macOS File Recovery App

## Overview

Vivacity is a **native macOS application** built with **SwiftUI** that allows users to recover deleted image and video files from internal and external storage devices connected to their Mac.

## AI Context & Handoff
> **Note to next AI Assistant (Codex or others):** Treat `PROJECT_PLAN.md` as the single source of truth for roadmap, status, and tickets.  
> **Where we are:** M1–M5 are complete. The app discovers devices, runs Fast Scan and filesystem-aware Deep Scan (FAT/APFS/HFS+), and streams previews. Code quality tools (`SwiftLint`, `SwiftFormat`, `Xcode Static Analyzer`) are clean.  
> **Current focus:** M6 Advanced Features (T-027 → T-029: lost partition search, scan session save/resume, disk imaging) plus M10 polish/navigation (T-017).  
> **Next up:** M7 camera recovery, then M8 scan results UX, then M9 recovery destination flow.

## Purpose

Users who accidentally delete photos or videos need a clean, modern macOS-native tool to scan drives and recover those files. Vivacity provides:

1. **Device discovery** — Lists all internal and external storage devices.
2. **Deep scan** — Searches selected devices for recoverable image and video files.
3. **Preview & selection** — Shows previews, names, and sizes of recoverable files.
4. **Safe recovery** — Validates destination space and recovers selected files.

## Tech Stack

| Layer        | Technology                        |
|--------------|-----------------------------------|
| UI           | SwiftUI (macOS 14+ / Sonoma)      |
| Language     | Swift 5.9+                        |
| Architecture | MVVM                              |
| Build        | Xcode 15+ / Swift Package Manager |
| Target       | macOS 14.0+ (Sonoma)              |

## Project Status

> [!IMPORTANT]
> This section must be updated by any agent after completing work.

| Milestone                      | Status |
|--------------------------------|--------|
| M1 Empty macOS app             | ✅ Done |
| M2 Device selection            | ✅ Done |
| M3 File scanning & preview     | ✅ Done |
| M4 Scan engine hardening       | ✅ Done |
| M5 Deep scan FS-aware carving  | ✅ Done |
| M6 Advanced features           | ⬜ TODO |
| M7 Advanced camera recovery    | ⬜ TODO |
| M8 Scan results UX             | ⬜ TODO |
| M9 Recovery destination        | ⬜ TODO |
| M10 Polish & edge cases        | 🔶 In progress |

> **Minimum Supported OS**: macOS 14.0 (Sonoma). Also compatible with macOS 15.x (Sequoia).

## Directory Structure (Planned)

```
Vivacity/
├── Vivacity.xcodeproj/          # Xcode project
├── Vivacity/
│   ├── VivacityApp.swift        # App entry point
│   ├── ContentView.swift        # Root view / navigation
│   ├── Models/                  # Data models
│   ├── ViewModels/              # MVVM view models
│   ├── Views/                   # SwiftUI views by screen
│   │   ├── DeviceSelection/
│   │   ├── FileScan/
│   │   └── RecoveryDestination/
│   ├── Services/                # Business logic & disk I/O
│   ├── Utilities/               # Helpers, extensions
│   └── Resources/               # Assets, colors, etc.
├── .agents/                     # Agent documentation
└── PROJECT_PLAN.md              # Master plan & tickets
```

## How to Build & Run

```bash
# Open in Xcode
open Vivacity.xcodeproj

# Or build from CLI
xcodebuild -project Vivacity.xcodeproj -scheme Vivacity -configuration Debug build
```

## Key Contacts

- **Owner**: João
