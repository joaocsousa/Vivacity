# Vivacity — Project Plan & Tickets

> **Source of truth**: This file is the canonical roadmap, status, and handoff doc. Other files (README, .agents/PROJECT.md) point back here to avoid drift.

> **Goal**: Build a native macOS SwiftUI app that lets users scan storage devices for deleted image/video files and recover them.
>
> **Minimum OS**: macOS 14.0 (Sonoma) — also compatible with macOS 15.x (Sequoia)

---



## Milestones Overview

| # | Milestone | Tickets | Status |
|---|-----------|---------|--------|
| M1 | Project Scaffolding | T-001 | ✅ DONE |
| M2 | Device Selection Screen | T-002 → T-005 | ✅ DONE |
| M3 | File Scan & Preview Screen | T-006 → T-012 (T-008 split into a/b) | ✅ DONE |
| M4 | Scan Engine Hardening | T-019 → T-021 | ✅ DONE |
| M5 | Deep Scan FS-Aware Carving | T-025 → T-026 | ✅ DONE |
| M6 | Advanced Features | T-027 → T-029 | ✅ DONE |
| M7 | Advanced Camera Recovery | T-030 → T-033 | ✅ DONE |
| M8 | Scan Results UX | T-022 → T-024 | ✅ DONE |
| M9 | Recovery Destination Screen | T-013 → T-015 | ✅ DONE |
| M10 | Polish & Edge Cases | T-016 → T-018 | ✅ DONE |
| M11 | Coverage & Quality Hardening | T-034 → T-036 | ✅ DONE |
| M12 | XcodeGen Migration | T-037 → T-039 | ✅ DONE |
| M13 | Recovery Quality Improvements | T-040 → T-046 | ⬜️ TODO |

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
| M9 | Destination picker works, space check prevents recovery when insufficient |
| M10 | Full end-to-end flow works in both light and dark mode |

> [!TIP]
> For testing M3 scanning, create a test USB drive with known deleted files to validate the scanner finds them.

---

## M4 — Scan Engine Hardening

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


## M5 — Deep Scan: Filesystem-Aware Carving

### T-025 ✅ FAT32 filesystem-aware carving

**Description**: Parse orphaned FAT directory entries and FAT chain fragments from raw sectors to reconstruct folder structures after formatting.

**Files**: `Carvers/FATCarver.swift` [NEW], `DeepScanService.swift`

---

### T-026 ✅ APFS/HFS+ metadata carving

**Description**: Parse orphaned catalog B-tree nodes to recover files with original names and paths from formatted or damaged APFS/HFS+ volumes.

**Files**: `Carvers/APFSCarver.swift` [NEW], `Carvers/HFSPlusCarver.swift` [NEW]

---

## M6 — Advanced Features

### T-027 ✅ Lost Partition Search

**Description**: Scan entire disk for partition signatures (GPT, MBR, NTFS boot sectors, FAT boot sectors, HFS+/APFS headers) and present found partitions as scannable virtual volumes.

**Files**: `PartitionSearchService.swift` [NEW], `DeviceSelectionView.swift`, `StorageDevice.swift`

---

### T-028 ✅ Scan session save/resume

**Description**: Save scan results to disk and resume later, including continuing Deep Scan from the last offset.

**Files**: `ScanSession.swift` [NEW], `SessionManager.swift` [NEW], `FileScanViewModel.swift`

---

### T-029 ✅ Byte-to-byte disk imaging

**Description**: Create sector-level backup of a drive before scanning. Allow scanning the image file instead of the live device.

**Files**: `DiskImageService.swift` [NEW], `DeviceSelectionView.swift`

---

## M7 — Advanced Camera Recovery

### T-030 ✅ Basic camera-aware recovery

**Description**: Detect camera directory patterns (DCIM, GoPro, Canon, Sony) and optimize recovery for common camera formats.

**Files**: `CameraRecoveryService.swift` [NEW], `CameraProfile.swift` [NEW]

---

### T-031 ✅ Fragmented video reconstruction

**Description**: Reassemble fragmented MP4/MOV files by analyzing container structure and camera-specific layout patterns.

**Files**: `Carvers/MP4Reconstructor.swift` [NEW], `Carvers/FragmentedVideoAssembler.swift` [NEW]

---

### T-032 ✅ Fragmented image reconstruction

