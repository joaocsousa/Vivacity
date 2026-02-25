---
name: Vivacity — macOS File Recovery App
description: Project context and status for AI agents working on the Vivacity codebase
---

# Vivacity — macOS File Recovery App

## Overview

Vivacity is a **native macOS application** built with **SwiftUI** that allows users to recover deleted image and video files from internal and external storage devices connected to their Mac.

## AI Context & Handoff
> **Note to next AI Assistant (Codex or others):**
> Welcome to Vivacity! The codebase is set up, compiling cleanly, and fully linted with **SwiftLint**, **SwiftFormat**, and **Xcode Static Analyzer** (0 warnings). 
> 
> **Where we are:** We have successfully built the M1-M3 milestones. The app currently discovers devices (Fast Scan) and can perform raw sector-by-sector carving (Deep Scan) for predefined file signatures. The UI allows users to select a device, scan it, and preview found files.
> 
> **What to do next:** Your immediate next priority is **M4 (Recovery Destination Screen)** — checking `PROJECT_PLAN.md` for tickets T-013 through T-015. After M4 is complete, you should move on to M6 (Scan Engine Hardening) to fix scanning bugs on real devices. Please read `PROJECT_PLAN.md` for detailed technical implementation steps.

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
| Device selection     | ✅ Done |
| File scanning        | ✅ Done |
| Preview & selection  | ✅ Done |
| Recovery destination | ❌ Not started |
| File recovery        | ❌ Not started |

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
