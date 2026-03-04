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

if ! git diff --quiet -- project.yml Vivacity.xcodeproj; then
  echo "error: Generated project is out of sync with project.yml."
  echo "Run 'xcodegen generate' and commit updated files."
  git --no-pager diff --stat -- project.yml Vivacity.xcodeproj
  exit 1
fi

echo "OK: XcodeGen spec and Vivacity.xcodeproj are in sync."
