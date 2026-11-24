import Foundation

/// Allows HTTPS everywhere; plain HTTP only on loopback or a local network.
/// This keeps API keys and screenshots from being sent in clear text to the public internet.
package enum AIEndpointPolicy {
    package static func allows(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), let host = url.host, !host.isEmpty else {
            return false
        }
        switch scheme {
        case "https":
            return true
        case "http":
            return isLocalHost(host)
        default:
            return false
        }
    }

    package static func isLocalHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower == "::1" || lower == "127.0.0.1" {
            return true
        }
        if lower.hasSuffix(".local") {
            return true
        }

        let parts = lower.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
            return false
        }
        if parts[0] == 127 || parts[0] == 10 || (parts[0] == 169 && parts[1] == 254) {
            return true
        }
        if parts[0] == 172, (16...31).contains(parts[1]) {
            return true
        }
        return parts[0] == 192 && parts[1] == 168
    }

    package static func httpRejectionMessage(for url: URL) -> String? {
        guard url.scheme?.lowercased() == "http" else {
            return nil
        }
        guard let host = url.host, !isLocalHost(host) else {
            return nil
        }
        return "为保护 API Key 和截图，远程 HTTP 接口已禁用；请改用 HTTPS，HTTP 仅允许 localhost 或局域网地址。"
    }
}
