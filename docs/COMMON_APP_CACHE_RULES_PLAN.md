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

Reference datasets and projects to mine:

- BleachBit CleanerML: declarative cleaner XML, useful for modeling rule shape and safety metadata, but mostly Linux/Windows paths.
  Source: https://github.com/bleachbit/cleanerml
- BleachBit CleanerML documentation: useful for rule semantics such as glob/walk/deep matching, OS guards, running-process guards, and schema validation.
  Source: https://docs.bleachbit.org/cml/cleanerml.html
- Winapp2.ini: large community-maintained cleaner database, useful for app taxonomy and transient-data naming patterns. Windows paths must not be copied directly.
  Source: https://github.com/MoscaDotTo/Winapp2
- BleachBit Winapp2 guide: documents the scale and import model for community cleaners.
  Source: https://docs.bleachbit.org/doc/winapp2ini.html
- Homebrew official docs: cleanup is a first-class Homebrew concept; the app should either call Homebrew deliberately or keep a conservative cache-only Trash path.
  Sources: https://docs.brew.sh/Manpage and https://docs.brew.sh/FAQ
- macOS developer-cache cleaners such as `cache-cleaner` / `mac-cleaner-cli`: useful as command-backed references for Docker, npm, Homebrew, git, and build caches, but every command/path must be revalidated before enabling.
  Sources: https://github.com/markcallen/cache-cleaner and https://github.com/guhcostan/mac-cleaner-cli
- macOS app-cleaner projects such as Pearcleaner: useful for bundle/app relation discovery and competitor scope, but its uninstall/orphan model is broader than cache cleaning.
  Source: https://github.com/alienator88/Pearcleaner

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

Consumer and productivity apps should ship as a separate rule batch from developer caches. Their data-loss profile is different: chat apps and office suites often mix cache, documents, offline assets, and account/session databases in nearby folders. Rules must therefore prefer app-declared cache locations, Electron cache subfolders, and update/log payloads; message databases, synced documents, and browser profiles are blocked unless a dedicated product surface explains the consequences.

Domestic communication and collaboration:

- WeChat: logs/temp/cache only; chat databases and file storage blocked.
- QQ / TIM: logs/cache only; received files blocked by default.
- DingTalk: cache/log/update payloads.
- Feishu / Lark: cache/log/update payloads; prefer the app's built-in cache clear affordance when available, and block message/workspace databases.
- Tencent Meeting: logs/cache.
- WeCom / Enterprise WeChat: cache/log/update payloads; messages and received files blocked.

Domestic productivity and office:

- WPS Office: cache/log/update payloads; cloud documents, templates, recent file databases, and account data blocked.
- Kingsoft Docs: cache/log only; synced workspace data blocked.
- Youdao / Baidu / Tencent document tools: cache/log/update payloads only; user documents blocked.

Domestic cloud and media:

- Baidu Netdisk: cache/temp/update payloads; synced files blocked.
- Alibaba Drive / Quark Drive / 115: cache/temp/update payloads; synced folders and offline files blocked.
- NetEase Cloud Music: cache confirm; downloaded music blocked.
- Bilibili / iQIYI / Youku desktop cache if installed.

International communication and collaboration:

- Slack: `Cache`, `Code Cache`, `GPUCache`, logs.
- Discord: `Cache`, `Code Cache`, `GPUCache`.
- Teams: cache/log/update payloads.
- Zoom: logs/cache.
- Notion / Obsidian / Evernote: web/cache/log only; vaults, notebooks, and synced databases blocked.

International productivity and office:

- Microsoft Office: `~/Library/Containers/com.microsoft.*` cache/log/temp subpaths only; Outlook mail stores, OneDrive sync roots, templates, identities, and AutoRecovery require confirm or blocked depending on path.
- Google Drive: application cache/log/update payloads only; synced Drive folders blocked.
- Google Chrome / Edge / Brave / Arc: browser cache directories only, never profile data.
- Adobe Creative Cloud / Acrobat: cache/log/update payloads confirm; user projects, presets, libraries, and cloud sync roots blocked.
- Dropbox / OneDrive / Box: app cache/log/update payloads only; sync roots blocked.

Browser and Electron template:

- Chrome / Edge / Brave / Arc: browser cache directories only, never profile data.
- Electron apps may opt into `Cache`, `Code Cache`, `GPUCache`, `Service Worker/CacheStorage`, `logs`, and `Crashpad/completed` only. `Local Storage`, `IndexedDB`, `Cookies`, `Session Storage`, and profile roots are blocked by default because they may contain login/session/business data.

