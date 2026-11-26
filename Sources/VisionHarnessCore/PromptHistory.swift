import Foundation

// MARK: - Prompt history (the harness's own, across every mode)
//
// Every prompt the user sends — in a chat, in code mode, on an agent thread,
// from an automation or the task queue — lands here with what came of it: how
// the turn ended, how long it took, and what it produced. One JSON file under
// the app-support folder, next to the conversations; it belongs to the
// installed harness, not to any project, and it is searchable from any mode
// (the Prompt History viewer, and the model's own `chat_search`/`harness_info`
// introspection tools).
//
// The per-chat timeline (`SessionVM.promptHistory`) stays the live, in-memory
// view; this is the durable, cross-mode ledger.

public struct PromptHistoryRecord: Codable, Identifiable, Hashable, Sendable {
    /// Which surface the prompt came from.
    public enum Mode: String, Codable, CaseIterable, Sendable {
        case chat, code, agent, automation
        public var label: String {
            switch self {
            case .chat: "Chat"
            case .code: "Code"
            case .agent: "Agent"
            case .automation: "Automation"
            }
        }
    }

    /// How the turn ended — mirrors the per-chat outcome chips.
    public enum Outcome: Codable, Hashable, Sendable {
        case working
        case completed(evidence: Int)
        case blocked(reason: String)
        case failed(reason: String)
        case stopped

        public var label: String {
            switch self {
            case .working: "working…"
            case .completed: "completed"
            case .blocked: "needs you"
            case .failed: "failed"
            case .stopped: "stopped"
            }
        }

        // MARK: Codable

        private enum CodingKeys: String, CodingKey { case kind, evidence, reason }
        private enum Kind: String, Codable { case working, completed, blocked, failed, stopped }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            switch try c.decode(Kind.self, forKey: .kind) {
            case .working: self = .working
            case .completed: self = .completed(evidence: try c.decodeIfPresent(Int.self, forKey: .evidence) ?? 0)
            case .blocked: self = .blocked(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
            case .failed: self = .failed(reason: try c.decodeIfPresent(String.self, forKey: .reason) ?? "")
            case .stopped: self = .stopped
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .working: try c.encode(Kind.working, forKey: .kind)
            case .completed(let evidence):
                try c.encode(Kind.completed, forKey: .kind)
                try c.encode(evidence, forKey: .evidence)
            case .blocked(let reason):
                try c.encode(Kind.blocked, forKey: .kind)
                try c.encode(reason, forKey: .reason)
            case .failed(let reason):
                try c.encode(Kind.failed, forKey: .kind)
                try c.encode(reason, forKey: .reason)
            case .stopped: try c.encode(Kind.stopped, forKey: .kind)
            }
        }
    }

    public let id: String
    public var chatID: String
    public var chatTitle: String
    public var mode: Mode
    public var text: String
    public var at: Date
    /// The turn-phase turn these results belong to (nil when it never phased).
    public var turnID: String?
    /// Wall-clock the turn took, seconds. Set when the turn ends.
    public var duration: TimeInterval?
    public var outcome: Outcome
    /// Names of files the turn changed (the artifacts it produced).
    public var changedFiles: [String]
    /// Names of attachments the prompt carried in.
    public var attachments: [String]
    /// The model that served the turn, when known.
    public var model: String?
    /// The attachments themselves, kept on disk (`AttachmentStore`), so a file or screenshot a prompt carried
    /// can be opened again from the history. Nil on records written before attachments were kept.
    public var attachmentFiles: [AttachmentReference]?

    public init(id: String = UUID().uuidString, chatID: String, chatTitle: String, mode: Mode,
                text: String, at: Date = .now, turnID: String? = nil, duration: TimeInterval? = nil,
                outcome: Outcome = .working, changedFiles: [String] = [], attachments: [String] = [],
                model: String? = nil, attachmentFiles: [AttachmentReference]? = nil) {
        self.id = id
        self.chatID = chatID
        self.chatTitle = chatTitle
        self.mode = mode
        self.text = text
        self.at = at
        self.turnID = turnID
        self.duration = duration
        self.outcome = outcome
        self.changedFiles = changedFiles
        self.attachments = attachments
        self.model = model
        self.attachmentFiles = attachmentFiles
    }
}

// MARK: - Reading the history: order, and getting it out

/// The order a list of prompts is shown or exported in.
public enum PromptHistorySort: String, CaseIterable, Sendable {
    case newestFirst, oldestFirst, longestFirst

    public var label: String {
        switch self {
        case .newestFirst: "Newest first"
        case .oldestFirst: "Oldest first"
        case .longestFirst: "Longest running"
        }
    }

    public func apply(_ records: [PromptHistoryRecord]) -> [PromptHistoryRecord] {
        switch self {
        case .newestFirst: records.sorted { $0.at > $1.at }
        case .oldestFirst: records.sorted { $0.at < $1.at }
        case .longestFirst: records.sorted { ($0.duration ?? -1, $0.at) > ($1.duration ?? -1, $1.at) }
        }
    }
}

