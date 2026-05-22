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
}
