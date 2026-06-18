import Foundation

/// Android（AOSP / Android Studio / Gradle）开发者工作流。
///
/// 设计动机（对位 [DEVELOPER_ONE_CLICK_PLAN.md](../../../../../docs/DEVELOPER_ONE_CLICK_PLAN.md)）：
/// Android 开发链的本地缓存与构建产物分布在 `~/.gradle`、`~/.android`、`~/Library/Android/sdk`
/// 以及 JetBrains 的 `~/Library/Caches|Logs/Google/AndroidStudio*` 多个目录；
/// 散落程度比 Apple 更高，仅靠 vendors.yaml 难以"按主题分卡"。
/// 本工作流按 [DeveloperWorkflow] 协议聚合 10 张卡片，作为侧边栏入口。
///
/// 与 [AppleWorkflow] 的对齐要点：
/// 1. **目录存在性预检**：所有 `.literal` 卡片必须先确认对应目录存在再展示，避免空入口污染 UI。
///    `~/.gradle` 与 `~/.android` 作为父目录，若不存在则相关子卡全部跳过；
/// 2. **`.versionedRoot` 三卡不预检**：SDK 子目录走 [KnownVersionedRoots] 的 `android.sdk-*.versioned`
///    规则，扫描时 [KnownVersionedRoots.scanAll] 自带空安全；
/// 3. **risk 默认 safe**：仅 AVD（模拟器实例）与 system-images（数 GB 镜像）走 `.confirm`，
///    要求用户显式确认；
/// 4. **JetBrains 路径含 glob `*`**：`~/Library/Caches/Google/AndroidStudio*` 形如
///    `AndroidStudio2024.1` 等多版本目录，按设计文档要求保留 glob 原样下发，UI 层负责 expand。
///
/// 删除通道统一为 `.filesystem`（回收站），不引入 `.commandLine`，因此所有卡片均无 allowlist 校验风险。
public struct AndroidWorkflow: DeveloperWorkflow {
    public let id: String = "workflow.android"
    public let displayName: String = "Android 开发者一键清理"
    public let subtitle: String = "Gradle / Android SDK / AVD / Android Studio 缓存与旧版本"

    public init() {}

