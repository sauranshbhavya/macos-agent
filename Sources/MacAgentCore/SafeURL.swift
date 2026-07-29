import Foundation

public enum SafeURLError: Error, LocalizedError, Equatable {
    case missingURL
    case invalidURL(String)
    case unsupportedScheme(String)
    case privateHostBlocked(String)

    public var errorDescription: String? {
        switch self {
        case .missingURL:
            return "Opening a URL requires a URL."
        case .invalidURL(let rawURL):
            return "\(rawURL) is not a valid URL."
        case .unsupportedScheme(let scheme):
            return "Only http and https URLs can be opened, not \(scheme)."
        case .privateHostBlocked(let host):
            return "\(host) is a private, local, or link-local address, which Sonny will not open or fetch."
        }
    }
}

public enum SafeURL {
    public static func validateWebURL(_ rawURL: String?) throws -> URL {
        guard let rawURL, !rawURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SafeURLError.missingURL
        }

        let trimmed = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(), let host = url.host else {
            throw SafeURLError.invalidURL(trimmed)
        }

        guard scheme == "http" || scheme == "https" else {
            throw SafeURLError.unsupportedScheme(scheme)
        }

        guard !isPrivateOrLocalHost(host) else {
            throw SafeURLError.privateHostBlocked(host)
        }

        return url
    }

    /// Blocks loopback, RFC1918/link-local/CGNAT ranges, and local-network hostnames so a URL
    /// the planner or a web page supplied can never point Sonny's fetches or opens at services
    /// on this machine or the local network. Checks literal hosts only — DNS resolution (and
    /// therefore DNS rebinding) is deliberately out of scope here.
    static func isPrivateOrLocalHost(_ rawHost: String) -> Bool {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host.isEmpty || host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") {
            return true
        }

        // IPv6 literals.
        if host == "::" || host == "::1" || host.hasPrefix("fe80:") || host.hasPrefix("fc") || host.hasPrefix("fd") {
            return true
        }
        if host.hasPrefix("::ffff:") {
            return isPrivateOrLocalHost(String(host.dropFirst("::ffff:".count)))
        }

        // Single-integer IPv4 form, e.g. http://2130706433/ == 127.0.0.1.
        if let numeric = UInt32(host) {
            return isPrivateIPv4(
                UInt8(truncatingIfNeeded: numeric >> 24),
                UInt8(truncatingIfNeeded: numeric >> 16)
            )
        }

        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            return isPrivateIPv4(octets[0], octets[1])
        }

        return false
    }

    private static func isPrivateIPv4(_ first: UInt8, _ second: UInt8) -> Bool {
        switch first {
        case 0, 10, 127:
            return true
        case 169:
            return second == 254
        case 172:
            return (16...31).contains(second)
        case 192:
            return second == 168
        case 100:
            return (64...127).contains(second)
        default:
            return false
        }
    }
}
