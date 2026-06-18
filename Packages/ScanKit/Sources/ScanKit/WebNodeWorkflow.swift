import Foundation

/// WebNode（前端 / Node.js 生态）开发者工作流。
///
/// 设计动机（对位 [DEVELOPER_ONE_CLICK_PLAN.md](../../../../../docs/DEVELOPER_ONE_CLICK_PLAN.md) §WebNode）：
/// 前端工程链的本地缓存与产物分布在三个层级：
/// 1. **全局包管理器缓存**：`~/Library/pnpm/store` / `~/.pnpm-store` /
///    `~/Library/Caches/Yarn` / `~/.yarn/cache` / `~/.npm` 等；
/// 2. **原生构建工具缓存**：`~/Library/Caches/node-gyp`、`~/Library/Caches/electron`；
/// 3. **散落工程目录**：用户 dev 根（`~/Developer` / `~/Projects` / ...）下每个
///    工程的 `node_modules` 子目录——这是磁盘头号黑洞，但路径不固定，需要专用 scanner。
///
/// 与 [AppleWorkflow] / [AndroidWorkflow] 的对齐要点：
/// 1. **5 张静态卡片用 `.literal`**：路径含 `~/...`，存在性检测时用
///    `home.appendingPathComponent(relative)` 解析为真实路径再 `dirExists`，
///    与 [AndroidWorkflow] 风格完全一致；
/// 2. **scattered 卡用 `.dynamicScanner`**：路由表 ID 为 `scanner.node-modules-scattered`，
///    实接 [NodeModulesScanner.detect]，遍历 5 个常见 dev 根；
/// 3. **本卡始终输出**：不做存在性预检——让用户自行决定要不要跑这次"慢扫描"，
///    避免因为某个根目录恰好不存在而把入口隐藏；
/// 4. **risk 等级**：5 张缓存卡均为 `.safe`（删后包管理器自动重建），
///    scattered 卡为 `.confirm`（删除散落 node_modules 后需重新 `pnpm install`）。
///
/// 删除通道统一为 `.filesystem`（回收站），不引入 `.commandLine`，因此所有卡片均无 allowlist 校验风险。
public struct WebNodeWorkflow: DeveloperWorkflow {
    public let id: String = "workflow.web-node"
    public let displayName: String = "Web / Node 开发者一键清理"
    public let subtitle: String = "pnpm / yarn / npm / node-gyp / electron 缓存与散落 node_modules"

    public init() {}

    public func cards(home: URL) -> [DeveloperCard] {
        var result: [DeveloperCard] = []
        result.reserveCapacity(6)

        // 1. card.webnode.pnpm-store —— 任一存在即出
        //    pnpm 全局 store 在新版本（>=8）默认 ~/Library/pnpm/store，
        //    老版本兼容 ~/.pnpm-store；任一存在即认为该机器是 pnpm 用户。
        let pnpmProbes = [
            home.appendingPathComponent("Library/pnpm/store", isDirectory: true),
            home.appendingPathComponent(".pnpm-store", isDirectory: true),
        ]
        if pnpmProbes.contains(where: Self.dirExists) {
            result.append(DeveloperCard(
                id: "card.webnode.pnpm-store",
                title: "pnpm 全局 store",
                summary: "pnpm 全局包硬链接 store，删后下次 `pnpm install` 自动重建",
                source: .literal(paths: ["~/Library/pnpm/store", "~/.pnpm-store"]),
                recipe: .filesystem,
                risk: .safe))
        }

        // 2. card.webnode.yarn-cache —— 任一存在即出
        //    Yarn v1 在 ~/Library/Caches/Yarn，
        //    Yarn Berry / Linux 风格在 ~/.yarn/cache 或 ~/.cache/yarn；任一存在即出。
        let yarnProbes = [
            home.appendingPathComponent("Library/Caches/Yarn", isDirectory: true),
            home.appendingPathComponent(".yarn/cache", isDirectory: true),
            home.appendingPathComponent(".cache/yarn", isDirectory: true),
        ]
        if yarnProbes.contains(where: Self.dirExists) {
            result.append(DeveloperCard(
                id: "card.webnode.yarn-cache",
                title: "Yarn 全局缓存",
                summary: "Yarn 全局包缓存，删后下次 `yarn install` 自动重建",
                source: .literal(paths: ["~/Library/Caches/Yarn", "~/.yarn/cache", "~/.cache/yarn"]),
                recipe: .filesystem,
                risk: .safe))
        }

        // 3. card.webnode.npm-cache —— ~/.npm 存在即出
        //    ~/.npm 是 npm 主目录，里面的 _cacache 是真正占空间的缓存子目录；
        //    路径下发两条让 UI 可一并清理，但条件只看父目录 ~/.npm 是否存在。
        let npmRoot = home.appendingPathComponent(".npm", isDirectory: true)
        if Self.dirExists(npmRoot) {
            result.append(DeveloperCard(
                id: "card.webnode.npm-cache",
                title: "npm 全局缓存",
                summary: "npm 包下载缓存（_cacache），删后下次 `npm install` 自动重建",
                source: .literal(paths: ["~/.npm/_cacache", "~/.npm"]),
                recipe: .filesystem,
                risk: .safe))
        }

        // 4. card.webnode.node-gyp-cache —— 始终输出（缓存可重建，路径固定，无需预检）
        //    node-gyp 编译时下载的 Node header 缓存，单版本约 30 MB，长期叠加会到 GB 级。
        //    不做存在性预检：路径单一且重建无副作用，避免因为目录不存在而隐藏入口。
        result.append(DeveloperCard(
            id: "card.webnode.node-gyp-cache",
            title: "node-gyp 编译缓存",
            summary: "node-gyp 编译时下载的 Node header 缓存，删后下次原生构建自动重建",
            source: .literal(paths: ["~/Library/Caches/node-gyp"]),
            recipe: .filesystem,
            risk: .safe))

        // 5. card.webnode.electron-cache —— 始终输出（同理）
        //    Electron prebuilt 压缩包缓存，单版本 70~150 MB，多版本叠加常见 1~2 GB。
        result.append(DeveloperCard(
            id: "card.webnode.electron-cache",
            title: "Electron prebuilt 缓存",
            summary: "Electron 预构建二进制缓存，删后下次 `electron` 构建自动重新下载",
            source: .literal(paths: [
                "~/Library/Caches/electron",
                "~/Library/Application Support/Caches/electron",
            ]),
            recipe: .filesystem,
            risk: .safe))

        // 6. card.webnode.node-modules-scattered —— 始终输出
        //    与 5 张缓存卡的关键区别：
        //    - 缓存卡 = 全局共享 + 可重建 → safe；
        //    - 本卡 = 工程本地 + 删后需 `pnpm install` 重建 → confirm；
        //    - 始终输出是为了让用户自行决定要不要触发慢扫描（dev 根下 BFS 数千目录），
        //      而不是因为某个根恰好不存在就把入口藏掉。
        result.append(DeveloperCard(
            id: "card.webnode.node-modules-scattered",
            title: "散落的 node_modules（按工程扫）",
            summary: "扫描 ~/Developer / ~/Projects / ~/Code / ~/workspace / ~/src 下的 node_modules",
            source: .dynamicScanner(scannerID: "scanner.node-modules-scattered"),
            recipe: .filesystem,
            risk: .confirm))

        return result
    }

    /// 目录存在性检测：必须是目录、不是普通文件。
    /// 与 [AppleWorkflow.dirExists] / [AndroidWorkflow.dirExists] 行为一致，防御同名文件污染。
    private static func dirExists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return false
        }
        return isDir.boolValue
    }
}
