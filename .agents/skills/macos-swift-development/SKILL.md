---
name: macOS Swift Development
description: Core conventions, commands, and best practices for developing the Vivacity native macOS app in Swift 5.9+ and SwiftUI.
---

# macOS Swift Development Skill

The Vivacity application is a modern macOS-native application requiring strict adherence to specific Swift and SwiftUI patterns. Any AI agent modifying this project must understand and apply these principles to ensure stability, performance, and code quality.

## Core Architecture: MVVM with Observation

Vivacity operates on a strictly separated MVVM architecture leveraging the Swift 5.9 Observation framework.

1. **Views**: Must be completely devoid of business logic. They bind to ViewModels and observe state.
2. **ViewModels**: Must be annotated with `@Observable` (not `ObservableObject`). All state intended for the View should be properties of the ViewModel.
3. **Services**: Encapsulate file system, disk, and operating system level operations. Only Services should call raw APIs.

Example ViewModel:
```swift
import Foundation
import Observation

@Observable
final class ExampleViewModel {
    var isLoading: Bool = false
    var items: [String] = []
    
    // Dependencies are injected or privately created
    private let service = ExampleService()
    
    init() {}
    
    @MainActor
    func loadData() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            items = try await service.fetchData()
        } catch {
            print("Error: \(error)")
        }
    }
}
```

## Structured Concurrency (`async`/`await`)

*   **Never use GCD (`DispatchQueue`).** 
*   Use asynchronous functions (`async throws`), `Task {}`, and `TaskGroup` for concurrent operations like deep scanning.
*   **Main Actor Isolation**: Any method in a ViewModel that updates properties bound to a SwiftUI View *must* be annotated with `@MainActor`.
*   **Cancellation**: Always check `Task.isCancelled` during long loops (e.g., `DeepScanService.swift`).

## Build and Analysis Commands

Do not use Xcode's GUI for regular development cycles; use the CLI tools configured for this project.

*   **Build the App:**
    ```bash
    xcodebuild build -scheme Vivacity -destination 'platform=macOS' SYMROOT="$(pwd)/build"
    ```
*   **Test, Format, & Lint Code (MANDATORY):**
    You **MUST** run the test suite, `swiftformat .`, and `swiftlint` when you believe you are finished with a task, before marking it as complete or notifying the user. Fix any failing tests, warnings, or errors that arise.
    ```bash
    xcodebuild test -scheme Vivacity -destination 'platform=macOS' SYMROOT="$(pwd)/build"
    swiftformat . && swiftlint
    ```
*   **Static Analyzer:**
    Use this to catch memory and logic bugs before opening a Pull Request.
    ```bash
    xcodebuild analyze -scheme Vivacity -destination 'platform=macOS' SYMROOT="$(pwd)/build"
    ```

## Recording UI Output (`macosrec`)

When implementing new UI features, it is highly recommended to capture visual evidence of your work. We use the custom CLI tool `macosrec`.

1. Find the window: `macosrec --list`
2. Screenshot: `macosrec --screenshot <windowID>`
3. Record GIF: `macosrec --record <windowID> --gif`

## SwiftUI View Rules

1.  **Start Tasks Correctly**: Use `.task { await viewModel.load() }` for async view lifecycle tasks. Do not use `.onAppear { Task { ... } }`.
2.  **No Logic in Views**: Move all conditionals, text formatting, and data manipulation into the ViewModel or View extension utilities.
3.  **Use SF Symbols**: Whenever a generic icon is needed (e.g., drives, checkmarks, warnings), use native `Image(systemName:)`. Do not use external image assets unless specifically requested.
