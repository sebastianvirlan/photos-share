import Foundation

// What the Mac's sharing server sends (see src/photos_share/server.py).

struct ServerInfo: Decodable {
    let app: String
    let api: Int
    let downloads: Bool
    let video: String
}

struct LibrarySummary: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let state: String
    let available: Bool
    let rev: Int
    let count: Int?
    let cover: String?
    let first: String?
    let last: String?
}

struct LibraryDetail: Decodable {
    let id: String
    let name: String
    let rev: Int
    let downloads: Bool
    let assets: [Asset]
    let albums: [Album]
    let people: [Person]
}

/// One photo or video. Short keys keep the payload small for big libraries.
struct Asset: Decodable, Identifiable, Hashable {
    let u: String
    let d: String
    let w: Int
    let h: Int
    let m: Bool
    let l: Bool
    let e: Bool
    let nf: Bool?
    let no: Bool?
    let f: Bool?
    let k: String?
    let ss: Bool?
    let g: [Double]?
    let pl: String?
    let p: [Int]?
    let hd: Bool?

    var id: String { u }
    var isVideo: Bool { m }
    var isLive: Bool { l }
    var isFavorite: Bool { f ?? false }
    var isHidden: Bool { hd ?? false }
    var hasFile: Bool { !(nf ?? false) }
    var place: String? { pl }
    var aspect: CGFloat { w > 0 && h > 0 ? CGFloat(w) / CGFloat(h) : 1 }

    var date: Date? { Asset.parse(d) }

    private static let iso = ISO8601DateFormatter()
    private static let local: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()

    /// Python's isoformat(): "2023-05-01T10:00:00.123456+03:00", the fraction and the offset
    /// both optional. The fraction (microseconds) is dropped; seconds are plenty here.
    static func parse(_ s: String) -> Date? {
        let plain = s.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return iso.date(from: plain) ?? local.date(from: plain)
    }
}

struct Album: Decodable, Identifiable, Hashable {
    let title: String
    let uuids: [String]   // oldest first
    let cover: String?
    var id: String { title }
}

struct Face: Decodable, Hashable {
    let u: String
    let x: Double
    let y: Double
    let s: Double
}

struct Person: Decodable, Identifiable, Hashable {
    let name: String
    let face: Face?
    let count: Int
    var id: String { name }
}

enum APIError: LocalizedError {
    case badAddress
    case notPhotosShare
    case needsPassword
    case wrongPassword
    case server(String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .badAddress: "That doesn’t look like a web address."
        case .notPhotosShare: "Something answered at that address, but it isn’t a Photos Share link."
        case .needsPassword: "This share needs its password."
        case .wrongPassword: "Wrong password."
        case .server(let m): m
        case .http(let c): "The Mac answered with an error (\(c))."
        }
    }
}

/// Talks to one sharing server. The token is the password-based session the server hands out;
/// it's sent as a Bearer header (and as the browser cookie to the video player).
struct API: Sendable {
    let base: URL
    let token: String?

    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        // Thumbnails and photos come with long cache lifetimes, so this keeps them on the phone.
        c.urlCache = URLCache(memoryCapacity: 64 << 20, diskCapacity: 1 << 30)
        c.requestCachePolicy = .useProtocolCachePolicy
        c.timeoutIntervalForRequest = 30
        c.httpMaximumConnectionsPerHost = 6
        return URLSession(configuration: c)
    }()

    /// Turns what the user typed ("name.ts.net:8080", a pasted link…) into the server's base URL.
    static func normalise(_ typed: String) -> URL? {
        var s = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        // Without a scheme: a port means the private (Tailscale) link, which is plain http;
        // the public link has no port and is https.
        if !s.contains("://") {
            let hostPart = s.split(separator: "/").first.map(String.init) ?? s
            s = (hostPart.contains(":") ? "http://" : "https://") + s
        }
        guard var c = URLComponents(string: s), let host = c.host, !host.isEmpty,
              c.scheme == "http" || c.scheme == "https" else { return nil }
        c.path = ""; c.query = nil; c.fragment = nil
        return c.url
    }

    func url(_ path: String) -> URL { URL(string: path, relativeTo: base)!.absoluteURL }

    func request(_ path: String) -> URLRequest { request(url: url(path)) }

    func request(url: URL) -> URLRequest {
        var r = URLRequest(url: url)
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return r
    }

    /// The cookie the server also accepts, for AVPlayer (which can't be given headers officially).
    var cookie: HTTPCookie? {
        guard let token, let host = base.host() else { return nil }
        return HTTPCookie(properties: [.name: "ps_session", .value: token, .domain: host, .path: "/"])
    }

    func data(_ path: String) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await API.session.data(for: request(path))
        guard let http = resp as? HTTPURLResponse else { throw APIError.http(0) }
        return (data, http)
    }

    func get<T: Decodable>(_ path: String, as: T.Type = T.self) async throws -> T {
        let (data, http) = try await data(path)
        if http.statusCode == 401 { throw APIError.needsPassword }
        guard http.statusCode == 200 else { throw APIError.http(http.statusCode) }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func info() async throws -> ServerInfo {
        do {
            let info: ServerInfo = try await get("/api/info")
            guard info.app == "photos-share" else { throw APIError.notPhotosShare }
            return info
        } catch is DecodingError {
            throw APIError.notPhotosShare
        }
    }

    func login(password: String) async throws -> String {
        var r = URLRequest(url: url("/api/login"))
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try JSONEncoder().encode(["password": password])
        let (data, resp) = try await API.session.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if code == 200, let token = body?["token"] as? String { return token }
        // A Mac from before the app login refuses this request like any other ("login
        // required"), which isn't the same as a wrong password.
        if code == 401, body?["error"] as? String == "login required" || code == 404 {
            throw APIError.server("The Mac’s Photos Share is too old for this app. On the Mac: update it (git pull && scripts/build-app.sh), then stop and start sharing.")
        }
        if code == 401 { throw APIError.wrongPassword }
        if let message = body?["error"] as? String { throw APIError.server(message) }
        throw APIError.http(code)
    }

    func libraries() async throws -> [LibrarySummary] { try await get("/api/libraries") }

    enum LibraryState { case ready(LibraryDetail), opening, unavailable, failed(String) }

    func library(_ id: String) async throws -> LibraryState {
        let (data, http) = try await data("/api/libraries/\(id)")
        switch http.statusCode {
        case 200: return .ready(try JSONDecoder().decode(LibraryDetail.self, from: data))
        case 202: return .opening
        case 503: return .unavailable
        case 401: throw APIError.needsPassword
        default:
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            return .failed(body?["error"] as? String ?? "The Mac couldn’t open this library.")
        }
    }

    func videoReady(_ lib: String, _ uuid: String) async throws -> String {
        struct S: Decodable { let state: String }
        return try await get("/video-status/\(lib)/\(uuid)", as: S.self).state
    }

    func thumbURL(_ lib: String, _ uuid: String) -> URL { url("/thumb/\(lib)/\(uuid)") }
    func photoURL(_ lib: String, _ uuid: String) -> URL { url("/photo/\(lib)/\(uuid)") }
    func videoURL(_ lib: String, _ uuid: String) -> URL { url("/video/\(lib)/\(uuid)") }
    func liveURL(_ lib: String, _ uuid: String) -> URL { url("/live/\(lib)/\(uuid)") }
}
