# Common App Cache Rules Plan

## Goal

Add common domestic and international app cache scanning without turning the cleaner into a risky "delete by app name" tool.

The rule system should only surface paths that are:

- user-level and reversible through Trash
- cache/log/temp/update payloads, not primary documents or account databases
- explainable in UI with source app, path, size, and side effects
- testable with fixtures before being enabled in production

## Industry Reference

- App uninstall and orphan cleanup should be separate concepts.
  - App uninstall: user selects an installed app, then reviews related files.
  - Orphan or remaining files: app is no longer installed, and the cleaner reverse-matches leftover service files.
- Rule-based cleaners usually keep rules declarative. BleachBit uses CleanerML XML; Winapp2 uses a large community-maintained declarative database.
- Orphan cleanup is high false-positive risk. It must default to conservative filtering, age thresholds, installed-app reverse lookup, and clear restore paths.

## Rule Model

Each common-app rule should be declarative:

```yaml
id: app.slack.cache
appNames: ["Slack"]
bundleIDs: ["com.tinyspeck.slackmacgap"]
category: communication
risk: safe
paths:
  - "~/Library/Application Support/Slack/Cache"
  - "~/Library/Application Support/Slack/Code Cache"
  - "~/Library/Application Support/Slack/GPUCache"
deleteMode: trash
notes:
  rebuild: "App may re-download thumbnails and web assets."
guards:
  requireInstalledBundleID: true
  excludeWhenRunning: true
```

Required fields:

- `id`
- `appNames` or `bundleIDs`
- `category`
- `risk`: `safe`, `confirm`, or `blocked`
- `paths`
- `deleteMode`
- `guards`

## Risk Rules

- `safe`: cache/log/temp/update download directories that the app can recreate.
- `confirm`: large offline assets, package stores, browser profiles, plugin caches, or directories that may require re-login/re-download.
- `blocked`: credentials, keychains, cookies, history, user documents, chat databases, browser profile databases, wallet data, IDE configs with tokens.

Never include:

- `~/Documents`, `~/Desktop`, `~/Downloads` catch-all paths
- browser profile root directories
- `Cookies`, `Login Data`, `History`, `Local State`
- chat message databases and media roots unless a dedicated UI explains the data loss
- password manager, wallet, SSH, GPG, certificate, or database credential directories

## First Rule Batch

Domestic apps:

- WeChat: logs/temp/cache only; chat databases and file storage blocked.
- QQ / TIM: logs/cache only; received files blocked by default.
- DingTalk: cache/log/update payloads.
- Feishu / Lark: cache/log/update payloads.
- Tencent Meeting: logs/cache.
- Baidu Netdisk: cache/temp/update payloads; synced files blocked.
- NetEase Cloud Music: cache confirm; downloaded music blocked.
- Bilibili / iQIYI / Youku desktop cache if installed.

International apps:

- Slack: `Cache`, `Code Cache`, `GPUCache`, logs.
- Discord: `Cache`, `Code Cache`, `GPUCache`.
- Teams: cache/log/update payloads.
- Zoom: logs/cache.
- Chrome / Edge / Brave / Arc: browser cache directories only, never profile data.
- VS Code / Cursor: logs, CachedData, GPUCache; extensions confirm.
- JetBrains IDEs: caches/logs, old version caches.
- Docker Desktop: build cache should be command-backed or confirm; volumes blocked.
- Postman / Insomnia: cache/log only; workspaces blocked.
- Spotify: cache confirm; downloaded/offline content confirm.

## Implementation Steps

1. Add `CommonAppCacheRule` model in ScanKit.
2. Add YAML/JSON rule loader with schema validation tests.
3. Add scanner that expands only explicit user-level paths and globs on the final path component.
4. Add running-app guard for rules marked `excludeWhenRunning`.
5. Add fixture tests for every rule family.
6. Add UI section "App Caches" with category filters and per-rule risk explanation.
7. Add deletion through existing Trash pipeline and UndoHistory.
8. Add exportable scan log: rule id, expanded paths, skipped reason, size, elapsed time.

## Acceptance Criteria

- No rule may emit a forbidden path under SafetyEngine.
- No rule may emit a primary app data root without `confirm`.
- Scanning must run off the main actor and publish results incrementally.
- A rule with 0 matched paths must not show a fake 0 KB cleanup item.
- Every enabled rule needs a test fixture and one negative test.
- UI must show why a path is safe or why confirmation is required.

