# Vivacity — Project Plan & Tickets

> **Goal**: Build a native macOS SwiftUI app that lets users scan storage devices for deleted image/video files and recover them.
>
> **Minimum OS**: macOS 14.0 (Sonoma) — also compatible with macOS 15.x (Sequoia)

---

## 🤖 AI Handoff Summary
> **Welcome Codex (or next AI)!** Here's the current state of the project:
> 
> * **Just Completed**: Setup and full resolution of code quality tools (`SwiftLint`, `SwiftFormat`, `Xcode Static Analyzer`). The project has **0 warnings/violations** and builds perfectly. We also extracted deep scan loops into `ScanContext` chunks and refactored line lengths in the FS scanners.
> * **Current Focus**: The app currently supports finding deleted files (Fast Scan) and carving magic bytes (Deep Scan), taking the user up to the preview screen. 
> * **Next Up**: Your immediate assignment is **M7: Deep Scan FS-Aware Carving (Tickets T-025 → T-026)**. The user has explicitly prioritized scanning engine improvements (M7/M8/M9) over UI and recovery flow (M10/M11).
> * **After That**: Continue with **M8: Advanced Features (T-027 → T-029)**.

---

## Milestones Overview

| # | Milestone | Tickets | Status |
|---|-----------|---------|--------|
| M1 | Project Scaffolding | T-001 | ✅ DONE |
| M2 | Device Selection Screen | T-002 → T-005 | ✅ DONE |
| M3 | File Scan & Preview Screen | T-006 → T-012 (T-008 split into a/b) | ✅ DONE |
| M6 | Scan Engine Hardening | T-019 → T-021 | ✅ DONE |
| M7 | Deep Scan FS-Aware Carving | T-025 → T-026 | ⬜ TODO |
| M8 | Advanced Features | T-027 → T-029 | ⬜ TODO |
| M9 | Advanced Camera Recovery | T-030 → T-031 | ⬜ TODO |
| M10 | Scan Results UX | T-022 → T-024 | ⬜ TODO |
| M11 | Recovery Destination Screen | T-013 → T-015 | ⬜ TODO |
| M12 | Polish & Edge Cases | T-016 → T-018 | 🔶 IN PROGRESS |

---

## M1 — Project Scaffolding

### T-001 ✅ Create empty macOS SwiftUI app

**Description**: Create a new Xcode project (macOS App, SwiftUI lifecycle) named **Vivacity**. The app should compile, launch, and show an empty window — nothing more.

**Acceptance Criteria**:
- Xcode project at `Vivacity/Vivacity.xcodeproj`
- `VivacityApp.swift` with `@main` entry point
- `ContentView.swift` with an empty `body`
- App builds via `xcodebuild` and launches with a blank window
- Deployment target: macOS 14.0
- Folder structure matches `.agents/PROJECT.md`

**Files to create / modify**:
- `Vivacity/VivacityApp.swift`
- `Vivacity/ContentView.swift`

---

## M2 — Device Selection Screen

### T-002 ✅ Create `StorageDevice` model

**Description**: Define the data model representing a storage device.

**Acceptance Criteria**:
- `struct StorageDevice: Identifiable, Hashable`
- Properties: `id`, `name` (display name), `volumePath` (mount point URL), `isExternal` (Bool), `totalCapacity` (bytes), `availableCapacity` (bytes)
- Conforms to `Sendable`

**Files**:
- `Vivacity/Models/StorageDevice.swift`

---

### T-003 ✅ Create `DeviceService` — enumerate connected devices

**Description**: Service that discovers all mounted volumes (internal + external) and returns `[StorageDevice]`.

**Acceptance Criteria**:
- Uses `FileManager` volume enumeration or DiskArbitration framework
- Filters out system/hidden volumes (e.g., Recovery, Preboot)
- Correctly flags internal vs. external devices
- Reports total and available capacity
- Async function: `func discoverDevices() async throws -> [StorageDevice]`

**Files**:
- `Vivacity/Services/DeviceService.swift`

---

### T-004 ✅ Create `DeviceSelectionViewModel`

**Description**: ViewModel for the device selection screen.

