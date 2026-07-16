import Foundation

public struct TaskHistorySection: Equatable, Sendable, Identifiable {
    public var title: String
    public var records: [CompletedTaskRecord]

    public init(title: String, records: [CompletedTaskRecord]) {
        self.title = title
        self.records = records
    }

    public var id: String { title }
}

public enum TaskHistoryGrouping {
    public static func groupedByOutcome(records: [CompletedTaskRecord]) -> [TaskHistorySection] {
        [
            TaskHistorySection(title: "Completed", records: records.filter { $0.outcomeStatus == .completed }),
            TaskHistorySection(title: "Failed", records: records.filter { $0.outcomeStatus == .failed }),
            TaskHistorySection(title: "Canceled", records: records.filter { $0.outcomeStatus == .canceled })
        ].filter { !$0.records.isEmpty }
    }
}