**Description**: Reassemble fragmented JPEG and RAW image files by identifying metadata (e.g. EXIF headers) and locating missing image data blocks, commonly caused by filesystem fragmentation.

**Files**: `Carvers/ImageReconstructor.swift` [NEW]

---

## M9 — Recovery Destination Screen

### T-013 ✅ Create `RecoveryDestinationViewModel`

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
- `VivacityTests/RecoveryDestinationViewModelTests.swift`

**Subtasks**:
- Define view model API and state (`destinationURL`, `requiredSpace`, `availableSpace`, `hasEnoughSpace`).
- Implement `selectDestination()` using `NSOpenPanel` and restrict to directories.
- Add storage-volume comparison logic to block destinations on scanned device.
- Implement `updateAvailableSpace()` using volume resource values.
- Add async `startRecovery()` stub to call `FileRecoveryService` once implemented.

---

### T-014 ✅ Create `RecoveryDestinationView`

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

**Subtasks**:
- Build layout: header, destination picker button, and path display.
- Show space required/available with clear error state when insufficient.
- Render “same device” warning and disable selection when invalid.
- Wire “Start Recovery” button to view model and show progress state.
- Add previews and verify disabled/enabled states visually.

---

### T-015 ✅ Create `FileRecoveryService`

**Description**: Service that reads raw bytes from the source device and writes recovered files to the destination.

