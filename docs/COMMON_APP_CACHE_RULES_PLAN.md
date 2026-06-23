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

## Researched Candidate Rule Matrix

This section is based on open-source macOS cleaner rules plus the project's existing `Resources/Rules/vendors.yaml` and `vendor_shared.yaml`. The user examples are not treated as the whole scope; the product should ship capabilities by app family, then add concrete app mappings when the path evidence is strong.

Sources checked:

- `mac-cleanup-go`: broad macOS target list with risk categories and Trash/manual modes.
  Source: https://github.com/2ykwang/mac-cleanup-go
- `mac-cleanup-py`: older but useful app-specific cleanup modules for Adobe, Google Drive, Steam, Teams, Telegram, Obsidian, Chromium, Arc, and EA.
  Source: https://github.com/mac-cleanup/mac-cleanup-py
- `mac-cleaner-cli`: browser cache scanner and path helpers for Chrome, Safari, Firefox, Arc, plus developer caches.
  Source: https://github.com/guhcostan/mac-cleaner-cli
- BleachBit CleanerML and Winapp2: rule-shape, option semantics, guards, and large community taxonomy. Their paths are not macOS-first and must not be copied directly.
  Sources: https://github.com/bleachbit/cleanerml, https://docs.bleachbit.org/cml/cleanerml.html, https://github.com/MoscaDotTo/Winapp2
- Feishu/Lark vendor docs: validates that the product treats cache clearing as a supported operation.
  Sources: https://www.feishu.cn/hc/en-US/articles/399507903065-clear-cache-and-system-reset-faqs and https://www.larksuite.com/hc/en-US/articles/360048488246-clear-cache-and-system-reset-faqs

### Capability families

| Family | Capability | Initial apps | Default risk | Notes |
| --- | --- | --- | --- | --- |
| Browser cache | Browser HTTP/GPU/shader cache only | Chrome, Edge, Brave, Arc, Chromium, Safari, Firefox | safe or confirm | Never delete profile roots, cookies, history, login data, web data, or Local State. |
| Electron cache | `Cache`, `Code Cache`, `GPUCache`, `Dawn*Cache`, `ShaderCache`, logs, completed crash reports | Slack, Discord, Notion, Obsidian, Linear, Postman, ChatGPT, Claude, Codex, VS Code forks | safe | Each app must opt in with bundle/app support mapping. No generic "delete every Electron app" pass. |
| Chat and meetings | App cache/log/update payloads | WeChat, Tencent Meeting, WhatsApp, Skype, Teams, Zoom, Feishu/Lark after fixture | safe or confirm | Message DB, received files, IndexedDB, Local Storage, and media roots are blocked unless a dedicated chat-storage UI is built. |
| Cloud sync | Cache only, never sync roots | Google Drive, Dropbox, OneDrive, Box after fixture | confirm | Require running-app guard because sync clients may rewrite caches while active. Offline re-download cost should be visible. |
| Office/productivity | Container cache/log/temp only | Microsoft Office, WPS, Kingsoft Docs, Evernote, Bear, Logseq | safe or confirm | Outlook stores, Office group container root, cloud docs, templates, AutoRecovery, and account data are blocked. WPS/Kingsoft need local fixture evidence before enabling beyond cache bundle dirs. |
| Design/media | Media/render/cache dirs only | Adobe, Premiere, Sketch, Figma, Blender, DaVinci, Final Cut, Bilibili, IINA, VLC, mpv | confirm | Render/media cache can be large and rebuildable but expensive; show side effects and keep running-app guard. |
| Game launchers | Launcher cache, shader cache, logs, temp downloads | Steam, Epic, Battle.net, GOG, EA, Riot | confirm | Game libraries, saves, mods, and user screenshots are blocked. |
| Remote/utility | App cache/logs | TeamViewer, AnyDesk, Alfred, CleanShot, The Unarchiver | safe | Simple bundle-cache mappings, low first-batch risk. |
| Developer assistant apps | App cache/logs, not workspace/user data | Postman, TablePlus, Charles, Sequel Ace, VMware, Parallels | safe or confirm | DB connection profiles, collections, VMs, snapshots, and workspaces are blocked. |

### P0: safe first batch

These are good first implementation candidates because the evidence points to cache/log directories and deletion can go through the existing Trash pipeline.