/// A list of prompts as text someone can paste elsewhere and analyse: Markdown to read, CSV for a spreadsheet,
/// JSON for a script. Every form carries the timestamp (ISO 8601, with the time zone), the chat, the outcome, how
/// long the turn took, and the names and kept paths of what was attached.
public enum PromptHistoryExport {
    public enum Format: String, CaseIterable, Sendable {
        case markdown, csv, json

        public var label: String {
            switch self {
            case .markdown: "Markdown"
            case .csv: "CSV"
            case .json: "JSON"
            }
        }
        public var fileExtension: String {
            switch self {
            case .markdown: "md"
            case .csv: "csv"
            case .json: "json"
            }
        }
    }

    public static func render(_ records: [PromptHistoryRecord], as format: Format,
                              timeZone: TimeZone = .current) -> String {
        switch format {
        case .markdown: markdown(records, timeZone: timeZone)
        case .csv: csv(records, timeZone: timeZone)
        case .json: json(records, timeZone: timeZone)
        }
    }

    static func stamp(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = timeZone
        return formatter.string(from: date)
    }

    static func attachmentNames(_ record: PromptHistoryRecord) -> [String] {
        if let files = record.attachmentFiles, !files.isEmpty { return files.map(\.name) }
        return record.attachments
    }

    static func durationText(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds > 0 else { return "" }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        if whole < 3_600 { return "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3_600)h \((whole % 3_600) / 60)m"
    }

    public static func markdown(_ records: [PromptHistoryRecord], timeZone: TimeZone = .current) -> String {
        guard !records.isEmpty else { return "No prompts." }
        let chats = Set(records.map(\.chatID))
        var out: [String] = []
        if chats.count == 1, let title = records.first?.chatTitle {
            out.append("# Prompts — \(title)")
        } else {
            out.append("# Prompts — \(chats.count) chats")
        }
        out.append("\(records.count) prompt\(records.count == 1 ? "" : "s")")
        for (index, record) in records.enumerated() {
            var meta = [stamp(record.at, timeZone: timeZone), record.mode.label, record.outcome.label]
            let took = durationText(record.duration)
            if !took.isEmpty { meta.append(took) }
            if let model = record.model, !model.isEmpty { meta.append(model) }
            if chats.count > 1 { meta.append(record.chatTitle) }
            var block = "## \(index + 1). \(meta.joined(separator: " · "))\n\n\(record.text)"
            if let files = record.attachmentFiles, !files.isEmpty {
                block += "\n\nAttached:\n" + files.map { "- \($0.name)" + ($0.path.map { " — \($0)" } ?? "") }
                    .joined(separator: "\n")
            } else if !record.attachments.isEmpty {
                block += "\n\nAttached: " + record.attachments.joined(separator: ", ")
            }
            if !record.changedFiles.isEmpty {
                block += "\n\nChanged: " + record.changedFiles.joined(separator: ", ")
            }
            out.append(block)
        }
        return out.joined(separator: "\n\n") + "\n"
    }

    public static func csv(_ records: [PromptHistoryRecord], timeZone: TimeZone = .current) -> String {
        func cell(_ text: String) -> String {
            text.contains(where: { $0 == "," || $0 == "\"" || $0.isNewline })
                ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
        }
        var lines = ["timestamp,chat,mode,outcome,duration_seconds,model,attachments,changed_files,prompt"]
        for record in records {
            lines.append([
                stamp(record.at, timeZone: timeZone), record.chatTitle, record.mode.rawValue, record.outcome.label,
                record.duration.map { String(Int($0.rounded())) } ?? "", record.model ?? "",
                attachmentNames(record).joined(separator: "; "), record.changedFiles.joined(separator: "; "),
                record.text,
            ].map(cell).joined(separator: ","))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func json(_ records: [PromptHistoryRecord], timeZone: TimeZone = .current) -> String {
        let rows: [[String: Any]] = records.map { record in
            var row: [String: Any] = [
                "timestamp": stamp(record.at, timeZone: timeZone),
                "chat": record.chatTitle,
                "chat_id": record.chatID,
                "mode": record.mode.rawValue,
                "outcome": record.outcome.label,
                "prompt": record.text,
            ]
            if let duration = record.duration { row["duration_seconds"] = (duration * 10).rounded() / 10 }
            if let model = record.model { row["model"] = model }
            if let files = record.attachmentFiles, !files.isEmpty {
                row["attachments"] = files.map { file -> [String: Any] in
                    var entry: [String: Any] = ["name": file.name, "kind": file.kind.rawValue, "bytes": file.bytes]
                    if let path = file.path { entry["path"] = path }
                    return entry
                }
            } else if !record.attachments.isEmpty {
                row["attachments"] = record.attachments.map { ["name": $0] }
            }
            if !record.changedFiles.isEmpty { row["changed_files"] = record.changedFiles }
            return row
        }
        guard let data = try? JSONSerialization.data(withJSONObject: rows,
                                                     options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text + "\n"
    }
}

/// The durable prompt ledger. Thread-safe; one JSON document rewritten
/// atomically on change (records are small; even thousands of prompts stay
/// well under a megabyte).
public final class PromptHistoryStore: @unchecked Sendable {
    private let lock = NSLock()
    /// Writes happen here, one at a time, in the order they were asked for.
    private static let io = DispatchQueue(label: "vision.PromptHistory.io", qos: .utility)
    private let fileURL: URL?
    private var records: [PromptHistoryRecord]
    /// How many records to keep. The oldest fall off the front.
    public var capacity: Int

    public init(fileURL: URL?, capacity: Int = 5_000) {
        self.fileURL = fileURL
        self.capacity = capacity
        self.records = Self.load(from: fileURL)
    }

    public static func standard() -> PromptHistoryStore {
        PromptHistoryStore(fileURL: AppPaths.support.appendingPathComponent("prompt-history.json"))
    }

    private static func load(from url: URL?) -> [PromptHistoryRecord] {
        guard let url, let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([PromptHistoryRecord].self, from: data) else { return [] }
        return decoded
    }

    private func persistLocked() {
        guard let fileURL else { return }
        if records.count > capacity { records.removeFirst(records.count - capacity) }
        let capped = Array(records.suffix(capacity))
        let url = fileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(capped) {
            // Off the caller's thread (often the main actor), but in order: each write is a snapshot of the whole
            // ledger, and on a concurrent queue an older snapshot could land after a newer one — the record
            // was there after a restart, its outcome and duration were not.
            Self.io.async {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    // MARK: Writing

    /// A prompt was sent.
    @discardableResult
    public func add(_ record: PromptHistoryRecord) -> PromptHistoryRecord {
        lock.lock()
        records.append(record)
        if records.count > capacity { records.removeFirst(records.count - capacity) }
        persistLocked()
        lock.unlock()
        return record
    }

    /// The turn ended: stamp the outcome, duration and artifacts onto the
    /// record that carries `turnID` (the newest match wins).
    public func finish(turnID: String?, outcome: PromptHistoryRecord.Outcome,
                       duration: TimeInterval?, changedFiles: [String] = [], model: String? = nil) {
        guard let turnID, !turnID.isEmpty else { return }
        lock.lock()
        if let index = records.lastIndex(where: { $0.turnID == turnID }) {
            records[index].outcome = outcome
            if let duration, duration > 0 { records[index].duration = duration }
            if !changedFiles.isEmpty { records[index].changedFiles = changedFiles }
            if let model { records[index].model = model }
            persistLocked()
        }
        lock.unlock()
    }

    /// The same, for a record known by its own id (an automation's turn has no
    /// turn-phase id).
    public func finishRecord(id: String, outcome: PromptHistoryRecord.Outcome,
                             duration: TimeInterval?, changedFiles: [String] = []) {
        lock.lock()
        if let index = records.firstIndex(where: { $0.id == id }) {
            records[index].outcome = outcome
            if let duration, duration > 0 { records[index].duration = duration }
            if !changedFiles.isEmpty { records[index].changedFiles = changedFiles }
            persistLocked()
        }
        lock.unlock()
    }

    /// A chat's title changed: keep the ledger's titles in step.
    public func retitle(chatID: String, title: String) {
        lock.lock()
        var changed = false
        for i in records.indices where records[i].chatID == chatID && records[i].chatTitle != title {
            records[i].chatTitle = title
            changed = true
        }
        if changed { persistLocked() }
        lock.unlock()
    }

    // MARK: Reading

    public var all: [PromptHistoryRecord] {
        lock.withLock { records }
    }

    public var count: Int {
        lock.withLock { records.count }
    }

    /// Newest first. `query` matches the prompt text and the chat title;
    /// `mode` nil means every surface.
    public func search(query: String, mode: PromptHistoryRecord.Mode? = nil, chatID: String? = nil,
                       limit: Int = 200) -> [PromptHistoryRecord] {
        lock.withLock {
            let words = query.lowercased().split(separator: " ").map(String.init)
            return records.reversed().filter { record in
                guard mode == nil || record.mode == mode else { return false }
                guard chatID == nil || record.chatID == chatID else { return false }
                guard !words.isEmpty else { return true }
                let haystack = ([record.text, record.chatTitle] + record.attachments).joined(separator: " ").lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }.prefix(limit).map { $0 }
        }
    }

    /// One chat's prompts, oldest first.
    public func records(inChat chatID: String) -> [PromptHistoryRecord] {
        lock.withLock { records.filter { $0.chatID == chatID } }
    }

    public func record(withID id: String) -> PromptHistoryRecord? {
        lock.withLock { records.first { $0.id == id } }
    }
}
