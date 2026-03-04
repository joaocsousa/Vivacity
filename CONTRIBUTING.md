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
2. Regenerate the project:

```bash
xcodegen generate
```

3. Validate project/code quality:

```bash
./scripts/check-xcodegen.sh
swiftformat .
swiftlint
xcodebuild test -scheme Vivacity -destination 'platform=macOS' SYMROOT="$(pwd)/build"
xcodebuild build -scheme Vivacity -destination 'platform=macOS' SYMROOT="$(pwd)/build"
```

## Source of Truth

- `project.yml` is canonical.
- `Vivacity.xcodeproj` is committed but must always be regenerated from `project.yml`.
- Pull requests that include project changes should include both `project.yml` and generated `Vivacity.xcodeproj` updates.
