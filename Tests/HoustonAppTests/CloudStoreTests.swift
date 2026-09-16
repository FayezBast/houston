import XCTest
import HoustonCore
@testable import Houston

private final class MemoryCloudSecrets: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    func read(_ account: String, _ interaction: Bool) -> Data? { lock.withLock { values[account] } }
    func save(_ value: String, _ account: String) { lock.withLock { values[account] = Data(value.utf8) } }
    func remove(_ account: String) { lock.withLock { _ = values.removeValue(forKey: account) } }
}

private actor CloudResponseQueue {
    var responses: [Result<Data, CloudAPIError>]
    init(_ responses: [Result<Data, CloudAPIError>]) { self.responses = responses }
    func send(_ request: URLRequest) throws -> Data { try responses.removeFirst().get() }
    func append(_ result: Result<Data, CloudAPIError>) { responses.append(result) }
}

private actor PendingCloudResponse {
    private let started: [XCTestExpectation]
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var count = 0
    init(_ started: [XCTestExpectation]) { self.started = started }
    func send(_ request: URLRequest) async throws -> Data {
        let index = count
        count += 1
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = continuation
            started[index].fulfill()
        }
    }
    func finish(_ index: Int, data: Data) { pending.removeValue(forKey: index)?.resume(returning: data) }
    func fail(_ index: Int, error: CloudAPIError) { pending.removeValue(forKey: index)?.resume(throwing: error) }
}

