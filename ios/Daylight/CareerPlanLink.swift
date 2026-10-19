import Foundation

enum CareerDates {
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func label(_ value: String) -> String { date(value)?.formatted(date: .abbreviated, time: .shortened) ?? (value.isEmpty ? "未提及" : value) }
}
enum CareerPlanLink {
    static func reference(_ job: CareerAssistantJSON) -> String { job["planReference"].string.isEmpty ? job.id : job["planReference"].string }
    static func event(job: CareerAssistantJSON, existing: PlanEvent?) -> PlanEvent? {
        let interview = job["followUp"]["interview"]
        guard let start = CareerDates.date(interview["start"].string), let end = CareerDates.date(interview["end"].string), end > start else { return nil }
        let fingerprint = [interview["start"].string, interview["end"].string, interview["location"].string, interview["notes"].string].joined(separator: "\n")
        if let existing, existing.careerRevision == fingerprint { return existing }
        var value = existing ?? PlanEvent(title: "", start: start, end: end)
        value.title = "面试 · \(job["company"].string) · \(job["title"].string)"
        value.start = start; value.end = end; value.location = interview["location"].string
        value.notes = interview["notes"].string + "\n来自日常求职。改期请在求职跟进中修改。\n" + job["url"].string
        value.careerReference = reference(job); value.careerRevision = fingerprint
        return value
    }
}
