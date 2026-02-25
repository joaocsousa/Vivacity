# Vivacity

A native macOS app for recovering deleted image and video files from storage devices.

Built with **SwiftUI** · Requires **macOS 14.0+** (Sonoma)

---

## Features

- **Device Discovery** — Lists all mounted internal and external volumes with auto-refresh on mount/unmount
- **Dual-Phase Scanning**
  - **Fast Scan** — Walks filesystem metadata (`.Trashes`, FAT 0xE5 markers) to find recently deleted files with original names
  - **Deep Scan** — Sector-by-sector scan using magic byte signatures to carve files from raw disk data
- **Live Preview** — Preview recovered images and videos in a split-view panel as results stream in
- **20+ File Formats** — JPEG, PNG, HEIC, TIFF, CR2, ARW, DNG, BMP, GIF, WebP, MP4, MOV, AVI, MKV, M4V, WMV, FLV, 3GP
- **EXIF-Based Naming** — Deep Scan results are named using embedded EXIF dates when available
- **Privileged Disk Access** — Transparent privilege escalation via macOS password dialog when raw device access is needed

## Getting Started

### Prerequisites

- macOS 14.0 (Sonoma) or later
- Xcode 15+

### Build & Run

```bash
git clone https://github.com/joaocsousa/Vivacity.git
cd Vivacity
xcodebuild build -scheme Vivacity -destination 'platform=macOS' SYMROOT="$(pwd)/build"
open build/Debug/Vivacity.app
```

Or open `Vivacity.xcodeproj` in Xcode and press ⌘R.

## How It Works

```
Select Device → Fast Scan → Deep Scan (optional) → Select Files → Recover
```

1. **Select a device** — Pick an internal or external volume from the device list
2. **Fast Scan** runs automatically — Finds recently deleted files using filesystem metadata (no admin access needed)
3. **Deep Scan** (optional) — Scans every sector for file signatures. Requires admin password for raw device access on external drives
4. **Preview & select** — Browse found files, preview images, select what to recover
5. **Recover** — Save selected files to a destination folder

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

See [PROJECT_PLAN.md](PROJECT_PLAN.md) for the full roadmap. Current status:

| Milestone | Status |
|-----------|--------|
| M1–M3: Scaffolding, Device Selection, Scan & Preview | ✅ Done |
| M4: Recovery Destination | ⬜ Next |
| M5: Polish & Edge Cases | 🔶 In Progress |
| M6: Scan Engine Hardening | ⬜ Planned |
| M7: Scan Results UX (filtering, confidence) | ⬜ Planned |
| M8–M10: FS Carving, Advanced Features, Camera Recovery | ⬜ Future |

## License

All rights reserved.
