import Foundation

/// Optional query completions from the selected provider. There is no
/// shared cookie jar, credential store, disk cache or fallback provider.
enum SearchSuggestions {
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCredentialStorage = nil
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        // Suggestions cease to be useful after the user has moved on.
        config.timeoutIntervalForRequest = 3
        config.timeoutIntervalForResource = 3
        return URLSession(configuration: config)
    }()

    static func template(for engine: Engine) -> String? {
        // OpenSearch endpoints published by the providers and Firefox's
        // search configuration. Custom engines never inherit another one.
        switch engine {
        case .google: return "https://www.google.com/complete/search?client=firefox&q=%s"
        case .duckduckgo: return "https://ac.duckduckgo.com/ac/?type=list&q=%s"
        case .bing: return "https://www.bing.com/osjson.aspx?query=%s"
        case .ecosia: return "https://ac.ecosia.org/autocomplete?type=list&q=%s"
        case .qwant: return "https://api.qwant.com/api/suggest/?client=opensearch&q=%s"
        case .kagi: return "https://kagi.com/api/autosuggest?q=%s"
        case .brave: return "https://search.brave.com/api/suggest?q=%s"
        case .startpage, .custom: return nil
        }
    }

    static func accepts(_ query: String) -> Bool {
        // A partly typed address, email or pasted credential URL is not a
        // search. Keep it local even before Address can parse it as a URL.
        query.count >= 2 && Address.url(from: query) == nil
            && query.rangeOfCharacter(from: CharacterSet(charactersIn: ":/@\\?#").union(.controlCharacters)) == nil
    }

    static func fetch(_ query: String, engine: Engine) async throws -> [String] {
        guard accepts(query), let template = template(for: engine),
              var url = Engine.url(for: query, template: template) else { return [] }
        #if DEBUG
        // E2E tests exercise URLSession and real typing against a local
        // server. This override cannot send probe queries to a remote host.
        if Store.testing, let text = ProcessInfo.processInfo.environment["SEARCH_SUGGESTIONS_URL"],
           var parts = URLComponents(string: text), parts.scheme == "http", parts.host == "127.0.0.1" {
            parts.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "engine", value: engine.rawValue)]
            if let local = parts.url { url = local }
        }
        #endif
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (bytes, response) = try await session.bytes(for: request)
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return [] }
        // Observed provider replies are under 4 KiB. Allow 64 KiB for
        // Unicode and provider metadata, but stop an unbounded response.
        let limit = 64 * 1024
        if response.expectedContentLength > limit {
            throw ResponseBudget(limit: limit, requested: response.expectedContentLength)
        }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw ResponseBudget(limit: limit, requested: Int64(data.count + 1)) }
            data.append(byte)
        }
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [Any], reply.count >= 2,
              let echoed = reply[0] as? String, echoed.caseInsensitiveCompare(query) == .orderedSame,
              let phrases = reply[1] as? [String] else { return [] }
        var seen: Set<String> = [query.lowercased()]
        // Five completions plus the direct search keep the common case to
        // six rows. Local history remains ahead of these remote results.
        return phrases.compactMap { phrase in
            let clean = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty, clean.rangeOfCharacter(from: .controlCharacters) == nil,
                  seen.insert(clean.lowercased()).inserted else { return nil }
            return clean
        }.prefix(5).map { $0 }
    }

    private struct ResponseBudget: LocalizedError {
        let limit: Int
        let requested: Int64
        var errorDescription: String? {
            "Search suggestion response budget is \(limit) bytes; the response requested \(requested) bytes."
        }
    }
}
