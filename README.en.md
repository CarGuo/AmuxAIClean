<div align="center">

<img src="docs/assets/logo.png" width="128" alt="AmuxAIClean" />

# AmuxAIClean

**An open-source, auditable, safe disk cleaner for macOS.**

English | [简体中文](README.md)

[![License MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
<!-- v2026.07.16: the product deployment floor is the contracted Ventura 13.5 baseline. -->
[![macOS 13.5+](https://img.shields.io/badge/macOS-13.5%2B-success)](docs/INSTALL.md)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange)](https://swift.org)
[![Tests 9 Packages](https://img.shields.io/badge/tests-9%20packages-brightgreen)](#quality--safety)
[![i18n zh-Hans EN](https://img.shields.io/badge/i18n-zh--Hans%20%7C%20EN-informational)](#languages)

[Download Latest](https://github.com/CarGuo/AmuxAICleanRelease/releases/latest) ·
[All Releases](https://github.com/CarGuo/AmuxAICleanRelease/releases) ·
[Install Guide](docs/INSTALL.md) ·
[Security Model](SECURITY.md) ·
[Roadmap](docs/ROADMAP_V1.md)

</div>

> **Special Thanks**: Sponsored by the [https://amux.ai/](https://amux.ai/) relay platform, which provided the development tokens and Apple Developer account for this project — and that is why the project is named **AmuxAIClean**.

---

## What it does for you

- **Find what you can actually delete**: user caches, app logs, Xcode build artifacts, downloads, trash.
- **Reclaim space stolen by code projects**: detect build / node_modules / target / .gradle / DerivedData across 12+ ecosystems including Android, Flutter, iOS, React Native, Electron, Rust, Go, Python.
- **See big files at a glance**: top 200 files >= 100 MB on a single screen, sortable by size or modification date.
- **Truly uninstall apps**: pick an installed app and see every leftover it dropped under config / cache / Preferences / Group Containers.
- **Inspect classic launch agents**: read-only coverage of the three launchd plist directories; modern Login & Background Items remain managed by System Settings.
- **Keep a recovery window**: everything goes to Trash and `unlink(2)` is never called. Restoration can be attempted while the exact Trash item still exists.

---

## Screenshots

<table>
  <tr>
    <td align="center" width="50%">
      <img src="docs/screenshots/02-scan-result.png" alt="Recommended scan results" /><br/>
      <sub><b>Recommended Scan</b>: live category scan with three-color safety badges, sorted by physical footprint</sub>
    </td>
    <td align="center" width="50%">
      <img src="docs/screenshots/03-large-files.png" alt="Large files Top 200" /><br/>
      <sub><b>Large Files</b>: top 200 files >= 100 MB on one screen; name / path / size / mtime sortable</sub>
    </td>
  </tr>
  <tr>
    <td align="center" width="50%">
      <img src="docs/screenshots/04-uninstall.png" alt="Uninstall leftovers" /><br/>
      <sub><b>Uninstall Leftovers</b>: detect config / cache / Preferences left around for an installed app</sub>
    </td>
    <td align="center" width="50%">
      <img src="docs/screenshots/01-overview.png" alt="Main window" /><br/>
      <sub><b>Main Window</b>: five entry points - Recommended / Custom Paths / Large Files / Full Disk / Dev Artifacts</sub>
    </td>
  </tr>
</table>

> Want to reproduce these screenshots? Just run `./Scripts/screenshots.sh`.

---

## What we do, what we do not

**We do**

- Local disk usage scanning, large-file finder, uninstall leftover sweep, launch-item inspector, duplicate detection, developer build-artifact scanning.
- Every delete goes to Trash; restoration can be attempted only while the matching Trash item still exists.
- The optional Sentinel is off by default. When enabled, it runs as a non-privileged agent for the signed-in user and watches Trash and cleanup hotspots locally. The current build automatically retires historical root-domain registrations; see [PRIVACY.md](PRIVACY.md) for its records, migration, unregister flow, and removal boundary.
- Local safety decisions do not depend on the network. The App itself creates HTTP requests only
  for GitHub update checks (enabled at launch on first install and configurable in Settings) and
  user-enabled, user-initiated AI requests. Scanning a network share or cloud placeholder, or
  invoking Quick Look, may still cause macOS or the storage provider to read remotely. See
  [PRIVACY.md](PRIVACY.md) for path and
  metadata fields, default redaction, and provider boundaries.

**We do not**

- Network traffic monitoring. Fake "memory cleaning". Fake "startup boost". Browser history wipers.
- Subscriptions. Telemetry. Ads. Bundled installers.

Why? See [PITFALLS.md](PITFALLS.md) and [SECURITY.md](SECURITY.md).

---

## Languages

Both **Simplified Chinese** and **English** are supported. The app follows your system language automatically. You can also pin a per-app language in System Settings.

---

## Install

<!-- v2026.10.14: public downloads belong to the distribution repository, not the private source repository. -->
Official installers are published to **[CarGuo/AmuxAICleanRelease](https://github.com/CarGuo/AmuxAICleanRelease)**.
Download the DMG and matching SHA256 file from its
[latest release](https://github.com/CarGuo/AmuxAICleanRelease/releases/latest).
This source repository contains the code and development documentation; maintainers should follow
the [publishing guide](docs/RELEASE.md#四发布到公开发行仓库).

Fastest path:

1. Grab the published `.dmg` from [Releases](https://github.com/CarGuo/AmuxAICleanRelease/releases/latest).
2. Drag into Applications. On first launch click "Open Anyway" in System Settings if Gatekeeper blocks it.
3. For complete scans, allow AmuxAIClean in System Settings -> Privacy & Security -> Full Disk Access. If denied, the app remains usable and marks affected results as incomplete.

Full install / TCC / signature verification flow is in [docs/INSTALL.md](docs/INSTALL.md).

> The current public release path is a maintainer-local **Developer ID Application signed and notarized final DMG**. See [docs/RELEASE.md](docs/RELEASE.md).

---

## Quality & Safety

- **Tests across 9 first-party SPM packages**: [ScanKit](Packages/ScanKit) / [SafetyKit](Packages/SafetyKit) / [AppUI](Packages/AppUI) / [HeuristicKit](Packages/HeuristicKit) / [LogKit](Packages/LogKit) / [BrewKit](Packages/BrewKit) / [FileSearchKit](Packages/FileSearchKit) / [AIKit](Packages/AIKit) / [TestHarness](Packages/TestHarness). The exact test count is whatever the current run reports.
- **Three-tier safety engine**: every delete candidate runs through a `safe / confirm / forbid` verdict. Rules are public YAML in [vendors.yaml](Resources/Rules/vendors.yaml).
- **Hard skip on TCC-sensitive paths**: Mail / Messages / Calendars / Photos Library never enter the candidate set, so we cannot accidentally trash your mail.
- **End-to-end integration tests pin the contract**: [V12SafetyIntegrationTests](Packages/AppUI/Tests/AppUITests/V12SafetyIntegrationTests.swift) asserts what must never be deletable.
- **Never `unlink(2)`**: every delete path is forced through `NSWorkspace.recycle()` (Trash).

Full threat model in [SECURITY.md](SECURITY.md).

---

## Build it yourself

```bash
git clone git@github.com:CarGuo/AmuxAIClean.git
cd AmuxAIClean
./Scripts/setup_dev.sh
```

> **Forks must read this**: [AmuxAIClean.xcodeproj/project.pbxproj](AmuxAIClean.xcodeproj/project.pbxproj) currently uses `Automatic + Apple Development` for Debug and `Manual + Developer ID Application: SentenceEnd Inc (W6H34N9728)` for Release. Before the first build, change the Team/signing setup to your own. See the "Signing Configuration" section in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

```bash
xcodebuild -project AmuxAIClean.xcodeproj -scheme AmuxAIClean -configuration Debug build
```

Full dev environment, signing, debugging tips in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

---

## Roadmap

| Version | Theme | Status |
|---|---|---|
| v1.0 | Full-disk scan / Recommended / Large files / Uninstall leftovers / SafetyEngine | Shipped |
| v1.1 | App footprint / Launch items / TCCSkipList / mtime filter / Auto update check | Shipped |
| v1.2 | Type buckets / Quick Look / Export / Duplicate detection (read-only) | Shipped |
| v1.3 | Floating HUD / Status-bar tray / Settings refactor | Shipped |
| v1.4 | Developer build-artifact scanner (Android / Flutter / iOS / RN / 12+ ecosystems) | Shipped |

See [docs/ROADMAP_V1.md](docs/ROADMAP_V1.md).

---

## Document map

| Doc | Content |
|---|---|
| [docs/INSTALL.md](docs/INSTALL.md) | Install, Gatekeeper, TCC Full Disk Access |
| [docs/RELEASE.md](docs/RELEASE.md) | Local Developer ID / DMG-only notarization flow and SHA256 verification |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Dev environment, build scripts, local debugging |
| [docs/DEV_ARTIFACTS_RULES.md](docs/DEV_ARTIFACTS_RULES.md) | Developer artifact scanner rules & extension |
| [docs/FEATURE_GAP.md](docs/FEATURE_GAP.md) | 23-dim x 8-competitor feature matrix |
| [docs/ROADMAP_V1.md](docs/ROADMAP_V1.md) | Version plan and per-milestone scope |
| [SECURITY.md](SECURITY.md) | Threat model, hard rules, vulnerability report |
| [PRIVACY.md](PRIVACY.md) | Network fields, local stores, permissions, Sentinel, and removal order |
| [PITFALLS.md](PITFALLS.md) | Lessons learned from this whole product category |
| [CONTRIBUTING.md](CONTRIBUTING.md) | PR red lines, commit conventions |

---

## Acknowledgements

- Sponsored by the [https://amux.ai/](https://amux.ai/) relay platform for providing development tokens and the Apple Developer account.
- Thanks to [Pearcleaner](https://github.com/alienator88/Pearcleaner) for the prior art on TCC skip lists and vendor rule curation. All rule files in this repo are independently authored; no competitor source is referenced.

---

## License

[MIT](LICENSE) · Copyright (c) 2026 CarGuo
