---
name: qieman-alpha-signals
description: Native macOS Qieman toolkit with atomic Swift CLI commands for public group-manager feeds, comments, platform actions, alfa advisory rebalancing, holdings, valuations, incremental updates, and signal extraction.
---

# Qieman Alpha Signals

Use the native Swift command-line tool in this repository. The toolkit is macOS-only and has no Python or local HTTP-server dependency.

## Setup

Resolve the repository, then use its launcher:

```bash
export QIEMAN_PROJECT_DIR=/path/to/qieman-manager-dashboard
QIEMAN="$QIEMAN_PROJECT_DIR/scripts/qieman"
```

The launcher builds `dist/bin/qieman-cli` on first use. Every data command emits machine-readable JSON with stable snake_case keys.

## Commands

```bash
$QIEMAN group-lookup --prod-code LONG_WIN --with-group-info
$QIEMAN group-posts --prod-code LONG_WIN --pages 5
$QIEMAN public-items --prod-code LONG_WIN --query "长赢计划"
$QIEMAN post-comments --post-id 73567 --sort-type hot
$QIEMAN platform-actions --prod-code LONG_WIN --side all --limit 20
$QIEMAN platform-holdings --prod-code LONG_WIN
$QIEMAN platform-timeline --prod-code LONG_WIN
$QIEMAN platform-monthly --prod-code LONG_WIN --months 12
$QIEMAN alfa-actions --po-code ZH157591
$QIEMAN valuation --fund-codes 021550,001052
$QIEMAN updates-watch --prod-code LONG_WIN --manager-name "ETF拯救世界"
$QIEMAN signal-extract --json-path /path/to/posts.json
```

To open the native application:

```bash
$QIEMAN app-open
```

## Routing

1. Group context: `group-lookup`.
2. Public manager feeds: `group-posts`, `public-items`.
3. Comments: `post-comments`.
4. Platform data: `platform-actions`, `platform-holdings`, `platform-timeline`, `platform-monthly`, `alfa-actions`.
5. Current estimates: `valuation`.
6. Incremental polling: `updates-watch`; first run builds a baseline unless `--emit-initial` is supplied.
7. Local JSON inference: `signal-extract`.

Login-state commands (`auth-status`, `following-users`, `my-groups`, `following-posts`, `space-items`) and `--forum-mode`/`--cookie-file` were removed with the login-state migration; do not issue them.

## Safety

- The Cookie lives at `~/Library/Application Support/QiemanDashboard/qieman.cookie`; there is no `--cookie-file` option.
- Never print or summarize raw Cookie values.
- Use absolute dates in user-facing summaries.
- Treat valuation as an estimate unless the returned source indicates a confirmed official NAV.

See [references/capabilities.md](references/capabilities.md) for the command contract.
