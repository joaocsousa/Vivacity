# Vivacity — Test Plan for Milestones M1–M5

> Scope: Validation of shipped functionality up through M5 (Scan Engine Hardening + FS-aware Deep Scan). This plan defines what to test; do **not** execute yet.

## 0) Test Environments & Assets (Device-Safe)
- Hardware: Apple Silicon Mac (Sonoma 14.x or Sequoia 15.x), 16 GB+ RAM.
- Build: Debug build via `xcodebuild -scheme Vivacity -destination 'platform=macOS'`.
- **No live device writes:** All tests use **disk images** (DMG/RAW) mounted read-only. Avoid interacting with real user disks.
- Disk images to prepare:
  - FAT32 image with deleted test files (create with `hdiutil create` + `newfs_msdos`; delete files to create 0xE5 entries).
  - ExFAT image with deleted files.
  - APFS image with deleted files (use snapshots, then delete).
- Test media set: JPEG, PNG, HEIC, MP4 (H.264), MOV (HEVC).
- Stub data for unit tests: small byte buffers containing signature headers for JPEG/PNG/MP4 to feed carvers without any disk IO.

## 0b) Fakes/Stubs Strategy
- **Services**: Wrap `DeviceService`, `FastScanService`, `DeepScanService`, and `PrivilegedDiskReader` behind protocols to allow in-memory fakes in unit tests.
- **Device discovery**: Provide a fake that returns predefined `StorageDevice` objects pointing to temporary disk images.
- **Disk reads**: Fake `PrivilegedDiskReader` that serves data from memory-mapped files or byte arrays; no raw `/dev/disk*` access.
- **Carvers**: Unit-test carvers with static byte buffers; no device or file system needed.
- **UI/ViewModels**: Inject fakes into view models to exercise state transitions without real IO.

## 1) M1 — App Scaffolding
- Launch: App starts without crashes; window appears.
- Deployment target: Builds and runs on macOS 14+.
- Entry view: Shows empty `NavigationStack` root (no stray debug UI).

## 2) M2 — Device Selection
- Discovery: Mounted volumes listed; excludes system volumes (Recovery/Preboot/VM).
- Metadata: Name, internal/external badge, capacity values accurate.
- Sorting: External devices first, then alphabetical.
- Refresh: “Refresh” reloads list; mount/unmount triggers auto refresh.
- Selection: Row highlight toggles; Start Scanning disabled until a device is selected; navigation occurs when enabled.
- Error handling: Simulate discovery failure (e.g., mock or deny permissions) → alert shown, UI recovers after retry.

## 3) M3 — File Scan & Preview (Automated)
- Unit: FastScanService emits expected events for a fixture image; progress increases monotonically.
- Unit: DeepScanService yields carved results from fixture buffers; deduplication skips existing offsets.
- Unit: FileScanViewModel state machine transitions (idle → fastScanning → fastComplete → deepScanning → complete) with fakes.
- UI (XCUITest with fakes): Launch app with injected fake services; verify list updates, selection toggles, and navigation to scan view. (No real device IO.)

## 4) M4 — Scan Engine Hardening (Automated)
- Unit: PrivilegedDiskReader fake ensures no chmod performed; FIFO path creation invoked; reader respects offset sequencing.
- Unit: VolumeInfo detects filesystem type for fake devices.
- Unit: FAT/ExFAT/NTFS catalog scanners return expected synthetic entries from fixture buffers.
- UI (XCUITest with fakes): Denied privilege scenario shows error banner/state; app remains responsive (fake injected to simulate denial).

## 5) M5 — Filesystem-Aware Deep Scan (Automated)
- Unit: FATCarver parses fixture buffer with crafted directory entries; returns expected filenames/offsets.
- Unit: APFSCarver/HFSPlusCarver parse fixture buffers with catalog nodes; produce expected carved file metadata.
- Unit: DeepScanService dedupes carved offsets against provided existing offsets.
- UI (XCUITest with fakes): Deep scan phase displays progress updates and appends carved rows supplied by fake service.

## 6) Regression & Cross-Cutting (Automated)
- Unit: Cancellation propagates through view model and terminates fake streams; scanTask cleared.
- Unit: Navigation/state reset helper resets selection and phase when re-entering scan view.
- UI (XCUITest with fakes): Run cancel → restart flow to ensure UI returns to idle and progress resets.

## 7) Acceptance Criteria per Milestone
- M1: Build + launch succeeds with empty root UI.
- M2: Accurate, refreshable device list with correct gating of Start Scanning.
- M3: End-to-end dual scan flow with live list, preview, selection, cancel/skip handling.
- M4: Privileged access path works safely; catalog scanners re-enabled; no permission regressions.
- M5: FS-aware deep scan returns carved files per FAT/APFS/HFS+ without duplicating fast-scan results.

## 8) Out of Scope (for this phase)
- Recovery destination flow (M9), file recovery write path, advanced camera recovery, UX filters, and full polish items.

## 9) Evidence to Capture When Executing (Automated Artifacts)
- Unit: Test logs and captured fixture inputs/outputs for carvers and services.
- UI (XCUITest): XCResult bundle with screenshots/attachments from fake-driven flows.
- Metrics: Optional timing logs for scan loops against fixture buffers (performance regressions).
