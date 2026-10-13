import Foundation
import SafetyKit

/// M5 / 2026-06：把"用户点击的那一行"的事实结构化打包给 AI。
///
/// 设计要点：
/// - **只装元数据，永不装文件内容**——与 [BulkScanner](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/ScanKit/Sources/ScanKit/BulkScanner.swift)
///   "不读 content" 一脉相承（[FEATURE_GAP §2.10](file:///Users/amuxuser/workspace/AmuxAIClean/docs/FEATURE_GAP.md)）；
/// - **本地 SafetyEngine 判定也作为事实告诉 AI**——让 AI 站在"已知本地判 forbid"的前提上解释，
///   减少胡说概率；同时由 [OpenAIChatClient](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AIKit/Sources/AIKit/OpenAIChatClient.swift)
///   后置 clamp 强制把"本地 forbid → AI canDelete forbid"钉死；
/// - 字段限定一个紧凑集合（path / size / mtime / verdict / vendor + 子项前 5 名预览），
///   控制 prompt token 数，避免长尾路径吃 tokens。
public struct PathInquiry: Sendable, Equatable, Codable {

    /// 路径（绝对路径，未去敏；出网前由 [PathRedactor](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AIKit/Sources/AIKit/PathRedactor.swift) 处理）
    public let path: String

    /// 是否目录
    public let isDirectory: Bool

    /// allocatedSize 累计（bytes）
    public let bytes: Int64

    /// 子项总数（目录非空时有意义）
    public let fileCount: Int

    /// 最近修改时间（可缺失）
    public let modificationDate: Date?

    /// 本地 SafetyEngine 三档判定
    public let verdict: SafetyVerdict

    /// vendor 命名（命中 vendors.yaml 时有值；否则 nil）
    public let vendorName: String?

    /// vendor reason 注释（vendors.yaml 里写的"为什么这条目录可清理"）
    public let vendorNote: String?

    /// 目录直接子项的前 5 个名字，用 `, ` 拼接；
    /// 给 AI 提供"这目录里大致放着什么类型的东西"的线索，
    /// 不发完整树以省 tokens。**不递归、不计算大小、只读 lastPathComponent。**
    public let childPreview: [String]

    public init(path: String,
                isDirectory: Bool,
                bytes: Int64,
                fileCount: Int,
                modificationDate: Date?,
                verdict: SafetyVerdict,
                vendorName: String?,
                vendorNote: String?,
                childPreview: [String]) {
        self.path = path
        self.isDirectory = isDirectory
        self.bytes = bytes
        self.fileCount = fileCount
        self.modificationDate = modificationDate
        self.verdict = verdict
        self.vendorName = vendorName
        self.vendorNote = vendorNote
        self.childPreview = childPreview
    }

    /// 从磁盘探一下前 5 个 lastPathComponent（不递归）。
    /// 失败 / 非目录 / 权限拒绝 → 返回空数组，不抛。
    public static func sampleChildren(at path: String, limit: Int = 5) -> [String] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return []
        }
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return [] }
        // 稳定排序，避免每次询问 prompt 不同导致缓存层（即便目前没缓存）漂移。
        return Array(names.sorted().prefix(limit))
    }
}

/// AI 返回的结构化建议。约定 JSON schema 见 [PromptBuilder](file:///Users/amuxuser/workspace/AmuxAIClean/Packages/AIKit/Sources/AIKit/PromptBuilder.swift)。
public struct AIAdvice: Sendable, Equatable, Codable {
    /// 一句话定性（<= 80 字）
    public let summary: String

    /// AI 给出的删除建议——**仅供参考**，不影响本地三档闸 / 默认勾选。
    public let canDelete: SafetyVerdict

    /// 原因（<= 200 字）
    public let reason: String

    /// 副作用列表（删除后会发生什么；可能为空）
    public let sideEffects: [String]

    public init(summary: String,
                canDelete: SafetyVerdict,
                reason: String,
                sideEffects: [String]) {
        self.summary = summary
        self.canDelete = canDelete
        self.reason = reason
        self.sideEffects = sideEffects
    }

    /// 安全 fallback：构造一个不携带 provider 原文的占位 advice。
    /// provider 输出可能包含路径、token 或服务端内部信息；UI 只依据 sentinel
    /// 展示本地化说明，批量复核层会把它提升为可重试的 decoding failure。
    ///
    /// `summary` 使用稳定的 sentinel key（`AIAdvice.unparsableSummaryKey`），
    /// UI 层检测到该 key 后会替换为本地化文案，避免在 AIKit 内引入 Bundle.module。
    public static func unparsable(rawText _: String) -> AIAdvice {
        AIAdvice(summary: unparsableSummaryKey,
                 canDelete: .confirm,
                 reason: "",
                 sideEffects: [])
    }

    /// fallback summary 的稳定 sentinel key。UI 层应当识别此值并替换为本地化文案。
    public static let unparsableSummaryKey: String = "ai.advice.unparsable.summary"
}
