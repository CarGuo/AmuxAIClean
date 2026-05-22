import Foundation

/// 一次性 CLI：扫本机所有 .app + ~/Library/Application Support/*，输出 vendor_shared.yaml 候选。
///
/// **设计**（PITFALLS §5.9 / 规则库策略）：
/// - 不抄任何外部规则（避免 license 纠纷）
/// - 自动从 *本机* 的真实 .app/AppSupport 提取候选
/// - 仅产出"建议"，是否纳入由人工 review
///
/// **用法**：
///   swift run seeding-tool > vendor_seed.yaml
///
@main
struct SeedingTool {
    static func main() {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        let appBundles = collectInstalledAppBundles(fm: fm)
        let appSupportDirs = collectAppSupportDirs(home: home, fm: fm)

        // 把 .app 的 bundleID 与 AppSupport 目录交叉
        let bundleIDs = Set(appBundles.compactMap(\.bundleID))
        let bundleIDPrefixes = Set(bundleIDs.map { topPrefix(of: $0) })

        var candidates: [VendorEntry] = []

        // 主流 vendor 手工种子（不依赖本机扫描，保证基础线）
        candidates.append(contentsOf: handCuratedVendors())

        // 从本机 AppSupport 目录扩充
        for entry in appSupportDirs {
            let name = (entry as NSString).lastPathComponent
            // 已在手工种子里的跳过
            if candidates.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                continue
            }
            candidates.append(VendorEntry(
                name: name,
                bundleIDPrefix: bundleIDPrefixes.first { $0.lowercased().contains(name.lowercased()) },
                appSupportSubdir: name,
                note: "auto-detected from \(entry)"
            ))
        }

        printYAML(candidates: candidates)