**Acceptance Criteria**:
- `@Observable class DeviceSelectionViewModel`
- Holds `devices: [StorageDevice]`, `selectedDevice: StorageDevice?`, `isLoading: Bool`, `errorMessage: String?`
- `func loadDevices() async` — calls `DeviceService`
- Refreshes on pull / on appear

**Files**:
- `Vivacity/ViewModels/DeviceSelectionViewModel.swift`

---

### T-005 ✅ Create `DeviceSelectionView`

**Description**: SwiftUI view that lists all available devices and lets the user select one to scan.

**Acceptance Criteria**:
- Displays each device with: name, internal/external badge, capacity info
- Highlights selected device
- "Start Scanning" button — enabled only when a device is selected
- Navigation to the scan screen on button press
- Uses `.task {}` to load devices on appear
- Clean, modern macOS-native look — SF Symbols for drive icons

**Files**:
- `Vivacity/Views/DeviceSelection/DeviceSelectionView.swift`
- `Vivacity/Views/DeviceSelection/DeviceRow.swift`

---

## M3 — File Scan & Preview Screen (Dual Scan Mode)

> Two-phase scanning: **Fast Scan** (metadata) runs first, then the user is
> prompted to optionally run **Deep Scan** (raw file carving). Files from both
> phases accumulate in a single list. Recovery is blocked while scanning.

### T-006 ✅ Define supported file formats

**Description**: Central list of image and video file signatures (magic bytes) and extensions the scanner should look for.

**Acceptance Criteria**:
- Image formats: JPEG, PNG, HEIC, HEIF, TIFF, BMP, GIF, WebP, RAW (CR2, NEF, ARW, DNG)
- Video formats: MP4, MOV, AVI, MKV, M4V, WMV, FLV, 3GP
- Struct or enum with extension string + magic byte signature for each format
- Conforms to `Sendable`

**Files**:
- `Vivacity/Models/FileSignature.swift`

---

### T-007 ✅ Create `RecoverableFile` model

**Description**: Data model representing a file that can be recovered.

**Acceptance Criteria**:
- `struct RecoverableFile: Identifiable, Hashable`
- Properties: `id`, `fileName` (or generated name), `fileExtension`, `fileType` (image / video enum), `sizeInBytes`, `offsetOnDisk`, `signatureMatch`
- `source` property: `.fastScan` or `.deepScan` — tracks which phase found it
- Computed property: `sizeInMB: Double`
- Conforms to `Sendable`

**Files**:
- `Vivacity/Models/RecoverableFile.swift`

---

### T-008a ✅ Create `FastScanService` — metadata-based scan

**Description**: Service that scans file system metadata for recently deleted files (`.Trashes`, deleted catalog entries).

**Acceptance Criteria**:
- Uses `FileManager` and/or POSIX APIs to find deleted-but-not-overwritten file entries
- Preserves original filenames and directory structure
- Yields results incrementally via `AsyncStream<RecoverableFile>` with `source = .fastScan`
- Reports progress via `AsyncStream<Double>`
- Respects `Task` cancellation
- Handles permissions gracefully

**Files**:
- `Vivacity/Services/FastScanService.swift`

---

### T-008b ✅ Create `DeepScanService` — raw byte carving

**Description**: Core service that performs raw sector-by-sector scan using magic byte signatures.

**Acceptance Criteria**:
- Opens the raw device or volume for reading (`open()` with `O_RDONLY`)
- Scans sequentially, matching magic bytes from `FileSignature`
- Yields results incrementally via `AsyncStream<RecoverableFile>` with `source = .deepScan`
- Generates file names (`file001.jpg`, `file002.mp4`, etc.)
- Reports progress (bytes scanned / total bytes)
- Deduplicates against files already found by Fast Scan (by offset)
- Respects `Task` cancellation

**Files**:
- `Vivacity/Services/DeepScanService.swift`

---

### T-009 ✅ Create `FileScanViewModel` — dual-phase state machine

**Description**: ViewModel for the scanning screen with two-phase scan flow.

