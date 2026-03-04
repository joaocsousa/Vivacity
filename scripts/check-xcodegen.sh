#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is not installed. Install with: brew install xcodegen"
  exit 1
fi

echo "Generating project from project.yml..."
xcodegen generate >/dev/null

if git ls-files --error-unmatch "Vivacity.xcodeproj" >/dev/null 2>&1; then
  echo "error: Vivacity.xcodeproj is tracked. Remove it from git (we keep it untracked) and rerun."
  exit 1
fi

if [[ ! -d "Vivacity.xcodeproj" ]]; then
  echo "error: xcodegen did not produce Vivacity.xcodeproj"
  exit 1
fi

echo "OK: Generated Vivacity.xcodeproj (untracked) from project.yml."
