---
name: Documentation & Process Management
description: Rules for maintaining the project plan, tickets, and internal AI documentation.
---

# Documentation & Process Skill

For Vivacity to succeed, especially through handoffs between different AI models (e.g., Gemini to Codex), the state of the project must be meticulously tracked in the markdown documentation. We do not use Jira or external trackers—the Git repository is the single source of truth.

## 1. Pre-Implementation Checklist

Before you write a single line of SwiftUI or Swift code, you must:
1. Read `.agents/PROJECT.md` to understand the high-level architecture and current milestone.
2. Open `PROJECT_PLAN.md` and find the specific ticket (`T-XXX`) you are assigned to or have decided to work on.
3. Verify that all dependent earlier tickets are marked `✅ DONE`.

## 2. In-Progress Updates

While working on a feature:
*   Use internal AI artifacts (like `task.md` or `implementation_plan.md`) to organize your thoughts.
*   If a ticket requires multiple steps across different files, update the ticket status in `PROJECT_PLAN.md` to `🔶 IN PROGRESS`.

## 3. Post-Implementation Documentation

Once the code is written, builds successfully, and is linted, you **MUST** execute these documentation updates before committing:

1.  **Mark the Ticket Done**: Open `PROJECT_PLAN.md`, find your ticket, and change its state to `✅ DONE`.
2.  **Update Milestone Status**: If your ticket completed a milestone, open `.agents/PROJECT.md` and change that milestone's status in the table to `✅ Done`.
3.  **Update READMEs**: If you added a major new overarching feature (e.g., Deep Scan is finally working, or Dark Mode was added), summarize it briefly in the top-level `README.md`.
4.  **Code Comments**: Ensure any new `public` or `internal` struct/class/function has standard Swift `///` doc comments explaining its purpose.

## 4. Creating New Tickets

If you discover a bug, edge case, or a necessary refactor that is *not* covered by the current active ticket:
1. Do not silently fix massive architectural issues inside an unrelated UI PR.
2. Create a new ticket in `PROJECT_PLAN.md` under the closest relevant milestone (usually "Polish & Edge Cases" or "Advanced Features").
3. Assign it the next sequential ID (e.g., `T-032`).
4. Detail the findings and acceptance criteria.

**By following this strict documentation protocol, any AI agent can wake up, read `PROJECT_PLAN.md`, and know exactly where to start within seconds.**
