import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A table row as JSON.
public typealias Row = [String: Any]

/// Sends one web request. The app uses the phone's normal internet connection (URLSession);
/// tests can swap in something else.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        try await withCheckedThrowingContinuation { cont in
            URLSession.shared.dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: SupabaseError.network(error.localizedDescription)); return }
                guard let http = response as? HTTPURLResponse else { cont.resume(throwing: SupabaseError.network("No response")); return }
                cont.resume(returning: (data ?? Data(), http))
            }.resume()
        }
    }
}

public enum SupabaseError: Error, Equatable, LocalizedError {
    case network(String)
    case server(status: Int, code: String?, message: String)
    case notSignedIn
    case badResponse

    /// Messages a person can act on (same wording as the web app).
    public var errorDescription: String? {
        switch self {
        case .network: return "No connection. Your changes are saved on this phone and will sync later."
        case .notSignedIn: return "Please sign in first."
        case .badResponse: return "The server sent something unexpected. Try again later."
        case .server(_, _, let msg):
            let rules: [(String, String)] = [
                ("Invalid login credentials", "Wrong email or password."),
                ("already registered", "This email already has an account. Sign in instead."),
                ("already been registered", "This email already has an account. Sign in instead."),
                ("Password should be", "Password is too short (at least 6 characters)."),
                ("invite code not found", "That invite code was not found."),
                ("household is full", "That household already has two people."),
                ("already in a household", "This account is already in a household."),
                ("Email not confirmed", "Please confirm your email first (check your inbox), then sign in."),
            ]
            for (needle, friendly) in rules where msg.range(of: needle, options: .caseInsensitive) != nil { return friendly }
            return msg
        }
    }
}

/// A signed-in session. Kept in the phone's Keychain by the app.
public struct AuthSession: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Double
    public var userId: String
    public var email: String?
}

/// Where the session is remembered between app launches.
public protocol SessionKeeper: AnyObject {
    func load() -> AuthSession?
    func save(_ session: AuthSession?)
}

public final class MemorySessionKeeper: SessionKeeper {
    var session: AuthSession?
    public init() {}
    public func load() -> AuthSession? { session }
    public func save(_ session: AuthSession?) { self.session = session }
}

/// Talks to a Supabase project over its web API: sign-in, tables, functions and photo storage.
/// Only the parts the budget app needs.
public final class SupabaseClient: @unchecked Sendable {
    public let url: URL
    public let anonKey: String
    let transport: HTTPTransport
    let keeper: SessionKeeper
    public private(set) var session: AuthSession?
    public var now: () -> Date = Date.init

    public init(url: URL, anonKey: String, transport: HTTPTransport = URLSessionTransport(), keeper: SessionKeeper = MemorySessionKeeper()) {
        self.url = url
        self.anonKey = anonKey
        self.transport = transport
        self.keeper = keeper
        self.session = keeper.load()
    }

    // MARK: requests

    func request(_ method: String, _ path: String, query: [(String, String)] = [], json: Any? = nil, body: Data? = nil,
                 headers: [String: String] = [:], auth: Bool = true) async throws -> (Data, HTTPURLResponse) {
        var comps = URLComponents(url: url.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            comps.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
            // "+" in a time zone ("+00:00") must not turn into a space.
            comps.percentEncodedQuery = comps.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        }
        var req = URLRequest(url: comps.url!)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue(anonKey, forHTTPHeaderField: "apikey")
        if auth {
            let token = try await validAccessToken()
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else if anonKey.hasPrefix("eyJ") {
            // Old-style anon keys are tokens and go in both headers. New "sb_publishable_…" keys
            // are not tokens and must only be sent as apikey.
            req.setValue("Bearer \(anonKey)", forHTTPHeaderField: "Authorization")
        }
        if let json {
            req.httpBody = try JSONSerialization.data(withJSONObject: json)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        } else if let body {
            req.httpBody = body
        }
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, res) = try await transport.send(req)
        guard (200..<300).contains(res.statusCode) else { throw Self.error(status: res.statusCode, data: data) }
        return (data, res)
    }

    static func error(status: Int, data: Data) -> SupabaseError {
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        let msg = (obj["message"] ?? obj["msg"] ?? obj["error_description"] ?? obj["error"]) as? String
        let code = (obj["code"] as? String) ?? (obj["error_code"] as? String)
        return .server(status: status, code: code, message: msg ?? "Request failed (\(status)).")
    }

