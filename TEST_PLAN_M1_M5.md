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

## 3) M3 — File Scan & Preview
- Fast Scan happy path: Runs to completion on test volume with deleted files; progress advances; results populate live list.
- Deep Scan prompt/flow: After Fast Scan completes, Deep Scan can be started, skipped, or cancelled.
- Selection UX: Select/deselect all; selection count updates; Recover button enabled only when criteria met.
- Preview: Selecting a file shows preview panel; image thumbnails render; video first-frame preview or fallback icon shown.
- Cancellation: Stop button halts active scan and transitions to completed state without crashes.
- Deduplication: Files found in Fast Scan not duplicated during Deep Scan (compare offsets/ids).

## 4) M4 — Scan Engine Hardening
- Privileged access: When scanning external raw device, app prompts once for password; scan proceeds without chmod side effects.
- Fallback behavior: If privilege denied, app surfaces the error and does not hang; limited scan path remains usable.
- Catalog scanners: FAT/ExFAT/NTFS catalog passes run and return results (use synthetic deleted 0xE5 files for FAT).
- Stability: Long-running scan (≥10 minutes) does not leak memory or crash; progress continues.

## 5) M5 — Filesystem-Aware Deep Scan
- FAT carving: Deleted directory entries reconstructed with names and offsets; carved files readable.
- APFS/HFS+ carving: Orphaned catalog nodes yield files with original names where present.
- Dedup vs Fast Scan: Carved results with offsets overlapping Fast Scan entries are skipped.
- Signature coverage: JPEG/PNG/HEIC/MP4/MOV headers detected in raw scan; estimated sizes plausible.
- Performance: Chunked read size (128 KB) maintains steady throughput; UI remains responsive.

## 6) Regression & Cross-Cutting
- Concurrency: Multiple scans cancelled/started sequentially do not leave dangling tasks (no repeated prompts).
- State reset: Navigating back from File Scan and re-entering resets scan state.
- Localization/sizing: UI tolerates narrow widths (min window); text truncation acceptable.

## 7) Acceptance Criteria per Milestone
- M1: Build + launch succeeds with empty root UI.
- M2: Accurate, refreshable device list with correct gating of Start Scanning.
- M3: End-to-end dual scan flow with live list, preview, selection, cancel/skip handling.
- M4: Privileged access path works safely; catalog scanners re-enabled; no permission regressions.
- M5: FS-aware deep scan returns carved files per FAT/APFS/HFS+ without duplicating fast-scan results.

## 8) Out of Scope (for this phase)
- Recovery destination flow (M9), file recovery write path, advanced camera recovery, UX filters, and full polish items.

## 9) Evidence to Capture When Executing
- Screenshots: Device list, scan in progress, preview panel.
- Logs: App log excerpts showing device discovery, privilege escalation path, and carve findings.
- Artifacts: List of recovered test files with sizes/offsets for later regression comparison.