    public func cards(home: URL) -> [DeveloperCard] {
        var result: [DeveloperCard] = []
        result.reserveCapacity(10)

        // 0. 大前提：任一 Android 相关根目录存在才有展示意义；否则视为"非 Android 开发者机器"返回空。
        //    覆盖 Gradle / Android SDK / JetBrains 三大根，避免空 home 时仍输出"永驻"卡片污染 UI。
        let gradleProbe       = home.appendingPathComponent(".gradle", isDirectory: true)
        let androidProbe      = home.appendingPathComponent(".android", isDirectory: true)
        let sdkProbe          = home.appendingPathComponent("Library/Android", isDirectory: true)
        let studioCachesProbe = home.appendingPathComponent("Library/Caches/Google", isDirectory: true)
        let studioLogsProbe   = home.appendingPathComponent("Library/Logs/Google", isDirectory: true)
        guard Self.dirExists(gradleProbe)
                || Self.dirExists(androidProbe)
                || Self.dirExists(sdkProbe)
                || Self.dirExists(studioCachesProbe)
                || Self.dirExists(studioLogsProbe) else {
            return []
        }

        // 1-2. ~/.gradle 系（caches / daemon）—— 需父目录预检
        //      ~/.gradle 不存在视为"非 Gradle 用户"，两张卡均跳过
        let gradleRoot = home.appendingPathComponent(".gradle", isDirectory: true)
        if Self.dirExists(gradleRoot) {
            // 1. card.android.gradle-caches —— Gradle 依赖与构建缓存，下次 build 自动重建
            result.append(DeveloperCard(
                id: "card.android.gradle-caches",
                title: "Gradle 构建缓存",
                summary: "Gradle 下载的依赖与构建中间产物，删后下次 build 会重新下载",
                source: .literal(paths: ["~/.gradle/caches"]),
                recipe: .filesystem,
                risk: .safe))

            // 2. card.android.gradle-daemon —— Gradle 守护进程日志与 jvm 状态，安全可删
            result.append(DeveloperCard(
                id: "card.android.gradle-daemon",
                title: "Gradle Daemon 日志",
                summary: "Gradle 守护进程的运行日志与状态，删后下次启动 daemon 自动重建",
                source: .literal(paths: ["~/.gradle/daemon"]),
                recipe: .filesystem,
                risk: .safe))
        }

        // 3-5. ~/.android 系（build-cache / cache / avd）—— 需父目录预检
        //      AVD 单独再做一次子目录存在性预检（用户可能 SDK 装了但从未建过模拟器）
        let androidRoot = home.appendingPathComponent(".android", isDirectory: true)
        if Self.dirExists(androidRoot) {
            // 3. card.android.android-build-cache —— 仅当 build-cache 子目录存在时展示
            let buildCache = androidRoot.appendingPathComponent("build-cache", isDirectory: true)
            if Self.dirExists(buildCache) {
                result.append(DeveloperCard(
                    id: "card.android.android-build-cache",
                    title: "Android Build Cache",
                    summary: "Android Gradle Plugin 的构建缓存，删后首次 build 变慢但功能不受影响",
                    source: .literal(paths: ["~/.android/build-cache"]),
                    recipe: .filesystem,
                    risk: .safe))
            }

            // 4. card.android.android-cache —— ~/.android/cache 不强制预检子目录存在性
            //    （父目录 ~/.android 存在即认为可展示，方便用户首次使用工具时一键清理）
            result.append(DeveloperCard(
                id: "card.android.android-cache",
                title: "Android SDK Manager 缓存",
                summary: "SDK Manager 下载临时缓存，删后无业务影响",
                source: .literal(paths: ["~/.android/cache"]),
                recipe: .filesystem,
                risk: .safe))

            // 5. card.android.android-avd —— AVD 必须做子目录预检
            //    AVD 实例数据包含用户应用 sandbox / SD 卡镜像，丢失不可恢复，强制 confirm
            let avd = androidRoot.appendingPathComponent("avd", isDirectory: true)
            if Self.dirExists(avd) {
                result.append(DeveloperCard(
                    id: "card.android.android-avd",
                    title: "Android 模拟器（AVD）",
                    summary: "AVD 实例数据（含应用 sandbox 与 SD 卡镜像），删除前请确认无需保留",
                    source: .literal(paths: ["~/.android/avd"]),
                    recipe: .filesystem,
                    risk: .confirm))
            }
        }

        // 6-8. SDK 三系 —— 走 KnownVersionedRoots 保留最新版本
        //      不做目录预检：scanAll 自带空安全（entries 命中 0 自动产出 0 hits）
        //      避免在 SDK 路径变动（如 Studio 自定义 location）时漏出卡片入口
        result.append(DeveloperCard(
            id: "card.android.sdk-build-tools",
            title: "Android SDK · Build Tools（旧版本）",
            summary: "保留最新版 build-tools，旧版本可在 SDK Manager 中重新安装",
            source: .versionedRoot(ruleID: "android.sdk-build-tools.versioned"),
            recipe: .filesystem,
            risk: .safe))

        result.append(DeveloperCard(
            id: "card.android.sdk-platforms",
            title: "Android SDK · Platforms（旧版本）",
            summary: "保留最新 platform，旧 API Level 可按需在 SDK Manager 中重新下载",
            source: .versionedRoot(ruleID: "android.sdk-platforms.versioned"),
            recipe: .filesystem,
            risk: .safe))

        // System Images 单镜像 1~3 GB，删除不可逆且重下耗时较长 → confirm
        result.append(DeveloperCard(
            id: "card.android.sdk-system-images",
            title: "Android SDK · System Images（旧版本）",
            summary: "模拟器系统镜像，单个 1~3 GB；删除前请确认对应 AVD 不再使用",
            source: .versionedRoot(ruleID: "android.sdk-system-images.versioned"),
            recipe: .filesystem,
            risk: .confirm))

        // 9-10. Android Studio（JetBrains）缓存与日志 —— 路径含 glob *
        //       多版本（如 AndroidStudio2024.1 / 2024.2）按设计文档约定保留 glob 原样下发，
        //       由 UI 层在执行阶段 expand。这两张卡不做存在性预检（glob 无法直接 stat）。
        result.append(DeveloperCard(
            id: "card.android.jetbrains-androidstudio-caches",
            title: "Android Studio 缓存（JetBrains）",
            summary: "Android Studio 索引与本地缓存，删后首次启动会重建索引",
            source: .literal(paths: ["~/Library/Caches/Google/AndroidStudio*"]),
            recipe: .filesystem,
            risk: .safe))

        result.append(DeveloperCard(
            id: "card.android.jetbrains-androidstudio-logs",
            title: "Android Studio 日志（JetBrains)",
            summary: "Android Studio 运行日志，删后无业务影响",
            source: .literal(paths: ["~/Library/Logs/Google/AndroidStudio*"]),
            recipe: .filesystem,
            risk: .safe))

        return result
    }

    /// 目录存在性检测：必须是目录、不是普通文件。
    /// 与 [AppleWorkflow.dirExists] 行为一致，防御同名文件污染。
    private static func dirExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }
}
