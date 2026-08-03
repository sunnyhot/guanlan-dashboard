# Native Swift CLI capability matrix

All commands are invoked through `scripts/qieman` and return JSON.

| Command | Purpose | Main options |
|---|---|---|
| `group-lookup` | Resolve group context | `--prod-code`, `--group-id`, `--group-url`, `--with-group-info` |
| `group-posts` | Public group-manager feed | `--prod-code`, `--manager-name`, `--keyword` |
| `public-items` | Public manager feed through native group APIs | `--prod-code`, `--manager-name`/`--author`, `--query`, `--preview` |
| `post-comments` | Comments for one post | `--post-id`, `--sort-type`, `--page-size` |
| `platform-actions` | Buy/sell actions and valuations | `--prod-code`, `--side`, `--since`, `--until` |
| `platform-holdings` | Current platform holdings | `--prod-code`, `--fund-code`, `--min-units` |
| `platform-timeline` | Per-asset action timeline | `--prod-code`, `--asset`, `--limit-entries` |
| `platform-monthly` | Monthly buy/sell cadence | `--prod-code`, `--months` |
| `alfa-actions` | Alfa advisory portfolio rebalancing | `--po-code` (default `ZH157591`), `--side`, `--since`, `--until` |
| `valuation` | Current fund estimates/NAV | `--fund-code` (repeatable), `--fund-codes` |
| `updates-watch` | Stateful incremental trades/posts | `--prod-code`, `--manager-name`, `--max-trades`, `--max-posts`, `--preview`, `--emit-initial`, `--state-file` |
| `signal-extract` | Keyword-based local signal extraction | `--json-path`, `--limit-items` |
| `app-open` | Open native macOS App | `--app-path` |

Removed contracts:

- The Python Web dashboard runtime and its start/status/stop API no longer exist.
- Public content uses the native Qieman group feed instead of probing content item IDs.
- Login-state commands (`auth-status`, `following-users`, `my-groups`, `following-posts`, `space-items`) and the `--cookie-file` option have been removed with the login-state migration; there is no `--cookie-file` parameter. The default Cookie path is `~/Library/Application Support/QiemanDashboard/qieman.cookie`.
- `updates-watch --forum-mode` is deprecated (login-state removed); every value falls back to `public`.
- Historical `valuation --at-date` lookup has been removed; `valuation` only returns current estimates or official NAV and reports unavailable values as `null`.
- File/image/OCR/table import commands do not exist.
