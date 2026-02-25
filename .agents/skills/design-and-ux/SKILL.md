---
name: Design & UX Standards
description: Instructions for creating a premium, modern, and highly polished macOS UI for Vivacity.
---

# Design & UX Skill

Vivacity is not just a utility; it must look and feel like a highly polished, premium macOS application. The user should be "wowed" by the clean aesthetics and smooth interactions. Whenever you add new UI elements or screens, you must adhere to these design principles.

## 1. The "Premium" Aesthetic

Do not build bare-bones or purely utilitarian interfaces.
*   **Color Palette**: Use subtle, modern color palettes. Rely heavily on system semantic colors (e.g., `.secondary`, `.quaternarySystemFill`) layered correctly, rather than hardcoding solid colors like `.red` or `.blue`.
*   **Translucency & Materials**: Use native materials sparingly but effectively to create depth. `.background(.regularMaterial)` or `.ultraThinMaterial` on sidebars or sticky headers works exceptionally well on macOS.
*   **Typography**: Stick to the native system font (`San Francisco`), but make intentional use of `.fontDesign(.rounded)` for numbers/metrics or distinct `.fontWeight` variations to establish a clear hierarchy.

## 2. Dynamic Interactions

An interface that feels alive encourages user confidence.
*   **Hover Effects**: Every clickable element (buttons, rows, cards) must have a subtle hover effect (e.g., slight background color shift or opacity change).
*   **Micro-animations**: Use explicit `.animation(.spring(response: 0.3, dampingFraction: 0.7), value: state)` when UI state changes (e.g., a file being selected, expanding a panel, or a scan completing).
*   **Transitions**: When new elements enter the screen, use `.transition(.opacity.combined(with: .move(edge: .bottom)))` rather than having them instantly appear.

## 3. Empty States & Loading

You are building a scanner—the user will spend time waiting or looking at empty lists.
*   Never show a completely blank screen.
*   **Empty States**: Show a high-quality SF Symbol, a clear title, and a subtitle explaining why the list is empty or what the user should do next.
*   **Loading**: Use custom animated progress indicators or sleek `ProgressView` styles. Do not just slap a standard spinner in the middle of a blank page.

## 4. Dark & Light Mode Support

*   Vivacity must look incredible in both Dark and Light modes.
*   Never hardcode colors like `Color.black` or `Color.white`. Use semantic colors like `Color.primary` and `Color(nsColor: .windowBackgroundColor)`.
*   Verify contrast on any custom accent colors.

## 5. Icons and Imagery

*   Rely entirely on **SF Symbols** (`Image(systemName:)`).
*   Use multicolor symbols or hierarchical rendering (`.symbolRenderingMode(.hierarchical)`) to make icons pop.

When building a screen for Vivacity, always ask yourself: *"Does this feel like a top-tier app feature by Apple or a premium indie developer?"* If not, elevate the design before committing the code.
