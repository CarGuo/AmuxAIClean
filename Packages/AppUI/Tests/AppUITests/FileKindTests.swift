import XCTest
@testable import AppUI

/// v1.2 P2-3：FileKind 入桶 / 兜底 / 大小写不敏感 单测。
final class FileKindTests: XCTestCase {

    // MARK: - 入桶规则

    func test_视频常见扩展名归video() {
        for ext in ["mov", "mp4", "mkv", "m4v", "webm"] {
            XCTAssertEqual(FileKind.from(extension: ext), .video, "ext=\(ext) 应入 video")
        }
    }

    func test_图片归image() {
        for ext in ["jpg", "jpeg", "png", "heic", "tiff"] {
            XCTAssertEqual(FileKind.from(extension: ext), .image)
        }
    }

    func test_音频归audio() {
        for ext in ["mp3", "m4a", "flac", "wav", "aac"] {
            XCTAssertEqual(FileKind.from(extension: ext), .audio)
        }
    }

    func test_归档归archive() {
        for ext in ["zip", "tar", "gz", "7z", "rar", "tgz"] {
            XCTAssertEqual(FileKind.from(extension: ext), .archive)
        }
    }

    func test_镜像归disk() {
        for ext in ["iso", "dmg", "img", "vmdk", "sparseimage"] {
            XCTAssertEqual(FileKind.from(extension: ext), .disk)
        }
    }

    func test_安装包归installer() {
        for ext in ["pkg", "ipa", "app", "deb"] {
            XCTAssertEqual(FileKind.from(extension: ext), .installer)
        }
    }

    func test_设计稿归design() {
        for ext in ["psd", "ai", "sketch", "fig"] {
            XCTAssertEqual(FileKind.from(extension: ext), .design)
        }
    }

    func test_文档归document() {
        for ext in ["pdf", "docx", "xlsx", "txt", "csv"] {
            XCTAssertEqual(FileKind.from(extension: ext), .document)
        }
    }

    func test_代码归code() {
        for ext in ["swift", "py", "json", "yml", "rs"] {
            XCTAssertEqual(FileKind.from(extension: ext), .code)
        }
    }

    // MARK: - 大小写 / 边界

    func test_大写扩展名也命中() {
        XCTAssertEqual(FileKind.from(extension: "MOV"), .video)
        XCTAssertEqual(FileKind.from(extension: "PDF"), .document)
        XCTAssertEqual(FileKind.from(extension: "Swift"), .code)
    }

    func test_未知扩展名兜底other() {
        XCTAssertEqual(FileKind.from(extension: "xyz"), .other)
        XCTAssertEqual(FileKind.from(extension: "qq"), .other)
    }

    func test_空扩展名兜底other() {
        XCTAssertEqual(FileKind.from(extension: ""), .other)
    }

    // MARK: - path 入参

    func test_path_with_extension() {
        XCTAssertEqual(FileKind.from(path: "/tmp/big.MP4"), .video)
        XCTAssertEqual(FileKind.from(path: "/Users/me/x.swift"), .code)
    }

    func test_path_no_extension() {
        XCTAssertEqual(FileKind.from(path: "/tmp/Makefile"), .other)
        XCTAssertEqual(FileKind.from(path: "/usr/local/bin/ls"), .other)
    }

    // MARK: - LargeFileItem.kind extension

    func test_LargeFileItem_kind_便捷属性() {
        let v = LargeFileItem(path: "/tmp/x.mp4", bytes: 1, modificationDate: nil)
        XCTAssertEqual(v.kind, .video)
        let u = LargeFileItem(path: "/tmp/x.unknown", bytes: 1, modificationDate: nil)
        XCTAssertEqual(u.kind, .other)
    }

    // MARK: - UI 资产存在性

    func test_所有桶都有label与systemImageName() {
        for k in FileKind.allCases {
            XCTAssertFalse(k.label.isEmpty, "\(k) 必须有 label")
            XCTAssertFalse(k.systemImageName.isEmpty, "\(k) 必须有 systemImageName")
        }
    }
}
