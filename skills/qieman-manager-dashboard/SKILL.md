---
name: qieman-manager-dashboard
description: Native macOS Qieman application and Swift CLI for manager posts, comments, platform rebalancing, holdings, average cost, and current valuation.
---

# Qieman Manager Dashboard

This project is a native macOS SwiftUI application. The former Python Web dashboard has been removed.

## Open the application

```bash
export QIEMAN_PROJECT_DIR=/path/to/qieman-manager-dashboard
"$QIEMAN_PROJECT_DIR/scripts/qieman" app-open
```

## Query data without opening the UI

```bash
QIEMAN="$QIEMAN_PROJECT_DIR/scripts/qieman"
$QIEMAN group-lookup --prod-code LONG_WIN --with-group-info
$QIEMAN group-posts --prod-code LONG_WIN --pages 3
$QIEMAN platform-actions --prod-code LONG_WIN --limit 20
$QIEMAN platform-holdings --prod-code LONG_WIN
$QIEMAN post-comments --post-id 73567
```

## Rules

- Use the Swift CLI; do not reconstruct the removed Python commands.
- Qieman platform adjustments are the source of trade actions, not forum keyword matching.
- Current valuation prefers official real-time NAV when available, then uses native estimate fallbacks.
- Keep raw Cookie values local and out of responses.
- The app supports manual portfolio/plan maintenance only; image, OCR and table import were removed.

See [references/modes.md](references/modes.md) for task routing.
