# Native application and CLI routing

Set `QIEMAN_PROJECT_DIR` to the repository and invoke `$QIEMAN_PROJECT_DIR/scripts/qieman`.

## Native UI

```bash
scripts/qieman app-open
```

Use the SwiftUI application for interactive portfolio, forum, platform, settings and workbench tasks.

## Community

```bash
scripts/qieman group-lookup --prod-code LONG_WIN --with-group-info
scripts/qieman group-posts --prod-code LONG_WIN
scripts/qieman public-items --prod-code LONG_WIN --query "长赢计划"
scripts/qieman post-comments --post-id 73567
```

## Platform and valuation

```bash
scripts/qieman platform-actions --prod-code LONG_WIN
scripts/qieman platform-holdings --prod-code LONG_WIN
scripts/qieman platform-timeline --prod-code LONG_WIN
scripts/qieman platform-monthly --prod-code LONG_WIN --months 12
scripts/qieman valuation --fund-codes 021550,001052
```

## Authentication

The Cookie path is `~/Library/Application Support/QiemanDashboard/qieman.cookie`; there is no `--cookie-file` option. Never expose the Cookie content.

## Removed modes

There is no localhost dashboard, HTTP route, Python crawler, OCR, image import, or spreadsheet import. Login-state commands (`auth-status`, `following-users`, `my-groups`, `following-posts`, `space-items`) and `--forum-mode` were removed with the login-state migration.
