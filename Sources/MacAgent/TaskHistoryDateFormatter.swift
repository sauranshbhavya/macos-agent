import Foundation

/// "Today, 3:04 PM", "Yesterday, 9:12 AM", or "Sep 3": how Insights and Memory date an entry.
enum TaskHistoryDateFormatter {
    static func relativeTimestamp(
        for date: Date,
        now: Date,
        calendar: Calendar = .current
    ) -> String {
        let time = timeFormatter.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today, \(time)"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        return dateFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()
}

extension String {
    /// Capitalizes only the first character. `.capitalized` would title-case every word of a
    /// typed command sentence.
    var sentenceCapitalized: String {
        guard let first else { return self }
        return first.uppercased() + dropFirst()
    }

    /// Breaks at the last space before `maxLength` rather than mid-word, for a one-line row.
    func truncatedForRowDisplay(maxLength: Int = 60) -> String {
        guard count > maxLength else { return self }
        let prefix = self.prefix(maxLength)
        if let lastSpace = prefix.lastIndex(of: " ") {
            return String(prefix[..<lastSpace]) + "…"
        }
        return String(prefix) + "…"
    }
}