**Acceptance Criteria**:
- `@Observable class FileScanViewModel`
- `scanPhase` enum: `.idle` → `.fastScanning` → `.fastComplete` → `.deepScanning` → `.complete`
- `foundFiles: [RecoverableFile]` — cumulative from both phases
- `selectedFiles: Set<RecoverableFile.ID>`, `progress: Double` (0–1)
- `canRecover: Bool` — true only when not scanning and ≥ 1 file selected
- `func startFastScan(device:) async` — runs Fast Scan, transitions to `.fastComplete`
- `func startDeepScan() async` — runs Deep Scan, appends to same list
- `func stopScanning()` — cancels current scan phase
- `func toggleSelection(_:)`, `selectAll()`, `deselectAll()`

**Files**:
- `Vivacity/ViewModels/FileScanViewModel.swift`

---

### T-010 ✅ Create `FileScanView` — progressive scan UI

**Description**: Main scan UI with progressive file list, Deep Scan prompt, and scan controls.

**Acceptance Criteria**:
- **Status bar**: current phase label + progress bar + "Stop" button
- **File list**: grows in real-time; each row shows icon, name, size, source badge ("Fast"/"Deep")
- **Deep Scan prompt**: banner after Fast Scan completes — _"X files found. Run Deep Scan for more?"_
- Selectable rows (checkbox or highlight)
- "Select All" / "Deselect All" toggle
- **Recover button**: enabled only when `canRecover` (not scanning + ≥ 1 selected)
- "Stop" button cancels current scan phase
- Navigation to recovery destination on "Recover"

**Files**:
- `Vivacity/Views/FileScan/FileScanView.swift`
- `Vivacity/Views/FileScan/FileRow.swift`

---

### T-011 ✅ Create `FilePreviewView` — preview panel

**Description**: When a file is selected in the list, show a preview in a side panel or detail view.

**Acceptance Criteria**:
- Images: Render thumbnail from raw bytes (or use `CGImage` from data)
- Videos: Show first-frame thumbnail or QuickLook-style preview
- Graceful fallback if preview cannot be generated (show file-type icon + message)
- Panel shows file name, extension, size

**Files**:
- `Vivacity/Views/FileScan/FilePreviewView.swift`
- `Vivacity/Services/PreviewService.swift` (thumbnail extraction)

---

### T-012 ✅ Wire up split view — list + preview

**Description**: Combine file list and preview into a split/detail layout.

**Acceptance Criteria**:
- `NavigationSplitView` or `HSplitView` — list on left, preview on right
- Selecting a file in the list updates the preview
- Responsive resizing

**Files**:
- Update `FileScanView.swift`

---



## User Flows

```mermaid
flowchart LR
    A["Launch App"] --> B["Device Selection"]
    B -->|Select device + Start| C["Scan & Preview"]
    C -->|Select files + Recover| D["Choose Destination"]
    D -->|Enough space + Start| E["Recovery in Progress"]
    E --> F["Recovery Complete ✅"]
```

---

## Verification Plan

### Build Verification
```bash
xcodebuild -project Vivacity.xcodeproj -scheme Vivacity -configuration Debug build
```

### Manual Verification (per milestone)

| Milestone | Manual Test |
|-----------|-------------|
| M1 | App launches and shows empty window |
| M2 | Internal + external drives listed correctly, selection works |
| M3 | Scan finds known deleted test files, preview loads, selection works |
| M4 | Destination picker works, space check prevents recovery when insufficient |
| M12 | Full end-to-end flow works in both light and dark mode |

> [!TIP]
> For testing M3 scanning, create a test USB drive with known deleted files to validate the scanner finds them.

---

## M6 — Scan Engine Hardening

### T-019 ✅ Fix `PrivilegedDiskReader` security

**Description**: Replace `chmod o+r` with a FIFO-based approach so the raw device is never world-readable.

**Acceptance Criteria**:
- FIFO created in `/tmp`, cleaned up on exit
- Password dialog shown once via `NSAppleScript`
- Device permissions never modified
- Works with both direct access and privileged access paths

**Files**: `Vivacity/Services/PrivilegedDiskReader.swift`

---

### T-020 ✅ Re-enable FAT32/ExFAT/NTFS catalog scanning in Fast Scan