        FileHandle.standardError.write(Data("\n# stats: \(appBundles.count) apps scanned, \(appSupportDirs.count) app-support dirs, \(candidates.count) vendor candidates\n".utf8))
    }

    // MARK: - Scanning

    static func collectInstalledAppBundles(fm: FileManager) -> [(path: String, bundleID: String?)] {
        let roots = ["/Applications", "/System/Applications", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var out: [(String, String?)] = []
        for root in roots {
            guard let it = fm.enumerator(atPath: root) else { continue }
            // 仅扫一层 .app（避免子 .app 比如 Contents/MacOS/Helper.app）
            var inspected = 0
            while let rel = it.nextObject() as? String {
                if rel.contains("/") {
                    it.skipDescendants()
                    continue
                }
                if rel.hasSuffix(".app") {
                    let p = root + "/" + rel
                    let bid = readBundleID(at: p)
                    out.append((p, bid))
                    inspected += 1
                    if inspected > 500 { break } // 兜底
                }
            }
        }
        return out
    }

    static func readBundleID(at appPath: String) -> String? {
        let plist = appPath + "/Contents/Info.plist"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: plist)),
              let any = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = any as? [String: Any]
        else { return nil }
        return dict["CFBundleIdentifier"] as? String
    }

    static func collectAppSupportDirs(home: String, fm: FileManager) -> [String] {
        let root = home + "/Library/Application Support"
        guard let entries = try? fm.contentsOfDirectory(atPath: root) else { return [] }
        return entries
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }

    static func topPrefix(of bundleID: String) -> String {
        let parts = bundleID.split(separator: ".")
        if parts.count >= 2 {
            return parts.prefix(2).joined(separator: ".")
        }
        return bundleID
    }

    // MARK: - Hand-curated seeds

    /// ~30 条主流 vendor —— 公开知识，不抄任何项目。
    static func handCuratedVendors() -> [VendorEntry] {
        return [
            // 设计 / 创意
            .init(name: "Adobe", bundleIDPrefix: "com.adobe", appSupportSubdir: "Adobe",
                  note: "Photoshop / Illustrator / Premiere / After Effects / Lightroom"),
            .init(name: "Sketch", bundleIDPrefix: "com.bohemiancoding.sketch3", appSupportSubdir: "com.bohemiancoding.sketch3"),
            .init(name: "Figma", bundleIDPrefix: "com.figma.Desktop", appSupportSubdir: "Figma"),
            .init(name: "Affinity", bundleIDPrefix: "com.seriflabs", appSupportSubdir: "Affinity"),

            // IDE
            .init(name: "JetBrains", bundleIDPrefix: "com.jetbrains", appSupportSubdir: "JetBrains",
                  note: "IntelliJ / PyCharm / WebStorm / GoLand / Rider / CLion / DataGrip"),
            .init(name: "Code", bundleIDPrefix: "com.microsoft.VSCode", appSupportSubdir: "Code"),
            .init(name: "Cursor", bundleIDPrefix: "com.todesktop.230313mzl4w4u92", appSupportSubdir: "Cursor"),
            .init(name: "Zed", bundleIDPrefix: "dev.zed.Zed", appSupportSubdir: "Zed"),
            .init(name: "Sublime Text", bundleIDPrefix: "com.sublimetext.4", appSupportSubdir: "Sublime Text"),

            // 浏览器
            .init(name: "Google", bundleIDPrefix: "com.google", appSupportSubdir: "Google",
                  note: "Chrome / Drive / Backup and Sync 共享，删 Cache 子目录最稳"),
            .init(name: "Firefox", bundleIDPrefix: "org.mozilla.firefox", appSupportSubdir: "Firefox"),
            .init(name: "BraveSoftware", bundleIDPrefix: "com.brave.Browser", appSupportSubdir: "BraveSoftware"),
            .init(name: "Microsoft Edge", bundleIDPrefix: "com.microsoft.edgemac", appSupportSubdir: "Microsoft Edge"),
            .init(name: "Arc", bundleIDPrefix: "company.thebrowser.Browser", appSupportSubdir: "Arc"),

            // 通讯
            .init(name: "Slack", bundleIDPrefix: "com.tinyspeck.slackmacgap", appSupportSubdir: "Slack"),
            .init(name: "discord", bundleIDPrefix: "com.hnc.Discord", appSupportSubdir: "discord"),
            .init(name: "zoom.us", bundleIDPrefix: "us.zoom.xos", appSupportSubdir: "zoom.us"),
            .init(name: "Telegram", bundleIDPrefix: "ru.keepcoder.Telegram", appSupportSubdir: "Telegram Desktop"),
            .init(name: "WeChat", bundleIDPrefix: "com.tencent.xinWeChat", appSupportSubdir: "WeChat"),
            .init(name: "QQ", bundleIDPrefix: "com.tencent.qq", appSupportSubdir: "QQ"),

            // 媒体
            .init(name: "Spotify", bundleIDPrefix: "com.spotify.client", appSupportSubdir: "Spotify"),
            .init(name: "NetEaseMusic", bundleIDPrefix: "com.netease.163music", appSupportSubdir: "NetEaseMusic"),

            // 容器 / 开发工具
            .init(name: "Docker", bundleIDPrefix: "com.docker.docker", appSupportSubdir: "Docker Desktop"),
            .init(name: "Microsoft", bundleIDPrefix: "com.microsoft", appSupportSubdir: "Microsoft",
                  note: "Word / Excel / PowerPoint / Teams 共享"),

            // 包管理 / 命令行（缓存目录）
            .init(name: "Homebrew", bundleIDPrefix: nil, appSupportSubdir: nil,
                  cachesPath: "~/Library/Caches/Homebrew",
                  note: "brew 下载缓存，可大量回收"),
            .init(name: "npm", bundleIDPrefix: nil, appSupportSubdir: nil,
                  cachesPath: "~/.npm",
                  note: "npm 缓存，rm 后下次自动重建"),
            .init(name: "yarn", bundleIDPrefix: nil, appSupportSubdir: nil,
                  cachesPath: "~/Library/Caches/Yarn",
                  note: "yarn 缓存"),
            .init(name: "pip", bundleIDPrefix: nil, appSupportSubdir: nil,
                  cachesPath: "~/Library/Caches/pip"),
            .init(name: "Carthage", bundleIDPrefix: nil, appSupportSubdir: nil,
                  cachesPath: "~/Library/Caches/org.carthage.CarthageKit"),
            .init(name: "CocoaPods", bundleIDPrefix: nil, appSupportSubdir: nil,
                  cachesPath: "~/Library/Caches/CocoaPods"),

            // 游戏
            .init(name: "Steam", bundleIDPrefix: "com.valvesoftware.steam", appSupportSubdir: "Steam"),
            .init(name: "Epic", bundleIDPrefix: "com.epicgames.EpicGamesLauncher", appSupportSubdir: "Epic"),

            // 笔记 / 生产力
            .init(name: "Notion", bundleIDPrefix: "notion.id", appSupportSubdir: "Notion"),
            .init(name: "Obsidian", bundleIDPrefix: "md.obsidian", appSupportSubdir: "obsidian"),
            .init(name: "Postman", bundleIDPrefix: "com.postmanlabs.mac", appSupportSubdir: "Postman"),
        ]
    }

    // MARK: - YAML output

    static func printYAML(candidates: [VendorEntry]) {
        var out = ""
        out += "# vendor_seed.yaml — 由 SeedingTool 自动生成\n"
        out += "# 生成时间: \(Date())\n"
        out += "# 命中规则会进入 SafetyEngine.evaluate，UI 默认 unchecked + 显示提示。\n"
        out += "#\n"
        out += "# **重要**：每条规则在加载到 SafetyEngine 时会经过 hardForbid 反向校验，\n"
        out += "#  写错也不会误删 /System 等危险目录（PITFALLS §5.9）。\n"
        out += "\n"
        out += "vendors:\n"
        for c in candidates {
            out += "  - name: \"\(c.name)\"\n"
            if let bid = c.bundleIDPrefix {
                out += "    bundle_id_prefix: \"\(bid)\"\n"
            }
            if let sub = c.appSupportSubdir {
                out += "    app_support_subdir: \"\(sub)\"\n"
            }
            if let cp = c.cachesPath {
                out += "    caches_path: \"\(cp)\"\n"
            }
            if let note = c.note {
                out += "    note: \"\(note)\"\n"
            }
        }
        FileHandle.standardOutput.write(Data(out.utf8))
    }
}

struct VendorEntry: Sendable {
    let name: String
    var bundleIDPrefix: String?
    var appSupportSubdir: String?
    var cachesPath: String?
    var note: String?
    init(name: String, bundleIDPrefix: String? = nil, appSupportSubdir: String? = nil,
         cachesPath: String? = nil, note: String? = nil) {
        self.name = name
        self.bundleIDPrefix = bundleIDPrefix
        self.appSupportSubdir = appSupportSubdir
        self.cachesPath = cachesPath
        self.note = note
    }
}