final class CloudStoreTests: XCTestCase {
    private var building: Data { Data(#"{"deployments":[{"uid":"dpl_1","name":"web","state":"BUILDING","url":null}]}"#.utf8) }
    private var ready: Data { Data(#"{"deployments":[{"uid":"dpl_1","name":"web","state":"READY","url":"web.vercel.app"}]}"#.utf8) }
    private var project: HoustonProject { HoustonProject(name: "Houston", path: "/tmp", vercelProjectID: "project1") }

    @MainActor func testOnlyVerifiedCandidateReplacesItsProviderCredential() async {
        let secrets = MemoryCloudSecrets()
        secrets.save("old-vercel", CloudProvider.vercel.secretAccount)
        secrets.save("sentry-secret", CloudProvider.sentry.secretAccount)
        let api = CloudAPI { request in
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer invalid" { throw CloudAPIError.unauthorized }
            return Data(#"{"deployments":[]}"#.utf8)
        }
        let store = CloudStore(api: api, readSecret: secrets.read, saveSecret: secrets.save, removeSecret: secrets.remove)
        let invalid = await store.saveAndVerify("invalid", provider: .vercel)
        XCTAssertFalse(invalid)
        XCTAssertEqual(secrets.read("cloud.vercel", false), Data("old-vercel".utf8))
        XCTAssertTrue(store.connectionErrors.contains(.vercel))
        let valid = await store.saveAndVerify("new-vercel", provider: .vercel)
        XCTAssertTrue(valid)
        XCTAssertEqual(secrets.read("cloud.vercel", false), Data("new-vercel".utf8))
        XCTAssertEqual(secrets.read("cloud.sentry", false), Data("sentry-secret".utf8))
        XCTAssertTrue(store.connected.contains(.vercel))
        await store.clearConnection(.vercel)
        XCTAssertNil(secrets.read("cloud.vercel", false))
        XCTAssertEqual(secrets.read("cloud.sentry", false), Data("sentry-secret".utf8))
        XCTAssertFalse(store.connected.contains(.vercel))
    }

    @MainActor func testQuietBaselineThenCompletionAndFailedRefreshPreservesStaleData() async {
        let secrets = MemoryCloudSecrets()
        secrets.save("vercel", "cloud.vercel")
        let responses = CloudResponseQueue([.success(building), .success(ready), .failure(.forbidden)])
        let store = CloudStore(api: CloudAPI { try await responses.send($0) }, readSecret: secrets.read, saveSecret: secrets.save, removeSecret: secrets.remove)
        var alerts: [CloudTransition] = []
        store.onTransition = { alerts.append($0) }
        let project = project
        await store.refresh(provider: .vercel, project: project)
        XCTAssertTrue(alerts.isEmpty)
        await store.refresh(provider: .vercel, project: project)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.projectID, project.id)
        XCTAssertEqual(store.snapshot(for: project).deployments.first?.state, "READY")
        let successfulDate = store.snapshot(for: project).states[.vercel]?.updatedAt
        await store.refresh(provider: .vercel, project: project)
        XCTAssertEqual(store.snapshot(for: project).deployments.first?.state, "READY")
        XCTAssertEqual(store.snapshot(for: project).states[.vercel]?.updatedAt, successfulDate)
        XCTAssertNotNil(store.snapshot(for: project).states[.vercel]?.message)
        XCTAssertEqual(alerts.count, 1)
    }

    @MainActor func testFailedReadingStaysLabeledDuringRetryUntilSuccess() async throws {
        let started = (0..<3).map { expectation(description: "Cloud request \($0) started") }
        let responses = PendingCloudResponse(started)
        let store = CloudStore(api: CloudAPI { try await responses.send($0) }, readSecret: { _, _ in Data("fixture".utf8) })
        let project = project
        let failedDeployment = Data(#"{"deployments":[{"uid":"dpl_1","name":"web","state":"ERROR"}]}"#.utf8)
        for index in 0..<3 {
            let refresh = Task { await store.refresh(provider: .vercel, project: project) }
            await fulfillment(of: [started[index]], timeout: 3)
            if index == 2 {
                let snapshot = store.snapshot(for: project)
                XCTAssertTrue(snapshot.states[.vercel]?.isLoading == true)
                XCTAssertNotNil(snapshot.states[.vercel]?.message)
                XCTAssertTrue(ProjectAttention.items(for: project, runs: [], snapshot: snapshot).first?.detail.hasPrefix("Earlier reading") == true)
            }
            if index == 1 { await responses.fail(index, error: .forbidden) }
            else { await responses.finish(index, data: failedDeployment) }
            await refresh.value
            let snapshot = store.snapshot(for: project)
            XCTAssertFalse(snapshot.states[.vercel]?.isLoading == true)
            XCTAssertEqual(snapshot.deployments.first?.state, "ERROR")
            XCTAssertEqual(snapshot.states[.vercel]?.message != nil, index == 1)
            XCTAssertEqual(ProjectAttention.items(for: project, runs: [], snapshot: snapshot).first?.detail.hasPrefix("Earlier reading"), index == 1)
        }
    }

    @MainActor func testFastCompletedDeploymentAlertsOnceButNewlyPagedHistoryStaysQuiet() async throws {
        let secrets = MemoryCloudSecrets()
        secrets.save("vercel", "cloud.vercel")
        let queue = CloudResponseQueue([.success(Data(#"{"deployments":[]}"#.utf8))])
        let store = CloudStore(api: CloudAPI { try await queue.send($0) }, readSecret: secrets.read)
        var alerts: [CloudTransition] = []
        store.onTransition = { alerts.append($0) }
        let project = project
        await store.refresh(provider: .vercel, project: project)
        XCTAssertTrue(alerts.isEmpty)
        let previousCheck = try XCTUnwrap(store.snapshot(for: project).states[.vercel]?.updatedAt)
        let data = try JSONSerialization.data(withJSONObject: ["deployments": [
            ["uid": "dpl_fast", "name": "web", "state": "READY", "createdAt": previousCheck.addingTimeInterval(1).timeIntervalSince1970 * 1000],
            ["uid": "dpl_historical", "name": "web", "state": "ERROR", "createdAt": previousCheck.addingTimeInterval(-60).timeIntervalSince1970 * 1000]
        ]])
        await queue.append(.success(data))
        await store.refresh(provider: .vercel, project: project)
        XCTAssertEqual(alerts.count, 1)
        XCTAssertTrue(alerts.first?.title.contains("ready") == true)
        await queue.append(.success(data))
        await store.refresh(provider: .vercel, project: project)
        XCTAssertEqual(alerts.count, 1)
    }

    @MainActor func testRemovingTokenDiscardsAnInFlightResponse() async {
        let secrets = MemoryCloudSecrets()
        secrets.save("vercel", "cloud.vercel")
        let started = expectation(description: "Cloud request started")
        let pending = PendingCloudResponse([started])
        let store = CloudStore(api: CloudAPI { try await pending.send($0) }, readSecret: secrets.read, saveSecret: secrets.save, removeSecret: secrets.remove)
        let project = project
        let refresh = Task { await store.refresh(provider: .vercel, project: project) }
        await fulfillment(of: [started], timeout: 2)
        await store.clearConnection(.vercel)
        await pending.finish(0, data: ready)
        await refresh.value
        XCTAssertTrue(store.snapshot(for: project).deployments.isEmpty)
        XCTAssertFalse(store.connected.contains(.vercel))
        XCTAssertNil(store.snapshot(for: project).states[.vercel]?.updatedAt)
    }

    @MainActor func testProjectConfigurationChangeRejectsPreviousScopeAndResponse() async {
        let secrets = MemoryCloudSecrets()
        secrets.save("vercel", "cloud.vercel")
        let first = expectation(description: "First project scope")
        let second = expectation(description: "Second project scope")
        let pending = PendingCloudResponse([first, second])
        let store = CloudStore(api: CloudAPI { try await pending.send($0) }, readSecret: secrets.read, saveSecret: secrets.save, removeSecret: secrets.remove)
        let original = project
        var edited = original
        edited.vercelProjectID = "project2"
        let originalTask = Task { await store.refresh(provider: .vercel, project: original) }
        await fulfillment(of: [first], timeout: 2)
        let editedTask = Task { await store.refresh(provider: .vercel, project: edited) }
        await fulfillment(of: [second], timeout: 2)
        await pending.finish(1, data: ready)
        await editedTask.value
        await pending.finish(0, data: building)
        await originalTask.value
        XCTAssertEqual(store.snapshot(for: edited).deployments.first?.state, "READY")
        XCTAssertTrue(store.snapshot(for: original).deployments.isEmpty, "An old project configuration cannot read the new scope’s cache")
    }

    @MainActor func testPreparingEditedProjectClearsOldValuesBeforeRefreshing() async {
        let secrets = MemoryCloudSecrets()
        secrets.save("vercel", "cloud.vercel")
        let ready = ready
        let store = CloudStore(api: CloudAPI { _ in ready }, readSecret: secrets.read)
        var project = project
        await store.refresh(provider: .vercel, project: project)
        XCTAssertEqual(store.snapshot(for: project).deployments.count, 1)
        project.vercelTeamID = "another-team"
        XCTAssertTrue(store.snapshot(for: project).deployments.isEmpty)
        store.prepare(project: project)
        XCTAssertTrue(store.snapshots[project.id]?.deployments.isEmpty == true)
        XCTAssertNil(store.snapshot(for: project).states[.vercel]?.updatedAt)
    }

    @MainActor func testSuspendingRejectsLateNetworkResultAndClearsLoadingState() async {
        let secrets = MemoryCloudSecrets()
        secrets.save("vercel", "cloud.vercel")
        let started = expectation(description: "Request before suspend")
        let pending = PendingCloudResponse([started])
        let store = CloudStore(api: CloudAPI { try await pending.send($0) }, readSecret: secrets.read)
        let project = project
        let refresh = Task { await store.refresh(provider: .vercel, project: project) }
        await fulfillment(of: [started], timeout: 2)
        store.suspend()
        await pending.finish(0, data: ready)
        await refresh.value
        XCTAssertTrue(store.snapshot(for: project).deployments.isEmpty)
        XCTAssertFalse(store.snapshot(for: project).states[.vercel]?.isLoading ?? true)
    }

    @MainActor func testMissingConfigurationOrTokenNeverMakesANetworkRequest() async {
        let store = CloudStore(api: CloudAPI { _ in XCTFail("Disconnected sources must not make requests"); return Data() }, readSecret: { _, _ in nil })
        let empty = HoustonProject(name: "Empty", path: "/tmp")
        await store.refresh(project: empty)
        XCTAssertTrue(store.snapshot(for: empty).deployments.isEmpty)
        XCTAssertNotNil(store.snapshot(for: empty).states[.vercel]?.message)
        XCTAssertNotNil(store.snapshot(for: empty).states[.sentry]?.message)
        XCTAssertNotNil(store.snapshot(for: empty).states[.linear]?.message)
        XCTAssertFalse(store.snapshot(for: empty).states[.linear]?.isLoading ?? true)
    }
}