| App/capability | Candidate paths | Evidence | Guard |
| --- | --- | --- | --- |
| WeChat cache | `~/Library/Caches/com.tencent.xinWeChat/*` | `mac-cleanup-go` | Exclude while WeChat is running. Do not touch chat DB or file storage. |
| Tencent Meeting cache | `~/Library/Caches/com.tencent.meeting/*` | `mac-cleanup-go` | Exclude while running. |
| WhatsApp cache | `~/Library/Caches/net.whatsapp.WhatsApp/*` | `mac-cleanup-go` | Exclude while running; do not touch message DB/media. |
| Skype cache | `~/Library/Caches/com.skype.skype/*` | `mac-cleanup-go` | Exclude while running. |
| Zoom cache/update | `~/Library/Caches/us.zoom.xos/*`, `~/Library/Application Support/zoom.us/AutoUpdater/*` | `mac-cleanup-go` | Exclude while running. |
| Notion cache | `~/Library/Application Support/Notion/Cache/*`, `~/Library/Application Support/Notion/Code Cache/*`, `~/Library/Application Support/Notion/GPUCache/*`, `~/Library/Caches/notion.id/*` | `mac-cleanup-go` | Exclude while running; do not touch workspace/db roots. |
| Obsidian cache/log | `~/Library/Application Support/obsidian/Cache/*`, `Code Cache/*`, `GPUCache/*`, `DawnGraphiteCache/*`, `DawnWebGPUCache/*`, `*.log` | `mac-cleanup-go`, `mac-cleanup-py` | Exclude while running; vaults are blocked. |
| Linear cache | `~/Library/Application Support/Linear/Cache/*`, `Code Cache/*`, `~/Library/Caches/com.linear/*` | `mac-cleanup-go` | Exclude while running. |
| Figma cache | `~/Library/Caches/com.figma.Desktop/*` | `mac-cleanup-go` | Exclude while running. |
| ChatGPT cache | `~/Library/Caches/com.openai.chat/*` | `mac-cleanup-go` | Exclude while running. |
| Claude cache | `~/Library/Caches/com.anthropic.claudefordesktop/*`, `~/Library/Caches/claude-cli-nodejs/*` | `mac-cleanup-go` | Exclude desktop app while running. |
| Codex cache/log | `~/Library/Application Support/Codex/Cache/*`, `Code Cache/*`, `GPUCache/*`, `Dawn*Cache/*`, `~/Library/Logs/com.openai.codex/*` | `mac-cleanup-go` | Exclude while running. |
| Google Updater cache | `~/Library/Application Support/Google/GoogleUpdater/crx_cache/*`, `~/Library/Application Support/Google/GoogleUpdater/*.old` | `mac-cleanup-go` | Vendor shared-dir guard: never delete `~/Library/Application Support/Google` root. |
| IINA/VLC/mpv cache | `~/Library/Caches/com.colliderli.iina/*`, `~/Library/Caches/org.videolan.vlc/*`, `~/Library/Caches/io.mpv/*` | `mac-cleanup-go` | Exclude while running. |
| Bilibili cache | `~/Library/Caches/tv.danmaku.bili/*` | `mac-cleanup-go` | Exclude while running. |
| Sketch cache | `~/Library/Caches/com.bohemiancoding.sketch3/*` | `mac-cleanup-go` | Exclude while running. |
| Postman cache | `~/Library/Caches/com.postmanlabs.mac/*` | `mac-cleanup-go` | Workspaces/databases blocked. |
| TablePlus/Charles/Sequel Ace cache | `~/Library/Caches/com.tinyapp.TablePlus/*`, `~/Library/Caches/com.charlesproxy.charles/*`, `~/Library/Caches/com.sequel-ace.sequel-ace/*` | `mac-cleanup-go` | Connection profiles blocked. |

### P1: useful but confirmation required

These can free real space, but the UI must show side effects such as re-download, reindex, re-render, or app restart.

