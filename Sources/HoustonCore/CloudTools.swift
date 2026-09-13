import Foundation

public enum CloudProvider: String, CaseIterable, Sendable, Identifiable {
    case vercel, sentry, linear
    public var id: String { rawValue }
    public var title: String { rawValue == "vercel" ? "Vercel" : rawValue.capitalized }
    public var secretAccount: String { "cloud.\(rawValue)" }
}

public struct CloudDeployment: Identifiable, Sendable, Equatable {
    public let id: String
    public let name: String
    public let state: String
    public let branch: String
    public let target: String
    public let createdAt: Date?
    public let url: URL?
    public let inspectorURL: URL?
    public var isComplete: Bool { ["READY", "ERROR", "CANCELED", "BLOCKED"].contains(state) }
}

public struct CloudIssue: Identifiable, Sendable, Equatable {
    public let id: String
    public let identifier: String
    public let title: String
    public let state: String
    public let priority: String
    public let eventCount: Int?
    public let userCount: Int?
    public let url: URL?
}

public enum CloudAPIError: LocalizedError, Sendable, Equatable {
    case invalidConfiguration(String), invalidResponse, unauthorized, forbidden, rateLimited, http(Int), tooLarge
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let message): message
        case .invalidResponse: "The service returned an unexpected response. Try refreshing."
        case .unauthorized: "This token has expired or is invalid. Update it in Cloud connections."
        case .forbidden: "This token cannot access the resource. Check its permissions and project settings."
        case .rateLimited: "The service is limiting requests. Wait a few minutes before refreshing."
        case .http(let code): "The service could not complete this request (HTTP \(code))."
        case .tooLarge: "The response exceeded Houston’s size limit. Open the service to see the full result."
        }
    }
}