    func jsonValue(_ data: Data) throws -> Any {
        if data.isEmpty { return NSNull() }
        do { return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) } catch { throw SupabaseError.badResponse }
    }

    // MARK: sign-in

    public var userId: String? { session?.userId }

    func takeSession(_ data: Data) throws -> AuthSession? {
        guard let obj = try jsonValue(data) as? [String: Any] else { throw SupabaseError.badResponse }
        guard let access = obj["access_token"] as? String, let refresh = obj["refresh_token"] as? String,
              let user = obj["user"] as? [String: Any], let uid = user["id"] as? String else { return nil }
        let expiresIn = (obj["expires_in"] as? Double) ?? 3600
        let s = AuthSession(accessToken: access, refreshToken: refresh, expiresAt: now().timeIntervalSince1970 + expiresIn,
                            userId: uid, email: user["email"] as? String)
        session = s
        keeper.save(s)
        return s
    }

    /// Creates an account. Returns false when the project asks for an email confirmation first.
    @discardableResult
    public func signUp(email: String, password: String) async throws -> Bool {
        let (data, _) = try await request("POST", "auth/v1/signup", json: ["email": email, "password": password], auth: false)
        return try takeSession(data) != nil
    }

    public func signIn(email: String, password: String) async throws {
        let (data, _) = try await request("POST", "auth/v1/token", query: [("grant_type", "password")],
                                          json: ["email": email, "password": password], auth: false)
        guard try takeSession(data) != nil else { throw SupabaseError.badResponse }
    }

    public func signOut() async {
        if session != nil { _ = try? await request("POST", "auth/v1/logout") }
        session = nil
        keeper.save(nil)
    }

    /// The access token, renewed shortly before it runs out.
    func validAccessToken() async throws -> String {
        guard let s = session else { throw SupabaseError.notSignedIn }
        if s.expiresAt - now().timeIntervalSince1970 > 60 { return s.accessToken }
        do {
            let (data, _) = try await request("POST", "auth/v1/token", query: [("grant_type", "refresh_token")],
                                              json: ["refresh_token": s.refreshToken], auth: false)
            guard let fresh = try takeSession(data) else { throw SupabaseError.badResponse }
            return fresh.accessToken
        } catch SupabaseError.server(let status, _, _) where status == 400 || status == 401 {
            session = nil
            keeper.save(nil)
            throw SupabaseError.notSignedIn
        }
    }

    // MARK: tables

    /// Rows of a table. `filters` are PostgREST filters such as ("server_updated_at", "gt.2026-…").
    public func select(_ table: String, filters: [(String, String)] = [], order: String? = nil,
                       limit: Int? = nil, offset: Int? = nil) async throws -> [Row] {
        var q: [(String, String)] = [("select", "*")] + filters
        if let order { q.append(("order", order)) }
        if let limit { q.append(("limit", String(limit))) }
        if let offset { q.append(("offset", String(offset))) }
        let (data, _) = try await request("GET", "rest/v1/\(table)", query: q)
        guard let rows = try jsonValue(data) as? [Row] else { throw SupabaseError.badResponse }
        return rows
    }

    /// Inserts or updates rows by id. Returns the ids the server accepted.
    public func upsert(_ table: String, rows: [Row]) async throws -> [String] {
        let (data, _) = try await request("POST", "rest/v1/\(table)", query: [("on_conflict", "id"), ("select", "id")], json: rows,
                                          headers: ["Prefer": "resolution=merge-duplicates,return=representation"])
        guard let out = try jsonValue(data) as? [Row] else { throw SupabaseError.badResponse }
        return out.compactMap { $0["id"] as? String }
    }

    public func update(_ table: String, values: Row, whereColumn: String, equals value: String) async throws {
        _ = try await request("PATCH", "rest/v1/\(table)", query: [(whereColumn, "eq.\(value)")], json: values)
    }

    /// Calls a database function (create_household, join_household).
    public func rpc(_ name: String, _ params: Row) async throws -> Any {
        let (data, _) = try await request("POST", "rest/v1/rpc/\(name)", json: params)
        return try jsonValue(data)
    }

    /// PostgREST "in" filter for a list of ids.
    public static func inList(_ ids: [String]) -> String {
        "in.(" + ids.map { "\"\($0.replacingOccurrences(of: "\"", with: ""))\"" }.joined(separator: ",") + ")"
    }

    // MARK: photo storage

    func objectPath(_ bucket: String, _ path: String) -> String {
        "storage/v1/object/\(bucket)/\(path)"
    }

    public func upload(bucket: String, path: String, jpeg: Data) async throws {
        _ = try await request("POST", objectPath(bucket, path), body: jpeg,
                              headers: ["Content-Type": "image/jpeg", "x-upsert": "true", "cache-control": "max-age=3600"])
    }

    public func download(bucket: String, path: String) async throws -> Data {
        try await request("GET", "storage/v1/object/authenticated/\(bucket)/\(path)").0
    }

    public func remove(bucket: String, paths: [String]) async throws {
        _ = try await request("DELETE", "storage/v1/object/\(bucket)", json: ["prefixes": paths])
    }
}
