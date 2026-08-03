import Foundation

public struct HackerNewsHeadline: Codable, Equatable, Sendable {
    public var title: String
    public var url: String?

    public init(title: String, url: String? = nil) {
        self.title = title
        self.url = url
    }
}

@MainActor
public protocol HackerNewsFetching {
    func topHeadlines(limit: Int) async throws -> [HackerNewsHeadline]
}

public enum HackerNewsError: Error, LocalizedError, Equatable {
    case invalidResponse
    case noHeadlines

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Hacker News returned an invalid response."
        case .noHeadlines:
            return "No Hacker News headlines were found."
        }
    }
}

public struct HackerNewsAPIClient: HackerNewsFetching {
    private let session: URLSession
    private let baseURL: URL

    public init(
        session: URLSession = .shared,
        baseURL: URL = URL(string: "https://hacker-news.firebaseio.com/v0")!
    ) {
        self.session = session
        self.baseURL = baseURL
    }

    public func topHeadlines(limit: Int) async throws -> [HackerNewsHeadline] {
        let topURL = baseURL.appendingPathComponent("topstories.json")
        let (data, response) = try await session.data(from: topURL)
        guard (response as? HTTPURLResponse)?.statusCode ?? 0 == 200 else {
            throw HackerNewsError.invalidResponse
        }

        let ids = try JSONDecoder().decode([Int].self, from: data)
        var headlines: [HackerNewsHeadline] = []
        for id in ids.prefix(max(limit, 0)) {
            let itemURL = baseURL.appendingPathComponent("item/\(id).json")
            let (itemData, itemResponse) = try await session.data(from: itemURL)
            guard (itemResponse as? HTTPURLResponse)?.statusCode ?? 0 == 200 else {
                continue
            }
            guard let item = try? JSONDecoder().decode(HackerNewsItem.self, from: itemData),
                  let title = item.title,
                  !title.isEmpty else {
                continue
            }
            headlines.append(HackerNewsHeadline(title: title, url: item.url))
        }

        guard !headlines.isEmpty else {
            throw HackerNewsError.noHeadlines
        }
        return headlines
    }

    private struct HackerNewsItem: Codable {
        var title: String?
        var url: String?
    }
}

public enum MarkdownWriter {
    public static func hackerNewsMarkdown(headlines: [HackerNewsHeadline], date: Date = Date()) -> String {
        var lines = [
            "# Hacker News Top \(headlines.count)",
            "",
            "Generated: \(ISO8601DateFormatter().string(from: date))",
            ""
        ]

        for (index, headline) in headlines.enumerated() {
            if let url = headline.url, !url.isEmpty {
                lines.append("\(index + 1). [\(escape(headline.title))](\(url))")
            } else {
                lines.append("\(index + 1). \(escape(headline.title))")
            }
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }
}