// Requests only go to fixed API hosts. Never forward a token through a redirect.
private final class CloudSessionDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct CloudAPI: Sendable {
    private let send: @Sendable (URLRequest) async throws -> Data
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: CloudSessionDelegate(), delegateQueue: nil)
    }()

    public init(send: @escaping @Sendable (URLRequest) async throws -> Data = CloudAPI.requestData) { self.send = send }

    public static func requestData(_ request: URLRequest) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw CloudAPIError.invalidResponse }
        try validateStatus(response.statusCode)
        let limit = 2_000_000
        guard response.expectedContentLength <= limit else { throw CloudAPIError.tooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw CloudAPIError.tooLarge }
            data.append(byte)
        }
        return data
    }

    public static func validateStatus(_ code: Int) throws {
        switch code {
        case 200..<300: return
        case 401: throw CloudAPIError.unauthorized
        case 403: throw CloudAPIError.forbidden
        case 429: throw CloudAPIError.rateLimited
        default: throw CloudAPIError.http(code)
        }
    }

    public func deployments(projectID: String, teamID: String, token: String) async throws -> [CloudDeployment] {
        try Self.parseDeployments(await send(Self.deploymentsRequest(projectID: projectID, teamID: teamID, token: token)))
    }

    public func deploymentLogs(id: String, teamID: String, token: String) async throws -> String {
        try Self.parseLogs(await send(Self.logsRequest(id: id, teamID: teamID, token: token)))
    }

    public func sentryIssues(organization: String, project: String, environment: String, token: String) async throws -> [CloudIssue] {
        try Self.parseSentry(await send(Self.sentryRequest(organization: organization, project: project, environment: environment, token: token)))
    }

    public func assignedIssues(projectID: String, token: String) async throws -> [CloudIssue] {
        try Self.parseLinear(await send(Self.linearRequest(projectID: projectID, token: token)))
    }

    public func verify(provider: CloudProvider, token: String) async throws {
        let request: URLRequest
        switch provider {
        case .vercel:
            request = try Self.request(provider, path: "/v7/deployments", query: [.init(name: "limit", value: "1")], token: token)
        case .sentry:
            request = try Self.request(provider, path: "/api/0/", token: token)
        case .linear:
            request = try Self.request(provider, path: "/graphql", token: token, body: ["query": "query HoustonConnection { viewer { id } }"])
        }
        let data = try await send(request)
        switch provider {
        case .vercel: _ = try Self.parseDeployments(data)
        case .sentry:
            let object = try DeveloperTools.object(data)
            guard let auth = object["auth"] as? [String: Any], let scopes = auth["scopes"] as? [String] else { throw CloudAPIError.unauthorized }
            guard !Set(scopes).isDisjoint(with: ["event:read", "event:write", "event:admin"]) else { throw CloudAPIError.forbidden }
        case .linear:
            let object = try Self.graphQLData(data)
            guard let viewer = object["viewer"] as? [String: Any], viewer["id"] is String else { throw CloudAPIError.invalidResponse }
        }
    }

    static func deploymentsRequest(projectID: String, teamID: String, token: String) throws -> URLRequest {
        guard !projectID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CloudAPIError.invalidConfiguration("Add a Vercel project ID or name in this project’s settings.")
        }
        return try request(.vercel, path: "/v7/deployments", query: [
            .init(name: "projectId", value: projectID), .init(name: "limit", value: "10"),
            .init(name: "teamId", value: teamID.isEmpty ? nil : teamID)
        ].filter { $0.value != nil }, token: token)
    }

    static func logsRequest(id: String, teamID: String, token: String) throws -> URLRequest {
        try request(.vercel, path: "/v3/deployments/\(segment(id))/events", query: [
            .init(name: "follow", value: "0"), .init(name: "builds", value: "1"),
            .init(name: "direction", value: "backward"), .init(name: "limit", value: "200"),
            .init(name: "teamId", value: teamID.isEmpty ? nil : teamID)
        ].filter { $0.value != nil }, token: token)
    }

    static func sentryRequest(organization: String, project: String, environment: String, token: String) throws -> URLRequest {
        guard !project.isEmpty else { throw CloudAPIError.invalidConfiguration("Add the Sentry project slug in this project’s settings.") }
        return try request(.sentry, path: "/api/0/organizations/\(segment(organization))/issues/", query: [
            .init(name: "project", value: project), .init(name: "query", value: "is:unresolved"),
            .init(name: "sort", value: "date"), .init(name: "statsPeriod", value: "14d"), .init(name: "limit", value: "20"),
            .init(name: "environment", value: environment.isEmpty ? nil : environment)
        ].filter { $0.value != nil }, token: token)
    }

    static func linearRequest(projectID: String, token: String) throws -> URLRequest {
        var filter: [String: Any] = ["state": ["type": ["nin": ["completed", "canceled"]]]]
        if !projectID.isEmpty { filter["project"] = ["id": ["eq": projectID]] }
        return try request(.linear, path: "/graphql", token: token, body: [
            "query": "query HoustonAssigned($filter: IssueFilter) { viewer { assignedIssues(first: 30, orderBy: updatedAt, filter: $filter) { nodes { id identifier title url priority priorityLabel state { name type } } } } }",
            "variables": ["filter": filter]
        ])
    }

    private static func request(_ provider: CloudProvider, path: String, query: [URLQueryItem] = [], token: String, body: [String: Any]? = nil) throws -> URLRequest {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw CloudAPIError.invalidConfiguration("Enter a valid \(provider.title) token.")
        }
        var components = URLComponents()
        components.scheme = "https"
        components.host = provider == .vercel ? "api.vercel.com" : provider == .sentry ? "sentry.io" : "api.linear.app"
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw CloudAPIError.invalidConfiguration("Check the project’s connection settings.") }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue(provider == .linear ? trimmed : "Bearer \(trimmed)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Houston/0.2", forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private static func segment(_ value: String) throws -> String {
        guard !value.isEmpty, value.count < 256, value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_" )).contains($0) }) else {
            throw CloudAPIError.invalidConfiguration("Use the resource ID or slug, without a URL, spaces, or slashes.")
        }
        return value
    }

    public static func safeLink(_ value: String?, domain: String? = nil, bareHostname: Bool = false) -> URL? {
        guard let value, !value.isEmpty else { return nil }
        let address = bareHostname && !value.contains("://") ? "https://\(value)" : value
        guard let url = URL(string: address), url.scheme == "https", let host = url.host?.lowercased(),
              host.contains("."), url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { return nil }
        if let domain, host != domain && !host.hasSuffix(".\(domain)") { return nil }
        return url
    }

    public static func parseDeployments(_ data: Data) throws -> [CloudDeployment] {
        let object = try DeveloperTools.object(data)
        guard let values = object["deployments"] as? [[String: Any]] else { throw CloudAPIError.invalidResponse }
        return try values.prefix(10).map { value in
            guard let id = value["uid"] as? String, let name = value["name"] as? String,
                  let state = (value["readyState"] ?? value["state"]) as? String else { throw CloudAPIError.invalidResponse }
            let meta = value["meta"] as? [String: Any] ?? [:]
            return CloudDeployment(id: id, name: name, state: state.uppercased(),
                branch: (meta["githubCommitRef"] ?? meta["gitlabCommitRef"] ?? meta["bitbucketCommitRef"]) as? String ?? "",
                target: value["target"] as? String ?? "preview", createdAt: milliseconds(value["createdAt"] ?? value["created"]),
                url: safeLink(value["url"] as? String, bareHostname: true), inspectorURL: safeLink(value["inspectorUrl"] as? String, domain: "vercel.com"))
        }
    }

    public static func parseLogs(_ data: Data) throws -> String {
        guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CloudAPIError.invalidResponse }
        // The API returns the latest bounded page backwards; display it in reading order.
        let lines = values.prefix(200).reversed().compactMap { value -> String? in
            let payload = value["payload"] as? [String: Any]
            return (payload?["text"] ?? value["text"]) as? String
        }
        return String(lines.joined(separator: "\n").suffix(80_000))
    }

    public static func parseSentry(_ data: Data) throws -> [CloudIssue] {
        guard let values = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw CloudAPIError.invalidResponse }
        return try values.prefix(20).map { value in
            guard let id = value["id"] as? String, let title = value["title"] as? String,
                  let state = value["status"] as? String else { throw CloudAPIError.invalidResponse }
            return CloudIssue(id: id, identifier: value["shortId"] as? String ?? "", title: title, state: state,
                priority: value["priority"] as? String ?? value["level"] as? String ?? "error",
                eventCount: integer(value["count"]), userCount: integer(value["userCount"]),
                url: safeLink(value["permalink"] as? String, domain: "sentry.io"))
        }
    }

    public static func parseLinear(_ data: Data) throws -> [CloudIssue] {
        let object = try graphQLData(data)
        guard let viewer = object["viewer"] as? [String: Any], let assigned = viewer["assignedIssues"] as? [String: Any],
              let values = assigned["nodes"] as? [[String: Any]] else { throw CloudAPIError.invalidResponse }
        return try values.prefix(30).map { value in
            guard let id = value["id"] as? String, let title = value["title"] as? String,
                  let state = value["state"] as? [String: Any], let name = state["name"] as? String else { throw CloudAPIError.invalidResponse }
            return CloudIssue(id: id, identifier: value["identifier"] as? String ?? "", title: title, state: name,
                priority: value["priorityLabel"] as? String ?? "No priority", eventCount: nil, userCount: nil,
                url: safeLink(value["url"] as? String, domain: "linear.app"))
        }
    }

    private static func graphQLData(_ data: Data) throws -> [String: Any] {
        let object = try DeveloperTools.object(data)
        if let errors = object["errors"] as? [[String: Any]], !errors.isEmpty {
            let codes = errors.compactMap { ($0["extensions"] as? [String: Any])?["code"] as? String }
            if codes.contains("RATELIMITED") { throw CloudAPIError.rateLimited }
            if codes.contains("AUTHENTICATION_ERROR") || codes.contains("UNAUTHENTICATED") { throw CloudAPIError.unauthorized }
            throw CloudAPIError.invalidResponse
        }
        guard let data = object["data"] as? [String: Any] else { throw CloudAPIError.invalidResponse }
        return data
    }

    private static func integer(_ value: Any?) -> Int? { (value as? Int) ?? (value as? String).flatMap(Int.init) }
    private static func milliseconds(_ value: Any?) -> Date? {
        let number = (value as? Double) ?? (value as? String).flatMap(Double.init)
        return number.flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0 / 1000) : nil }
    }
}
