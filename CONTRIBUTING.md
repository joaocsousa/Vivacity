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
xcodebuild build -scheme Vivacity -destination 'platform=macOS' SYMROOT="$(pwd)/build"
```

## Source of Truth

- `project.yml` is canonical.
- `Vivacity.xcodeproj` is generated locally and ignored by git.
- Pull requests should only include `project.yml` changes (plus any required scripts/docs).
