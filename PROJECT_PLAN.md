# Vivacity — Project Plan & Tickets

> **Goal**: Build a native macOS SwiftUI app that lets users scan storage devices for deleted image/video files and recover them.

---

## Milestones Overview

| # | Milestone | Tickets | Status |
|---|-----------|---------|--------|
| M1 | Project Scaffolding | T-001 | ✅ DONE |
| M2 | Device Selection Screen | T-002 → T-005 | ✅ DONE |
| M3 | File Scan & Preview Screen | T-006 → T-012 (T-008 split into a/b) | ⬜ TODO |
| M4 | Recovery Destination Screen | T-013 → T-015 | ⬜ TODO |
| M5 | Polish & Edge Cases | T-016 → T-018 | ⬜ TODO |

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

### T-006 ⬜ Define supported file formats

**Description**: Central list of image and video file signatures (magic bytes) and extensions the scanner should look for.

**Acceptance Criteria**:
- Image formats: JPEG, PNG, HEIC, HEIF, TIFF, BMP, GIF, WebP, RAW (CR2, NEF, ARW, DNG)
- Video formats: MP4, MOV, AVI, MKV, M4V, WMV, FLV, 3GP
- Struct or enum with extension string + magic byte signature for each format
- Conforms to `Sendable`

**Files**:
- `Vivacity/Models/FileSignature.swift`

---

### T-007 ⬜ Create `RecoverableFile` model

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

### T-008a ⬜ Create `FastScanService` — metadata-based scan

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

### T-008b ⬜ Create `DeepScanService` — raw byte carving

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

### T-009 ⬜ Create `FileScanViewModel` — dual-phase state machine

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

### T-010 ⬜ Create `FileScanView` — progressive scan UI

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

### T-011 ⬜ Create `FilePreviewView` — preview panel

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

### T-012 ⬜ Wire up split view — list + preview

**Description**: Combine file list and preview into a split/detail layout.

**Acceptance Criteria**:
- `NavigationSplitView` or `HSplitView` — list on left, preview on right
- Selecting a file in the list updates the preview
- Responsive resizing

**Files**:
- Update `FileScanView.swift`

---

## M4 — Recovery Destination Screen

### T-013 ⬜ Create `RecoveryDestinationViewModel`

**Description**: ViewModel for destination selection.

**Acceptance Criteria**:
- `@Observable class RecoveryDestinationViewModel`
- Properties: `destinationURL: URL?`, `requiredSpace: Int64`, `availableSpace: Int64`, `hasEnoughSpace: Bool` (computed)
- `func selectDestination()` — opens folder picker (`NSOpenPanel`)
- `func updateAvailableSpace()` — queries selected volume
- `func startRecovery() async` — triggers file recovery

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
- "Start Recovery" button — enabled only when `hasEnoughSpace`
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

## M5 — Polish & Edge Cases

### T-016 ⬜ Permission handling & sandboxing

**Description**: Ensure the app requests the necessary permissions and handles denial gracefully.

**Acceptance Criteria**:
- App entitlements configured: `com.apple.security.device.usb`, full-disk access if needed
- Guides user to System Preferences if permissions are missing
- Sandboxing decisions documented (may need to be non-sandboxed for raw disk access)

**Files**:
- `Vivacity/Vivacity.entitlements`
- `Vivacity/Views/PermissionPromptView.swift`

---

### T-017 ⬜ Navigation & app flow integration

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
| M5 | Full end-to-end flow works in both light and dark mode |

> [!TIP]
> For testing M3 scanning, create a test USB drive with known deleted files to validate the scanner finds them.
