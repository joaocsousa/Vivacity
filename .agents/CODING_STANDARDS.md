---
name: Vivacity Coding Standards
description: Swift and SwiftUI coding conventions for the Vivacity macOS app
---

# Coding Standards & Style Guide

## Swift Language

- **Swift version**: 5.9+
- **macOS deployment target**: 14.0 (Sonoma)
- **Strict concurrency**: Use Swift's structured concurrency (`async`/`await`, `Task`, `AsyncSequence`) — avoid GCD unless interfacing with legacy APIs.

## Architecture — MVVM

```
View  →  ViewModel (ObservableObject / @Observable)  →  Service / Model
```

- **Views** are purely declarative SwiftUI — no business logic.
- **ViewModels** conform to `@Observable` (Swift 5.9 Observation framework) or `ObservableObject` with `@Published` properties.
- **Services** encapsulate disk I/O, device enumeration, and file recovery operations.
- **Models** are plain `struct` types conforming to `Identifiable`, `Hashable`, and `Sendable` where appropriate.

## Naming Conventions

| Element            | Convention          | Example                      |
|--------------------|---------------------|------------------------------|
| Types / Protocols  | UpperCamelCase      | `DeviceListViewModel`        |
| Functions / Vars   | lowerCamelCase      | `startScanning()`            |
| Constants          | lowerCamelCase      | `let maxFileSize = ...`      |
| Enum cases         | lowerCamelCase      | `.internalDrive`             |
| File names         | Match primary type  | `DeviceListViewModel.swift`  |

## SwiftUI Best Practices

1. **Keep views small** — Extract subviews into separate files/types when they exceed ~50 lines.
2. **Use `@State` for local state**, `@Binding` for parent-owned state, `@Environment` for app-wide dependencies.
3. **Prefer `@Observable` macro** (Swift 5.9) over `ObservableObject` for new code.
4. **Use `.task {}` modifier** for async work tied to view lifecycle — not `onAppear`.
5. **Leverage `NavigationStack`** with typed navigation paths.
6. **Use SF Symbols** for icons — no custom icon assets unless absolutely necessary.
7. **Support Dark Mode** — always test both appearances.

## Error Handling

- Use `Result` or `throws` — never force-unwrap (`!`) in production code.
- Present user-facing errors via `.alert()` modifiers bound to ViewModel state.
- Log internal errors with `os.Logger`.

## Concurrency

- All disk/IO operations must run off the main actor.
- Use `@MainActor` on ViewModels to guarantee UI updates happen on the main thread.
- Use `Task` and `TaskGroup` for parallel file scanning.
- Respect cancellation: check `Task.isCancelled` in long-running loops.

## Code Organization per File

```swift
// 1. Imports
import SwiftUI

// 2. Type declaration
struct DeviceSelectionView: View {
    // 3. Properties (state, bindings, environment)
    // 4. Body
    var body: some View { ... }
}

// 5. Subviews (private extensions)
private extension DeviceSelectionView { ... }

// 6. Previews
#Preview { ... }
```

## Formatting

- **Indentation**: 4 spaces (Xcode default).
- **Line length**: Soft limit 120 characters.
- **Trailing commas**: Use in multi-line collections/enums.
- **Braces**: K&R style (opening brace on same line).

## Access Control

- Default to `private` / `fileprivate` — expose only what is needed.
- Use `internal` (implicit) for types shared within the module.
- Mark ViewModel properties that the View reads as `private(set)` where possible.

## Documentation

- Add `///` doc comments on all public types and non-trivial functions.
- Use `// MARK: -` to separate logical sections within a file.

## Testing

- Unit test ViewModels and Services — Views are tested visually via Xcode Previews.
- Test files live in `VivacityTests/` and mirror the source structure.
- Use Swift Testing framework (`@Test`, `#expect`) for new tests.

## Git Workflow

- **All changes must go through pull requests** — never push directly to `main`.
- Create a feature branch from `main` (e.g., `feature/m4-recovery`, `fix/deep-scan-permissions`).
- PRs should have a descriptive title and body summarizing the changes.
- Merge via GitHub after review.

## Documentation

- **`README.md`** and **`PROJECT_PLAN.md`** must be updated as part of every PR that changes functionality, adds features, or modifies the project structure.
- Update milestone and ticket statuses in `PROJECT_PLAN.md` when completing work.
- Update `.agents/PROJECT.md` project status table when milestones change.
- Add `///` doc comments on all public types and non-trivial functions.
- Use `// MARK: -` to separate logical sections within a file.
