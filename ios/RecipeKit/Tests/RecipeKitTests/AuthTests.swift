//
//  AuthTests.swift
//  RecipeKitTests
//
//  Stage 3 client auth core: session-store round-trip (in-memory backend),
//  AuthAPI request shaping + response decoding + HTTP error mapping (URLProtocol
//  stub, no network), and access-token expiry logic.
//

import XCTest
@testable import RecipeKit

// MARK: - URLProtocol stub

final class AuthStubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = AuthStubURLProtocol.handler else {
            fatalError("no handler set")
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() {}
}

private func stubbedSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AuthStubURLProtocol.self]
    return URLSession(configuration: config)
}

private let tokenJSON = """
{"access_token":"acc","refresh_token":"ref","token_type":"bearer","expires_in":1800,
 "user":{"id":"u1","email":"a@b.com","email_verified":false,"full_name":"Ada L"}}
""".data(using: .utf8)!

// MARK: - In-memory secret store

final class InMemorySecretStore: TokenSecretStore {
    private var storage: [String: String] = [:]
    func read(_ account: String) -> String? { storage[account] }
    func write(_ value: String, account: String) { storage[account] = value }
    func delete(_ account: String) { storage[account] = nil }
}

final class AuthTests: XCTestCase {

    private func api() -> AuthAPI {
        AuthAPI(baseURL: URL(string: "https://example.test")!, session: stubbedSession(), appKey: { "test-key" })
    }

    override func tearDown() {
        AuthStubURLProtocol.handler = nil
        super.tearDown()
    }

    // MARK: Session store

    func testSessionStoreRoundTrips() {
        let store = AuthSessionStore(backend: InMemorySecretStore())
        let session = AuthSession(
            accessToken: "a", refreshToken: "r",
            accessExpiresAt: Date(timeIntervalSince1970: 1_000_000),
            user: AuthUser(id: "u1", email: "a@b.com", emailVerified: true, fullName: "Ada")
        )
        XCTAssertNil(store.load())
        store.save(session)
        XCTAssertEqual(store.load(), session)
        store.clear()
        XCTAssertNil(store.load())
    }

    func testAccessTokenExpiryDetection() {
        let soon = AuthSession(accessToken: "a", refreshToken: "r",
                               accessExpiresAt: Date().addingTimeInterval(30),
                               user: AuthUser(id: "u", email: nil, emailVerified: false, fullName: nil))
        XCTAssertTrue(soon.accessTokenExpiring())     // within 60s leeway
        let later = AuthSession(accessToken: "a", refreshToken: "r",
                                accessExpiresAt: Date().addingTimeInterval(3600),
                                user: soon.user)
        XCTAssertFalse(later.accessTokenExpiring())
    }

    // MARK: AuthAPI success

    func testLoginDecodesSessionAndSendsAppKey() async throws {
        AuthStubURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-App-Key"), "test-key")
            XCTAssertTrue(request.url!.absoluteString.hasSuffix("/auth/login"))
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, tokenJSON)
        }
        let session = try await api().login(email: "a@b.com", password: "supersecret1")
        XCTAssertEqual(session.accessToken, "acc")
        XCTAssertEqual(session.refreshToken, "ref")
        XCTAssertEqual(session.user.id, "u1")
        XCTAssertGreaterThan(session.accessExpiresAt, Date())  // ~30 min out
    }

    func testRegisterOmitsNilFullName() async throws {
        AuthStubURLProtocol.handler = { request in
            let body = request.httpBodyData()
            let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            XCTAssertNil(obj["full_name"])   // nil optional dropped, not sent as null
            XCTAssertEqual(obj["email"] as? String, "a@b.com")
            let resp = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (resp, tokenJSON)
        }
        _ = try await api().register(email: "a@b.com", password: "supersecret1", fullName: nil)
    }

    // MARK: AuthAPI error mapping

    func assertMaps(status: Int, to expected: AuthError, file: StaticString = #filePath, line: UInt = #line) async {
        AuthStubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data())
        }
        do {
            _ = try await api().login(email: "a@b.com", password: "x")
            XCTFail("expected error", file: file, line: line)
        } catch let error as AuthError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("wrong error type: \(error)", file: file, line: line)
        }
    }

    func testErrorMapping() async {
        await assertMaps(status: 401, to: .invalidCredentials)
        await assertMaps(status: 409, to: .emailInUse)
        await assertMaps(status: 429, to: .rateLimited)
        await assertMaps(status: 500, to: .server(500))
    }

    func testOfflineMapping() async {
        AuthStubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        do {
            _ = try await api().login(email: "a@b.com", password: "x")
            XCTFail("expected offline")
        } catch let error as AuthError {
            XCTAssertEqual(error, .offline)
        } catch {
            XCTFail("wrong error type: \(error)")
        }
    }
}

// Read back a request body even when URLProtocol delivers it as a stream.
extension URLRequest {
    func httpBodyData() -> Data {
        if let body = httpBody { return body }
        guard let stream = httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
