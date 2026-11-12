import Foundation

/// The live usage request (docs/usage-live.md). The app sends it with URLSession, because Cloudflare
/// challenges the system Python and curl. The engine only decrypts the cookies (`usage-cookies`).
public enum LiveUsageClient {
    /// Sends one request. Injected, so tests run without the network.
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    /// URLSession with no cookie storage and no cache: nothing about the request is written to disk.
    public static let ephemeralConfiguration: URLSessionConfiguration = {
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.urlCache = nil
        c.timeoutIntervalForRequest = 15
        return c
    }()

    public static let urlSession: Transport = { request in
        try await URLSession(configuration: ephemeralConfiguration).data(for: request)
    }

    public static func request(org: String, cookie: String) -> URLRequest? {
        guard let path = org.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_"))),
              let url = URL(string: "https://claude.ai/api/organizations/\(path)/usage") else { return nil }
        var r = URLRequest(url: url)
        r.httpShouldHandleCookies = false
        r.setValue(cookie, forHTTPHeaderField: "Cookie")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        return r
    }

    /// The answer of claude.ai as usage: the `limits` list, one entry per bar of the Usage page.
    public static func parse(_ data: Data, status: Int) -> LiveAccountUsage {
        guard status == 200 else { return .failed("http-\(status)") }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .failed("not-json") }
        let limits = (json["limits"] as? [[String: Any]] ?? []).compactMap { l -> LiveLimit? in
            guard let kind = l["kind"] as? String, let percent = (l["percent"] as? NSNumber)?.doubleValue else { return nil }
            let model = (l["scope"] as? [String: Any])?["model"] as? [String: Any]
            return LiveLimit(kind: kind, percent: percent, resetsAt: (l["resets_at"] as? String).flatMap(epoch),
                             label: model?["display_name"] as? String)
        }
        return LiveAccountUsage(ok: true, limits: limits, error: nil)
    }

    /// Usage of each account. Accounts whose cookies failed keep that error and send no request.
    public static func fetch(_ cookies: [String: LiveCookies], transport: @escaping Transport = urlSession) async -> [String: LiveAccountUsage] {
        await withTaskGroup(of: (String, LiveAccountUsage).self) { group in
            for (id, c) in cookies {
                group.addTask {
                    guard c.ok, let org = c.org, let cookie = c.cookie else { return (id, .failed(c.error ?? "no-login")) }
                    guard let req = request(org: org, cookie: cookie) else { return (id, .failed("no-login")) }
                    do {
                        let (data, resp) = try await transport(req)
                        return (id, parse(data, status: (resp as? HTTPURLResponse)?.statusCode ?? 0))
                    } catch {
                        return (id, .failed("network"))
                    }
                }
            }
            var out: [String: LiveAccountUsage] = [:]
            for await (id, u) in group { out[id] = u }
            return out
        }
    }

    /// "2026-11-16T15:00:00.054311+00:00" as epoch seconds. claude.ai sends 6 digits of seconds
    /// fraction, which ISO8601DateFormatter does not read, so the fraction is dropped first.
    static func epoch(_ text: String) -> Double? {
        let plain = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: plain)?.timeIntervalSince1970
    }
}
