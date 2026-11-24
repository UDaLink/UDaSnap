import Foundation

/// Stable identity for an AI endpoint + model consent record.
/// Query parameters are intentionally excluded because they may contain temporary tokens.
package enum AIConsentKey {
    package static func make(for settings: AISettings) -> String {
        let raw = settings.trimmedBaseURL
        let model = settings.trimmedModel
        guard let components = URLComponents(string: raw),
            let scheme = components.scheme?.lowercased(),
            let host = components.host?.lowercased()
        else {
            var fallback = raw
            while fallback.hasSuffix("/") { fallback.removeLast() }
            return "\(fallback)|\(model)"
        }

        var endpoint = "\(scheme)://\(host)"
        if let port = components.port {
            endpoint += ":\(port)"
        }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        endpoint += path
        return "\(endpoint)|\(model)"
    }

    package static func displayHost(for baseURL: String) -> String {
        guard let components = URLComponents(string: baseURL),
            let host = components.host,
            !host.isEmpty
        else {
            return baseURL.isEmpty ? "未配置" : baseURL
        }
        var value = "\(components.scheme ?? "https")://\(host)"
        if let port = components.port {
            value += ":\(port)"
        }
        return value
    }
}