| App/capability | Candidate paths | Evidence | Guard |
| --- | --- | --- | --- |
| Google Drive cache | `~/Library/Application Support/Google/DriveFS/*/content_cache/*`, `~/Library/Caches/com.google.drivefs/*` | `mac-cleanup-go`, `mac-cleanup-py` | Confirm + exclude while running. Do not kill the app automatically. Sync roots and CloudStorage documents are blocked. |
| Dropbox cache | `~/Dropbox/.dropbox.cache/*` | `mac-cleanup-go`, `mac-cleanup-py` | Confirm + exclude while running. Never scan/delete the Dropbox sync root as cache. |
| OneDrive cache | `~/Library/Caches/com.microsoft.OneDrive/*` | `mac-cleanup-go` | Confirm + exclude while running. OneDrive sync roots and Office group container roots blocked. |
| Adobe media cache | `~/Library/Application Support/Adobe/Common/Media Cache Files/*`, `~/Library/Application Support/Adobe/Common/Media Cache/*`, `~/Library/Caches/com.adobe.PremierePro.*/*` | `mac-cleanup-go`, `mac-cleanup-py` | Confirm + exclude while Adobe apps are running. Never delete Adobe shared root, presets, libraries, projects, or cloud sync roots. |
| Steam cache | `~/Library/Application Support/Steam/appcache`, `depotcache`, `logs`, `steamapps/shadercache`, `steamapps/temp`, `steamapps/download` | `mac-cleanup-py` | Confirm + exclude while running. Game libraries, saves, screenshots, and workshop content blocked. |
| Battle.net/Epic/GOG/EA/Riot cache | `~/Library/Caches/com.blizzard.Battle.net/*`, `~/Library/Application Support/Battle.net/Cache/*`, `~/Library/Caches/com.epicgames.EpicGamesLauncher/*`, `~/Library/Caches/com.gog.galaxy/*`, `~/Library/Caches/com.ea.*/*`, `~/Library/Caches/com.riotgames.*/*` | `mac-cleanup-go`, `mac-cleanup-py` | Confirm; game content blocked. |
| Teams safe subset | `~/Library/Application Support/Microsoft/Teams/Cache`, `Application Cache`, `Code Cache`, `gpucache`, `tmp`, logs/watchdog files | `mac-cleanup-py` | Confirm + exclude while running. `IndexedDB`, `databases`, `Local Storage`, `blob_storage` are not in the safe subset. |
| VMware/Parallels cache | `~/Library/Caches/com.vmware.fusion/*`, `~/Library/Caches/com.parallels.*/*` | `mac-cleanup-go` | Confirm. VM bundles, snapshots, and disk images blocked. |
| DaVinci/Final Cut render cache | `~/Library/Caches/com.blackmagic-design.DaVinciResolve/*`, `~/Movies/CacheClip/*`, `~/Library/Caches/com.apple.FinalCut/*` | `mac-cleanup-go` | Confirm with render/proxy cache warning. Project libraries blocked. |

### P2: block by default or manual guide only

These were found in existing tools, but they are too risky for a generic common-cache rule.

| App/path family | Existing source evidence | GSYCleanMac decision |
| --- | --- | --- |
| Telegram `postbox/db` | `mac-cleanup-go`, `mac-cleanup-py` | Manual guide only. It may contain chat history and media indexes. Do not delete through normal cache flow. |
| Arc `History`, `Cookies`, `Web Data` | `mac-cleanup-py` | Block. Only `~/Library/Caches/Arc`, `~/Library/Caches/company.thebrowser.Browser`, and CloudKit cache candidates can be considered. |
| Teams `IndexedDB`, `databases`, `Local Storage`, `blob_storage` | `mac-cleanup-py` | Block or require a dedicated "reset Teams local data" UI. Not part of cache cleanup. |
| Browser profile roots | Generic browser cleaners | Block. Only explicit cache paths under cache roots/profile cache subdirs. |
| Microsoft Office group container root | Project `vendor_shared.yaml` | Block. Only app-specific cache/log/temp subpaths after rule evidence. |
| Apple Mail, Photos, Music libraries | OS/app data | Block in common-cache batch. Require dedicated product surfaces. |
| Chat received-file roots and message DBs | App data | Block. Cache cleanup is not chat-history cleanup. |
| WPS/Kingsoft/Feishu/DingTalk guessed Application Support roots | Not enough current open-rule evidence | Do not enable from guesses. Add fixture discovery first, then enable only cache/log/update subpaths. |

### Domestic and international rollout list

This is the broader coverage backlog. It should be implemented by evidence strength, not by brand importance.

Ready from open-rule evidence:

- Domestic: WeChat, Tencent Meeting, Bilibili.
- International communication: WhatsApp, Skype, Zoom, Teams safe subset, Slack/Discord through Electron template after explicit mapping.
- International productivity/knowledge: Notion, Obsidian, Linear, Figma, Evernote, Bear, Logseq.
- AI tools: ChatGPT, Claude, Codex, Antigravity/Qoder/Filo only if installed and fixture verified.
- Cloud sync: Dropbox, Google Drive, OneDrive.
- Browser: Chrome, Safari, Firefox, Arc, plus Chrome-family browsers through explicit mappings for Edge/Brave/Chromium.
- Design/media/game: Adobe/Premiere, Sketch, Blender, IINA, VLC, mpv, Steam, Epic, Battle.net, GOG, EA, Riot.
- Developer-adjacent: Postman, TablePlus, Charles, Sequel Ace, VMware, Parallels, TeamViewer, AnyDesk, Alfred, CleanShot.

Needs local fixture or official docs before enabling:

- Feishu/Lark: vendor cache-reset docs exist, but exact macOS paths should be captured from an installed app and limited to cache/log/update payloads.
- DingTalk: capture installed bundle IDs and Library cache/log locations; do not infer from app name alone.
- WPS/Kingsoft Docs: capture cache/log/update paths; cloud docs, templates, recent-file DBs, and account state are blocked.
- QQ/TIM/WeCom: capture cache/log locations; chat DB and received files blocked.
- Baidu Netdisk, Alibaba Drive, Quark Drive, 115: capture cache/temp/update paths; sync/offline roots blocked.
- NetEase Cloud Music, iQIYI, Youku: distinguish streaming cache from downloaded/offline media before enabling.

### Rule import policy

- Existing open-source rules are evidence, not executable truth.
- Every imported path must pass the SafetyEngine and shared-vendor-dir checks.
- A rule with only guessed paths must stay disabled until a fixture proves path existence and side effects.
- Globs should only appear at the last one or two path components. Never glob a vendor root such as `~/Library/Application Support/Microsoft/*`.
- Running-app guards are required for browsers, Electron apps, chat apps, sync clients, Adobe apps, game launchers, and VM tools.
- Deletion defaults to Trash. Direct delete is not allowed for common app caches.
- The scan must publish incrementally and cap concurrent path walkers to avoid async storms and UI stalls.

### First implementation slice

The first real code slice is now split into two production-safe layers:

1. Rule metadata support landed in `vendors.yaml`: `category`, `source`, and explicit `bundle_id_prefix` for running-app guards.
2. `CommonAppCacheScanner` expands only `~` and explicit cache paths, skips missing/empty paths, and returns real size/count metadata.
3. Shipped P0 rules for WeChat, Tencent Meeting, Zoom, WhatsApp, Skype, Notion, Obsidian, Linear, Figma, ChatGPT, Claude, Codex, Slack, Discord, Google Updater, Chrome, Edge, Brave, Firefox, Safari, IINA, VLC, mpv, Bilibili, Sketch, Postman, TablePlus, Charles, and Sequel Ace.
4. Shipped P1 confirm rules for Google Drive, Dropbox, OneDrive, Adobe/Premiere, Steam, and Teams safe subset.
5. Added blocked-neighbor rules/tests for Telegram DB, Arc cookies/history, Teams IndexedDB/Local Storage, browser cookies/history/login data, Office group container, CloudStorage/sync roots, chat/business local storage, and app data roots that must not be treated as cache.
6. True deletion of common-app cache rows is blocked when the related app's bundle id is currently running. Dry-run preview remains allowed.

Still deliberately not enabled from guesses:

- Feishu/Lark, DingTalk, QQ/TIM/WeCom, WPS/Kingsoft, Baidu Netdisk, Alibaba Drive, Quark Drive, 115, NetEase Cloud Music, iQIYI, Youku.
- These need local fixture capture or official path docs before shipping any path beyond generic bundle cache roots.

### Fixture capture workflow

The project now includes a read-only capture helper:

```bash
Scripts/capture_app_cache_fixture.sh --out /tmp/gsy-cache-fixtures --with-size Feishu DingTalk WPS QQ TIM WeCom
```

The helper records installed app bundle identifiers and matched Library candidates into Markdown and JSONL. It is intentionally not a rule importer:

- Captured paths are evidence, not production rules.
- `--with-size` is opt-in because `du` can be expensive on large caches.
- New production rules still require SafetyEngine blockers, running-app guards, risk labels, and tests.
- Chat databases, received files, cloud sync roots, browser profile roots, and office account data remain blocked even if the fixture finds them.

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
