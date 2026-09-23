import XCTest
import os
@testable import LoveLetter

final class GitHubAuthModelsTests: XCTestCase {

    func test_deviceCodeResponse_decodesFromGitHubJSON() throws {
        let json = """
        {
          "device_code": "abc123",
          "user_code": "WDJB-MJHT",
          "verification_uri": "https://github.com/login/device",
          "expires_in": 900,
          "interval": 5
        }
        """.data(using: .utf8)!
        let response = try JSONDecoder().decode(DeviceCodeResponse.self, from: json)
        XCTAssertEqual(response.deviceCode, "abc123")
        XCTAssertEqual(response.userCode, "WDJB-MJHT")
        XCTAssertEqual(response.verificationUri, "https://github.com/login/device")
        XCTAssertEqual(response.expiresIn, 900)
        XCTAssertEqual(response.interval, 5)
    }

    func test_gitHubRepo_decodesFromGitHubJSON() throws {
        let json = """
        {
          "id": 42,
          "name": "feedback",
          "full_name": "acme/feedback",
          "private": true,
          "owner": { "login": "acme" }
        }
        """.data(using: .utf8)!
        let repo = try JSONDecoder().decode(GitHubRepo.self, from: json)
        XCTAssertEqual(repo.id, 42)
        XCTAssertEqual(repo.name, "feedback")
        XCTAssertEqual(repo.fullName, "acme/feedback")
        XCTAssertTrue(repo.isPrivate)
        XCTAssertEqual(repo.owner.login, "acme")
        XCTAssertFalse(repo.owner.isOrganization, "no type: not known to be an organization")
    }

    func test_gitHubRepo_decodesTheOwnerType() throws {
        let json = """
        { "id": 1, "name": "fb", "full_name": "acme/fb", "private": false,
          "owner": { "login": "acme", "type": "Organization" } }
        """.data(using: .utf8)!
        let repo = try JSONDecoder().decode(GitHubRepo.self, from: json)
        XCTAssertEqual(repo.owner.type, "Organization")
        XCTAssertTrue(repo.owner.isOrganization)
    }

    func test_gitHubUser_decodesFromGitHubJSON() throws {
        let json = """
        { "login": "octocat", "avatar_url": "https://example.com/a.png" }
        """.data(using: .utf8)!
        let user = try JSONDecoder().decode(GitHubUser.self, from: json)
        XCTAssertEqual(user.login, "octocat")
        XCTAssertEqual(user.avatarURL, "https://example.com/a.png")
    }
}

final class GitHubAuthServiceTests: XCTestCase {

    private func ok(_ req: URLRequest) -> HTTPURLResponse {
        HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    }

    private func tokenJSON(_ token: String) -> Data {
        """
        { "access_token": "\(token)", "token_type": "bearer", "scope": "repo" }
        """.data(using: .utf8)!
    }

    private func errorJSON(_ code: String) -> Data {
        """
        { "error": "\(code)", "error_description": "" }
        """.data(using: .utf8)!
    }

    // MARK: requestDeviceCode

    func test_requestDeviceCode_decodesResponse() async throws {
        let responseJSON = """
        {
          "device_code": "devcode",
          "user_code": "ABCD-1234",
          "verification_uri": "https://github.com/login/device",
          "expires_in": 900,
          "interval": 5
        }
        """.data(using: .utf8)!
        MockURLProtocol.requestHandler = { req in (self.ok(req), responseJSON) }
        let service = GitHubAuthService(session: .mock)
        let result = try await service.requestDeviceCode()
        XCTAssertEqual(result.userCode, "ABCD-1234")
        XCTAssertEqual(result.deviceCode, "devcode")
    }

