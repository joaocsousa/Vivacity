---
description: How to submit code changes to the Vivacity project
---

# Making Changes

All changes to the Vivacity codebase must follow this workflow.

// turbo-all

## Steps

1. Create a feature branch from `main`:
   ```bash
   git checkout main && git pull origin main
   git checkout -b <branch-name>
   ```
   Branch naming: `feature/<name>`, `fix/<name>`, or `docs/<name>`.

2. Make your code changes.

3. Update documentation as needed:
   - **`README.md`** — if the change affects features, architecture, or build instructions.
   - **`PROJECT_PLAN.md`** — update ticket statuses (⬜ → 🔶 → ✅) and add new tickets if needed.
   - **`.agents/PROJECT.md`** — update the project status table if a milestone status changed.
   - **Code comments** — add `///` doc comments on new public types and functions.

4. Build and verify:
   ```bash
   xcodebuild build -scheme Vivacity -destination 'platform=macOS' SYMROOT="$(pwd)/build"
   ```

5. Commit with a descriptive message:
   ```bash
   git add -A && git commit -m "<type>: <description>"
   ```
   Types: `feat`, `fix`, `docs`, `refactor`, `chore`.

6. Push and create a pull request:
   ```bash
   git push origin <branch-name>
   gh pr create --title "<title>" --body "<description>"
   ```

7. After the PR is merged, switch back to `main`:
   ```bash
   git checkout main && git pull origin main
   ```

## Rules

- **Never push directly to `main`** — all changes must go through PRs.
- **Always update documentation** — README and PROJECT_PLAN.md must reflect the current state.
- **One concern per PR** — don't mix unrelated changes.