**Description**: Fast Scan should use the filesystem-specific catalog scanners (`FATDirectoryScanner`, `ExFATScanner`, `NTFSScanner`) in addition to the FileManager walk, so deleted files on cameras (marked with 0xE5) are found.

**Acceptance Criteria**:
- Phase A: FileManager walk (no permissions needed)
- Phase B: Catalog scanner for the detected filesystem type
- Deduplication between phases
- Camera with deleted photos → Fast Scan finds them via 0xE5 markers

**Files**: `FastScanService.swift`, `FATDirectoryScanner.swift`, `ExFATScanner.swift`, `NTFSScanner.swift`

---

### T-021 ✅ Clean up dead `PermissionService` code

**Description**: Remove or consolidate `PermissionService` now that `PrivilegedDiskReader` handles authorization.

**Files**: `PermissionService.swift`, `FileScanView.swift`

---


## M7 — Deep Scan: Filesystem-Aware Carving

### T-025 ⬜ FAT32 filesystem-aware carving

**Description**: Parse orphaned FAT directory entries and FAT chain fragments from raw sectors to reconstruct folder structures after formatting.

**Files**: `Carvers/FATCarver.swift` [NEW], `DeepScanService.swift`

---

### T-026 ⬜ APFS/HFS+ metadata carving

**Description**: Parse orphaned catalog B-tree nodes to recover files with original names and paths from formatted or damaged APFS/HFS+ volumes.

**Files**: `Carvers/APFSCarver.swift` [NEW], `Carvers/HFSPlusCarver.swift` [NEW]

---

## M8 — Advanced Features

### T-027 ⬜ Lost Partition Search

**Description**: Scan entire disk for partition signatures (GPT, MBR, NTFS boot sectors, FAT boot sectors, HFS+/APFS headers) and present found partitions as scannable virtual volumes.

**Files**: `PartitionSearchService.swift` [NEW], `DeviceSelectionView.swift`, `StorageDevice.swift`

---

### T-028 ⬜ Scan session save/resume

**Description**: Save scan results to disk and resume later, including continuing Deep Scan from the last offset.

**Files**: `ScanSession.swift` [NEW], `SessionManager.swift` [NEW], `FileScanViewModel.swift`

---

### T-029 ⬜ Byte-to-byte disk imaging

**Description**: Create sector-level backup of a drive before scanning. Allow scanning the image file instead of the live device.

**Files**: `DiskImageService.swift` [NEW], `DeviceSelectionView.swift`

---

## M9 — Advanced Camera Recovery

### T-030 ⬜ Basic camera-aware recovery

**Description**: Detect camera directory patterns (DCIM, GoPro, Canon, Sony) and optimize recovery for common camera formats.

**Files**: `CameraRecoveryService.swift` [NEW], `CameraProfile.swift` [NEW]

---

### T-031 ⬜ Fragmented video reconstruction

**Description**: Reassemble fragmented MP4/MOV files by analyzing container structure and camera-specific layout patterns.

**Files**: `Carvers/MP4Reconstructor.swift` [NEW], `Carvers/FragmentedVideoAssembler.swift` [NEW]

---

## M11 — Recovery Destination Screen

### T-013 ⬜ Create `RecoveryDestinationViewModel`

**Description**: ViewModel for destination selection.

**Acceptance Criteria**:
- `@Observable class RecoveryDestinationViewModel`
- Properties: `destinationURL: URL?`, `requiredSpace: Int64`, `availableSpace: Int64`, `hasEnoughSpace: Bool` (computed)
- `func selectDestination()` — opens folder picker (`NSOpenPanel`)
- `func updateAvailableSpace()` — queries selected volume
- `func startRecovery() async` — triggers file recovery
- **⚠️ Must reject destinations on the same device that was scanned** — comparing volume paths to prevent overwriting recoverable data

**Files**:
- `Vivacity/ViewModels/RecoveryDestinationViewModel.swift`

---

### T-014 ⬜ Create `RecoveryDestinationView`

**Description**: UI for picking a destination folder and confirming recovery.