    func test_requestDeviceCode_throwsOnNon200() async throws {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data())
        }
        let service = GitHubAuthService(session: .mock)
        do {
            _ = try await service.requestDeviceCode()
            XCTFail("Expected throw")
        } catch GitHubAuthService.AuthError.apiError(let code) {
            XCTAssertEqual(code, 500)
        }
    }

    // MARK: pollForToken

    func test_pollForToken_returnsToken_whenImmediatelyAuthorized() async throws {
        MockURLProtocol.requestHandler = { req in (self.ok(req), self.tokenJSON("gho_test")) }
        let service = GitHubAuthService(session: .mock)
        let token = try await service.pollForToken(deviceCode: "devcode", interval: 0)
        XCTAssertEqual(token, "gho_test")
    }

    func test_pollForToken_retriesOnAuthorizationPending() async throws {
        let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        MockURLProtocol.requestHandler = { req in
            let n = callCount.withLock { count -> Int in
                count += 1
                return count
            }
            let data = n < 3 ? self.errorJSON("authorization_pending") : self.tokenJSON("gho_retry")
            return (self.ok(req), data)
        }
        let service = GitHubAuthService(session: .mock)
        let token = try await service.pollForToken(deviceCode: "devcode", interval: 0)
        XCTAssertEqual(token, "gho_retry")
        XCTAssertEqual(callCount.withLock { $0 }, 3)
    }

    func test_pollForToken_throwsAccessDenied() async throws {
        MockURLProtocol.requestHandler = { req in (self.ok(req), self.errorJSON("access_denied")) }
        let service = GitHubAuthService(session: .mock)
        do {
            _ = try await service.pollForToken(deviceCode: "devcode", interval: 0)
            XCTFail("Expected throw")
        } catch GitHubAuthService.AuthError.accessDenied {
            // pass
        }
    }

    func test_pollForToken_throwsExpiredToken() async throws {
        MockURLProtocol.requestHandler = { req in (self.ok(req), self.errorJSON("expired_token")) }
        let service = GitHubAuthService(session: .mock)
        do {
            _ = try await service.pollForToken(deviceCode: "devcode", interval: 0)
            XCTFail("Expected throw")
        } catch GitHubAuthService.AuthError.expiredToken {
            // pass
        }
    }

    // MARK: listRepos

    func test_listRepos_returnsDecodedRepos() async throws {
        let reposJSON = """
        [
          { "id": 1, "name": "alpha", "full_name": "org/alpha", "private": false, "owner": { "login": "org" } },
          { "id": 2, "name": "beta",  "full_name": "org/beta",  "private": true,  "owner": { "login": "org" } }
        ]
        """.data(using: .utf8)!
        MockURLProtocol.requestHandler = { req in (self.ok(req), reposJSON) }
        let service = GitHubAuthService(session: .mock)
        let repos = try await service.listRepos(token: "tok")
        XCTAssertEqual(repos.count, 2)
        XCTAssertEqual(repos[0].name, "alpha")
        XCTAssertTrue(repos[1].isPrivate)
    }

    func test_pollForToken_incrementsIntervalOnSlowDown() async throws {
        let callCount = OSAllocatedUnfairLock<Int>(initialState: 0)
        MockURLProtocol.requestHandler = { req in
            let n = callCount.withLock { count -> Int in
                count += 1
                return count
            }
            let data = n == 1 ? self.errorJSON("slow_down") : self.tokenJSON("gho_slow")
            return (self.ok(req), data)
        }
        let service = GitHubAuthService(session: .mock)
        let token = try await service.pollForToken(deviceCode: "devcode", interval: 0)
        XCTAssertEqual(token, "gho_slow")
        XCTAssertEqual(callCount.withLock { $0 }, 2)
    }

    func test_listRepos_paginatesUntilPageBelowHundred() async throws {
        let makeRepos: (Int, Int) -> Data = { startId, count in
            let items = (startId..<(startId + count)).map { n in
                """
                { "id": \(n), "name": "repo\(n)", "full_name": "org/repo\(n)", "private": false, "owner": { "login": "org" } }
                """
            }
            return ("[\(items.joined(separator: ","))]").data(using: .utf8)!
        }
        let pageRequests = OSAllocatedUnfairLock<Int>(initialState: 0)
        MockURLProtocol.requestHandler = { req in
            let n = pageRequests.withLock { count -> Int in
                count += 1
                return count
            }
            let data = n == 1 ? makeRepos(1, 100) : makeRepos(101, 1)
            return (self.ok(req), data)
        }
        let service = GitHubAuthService(session: .mock)
        let repos = try await service.listRepos(token: "tok")
        XCTAssertEqual(repos.count, 101)
        XCTAssertEqual(pageRequests.withLock { $0 }, 2)
    }

    func test_requestDeviceCode_postsToCorrectURL() async throws {
        let capturedRequest = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
        MockURLProtocol.requestHandler = { req in
            capturedRequest.withLock { $0 = req }
            let responseJSON = """
            { "device_code": "d", "user_code": "U-CODE", "verification_uri": "https://github.com/login/device", "expires_in": 900, "interval": 5 }
            """.data(using: .utf8)!
            return (self.ok(req), responseJSON)
        }
        let service = GitHubAuthService(session: .mock)
        _ = try await service.requestDeviceCode()
        let captured = capturedRequest.withLock { $0 }
        XCTAssertEqual(captured?.url?.absoluteString, "https://github.com/login/device/code")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    // MARK: fetchCurrentUser

    func test_fetchCurrentUser_decodesLoginAndAvatar() async throws {
        let json = """
        { "login": "octocat", "avatar_url": "https://avatars.githubusercontent.com/u/1?v=4", "id": 1 }
        """.data(using: .utf8)!
        MockURLProtocol.requestHandler = { req in (self.ok(req), json) }
        let service = GitHubAuthService(session: .mock)
        let user = try await service.fetchCurrentUser(token: "tok")
        XCTAssertEqual(user.login, "octocat")
        XCTAssertEqual(user.avatarURL, "https://avatars.githubusercontent.com/u/1?v=4")
    }

    func test_fetchCurrentUser_throwsOnUnauthorized() async throws {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data())
        }
        let service = GitHubAuthService(session: .mock)
        do {
            _ = try await service.fetchCurrentUser(token: "tok")
            XCTFail("Expected throw")
        } catch GitHubAuthService.AuthError.apiError(let code) {
            XCTAssertEqual(code, 401)
        }
    }
    // MARK: createRepo

    func test_createRepo_postsToTheOrganizationAndDecodesTheNewRepo() async throws {
        let json = """
        { "id": 7, "name": "fb", "full_name": "acme/fb", "private": true,
          "owner": { "login": "acme", "type": "Organization" } }
        """.data(using: .utf8)!
        let lock = OSAllocatedUnfairLock<URLRequest?>(initialState: nil)
        MockURLProtocol.requestHandler = { req in
            lock.withLock { $0 = req }
            return (HTTPURLResponse(url: req.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, json)
        }
        let repo = try await GitHubAuthService(session: .mock)
            .createRepo(name: "fb", organization: "acme", isPrivate: true, description: "d", token: "tok")
        let captured = lock.withLock { $0 }
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.github.com/orgs/acme/repos")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(repo.fullName, "acme/fb")
        XCTAssertTrue(repo.owner.isOrganization)
    }

    func test_createRepo_422CarriesGitHubsReason() async throws {
        let json = """
        { "message": "Repository creation failed.",
          "errors": [{ "resource": "Repository", "code": "custom", "field": "name",
                       "message": "name already exists on this account" }] }
        """.data(using: .utf8)!
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, json)
        }
        do {
            _ = try await GitHubAuthService(session: .mock)
                .createRepo(name: "fb", organization: nil, isPrivate: true, description: "d", token: "tok")
            XCTFail("Expected throw")
        } catch let error as GitHubAuthService.ValidationFailed {
            XCTAssertEqual(error.message, "name already exists on this account")
        }
    }

    func test_ensureLabel_treatsAnExistingLabelAsDone() async throws {
        MockURLProtocol.requestHandler = { req in
            (HTTPURLResponse(url: req.url!, statusCode: 422, httpVersion: nil, headerFields: nil)!, Data())
        }
        try await GitHubAuthService(session: .mock)
            .ensureLabel("bug", color: "d73a4a", owner: "acme", repo: "fb", token: "tok")
    }
}
