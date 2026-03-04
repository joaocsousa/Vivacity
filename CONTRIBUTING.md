# Contributing to Vivacity

## Prerequisites

- Xcode 15+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- `swiftformat`
- `swiftlint`

Install tooling with Homebrew:

```bash
brew install xcodegen swiftformat swiftlint
```

## Development Flow

1. Update project config in `project.yml` (not `project.pbxproj`).
2. Regenerate the project (untracked):

```bash
xcodegen generate
```

3. Validate project/code quality:

```bash
./scripts/check-xcodegen.sh   # regenerates and ensures xcodeproj stays untracked
swiftformat .
swiftlint
xcodebuild test -scheme Vivacity -destination 'platform=macOS' SYMROOT="$(pwd)/build"
xcodebuild test -scheme VivacityUI -destination 'platform=macOS' SYMROOT="$(pwd)/build"
xcodebuild build -scheme Vivacity -destination 'platform=macOS' SYMROOT="$(pwd)/build"
```

## SwiftLint Policy

- Never use `swiftlint:disable` or `swiftlint:enable` in source code.
- Do not silence warnings. Fix the underlying code so lint passes cleanly.

## Scan Behavior (Current)

Vivacity now uses a **single unified scan flow** from the user perspective.

- One scan action runs all available methods in one pass:
  - filesystem metadata scan
  - raw catalog/index scan (FAT32/ExFAT/NTFS)
  - deep sector carving
- Results are merged live into one list.
- Progress UI is unified and shows one progress bar, percentage, and ETA.

## Source of Truth

- `project.yml` is canonical.
- `Vivacity.xcodeproj` is generated locally and ignored by git.
- Pull requests should only include `project.yml` changes (plus any required scripts/docs).
