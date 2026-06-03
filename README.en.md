<div align="center">

<img src="docs/assets/logo.png" width="128" alt="GSYCleanMac" />

# GSYCleanMac

**An open-source, auditable, safe disk cleaner for macOS.**

English | [简体中文](README.md)

[![License MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 15+](https://img.shields.io/badge/macOS-15%2B-success)](docs/INSTALL.md)
[![Swift 6](https://img.shields.io/badge/Swift-6-orange)](https://swift.org)
[![Tests 370+ Pass](https://img.shields.io/badge/tests-370%2B%20pass-brightgreen)](#quality--safety)
[![i18n zh-Hans EN](https://img.shields.io/badge/i18n-zh--Hans%20%7C%20EN-informational)](#languages)

[Download Latest](https://github.com/CarGuo/GSYCleanMac/releases/latest) ·
[Install Guide](docs/INSTALL.md) ·
[Security Model](SECURITY.md) ·
[Roadmap](docs/ROADMAP_V1.md)

</div>

---

## What it does for you

- **Find what you can actually delete**: user caches, app logs, Xcode build artifacts, downloads, trash.
- **Reclaim space stolen by code projects**: detect build / node_modules / target / .gradle / DerivedData across 12+ ecosystems including Android, Flutter, iOS, React Native, Electron, Rust, Go, Python.
- **See big files at a glance**: top 200 files >= 100 MB on a single screen, sortable by size or modification date.
- **Truly uninstall apps**: pick an installed app and see every leftover it dropped under config / cache / Preferences / Group Containers.
- **Manage launch items**: list LaunchAgents / LaunchDaemons with one toggle each.
- **Reversible deletes**: every delete goes through the system Trash, never `unlink(2)`. Undo any time.

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
- Every delete goes to Trash. Reversible.

**We do not**

- Network traffic monitoring. Fake "memory cleaning". Fake "startup boost". Browser history wipers.
- Subscriptions. Telemetry. Ads. Bundled installers.

Why? See [PITFALLS.md](PITFALLS.md) and [SECURITY.md](SECURITY.md).

---

## Languages

Both **Simplified Chinese** and **English** are supported. The app follows your system language automatically. You can also pin a per-app language in System Settings.

---

## Install

Fastest path:

1. Grab the `.dmg` or `.app.zip` from [Releases](https://github.com/CarGuo/GSYCleanMac/releases/latest).
2. Drag into Applications. On first launch click "Open Anyway" in System Settings if Gatekeeper blocks it.
3. In System Settings -> Privacy & Security -> Full Disk Access, enable GSYCleanMac so it can read `~/Library`.

Full install / TCC / signature verification flow is in [docs/INSTALL.md](docs/INSTALL.md).

> Because this is an open-source project we ship with **ad-hoc code signing + SHA256 checksums**, no Apple Developer Program ($99/year) needed. Every release ships a `.sha256` file so you can verify the .app you downloaded is exactly the binary that came out of CI. See [docs/RELEASE.md](docs/RELEASE.md).

---

## Quality & Safety

- **370+ unit tests across 5 SPM packages**: [ScanKit](Packages/ScanKit) / [SafetyKit](Packages/SafetyKit) / [HeuristicKit](Packages/HeuristicKit) / [TestHarness](Packages/TestHarness) / [AppUI](Packages/AppUI).
- **Three-tier safety engine**: every delete candidate runs through a `safe / confirm / forbid` verdict. Rules are public YAML in [vendors.yaml](Resources/Rules/vendors.yaml).
- **Hard skip on TCC-sensitive paths**: Mail / Messages / Calendars / Photos Library never enter the candidate set, so we cannot accidentally trash your mail.
- **End-to-end integration tests pin the contract**: [V12SafetyIntegrationTests](Packages/AppUI/Tests/AppUITests/V12SafetyIntegrationTests.swift) asserts what must never be deletable.
- **Never `unlink(2)`**: every delete path is forced through `NSWorkspace.recycle()` (Trash).

Full threat model in [SECURITY.md](SECURITY.md).

---

## Build it yourself

```bash
git clone git@github.com:CarGuo/GSYCleanMac.git
cd GSYCleanMac
./Scripts/setup_dev.sh
```

> **Forks must read this**: [GSYCleanMac.xcodeproj/project.pbxproj](GSYCleanMac.xcodeproj/project.pbxproj) hard-codes the project author's `DEVELOPMENT_TEAM = 39PK4PKRP3`. Before the first build, you MUST change it to your own Team ID (double-click `GSYCleanMac.xcodeproj` → `Signing & Capabilities` → pick your Personal Team; or use `sed` to replace). See the "Free Apple ID Run" section in [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md).

```bash
xcodebuild -project GSYCleanMac.xcodeproj -scheme GSYCleanMac -configuration Debug build
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
| [docs/RELEASE.md](docs/RELEASE.md) | Release flow, ad-hoc signing, SHA256 verify, tag-triggered CI |
| [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md) | Dev environment, build scripts, local debugging |
| [docs/DEV_ARTIFACTS_RULES.md](docs/DEV_ARTIFACTS_RULES.md) | Developer artifact scanner rules & extension |
| [docs/FEATURE_GAP.md](docs/FEATURE_GAP.md) | 23-dim x 8-competitor feature matrix |
| [docs/ROADMAP_V1.md](docs/ROADMAP_V1.md) | Version plan and per-milestone scope |
| [SECURITY.md](SECURITY.md) | Threat model, hard rules, vulnerability report |
| [PITFALLS.md](PITFALLS.md) | Lessons learned from this whole product category |
| [CONTRIBUTING.md](CONTRIBUTING.md) | PR red lines, commit conventions |

---

## Acknowledgements

Thanks to [Pearcleaner](https://github.com/alienator88/Pearcleaner) for the prior art on TCC skip lists and vendor rule curation. All rule files in this repo are independently authored; no competitor source is referenced.

---

## License

[MIT](LICENSE) · Copyright (c) 2026 CarGuo