**Acceptance Criteria**:
- Button to "Choose Destination…" — opens native folder picker
- Displays selected path
- Shows "Space needed: X MB" and "Space available: Y MB"
- Visual indicator if not enough space (red warning, button disabled)
- **⚠️ Show warning and prevent selection if destination is on the scanned device**
- "Start Recovery" button — enabled only when `hasEnoughSpace` and destination ≠ scanned device
- Progress/status while recovery runs

**Files**:
- `Vivacity/Views/RecoveryDestination/RecoveryDestinationView.swift`

---

### T-015 ⬜ Create `FileRecoveryService`

**Description**: Service that reads raw bytes from the source device and writes recovered files to the destination.

**Acceptance Criteria**:
- Reads from offset + expected size for each selected `RecoverableFile`
- Writes to destination directory with generated or original file names
- Reports progress via callback / `AsyncStream`
- Handles errors per-file (doesn't abort entire batch on one failure)
- Respects cancellation

**Files**:
- `Vivacity/Services/FileRecoveryService.swift`

---

## M10 — Scan Results UX

### T-022 ⬜ Add result filtering

**Description**: Filter toolbar (by type, size, filename search) above the file list, matching Disk Drill's UX.

**Files**: `FileScanViewModel.swift`, `FileScanView.swift`, `FilterToolbar.swift` [NEW]

---

### T-023 ⬜ Add recovery confidence indicator

**Description**: Green/yellow/red dot per file indicating estimated recovery chances based on scan source and contiguity.

**Files**: `RecoverableFile.swift`, `FileRow.swift`, `FastScanService.swift`, `DeepScanService.swift`

---

### T-024 ⬜ File size estimation for Deep Scan results

**Description**: Estimate file sizes by finding the next header or known footer bytes (e.g., JPEG `FF D9`, PNG `IEND`).

**Files**: `DeepScanService.swift`, `FileFooterDetector.swift` [NEW]

---

## M12 — Polish & Edge Cases

### T-016 ✅ Permission handling — privileged disk access

**Description**: Before scanning, silently probe whether the app can open the raw disk device. If access works (common for external USB/SD drives), proceed immediately with no prompt. If access is denied (`EACCES`), use `AuthorizationServices` to request elevated privileges via the native macOS password dialog. The user sees this as a "disk access" request, not an "admin" request.

> **Note**: The app is non-sandboxed (`com.apple.security.app-sandbox = false`), so `.Trashes` and filesystem directories are already accessible. The only runtime permission needed is elevated privileges for raw disk device I/O (`/dev/diskXsY`).

**Acceptance Criteria**:
- `PermissionService` probes raw device access silently — no prompt if already permitted
- If denied, uses `AuthorizationServices` to show macOS password dialog
- If the user cancels the password dialog, show `PermissionDeniedView` with:
  - Shield icon + "Disk Access Needed" title
  - Explanation: reading raw disk sectors requires elevated privileges
  - "Without disk access, scanning will be limited to files found in the Trash."
  - "Try Again" button → re-prompts the password dialog
  - "Continue with limited scan" subtle link → proceeds with Trash-only scan
- Works on macOS 14.0+ (Sonoma) and 15.x (Sequoia) — same API

**Files**:
- `Vivacity/Services/PermissionService.swift` [NEW]
- `Vivacity/Views/FileScan/PermissionDeniedView.swift` [NEW]
- `Vivacity/Views/FileScan/FileScanView.swift` [MODIFY]
- `Vivacity/ViewModels/FileScanViewModel.swift` [MODIFY]

---

### T-017 🔶 Navigation & app flow integration

**Description**: Wire all screens together with proper navigation.

**Acceptance Criteria**:
- `NavigationStack`-based flow: Device Selection → Scan → Recovery
- Back navigation at each step
- State resets appropriately when navigating back

**Files**:
- Update `ContentView.swift`

---

### T-018 ⬜ Final visual polish & testing

**Description**: Overall UI refinement, dark mode support, and manual testing.

**Acceptance Criteria**:
- Consistent spacing, typography, and color usage
- Dark and light mode verified
- App icon (placeholder acceptable)
- Manual walkthrough of full flow: select device → scan → preview → recover

