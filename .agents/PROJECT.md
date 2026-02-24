---
name: Vivacity — macOS File Recovery App
description: Project context and status for AI agents working on the Vivacity codebase
---

# Vivacity — macOS File Recovery App

## Overview

Vivacity is a **native macOS application** built with **SwiftUI** that allows users to recover deleted image and video files from internal and external storage devices connected to their Mac.

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

| Milestone            | Status      |
|----------------------|-------------|
| Empty macOS app      | ✅ Done |
| Device selection     | ❌ Not started |
| File scanning        | ❌ Not started |
| Preview & selection  | ❌ Not started |
| Recovery destination | ❌ Not started |
| File recovery        | ❌ Not started |

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
