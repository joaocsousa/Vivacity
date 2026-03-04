# Vivacity

A native macOS app for recovering deleted image and video files from storage devices.

Built with **SwiftUI** · Requires **macOS 14.0+** (Sonoma)

For the canonical roadmap, status, and handoff details, see [PROJECT_PLAN.md](PROJECT_PLAN.md).

---

## Features

- **Device Discovery** — Lists all mounted internal and external volumes with auto-refresh on mount/unmount
- **Unified Multi-Method Scan**
  - **Filesystem metadata scan** — Walks mounted metadata (`.Trashes`, APFS snapshots, etc.) for recently deleted files
  - **Raw catalog scan** — FAT32, ExFAT, and NTFS directory/MFT scanning for deleted entries
  - **Deep raw carving** — Sector-by-sector signature carving with format-aware validation and reconstruction
- **Live Preview** — Preview recovered images and videos in a split-view panel as results stream in
- **20+ File Formats** — JPEG, PNG, HEIC, TIFF, CR2, ARW, DNG, BMP, GIF, WebP, MP4, MOV, AVI, MKV, M4V, WMV, FLV, 3GP
- **EXIF-Based Naming** — Carved media results are named using embedded EXIF dates when available
- **Privileged Disk Access** — Transparent privilege escalation via macOS password dialog when raw device access is needed

## Getting Started

### Prerequisites

- macOS 14.0 (Sonoma) or later
- Xcode 15+

### Build & Run

```bash
git clone https://github.com/joaocsousa/Vivacity.git
cd Vivacity
xcodegen generate
xcodebuild build -scheme Vivacity -destination 'platform=macOS' SYMROOT="$(pwd)/build"
open build/Debug/Vivacity.app
```

Or regenerate and open the project in Xcode:

```bash
xcodegen generate
open Vivacity.xcodeproj
```

### Xcode Project Workflow (XcodeGen)

- `project.yml` is the single source of truth for project structure and build settings.
- `Vivacity.xcodeproj` is **not** committed; regenerate locally from `project.yml`.
- Do not edit `Vivacity.xcodeproj/project.pbxproj` manually. Update `project.yml`, then run:

```bash
xcodegen generate
```

- To regenerate/verify before builds or PRs:

```bash
./scripts/check-xcodegen.sh   # regenerates and ensures the project remains untracked
```

### Testing & Code Quality

Vivacity includes a suite of unit and UI tests. You are expected to run the test suite and linters to ensure your code is consistently formatted and robust.

**Run Tests:**
```bash
xcodebuild test -scheme Vivacity -destination 'platform=macOS' SYMROOT="$(pwd)/build"
```

Vivacity uses **SwiftFormat** and **SwiftLint** to maintain code quality. 

Ensure both are installed (`brew install swiftlint swiftformat`). 
Before committing, format your code:
```bash
swiftformat .
```
SwiftLint runs automatically during the Xcode build phase to surface warnings.

## How It Works

```
Select Device → Unified Scan (all methods) → Select Files → Recover
```

1. **Select a device** — Pick an internal or external volume from the device list
2. **Unified scan** runs once — Vivacity runs all available scan methods in one pass and streams combined results
3. **Preview & select** — Browse found files, preview images, select what to recover
4. **Recover** — Save selected files to a destination folder

## Scan Methods

During one scan run, Vivacity combines these methods:

1. **Filesystem metadata scan**
   - Mounted volume walks (including trash locations).
   - APFS snapshot inspection to find files removed from the live view.
2. **Raw catalog/index scan** (filesystem-aware)
   - FAT32 directory entry recovery (`0xE5` markers).
   - ExFAT deleted entry-set recovery.
   - NTFS MFT deleted-record recovery.
3. **Deep sector carving**
   - Full-device byte scan for known file signatures.
   - Footer/structure validation (for example JPEG/PNG/WebP/GIF/MP4-family logic).
   - Fragment/contiguity heuristics and confidence scoring.

Results are merged into a single list in real time, with one progress bar, percentage, and ETA.

## Architecture

```
Vivacity/
├── Models/
│   ├── StorageDevice.swift       # Device model
│   ├── RecoverableFile.swift     # Found file model
│   ├── FileSignature.swift       # Magic byte definitions
│   └── VolumeInfo.swift          # Filesystem detection
├── Services/
│   ├── DeviceService.swift       # Volume enumeration
│   ├── FastScanService.swift     # Metadata-based scan
│   ├── DeepScanService.swift     # Signature carving scan
│   ├── FATDirectoryScanner.swift # FAT32 0xE5 recovery
│   ├── ExFATScanner.swift        # ExFAT directory scanning
│   ├── NTFSScanner.swift         # NTFS MFT scanning
│   ├── PrivilegedDiskReader.swift# Privileged device access
│   ├── PermissionService.swift   # Authorization helpers
│   └── EXIFDateExtractor.swift   # EXIF date parsing
├── ViewModels/
│   ├── DeviceSelectionViewModel.swift
│   └── FileScanViewModel.swift
└── Views/
    ├── DeviceSelection/          # Device picker UI
    └── FileScan/                 # Scan results + preview UI
```

## Roadmap

The canonical roadmap, status, and project plan are maintained exclusively in [PROJECT_PLAN.md](PROJECT_PLAN.md) to avoid drift. Please refer to that document for all milestone statuses and ticket details.

## License

All rights reserved.
