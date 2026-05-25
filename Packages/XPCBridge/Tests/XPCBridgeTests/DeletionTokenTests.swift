import XCTest
@testable import XPCBridge

final class DeletionTokenTests: XCTestCase {
    private let key = Data(repeating: 0xAB, count: 32)

    private func makeRequest(
        paths: [String] = ["/tmp/foo"],
        dryRun: Bool = true,
        expiresIn: TimeInterval = 30
    ) -> DeletionRequest {
        DeletionRequest(
            paths: paths,
            dryRun: dryRun,
            nonce: UUID().uuidString,
            expiresAt: Date().timeIntervalSince1970 + expiresIn,
            requestID: UUID().uuidString
        )
    }

    func testSignAndVerifyHappyPath() throws {
        let req = makeRequest()
        let sig = try DeletionTokenSigner.sign(req, key: key)
        let envelope = SignedDeletionRequest(request: req, signature: sig)
        XCTAssertNil(DeletionTokenSigner.verify(envelope, key: key))
    }

    func testTamperedPathRejected() throws {
        let req = makeRequest(paths: ["/tmp/foo"])
        let sig = try DeletionTokenSigner.sign(req, key: key)
        // 把 paths 篡改一下
        let tampered = DeletionRequest(
            paths: ["/etc/passwd"],
            dryRun: req.dryRun,
            nonce: req.nonce,
            expiresAt: req.expiresAt,
            requestID: req.requestID
        )
        let envelope = SignedDeletionRequest(request: tampered, signature: sig)
        XCTAssertEqual(DeletionTokenSigner.verify(envelope, key: key), "bad-signature")
    }

    func testTamperedDryRunRejected() throws {
        // dryRun=true 签名后被改成 false（典型的"绕过 dry-run 攻击"）
        let req = makeRequest(dryRun: true)
        let sig = try DeletionTokenSigner.sign(req, key: key)
        let tampered = DeletionRequest(
            paths: req.paths,
            dryRun: false,
            nonce: req.nonce,
            expiresAt: req.expiresAt,
            requestID: req.requestID
        )
        let envelope = SignedDeletionRequest(request: tampered, signature: sig)
        XCTAssertEqual(DeletionTokenSigner.verify(envelope, key: key), "bad-signature")
    }

    func testWrongKeyRejected() throws {
        let req = makeRequest()
        let sig = try DeletionTokenSigner.sign(req, key: key)
        let envelope = SignedDeletionRequest(request: req, signature: sig)
        let wrongKey = Data(repeating: 0xCD, count: 32)
        XCTAssertEqual(DeletionTokenSigner.verify(envelope, key: wrongKey), "bad-signature")
    }

    func testExpiredRejected() throws {
        let req = makeRequest(expiresIn: -1)
        let sig = try DeletionTokenSigner.sign(req, key: key)
        let envelope = SignedDeletionRequest(request: req, signature: sig)
        XCTAssertEqual(DeletionTokenSigner.verify(envelope, key: key), "expired")
    }

    func testFutureTooFarRejected() throws {
        let req = makeRequest(expiresIn: 3600)
        let sig = try DeletionTokenSigner.sign(req, key: key)
        let envelope = SignedDeletionRequest(request: req, signature: sig)
        XCTAssertEqual(DeletionTokenSigner.verify(envelope, key: key), "expires-too-far")
    }

    func testEmptyPathsRejected() throws {
        let req = makeRequest(paths: [])
        let sig = try DeletionTokenSigner.sign(req, key: key)
        let envelope = SignedDeletionRequest(request: req, signature: sig)
        XCTAssertEqual(DeletionTokenSigner.verify(envelope, key: key), "empty-paths")
    }

    func testCanonicalizationIsStable() throws {
        // 两次序列化结果必须 byte-equal，否则签名无意义
        let req = makeRequest()
        let a = try DeletionTokenSigner.canonicalize(req)
        let b = try DeletionTokenSigner.canonicalize(req)
        XCTAssertEqual(a, b)
    }

    // MARK: - v1.3.zzzz Phase 3-E：accessDeniedPaths 字段

    /// 默认空 accessDeniedPaths 不应出现在 canonical JSON 里——这是与 v0.2 envelope 字节兼容的关键。
    func testCanonicalOmitsEmptyAccessDenied() throws {
        let req = makeRequest()  // 默认 accessDeniedPaths=[]
        let json = try DeletionTokenSigner.canonicalize(req)
        let str = String(data: json, encoding: .utf8) ?? ""
        XCTAssertFalse(str.contains("accessDeniedPaths"),
                       "空数组必须省略字段以保持与 v0.2 envelope 签名兼容：\(str)")
    }

    /// 老主 App 签的不带 accessDeniedPaths 的 envelope，新 Helper decode 后再 verify 必须通过——
    /// 这是 envelope 演进的字节兼容性合同。
    func testLegacyEnvelopeWithoutFieldStillVerifies() throws {
        let req = makeRequest()
        let sig = try DeletionTokenSigner.sign(req, key: key)
        let envelope = SignedDeletionRequest(request: req, signature: sig)
        // 编码后再解码，模拟跨进程 IPC
        let payload = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(SignedDeletionRequest.self, from: payload)
        XCTAssertNil(DeletionTokenSigner.verify(decoded, key: key))
        XCTAssertEqual(decoded.request.accessDeniedPaths, [],
                       "decode 后默认空数组")
    }

    /// 新主 App 签的带非空 accessDeniedPaths 的 envelope，必须能通过自身 verify。
    func testNewEnvelopeWithAccessDeniedRoundtrips() throws {
        let req = DeletionRequest(
            paths: ["/Users/x/Caches/foo"],
            dryRun: true,
            nonce: "n",
            expiresAt: Date().timeIntervalSince1970 + 30,
            requestID: "r",
            accessDeniedPaths: ["/Users/x/Library", "/var/folders/zz"]
        )
        let sig = try DeletionTokenSigner.sign(req, key: key)
        let envelope = SignedDeletionRequest(request: req, signature: sig)
        let payload = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(SignedDeletionRequest.self, from: payload)
        XCTAssertEqual(decoded.request.accessDeniedPaths,
                       ["/Users/x/Library", "/var/folders/zz"])
        XCTAssertNil(DeletionTokenSigner.verify(decoded, key: key))
    }

    /// 篡改 accessDeniedPaths 必须导致签名失败——证明它已经进入 HMAC 计算。
    func testTamperedAccessDeniedRejected() throws {
        let req = DeletionRequest(
            paths: ["/Users/x/Caches/foo"],
            dryRun: true,
            nonce: "n",
            expiresAt: Date().timeIntervalSince1970 + 30,
            requestID: "r",
            accessDeniedPaths: ["/Users/x/Library"]
        )
        let sig = try DeletionTokenSigner.sign(req, key: key)
        // 改 accessDeniedPaths（典型攻击：客户端把"原本要拦截的路径"从 set 里悄悄抹掉）
        let tampered = DeletionRequest(
            paths: req.paths,
            dryRun: req.dryRun,
            nonce: req.nonce,
            expiresAt: req.expiresAt,
            requestID: req.requestID,
            accessDeniedPaths: []
        )
        let envelope = SignedDeletionRequest(request: tampered, signature: sig)
        XCTAssertEqual(DeletionTokenSigner.verify(envelope, key: key), "bad-signature")
    }
}