Developer-adjacent apps that are also consumer-facing:

- VS Code / Cursor: logs, CachedData, GPUCache; extensions confirm.
- JetBrains IDEs: caches/logs, old version caches.
- Docker Desktop: build cache should be command-backed or confirm; volumes blocked.
- Postman / Insomnia: cache/log only; workspaces blocked.
- Spotify: cache confirm; downloaded/offline content confirm.

Rule evidence sources for consumer/productivity apps:

- AppCleaner/Pearcleaner-style leftover discovery is useful for finding related bundle IDs and Library locations, but its uninstall model is broader than cache cleaning. Cache rules must not inherit "all related files" behavior.
- BleachBit CleanerML contribution guidance is a good policy baseline: option names must accurately describe what they delete, and cleaners should avoid settings the user may regret deleting.
- Vendor help pages, such as Feishu/Lark's cache clearing FAQ, are high-confidence sources for whether an app treats a cache as disposable.
  Sources: https://www.feishu.cn/hc/en-US/articles/399507903065-clear-cache-and-system-reset-faqs and https://www.larksuite.com/hc/en-US/articles/360048488246-clear-cache-and-system-reset-faqs

## Developer Cache Rule Batch

These rules should ship before broad consumer-app caches because they match the product's current user base and have clearer rebuild semantics.

Safe by default:

- Xcode: `DerivedData`, `Archives` old slices, `iOS DeviceSupport` old versions, `CoreSimulator/Caches`; simulator devices/runtimes require dedicated UI.
- Swift Package Manager: `.build`, `~/Library/Caches/org.swift.swiftpm`, `~/Library/org.swift.swiftpm` cache subdirectories only.
- CocoaPods: project `Pods` only when selected from developer workflow; `~/Library/Caches/CocoaPods`.
- Carthage: project `Carthage/Build`.
- Gradle: project `.gradle`, `~/.gradle/caches/modules-2/files-2.1` old entries; never delete `~/.gradle/gradle.properties`.
- Maven: `~/.m2/repository` artifacts only with confirmation; never delete `settings.xml`.
- npm / Yarn / pnpm: command-backed cache clean preferred; path fallback only for cache dirs (`~/.npm/_cacache`, `~/Library/Caches/Yarn`, `~/Library/pnpm/store`).
- Flutter / Dart: `.dart_tool`, `build`, `.pub-cache/hosted` old cache entries; never delete package config needed by current project without confirmation.
- Rust: `target`, `~/.cargo/registry/cache`, `~/.cargo/git/checkouts`; never delete credentials/config.
- Go: module/build caches (`~/Library/Caches/go-build`, `~/go/pkg/mod/cache`) with confirmation.
- Python: `__pycache__`, `.pytest_cache`, `.mypy_cache`, `.ruff_cache`, `.tox`; virtualenv directories confirm.
- Ruby: Bundler cache, `.bundle/cache`; never delete gem credentials.

Confirm by default:

- Docker Desktop: build cache should be command-backed or confirm-only; volumes/images/containers are blocked unless a dedicated Docker UI explains data loss.
- JetBrains IDEs: `~/Library/Caches/JetBrains/*`, logs, old version caches; settings/plugins confirm.
- VS Code / Cursor / Windsurf: `CachedData`, `Code Cache`, `GPUCache`, logs; extensions and user data blocked.
- Android Studio: Gradle/Android build caches; SDK platforms/system-images blocked unless shown as SDK components.
- Postman / Insomnia / Apifox: cache/log only; collections/workspaces/databases blocked.

Domestic developer tools:

- WeChat Developer Tools: cache/log/temp only; project files and account/session data blocked.
- HBuilderX / DCloud: build/cache/log dirs; plugins and user projects blocked.
- Huawei DevEco Studio: IDE caches/logs and Gradle/ohpm caches; SDK/toolchain packages confirm.
- Tencent CloudBase / mini-program CLIs: npm-style caches and logs; project workspace blocked.

Rule source policy:

- Imported rules are evidence, not executable truth.
- Every imported path must be mapped to macOS path conventions and verified with a fixture.
- Every rule needs `bundleIDs` or executable/app-name detection where possible.
- Browser/Electron apps can share a template for `Cache`, `Code Cache`, `GPUCache`, `Service Worker/CacheStorage`, and logs, but each app must explicitly opt in.
- Command-backed cleaners are preferred for package managers where official commands exist; path deletion is fallback and must move to Trash.

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