**Acceptance Criteria**:
- Reads from offset + expected size for each selected `RecoverableFile`
- Writes to destination directory with generated or original file names
- Reports progress via callback / `AsyncStream`
- Handles errors per-file (doesn't abort entire batch on one failure)
- Respects cancellation

**Files**:
- `Vivacity/Services/FileRecoveryService.swift`

**Subtasks**:
- Define recovery API (async function + progress callback/stream).
- Read raw bytes at `offsetOnDisk` for each selected `RecoverableFile`.
- Write files to destination with collision-safe naming.
- Handle per-file errors without aborting the batch.
- Support cancellation and emit final completion status.

---

---

### T-033 ✅ Deep Scan live previews

**Description**: Enable live previewing of files discovered via Deep Scan before recovery runs. 
This requires extracting the raw bytes from `/dev/disk` using the discovered `offsetOnDisk` and `sizeInBytes` into an `NSTemporaryDirectory()` on-the-fly when the user clicks a row in the UI, and constructing an `NSImage` or `AVPlayer` from that temporary location.

**Files**: `FilePreviewView.swift`, `LivePreviewService.swift` [NEW]

---

## M8 — Scan Results UX

### T-022 ✅ Add result filtering

**Description**: Filter toolbar (by type, size, filename search) above the file list, matching Disk Drill's UX.

**Files**: `FileScanViewModel.swift`, `FileScanView.swift`, `FilterToolbar.swift` [NEW]

**Subtasks**:
- Define filter state (type, size range, filename query) in view model.
- Add filtering logic to derived list without mutating `foundFiles`.
- Implement `FilterToolbar` UI and bind to view model state.
- Ensure selection count updates reflect filtered vs total lists.
- Add lightweight unit tests for filter combinations.

---

### T-023 ✅ Add recovery confidence indicator

**Description**: Green/yellow/red dot per file indicating estimated recovery chances based on scan source and contiguity.

**Files**: `RecoverableFile.swift`, `FileRow.swift`, `FastScanService.swift`, `DeepScanService.swift`

**Subtasks**:
- Define confidence rules based on scan source and contiguity signals.
- Add confidence field or computed property to `RecoverableFile`.
- Render colored indicator in `FileRow` with accessible label.
- Update scan services to compute confidence where possible.
- Add tests for confidence classification.

---

### T-024 ✅ File size estimation for Deep Scan results

**Description**: Estimate file sizes by finding the next header or known footer bytes (e.g., JPEG `FF D9`, PNG `IEND`).

**Files**: `DeepScanService.swift`, `FileFooterDetector.swift` [NEW]

**Subtasks**:
- Implement footer/header detection for JPEG/PNG at minimum.
- Add a scanning window to estimate size without reading full disk.
- Integrate size estimation into Deep Scan result creation.
- Ensure size estimation is bounded and cancellation-aware.
- Add unit tests for footer detection and size estimation.

---

## M10 — Polish & Edge Cases

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

### T-017 ✅ Navigation & app flow integration

**Description**: Wire all screens together with proper navigation.

**Acceptance Criteria**:
- `NavigationStack`-based flow: Device Selection → Scan → Recovery
- Back navigation at each step
- State resets appropriately when navigating back

**Files**:
- Update `ContentView.swift`

**Subtasks**:
- Define navigation routes (device → scan → destination → recovery).
- Ensure back navigation resets scan state appropriately.
- Pass selected files and device into destination screen.
- Add recovery completion state and success view placeholder.
- Update previews to reflect navigation flow.

---

### T-018 ✅ Final visual polish & testing

**Description**: Overall UI refinement, dark mode support, and manual testing.

**Acceptance Criteria**:
- Consistent spacing, typography, and color usage
- Dark and light mode verified
- App icon (placeholder acceptable)
- Manual walkthrough of full flow: select device → scan → preview → recover

**Subtasks**:
- Audit spacing and typography for each screen (device, scan, destination).
- Verify light/dark appearance and fix contrast issues.
- Add placeholder app icon and confirm in Dock/Launchpad.
- Run manual end-to-end walkthrough and document issues.

**Completion Notes**:
- Final contrast + semantic-color polish applied to device and scan rows/overlays.
- Placeholder app icon assets added and wired in `Assets.xcassets`.
- End-to-end flow verified by app/UI tests (device selection → scan → preview/list interaction → recovery destination flow).

---

## M11 — Coverage & Quality Hardening

### T-034 ✅ Increase Fast Scan critical-path coverage

**Description**: Add unit tests for `FastScanService` to cover high-risk behavior currently at 0% line coverage, starting with filesystem trash discovery and APFS snapshot enumeration paths.

**Acceptance Criteria**:
- `FastScanServiceTests` added under `VivacityTests`
- Covers trash-directory discovery of supported media files and ignores unsupported files
- Covers APFS snapshot flow (discover snapshot names, mount callback usage, only emit files missing from live volume)
- Verifies stream emits completion/progress events for successful scan runs

**Files**:
- `VivacityTests/Services/FastScanServiceTests.swift` [NEW]
- `Vivacity/Services/FastScanService.swift` [NO API CHANGE EXPECTED]

**Completion Notes**:
- Added `FastScanServiceTests` covering trash discovery and APFS snapshot enumeration paths.
- Fixed snapshot/live-path comparison in `FastScanService.enumerateSnapshot` so files still present on the live volume are not emitted as deleted.
- Coverage improved for `FastScanService.swift` from 0% to 58.93% (340/577 lines) in the latest coverage run.

---

### T-035 ✅ Add filesystem catalog scanner test coverage

**Description**: Add deterministic unit tests for `FATDirectoryScanner`, `ExFATScanner`, and `NTFSScanner` using synthetic buffers/readers to validate deleted-entry parsing and edge cases.

**Acceptance Criteria**:
- Scanner-specific tests exist for happy path and malformed/corrupt entry paths
- At least one test per scanner validates deleted-entry detection and emitted `RecoverableFile`
- Coverage for each scanner file improves from 0%

**Files**:
- `VivacityTests/Services/FATDirectoryScannerTests.swift` [NEW]
- `VivacityTests/Services/ExFATScannerTests.swift` [NEW]
- `VivacityTests/Services/NTFSScannerTests.swift` [NEW]

**Completion Notes**:
- Added deterministic raw-buffer unit tests for FAT, ExFAT, and NTFS scanner flows with deleted-entry fixtures.
- Each scanner now has at least one happy-path deleted-file detection test that validates emitted `RecoverableFile` metadata.
- Coverage after this task:
  - `FATDirectoryScanner.swift`: 82.56% (303/367)
  - `ExFATScanner.swift`: 79.50% (256/322)
  - `NTFSScanner.swift`: 85.01% (312/367)

---

### T-036 ✅ Eliminate Swift 6 compatibility warnings in scan pipeline

**Description**: Resolve warnings that become Swift 6 errors, starting with async iteration over `FileManager` enumerators in `FastScanService`.

**Acceptance Criteria**:
- No `makeIterator` async-context warnings in `FastScanService.swift`
- Release build completes without Swift 6 migration warnings in modified files
- Behavior remains unchanged (scan results and cancellation semantics)

**Files**:
- `Vivacity/Services/FastScanService.swift`

**Completion Notes**:
- Replaced async `for-in` enumeration over `FileManager` enumerators with `while let ... = enumerator.nextObject() as? URL` in `FastScanService`.
- Removed Swift 6 migration warnings related to `makeIterator` in `FastScanService` while preserving scan behavior.
- Release builds now complete without Swift 6 migration warnings in `FastScanService.swift` (other pre-existing non-Swift6 warnings remain in carver files).

---

## M12 — XcodeGen Migration

### T-037 ✅ Define XcodeGen source-of-truth project spec

**Description**: Introduce a `project.yml` that reproduces the current `Vivacity.xcodeproj` structure and build settings so the project can be generated deterministically.

**Acceptance Criteria**:
- `project.yml` exists and defines `Vivacity`, `VivacityTests`, and `VivacityUITests` targets
- Target build settings, deployment target, entitlements, test host/bundle settings, and Swift versions match current behavior
- Existing run script phases (e.g., SwiftLint) are represented in XcodeGen spec
- `xcodegen generate` produces a buildable project

**Files**:
- `project.yml` [NEW]
- `Vivacity.xcodeproj/project.pbxproj` [GENERATED]

**Completion Notes**:
- Added `project.yml` defining `Vivacity`, `VivacityTests`, and `VivacityUITests` targets with macOS 14.0 + Swift 5 settings.
- Ported critical target settings (entitlements, bundle IDs, test host/bundle loader, app versioning) into XcodeGen config.
- Added SwiftLint pre-build script in spec with an output file stamp to avoid unconditional reruns.
- Regenerated `Vivacity.xcodeproj` via `xcodegen generate`.

---

### T-038 ✅ Validate generated-project parity

**Description**: Verify that the generated `.xcodeproj` is functionally equivalent to the current hand-maintained project.

**Acceptance Criteria**:
- `xcodebuild test -scheme Vivacity -destination 'platform=macOS'` passes using generated project
- `xcodebuild build -scheme Vivacity -destination 'platform=macOS'` passes using generated project
- `swiftlint` and `swiftformat` workflows still run without project configuration regressions
- No missing target membership issues (all source and test files compile in the expected targets)

**Files**:
- `project.yml` [MODIFY]
- `Vivacity.xcodeproj/project.pbxproj` [GENERATED]

**Completion Notes**:
- Verified generated project via `xcodebuild test -scheme Vivacity -destination 'platform=macOS' SYMROOT="$(pwd)/build"` (`** TEST SUCCEEDED **`).
- Verified generated project via `xcodebuild build -scheme Vivacity -destination 'platform=macOS' SYMROOT="$(pwd)/build"` (`** BUILD SUCCEEDED **`).
- Re-ran `swiftformat .` and `swiftlint` after migration changes; lint passes with 0 violations.
- Confirmed source/test target membership by successful compilation/execution of all unit and UI test targets.

---

### T-039 ✅ Document and enforce XcodeGen workflow

**Description**: Finalize repository workflow so contributors use XcodeGen as the canonical project definition.

**Acceptance Criteria**:
- README documents `xcodegen generate` as the standard setup step
- Decision is explicitly documented on whether `Vivacity.xcodeproj` is committed or regenerated locally
- Add lightweight guardrails (documentation and/or script) to prevent manual drift from `project.yml`

**Files**:
- `README.md` [MODIFY]
- `CONTRIBUTING.md` [NEW/MODIFY if present]
- `scripts/` [NEW/MODIFY if guard script is added]

**Completion Notes**:
- Updated README onboarding to run `xcodegen generate` before build and documented XcodeGen as source of truth.
- Added `CONTRIBUTING.md` with explicit contribution workflow for regenerate → verify → test/build.
- Documented and enforced decision to commit both `project.yml` and generated `Vivacity.xcodeproj`.
- Added lightweight guard script `scripts/check-xcodegen.sh` to detect project/spec drift.
---

---

## M13 — Recovery Quality Improvements

### T-040 ✅ Design confidence scoring and entropy filtering

**Description**: Introduce a confidence score for carved files combining signature strength, footer/structure presence, size plausibility, and entropy checks; drop low-confidence/low-entropy hits and surface confidence in the UI.

**Acceptance Criteria**:
- Confidence score computed for every `RecoverableFile` in deep scan path and persisted through the pipeline.
- Entropy/structure check filters out noise before emission.
- UI shows confidence badges and default-selects only medium/high confidence files.
- Tests cover scoring components and an end-to-end fixture where low-entropy hits are removed.

**Files**:
- `Vivacity/Services/DeepScanService.swift`
- `Vivacity/Models/RecoverableFile.swift`
- `Vivacity/ViewModels/FileScanViewModel.swift`
- `Vivacity/Views/FileScan/FileRow.swift`
- `VivacityTests/**` (new fixtures + tests)

**Completion Notes**:
- Added a persisted `confidenceScore` on `RecoverableFile` and mapped it to low/medium/high confidence buckets for UI and selection logic.
- Implemented deep-scan confidence scoring using signature strength, structure signal, size plausibility, and Shannon entropy.
- Added entropy-based JPEG false-positive suppression before emitting scan results.
- Updated file rows to show explicit confidence badges.
- Updated default selection behavior to auto-select only medium/high confidence discoveries.
- Added tests covering entropy suppression, confidence scoring persistence/classification, and default-selection behavior.

---

### T-041 ✅ Extend signatures and size inference

**Description**: Expand signature coverage (CR3, RAF, RW2, AVIF, ProRes/MOV atom patterns, JPEG variants) and improve size estimation using format-aware footer/box parsing.

**Acceptance Criteria**:
- `FileSignature.swift` includes added formats/variants with tests.
- JPEG size inference scans SOF/EOI; MP4/MOV size inference pairs `moov`/`mdat` boxes; graceful fallback on partials.
- Unit tests per new format and size-estimation correctness on partial files.

**Files**:
- `Vivacity/Models/FileSignature.swift`
- `Vivacity/Services/DeepScanService.swift`
- `VivacityTests/**` (fixtures for new formats)

**Completion Notes**:
- Extended signature coverage with `cr3`, `raf`, `rw2`, and `avif` and wired extension/category mapping.
- Added deep-scan matching for CR3/AVIF `ftyp` brands and MOV atom-pattern detection for files missing `ftyp`.
- Increased cross-boundary signature window to support longer RAW signatures (e.g., RAF).
- Improved JPEG size inference with SOF/EOI segment parsing before fallback heuristics.
- Improved MP4/MOV size inference to prefer paired media structures (`moov`/`mdat` or `moof`/`mdat`) with graceful fallback on partials.
- Added unit tests for new signatures, MOV atom detection, JPEG sizing path, and MP4 partial fallback behavior.

---

### T-042 ✅ Improve fragmented media reconstruction

**Description**: Rebuild fragmented MP4/MOV (stco/co64 chunk tables, CTS/DTS ordering) and add JPEG/HEIC split-segment reassembly with Huffman table re-seeding; output playable or best-effort partials.

**Acceptance Criteria**:
- `FragmentedVideoAssembler` rebuilds chunk tables and orders fragments correctly; playable output validated by tests.
- JPEG/HEIC reassembly merges split segments; falls back to partial save with clear flag.
- Tests with fragmented MP4/JPEG fixtures demonstrating successful reconstruction.

**Files**:
- `Vivacity/Services/FragmentedVideoAssembler.swift`
- `Vivacity/Services/ImageReconstructor.swift`
- `VivacityTests/**` (fragmented media fixtures)

**Completion Notes**:
- Implemented fragmented MP4/MOV assembly heuristics that scan and order nearby ISO BMFF boxes, detect playable `moov/moof` + `mdat` structures, and update unbounded video candidates with reconstructed best-effort size.
- Extended image reconstruction with a detailed result API (`ImageReconstructionResult`) carrying format and partial-status metadata.
- Added JPEG split-segment improvements including missing Huffman-table re-seeding before SOS and explicit partial output signaling when EOI is not found.
- Added HEIC split-segment reassembly by merging relevant ISO BMFF box sectors and reporting partial vs complete outcomes based on `moov/moof` + `mdat` presence.
- Added unit tests covering fragmented MP4 inference, JPEG/HEIC segment reconstruction, Huffman re-seeding, and partial-save signaling.

---

### T-043 ✅ Suppress false positives and deduplicate results

**Description**: Reduce duplicate/false hits via rolling Bloom filter of offsets, overlap checks, and size-vs-available-bytes guards.

**Acceptance Criteria**:
- Duplicate/overlapping signature hits are emitted once per offset.
- Matches that overrun device bounds or collide with existing ranges are rejected.
- Tests include overlapping-signature and out-of-bounds fixtures ensuring single emission and proper rejection.

**Files**:
- `Vivacity/Services/DeepScanService.swift`
- `VivacityTests/**`

**Completion Notes**:
- Added a rolling Bloom filter + exact offset set to short-circuit duplicate deep-scan hits while preserving exact dedupe correctness.
- Added claimed byte-range tracking for emitted candidates and rejected new candidates whose inferred ranges overlap existing claims.
- Added explicit size-vs-device-bounds guards to reject candidates whose inferred size would overrun available bytes on the scanned device.
- Applied the dedupe/overlap/bounds checks to both filesystem-carved and linear signature-scan candidates.
- Added targeted tests for overlapping JPEG candidates (single emission) and out-of-bounds PNG size inference rejection.

---

### T-044 ✅ Optimize scan performance and add resumability

**Description**: Add bounded-parallel scanning (TaskGroup) with adaptive chunk/read-ahead tuned to device block size; checkpoint scan cursor to resume after interruption.

**Acceptance Criteria**:
- Deep scan uses bounded concurrency with configurable limit; chunk size adapts to hit density/block size.
- Scan cursor (offset + signature state) is persisted periodically and used to resume.
- Benchmark test ensures max wall time on synthetic 1GB image stays within target; resume test continues after forced stop.

**Files**:
- `Vivacity/Services/DeepScanService.swift`
- `Vivacity/ViewModels/FileScanViewModel.swift`
- `VivacityTests/**` (benchmark/resume tests)

**Completion Notes**:
- Added bounded deep-scan parallelism (`TaskGroup`) with configurable worker limits via `PerformanceConfiguration`.
- Added adaptive chunk sizing driven by device `blockSize`, hit density, and bytes read throughput, with dynamic buffer resizing during scan.
- Added periodic deep-scan checkpoint events (`.checkpoint(offset)`) and final checkpoint emission before completion.
- Added resumability in `FileScanViewModel` by tracking latest checkpoint offset and periodically autosaving active scan sessions.
- Updated Fast Scan and scanner tests for new `ScanEvent`/`VolumeInfo` shape and kept event handling exhaustive.
- Verification on March 4, 2026: `xcodebuild test -scheme Vivacity -destination 'platform=macOS'` passed (81 unit + 1 UI); `xcodebuild build -scheme Vivacity` passed; `swiftlint` passes with warnings only.

---

### T-045 ✅ Salvage metadata and improve naming

**Description**: Extract EXIF/QuickTime metadata even from partial files to recover capture time/device; use for smarter filenames and grouping.

**Acceptance Criteria**:
- Partial files attempt EXIF/QuickTime atom extraction; failures do not crash.
- Recovered filenames incorporate capture time/device when available; grouping respects timezone offsets.
- Tests validate metadata extraction on partial JPEG/MOV fixtures and naming logic.

**Files**:
- `Vivacity/Services/EXIFDateExtractor.swift`
- `Vivacity/Services/PreviewService.swift`
- `Vivacity/Services/FileRecoveryService.swift`
- `VivacityTests/**` (partial media fixtures)

**Completion Notes**:
- Extended `EXIFDateExtractor` with resilient partial-media metadata extraction returning capture date, timezone offset, and device hints.
- Added QuickTime/MOV extraction from partial atom streams via `mvhd` creation time parsing plus ISO8601 fallback scanning.
- Added timezone-aware filename tokens (e.g. `yyyyMMdd_HHmmss+HHMM`) and filename-safe device tokens for naming/grouping.
- Updated `FileRecoveryService` to infer metadata-driven output filenames from head samples before writing recovered files, with safe fallback to original scan names.
- Added tests for partial JPEG metadata extraction with timezone, partial MOV `mvhd` extraction, and metadata-driven naming in recovery output.
- Regenerated Xcode project via XcodeGen so new tests are included in the test target.

---

### T-046 Surface recovery quality in UI and verify samples

**Description**: Expose confidence/corruption likelihood in the UI and add a “Verify sample” action that hashes head/tail bytes before full recovery to catch stale/locked sectors.

**Acceptance Criteria**:
- UI shows confidence badge and corruption likelihood per file; default selection uses confidence thresholds.
- “Verify sample” hashes head/tail and warns on mismatch/unreadable data before recovery.
- UI snapshot and flow tests cover badges and verify action.

**Files**:
- `Vivacity/Views/FileScan/FileRow.swift`
- `Vivacity/ViewModels/FileScanViewModel.swift`
- `Vivacity/Services/FileRecoveryService.swift`
- `VivacityTests/**` (UI snapshot/flow tests)
