import XCTest
@testable import AppUI

/// v1.2 P1-4：修改日期过滤行为单测。
///
/// 用 fixed `now` 注入，避免单测在跨日 / 跨时区时偶发抖动。
final class MtimeFilterTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func test_全部_总是通过() {
        let f = AppSettings.MtimeFilter.all
        XCTAssertTrue(f.passes(now, now: now))
        XCTAssertTrue(f.passes(Date(timeIntervalSince1970: 0), now: now))
        XCTAssertTrue(f.passes(nil, now: now))
    }

    func test_30天_刚好30天通过_31天不通过() {
        let f = AppSettings.MtimeFilter.last30Days
        let day = TimeInterval(86_400)
        XCTAssertTrue(f.passes(now.addingTimeInterval(-30 * day), now: now), "刚好 30 天应通过（含等号）")
        XCTAssertTrue(f.passes(now.addingTimeInterval(-1 * day), now: now), "1 天前必通过")
        XCTAssertFalse(f.passes(now.addingTimeInterval(-31 * day), now: now), "31 天前应被过滤")
    }

    func test_1年_365天通过_366天不通过() {
        let f = AppSettings.MtimeFilter.last1Year
        let day = TimeInterval(86_400)
        XCTAssertTrue(f.passes(now.addingTimeInterval(-365 * day), now: now))
        XCTAssertFalse(f.passes(now.addingTimeInterval(-366 * day), now: now))
    }

    func test_mtime为nil_按全部处理_不丢数据() {
        XCTAssertTrue(AppSettings.MtimeFilter.all.passes(nil, now: now))
        XCTAssertTrue(AppSettings.MtimeFilter.last30Days.passes(nil, now: now),
                      "mtime 缺失（iCloud 占位 / SMB）应被保留显示，避免误以为已过滤")
        XCTAssertTrue(AppSettings.MtimeFilter.last1Year.passes(nil, now: now))
    }

    func test_未来时间_应该通过_因为timeIntervalSince为负() {
        let f = AppSettings.MtimeFilter.last30Days
        let future = now.addingTimeInterval(3600)
        XCTAssertTrue(f.passes(future, now: now), "用户改了系统时间，未来时间不能被误判为'30 天前'")
    }

    func test_label_本地化() {
        // i18n 化后 label 来自 String(localized: "mtime.filter.*", bundle: .module)；
        // 在 SPM xctest 下 Bundle.module 通常 fallback 到 key 字符串，
        // 但生产 App 内会渲染为中文/英文。测试只断言：
        // 1) label 非空（确保 enum 真的产出了字符串）
        // 2) 三种 case 互不相同（确保不是同一个 fallback 错位到所有 case）
        let all = AppSettings.MtimeFilter.all.label
        let m30 = AppSettings.MtimeFilter.last30Days.label
        let y1 = AppSettings.MtimeFilter.last1Year.label
        XCTAssertFalse(all.isEmpty)
        XCTAssertFalse(m30.isEmpty)
        XCTAssertFalse(y1.isEmpty)
        XCTAssertNotEqual(all, m30)
        XCTAssertNotEqual(m30, y1)
        XCTAssertNotEqual(all, y1)
    }

    @MainActor
    func test_mtimeFilter_持久化_重启能读到() throws {
        let suite = "AmuxAIClean.tests.MtimeFilter.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        do {
            let s = AppSettings(testSuite: suite)
            XCTAssertEqual(s.mtimeFilter, .all)
            s.mtimeFilter = .last30Days
        }
        let s2 = AppSettings(testSuite: suite)
        XCTAssertEqual(s2.mtimeFilter, .last30Days)
    }

    @MainActor
    func test_mtimeFilter_脏数据应回退到默认() throws {
        let suite = "AmuxAIClean.tests.MtimeFilter.dirty.\(UUID().uuidString)"
        UserDefaults().removePersistentDomain(forName: suite)
        let d = UserDefaults(suiteName: suite)!
        d.set("garbage_value", forKey: AppSettings.Keys.mtimeFilter)
        let s = AppSettings(testSuite: suite)
        XCTAssertEqual(s.mtimeFilter, .all, "脏数据应回退到 .all 而不是 crash")
    }
}
