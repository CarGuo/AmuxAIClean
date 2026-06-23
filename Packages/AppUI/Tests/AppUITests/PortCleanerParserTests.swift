import XCTest
@testable import AppUI

final class PortCleanerParserTests: XCTestCase {
    func test_parseLsof_监听TCP和UDP都能解析() {
        let sample = """
        p123
        cnode
        Lguoshuyu
        PTCP
        TST=LISTEN
        n*:3000
        PUDP
        n127.0.0.1:5353
        p456
        cPostgres
        Lpostgres
        PTCP
        TST=LISTEN
        n127.0.0.1:5432
        """

        let entries = PortCleanerParser.parseLsof(sample)

        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries.map(\.localPort).sorted(), [3000, 5353, 5432])
        XCTAssertTrue(entries.contains { $0.processName == "node" && $0.proto == .tcp && $0.localAddress == "*" })
        XCTAssertTrue(entries.contains { $0.processName == "node" && $0.proto == .udp && $0.localAddress == "127.0.0.1" })
        XCTAssertTrue(entries.contains { $0.processName == "Postgres" && $0.pid == 456 && $0.user == "postgres" })
    }

    func test_parseLsof_IPV6和远端地址都能解析() {
        let sample = """
        p789
        cExample
        Ltester
        PTCP
        TST=ESTABLISHED
        n[::1]:8080->[::1]:50123
        """

        let entries = PortCleanerParser.parseLsof(sample)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].localAddress, "::1")
        XCTAssertEqual(entries[0].localPort, 8080)
        XCTAssertEqual(entries[0].remoteAddress, "::1")
        XCTAssertEqual(entries[0].remotePort, 50123)
        XCTAssertEqual(entries[0].state, "ESTABLISHED")
    }

    func test_parseLsof_macOS常见字段顺序也能保留状态并去重() {
        let sample = """
        p1109
        cControlCenter
        Lguoshuyu
        f10
        PTCP
        n*:7000
        TST=LISTEN
        f11
        PTCP
        n*:7000
        TST=LISTEN
        """

        let entries = PortCleanerParser.parseLsof(sample)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].localPort, 7000)
        XCTAssertEqual(entries[0].state, "LISTEN")
        XCTAssertEqual(entries[0].processName, "ControlCenter")
    }

    func test_parseHostPort_非法地址返回nil() {
        XCTAssertNil(PortCleanerParser.parseHostPort("no-port"))
        XCTAssertNil(PortCleanerParser.parseHostPort("[::1]8080"))
        XCTAssertNil(PortCleanerParser.parseHostPort("localhost:abc"))
    }

    func test_groups_同进程聚合并按端口数量排序() {
        let entries = [
            PortCleanerEntry(proto: .tcp, localAddress: "*", localPort: 3000, pid: 1, processName: "node", processPath: "/usr/local/bin/node", user: "me"),
            PortCleanerEntry(proto: .tcp, localAddress: "*", localPort: 3001, pid: 1, processName: "node", processPath: "/usr/local/bin/node", user: "me"),
            PortCleanerEntry(proto: .tcp, localAddress: "127.0.0.1", localPort: 5432, pid: 2, processName: "postgres", processPath: "/opt/postgres", user: "me")
        ]

        let groups = PortCleanerGroup.groups(from: entries)

        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups[0].title, "node")
        XCTAssertEqual(groups[0].portCount, 2)
        XCTAssertEqual(groups[0].pids, [1])
    }

    func test_terminationProtection_系统和root进程不可请求结束() {
        let apple = PortCleanerEntry(
            proto: .tcp,
            localAddress: "*",
            localPort: 5000,
            pid: 1109,
            processName: "ControlCenter",
            processPath: "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
            user: "guoshuyu"
        )
        let rootDaemon = PortCleanerEntry(
            proto: .tcp,
            localAddress: "*",
            localPort: 22,
            pid: 99,
            processName: "sshd",
            processPath: "/usr/sbin/sshd",
            user: "root"
        )
        let devServer = PortCleanerEntry(
            proto: .tcp,
            localAddress: "127.0.0.1",
            localPort: 3000,
            pid: 12345,
            processName: "node",
            processPath: "/opt/homebrew/bin/node",
            user: "guoshuyu"
        )

        XCTAssertEqual(apple.terminationProtection, .systemProcess)
        XCTAssertFalse(apple.canRequestTermination)
        XCTAssertEqual(rootDaemon.terminationProtection, .privilegedUser)
        XCTAssertFalse(rootDaemon.canRequestTermination)
        XCTAssertNil(devServer.terminationProtection)
        XCTAssertTrue(devServer.canRequestTermination)
    }

    func test_groups_terminablePids只包含可安全请求结束的进程() {
        let entries = [
            PortCleanerEntry(proto: .tcp, localAddress: "*", localPort: 3000, pid: 1, processName: "launchd", processPath: "/sbin/launchd", user: "root"),
            PortCleanerEntry(proto: .tcp, localAddress: "127.0.0.1", localPort: 3001, pid: 42, processName: "node", processPath: "/opt/homebrew/bin/node", user: "me")
        ]

        let group = PortCleanerGroup(
            id: "mixed",
            title: "mixed",
            path: nil,
            user: nil,
            entries: entries
        )

        XCTAssertEqual(group.terminablePids, [42])
    }
}
