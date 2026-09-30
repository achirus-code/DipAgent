import Foundation

enum APIError: LocalizedError {
    case invalidURL
    case unauthorized
    /// The agent answered 404 for a route it doesn't have – it runs an older version than this app expects.
    case outdatedAgent
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return String(localized: "Invalid agent address")
        case .unauthorized: return String(localized: "Invalid token – please check the settings")
        case .outdatedAgent: return String(localized: "The agent doesn't know this function yet – update the agent (add-on or Docker image) to the latest version.")
        case .http(let code, let message): return message.isEmpty ? String(localized: "Agent error (\(String(code)))") : message
        }
    }
}

struct APIClient {
    /// Default DipAgent agent port – used whenever the address has no explicit port.
    static let defaultPort = 3470

    let baseURL: URL
    let token: String

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.waitsForConnectivity = false
        return URLSession(configuration: config)
    }()

    init(server: String, token: String) throws {
        var raw = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.isEmpty { throw APIError.invalidURL }
        let explicitHTTPS = raw.lowercased().hasPrefix("https://")
        if !raw.contains("://") { raw = "http://" + raw }
        while raw.hasSuffix("/") { raw.removeLast() }
        guard var components = URLComponents(string: raw), components.host != nil else { throw APIError.invalidURL }
        // "192.168.1.10" → http://192.168.1.10:3470; https addresses (reverse proxy) keep their standard port
        if components.port == nil && !explicitHTTPS {
            components.port = Self.defaultPort
        }
        guard let url = components.url else { throw APIError.invalidURL }
        baseURL = url
        self.token = token
    }

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await request("GET", path, query: query, body: Optional<BotInput>.none)
    }

    func post<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        try await request("POST", path, query: query, body: Optional<BotInput>.none)
    }

    func send<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B) async throws -> T {
        try await request(method, path, body: body)
    }

    func delete(_ path: String, query: [String: String] = [:]) async throws {
        _ = try await raw("DELETE", path, query: query, body: nil)
    }

    /// Downloads a file (e.g. a backup); returns the bytes and the file name the agent suggests.
    func download(_ path: String) async throws -> (Data, String?) {
        let (data, response) = try await perform("GET", path, query: [:], body: nil, contentType: nil)
        let disposition = response?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let name = disposition.split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix("filename=") }?
            .dropFirst("filename=".count)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return (data, name.flatMap { $0.isEmpty ? nil : $0 })
    }

    /// Uploads a file as the request body (e.g. a backup to restore).
    func upload<T: Decodable>(_ path: String, data: Data, contentType: String) async throws -> T {
        let (response, _) = try await perform("POST", path, query: [:], body: data, contentType: contentType)
        return try JSONDecoder().decode(T.self, from: response)
    }

    private func request<T: Decodable, B: Encodable>(
        _ method: String, _ path: String, query: [String: String] = [:], body: B?
    ) async throws -> T {
        let data = try await raw(method, path, query: query, body: try body.map { try JSONEncoder().encode($0) })
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func raw(_ method: String, _ path: String, query: [String: String], body: Data?) async throws -> Data {
        try await perform(method, path, query: query, body: body, contentType: "application/json").0
    }

    private func perform(
        _ method: String, _ path: String, query: [String: String], body: Data?, contentType: String?
    ) async throws -> (Data, HTTPURLResponse?) {
        guard var components = URLComponents(url: baseURL.appendingPathComponent("api" + path), resolvingAgainstBaseURL: false)
        else { throw APIError.invalidURL }
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(AppLanguage.current, forHTTPHeaderField: "Accept-Language") // agent answers in the app's language
        if let body {
            req.httpBody = body
            req.setValue(contentType ?? "application/octet-stream", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await Self.session.data(for: req)
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(code) else {
            let detail = Self.detail(from: data)
            // FastAPI's plain "Not Found" means the route itself is missing (our own 404s carry a translated message)
            if code == 404, detail == "Not Found" { throw APIError.outdatedAgent }
            throw APIError.http(code, detail)
        }
        return (data, http)
    }

    /// FastAPI errors look like {"detail": "..."} or {"detail": [{"msg": "..."}]}.
    private static func detail(from data: Data) -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        if let s = obj["detail"] as? String { return s }
        if let list = obj["detail"] as? [[String: Any]] {
            return list.compactMap { $0["msg"] as? String }.joined(separator: "\n")
        }
        return ""
    }
}
