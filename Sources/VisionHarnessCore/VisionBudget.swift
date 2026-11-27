import Foundation
import CryptoKit

// MARK: - Pictures in a request: how many fit, and what happens to the rest
//
// A vision model takes only so many pictures in one request. vLLM refuses the whole request past its
// `--limit-mm-per-prompt` (a Spark Swapper serves Inkling 2 Mini with 8, and vLLM's own default has been as low
// as 1), llama.cpp runs out of window, and every server slows down on megabytes of base64. A long chat collects
// pictures from three places: screenshots the user attached, PDFs turned into page images, and what the screen
// tools captured while driving the desktop. Left alone, the chat reaches the limit and every request after
// that is refused — it looks stuck.
//
// So before each request the harness decides which pictures travel:
//
//   1. what a tool captured last goes first — the screen being driven right now — sharing the room with
//   2. the pictures on the user's newest message, which are what is being asked about;
//   3. then the newest pictures before those, whoever made them, until the count or the token share is used;
//   4. everything older is rolled off: taken out of the request, kept on disk (`AttachmentStore`), and replaced
//      by a line that says what it was and where it is, so the model can ask for it again with `view_image`.
//
// The limit is the route's setting when it has one, otherwise a safe default, and it is corrected downward the
// first time a server says how many it really takes (`ImageLimit`).

public struct ImageBudget: Sendable, Equatable, Codable {
    /// The most pictures one request may carry. 0 sends none.
    public var maxImages: Int
    /// The most vision tokens the pictures may take together (nil: no token cap). One picture is always let
    /// through even when it alone is over the cap — refusing to show anything helps nobody.
    public var maxImageTokens: Int?

    /// What a route gets until it says otherwise. Eight is what a Spark Swapper's vLLM models are served with.
    public static let defaultMaxImages = 8
    /// The share of the context window pictures may take.
    public static let windowShare = 0.4

    public init(maxImages: Int = ImageBudget.defaultMaxImages, maxImageTokens: Int? = nil) {
        self.maxImages = max(0, maxImages)
        self.maxImageTokens = maxImageTokens
    }

    public static let standard = ImageBudget()

    /// The budget for a route: its picture limit (nil = the default) and a share of its context window.
    public static func forRoute(maxImages: Int?, contextWindow: Int?) -> ImageBudget {
        let tokens = contextWindow.flatMap { $0 > 0 ? Int(Double($0) * windowShare) : nil }
        return ImageBudget(maxImages: maxImages ?? defaultMaxImages, maxImageTokens: tokens)
    }
}

public enum ImageRollOff {
    public struct Report: Sendable, Equatable {
        /// Pictures still in the request.
        public var kept: Int
        /// Pictures taken out by this pass.
        public var rolledOff: Int
        public init(kept: Int, rolledOff: Int) {
            self.kept = kept
            self.rolledOff = rolledOff
        }
    }

    /// How many pictures the transcript would send as it stands.
    public static func imageCount(_ messages: [LLMMessage]) -> Int {
        messages.reduce(0) { $0 + ($1.attachments ?? []).filter { $0.kind == .image }.count }
    }

    /// Make the transcript fit `budget`, rolling the oldest pictures off. `store` keeps what is rolled off on disk
    /// so the note that replaces a picture can say where it is; without one the note names it only.
    @discardableResult
    public static func fit(_ messages: inout [LLMMessage], budget: ImageBudget,
                           store: AttachmentStore? = nil) -> Report {
        struct Slot { let message: Int; let attachment: Int; let tokens: Int }
        var slots: [Slot] = []
        for (m, message) in messages.enumerated() {
            for (a, attachment) in (message.attachments ?? []).enumerated() where attachment.kind == .image {
                slots.append(Slot(message: m, attachment: a, tokens: ImageSize.tokens(for: attachment.data)))
            }
        }
        guard !slots.isEmpty else { return Report(kept: 0, rolledOff: 0) }

        // The user's newest message: its pictures are the ask itself.
        let newestAsk = messages.lastIndex { $0.role == .user && $0.imageSource == nil }
        // What a tool captured last, after that ask: where the work stands right now (the screen being driven).
        let latestCapture = messages.lastIndex { $0.imageSource != nil && !($0.attachments ?? []).isEmpty }
            .flatMap { index in newestAsk.map { index > $0 } ?? true ? index : nil }
        let askHasPictures = slots.contains { $0.message == newestAsk }
        // The latest capture goes first, but takes at most half the room when the ask brought pictures too,
        // so neither a burst of frames nor a pile of attachments leaves the model blind to the other.
        let captureShare = askHasPictures ? max(1, (budget.maxImages + 1) / 2) : budget.maxImages
        let captureSlots = slots.filter { $0.message == latestCapture }
        let favoured = Set(captureSlots.suffix(captureShare).map(\.attachment))
        func rank(_ slot: Slot) -> Int {
            if slot.message == latestCapture, favoured.contains(slot.attachment) { return 0 }
            if slot.message == newestAsk { return 1 }
            return 2
        }
        // Within a rank: newest message first; a capture's later frames first (they show where things ended
        // up), the user's own pictures in the order they attached them.
        let ordered = slots.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            if ra != rb { return ra < rb }
            if a.message != b.message { return a.message > b.message }
            return a.message == newestAsk ? a.attachment < b.attachment : a.attachment > b.attachment
        }
        var keep = Set<[Int]>()
        var tokens = 0
        for slot in ordered {
            guard keep.count < budget.maxImages else { break }
            if let cap = budget.maxImageTokens, !keep.isEmpty, tokens + slot.tokens > cap { continue }
            keep.insert([slot.message, slot.attachment])
            tokens += slot.tokens
        }
        let dropped = slots.filter { !keep.contains([$0.message, $0.attachment]) }
        guard !dropped.isEmpty else { return Report(kept: slots.count, rolledOff: 0) }

        for (m, group) in Dictionary(grouping: dropped, by: \.message) {
            let all = messages[m].attachments ?? []
            let goneIndexes = Set(group.map(\.attachment))
            let gone = all.enumerated().filter { goneIndexes.contains($0.offset) }.map(\.element)
            let left = all.enumerated().filter { !goneIndexes.contains($0.offset) }.map(\.element)
            messages[m].attachments = left.isEmpty ? nil : left
            let note = rolledOffNote(gone, source: messages[m].imageSource, limit: budget.maxImages, store: store)
            if messages[m].imageSource != nil, left.isEmpty {
                // A tool's picture message with nothing left in it: the note is the whole message.
                messages[m].content = note
            } else {
                let body = messages[m].content ?? ""
                messages[m].content = body.isEmpty ? note : body + "\n\n" + note
            }
        }
        return Report(kept: slots.count - dropped.count, rolledOff: dropped.count)
    }

    /// The line that stands in for pictures taken out of the request.
    static func rolledOffNote(_ gone: [MessageAttachment], source: String?, limit: Int,
                              store: AttachmentStore?) -> String {
        let listed = gone.prefix(12).map { attachment -> String in
            if let url = store?.save(attachment) { return "\(attachment.name) → \(url.path)" }
            return attachment.name
        }.joined(separator: "; ")
        let more = gone.count > 12 ? "; and \(gone.count - 12) more" : ""
        let whose = source.map { "from \($0)" } ?? "the user attached"
        let why = limit > 0
            ? "this model takes \(limit) picture\(limit == 1 ? "" : "s") per request and newer ones needed the room"
            : "this model is not taking pictures"
        let how = store == nil
            ? "Ask for it again, or capture a fresh one, if you need to see it."
            : "If you need to see one again, call view_image with its path (or capture a fresh one)."
        return "[\(gone.count) earlier picture\(gone.count == 1 ? "" : "s") \(whose) rolled off: \(why). \(listed)\(more). \(how)]"
    }
}

// MARK: - What a server says about its picture limit

public enum ImageLimit {
    /// The limit a server's refusal names, when it names one:
    ///   vLLM            "At most 8 image(s) may be provided in one request."
    ///   older vLLM      "You set image=1 (or defaulted to 1) in `--limit-mm-per-prompt`, but found 3 items"
    ///   hosted APIs     "Too many images: a maximum of 20 images is allowed" / "up to 10 images"
    public static func parse(_ text: String) -> Int? {
        let patterns = [
            #"at most (\d+) image"#,
            #"image\s*=\s*(\d+)"#,
            #"maximum (?:of |number of images is |is )?(\d+) image"#,
            #"max(?:imum)? (?:number of )?images?(?: per (?:request|prompt|message))?(?: is|:)? (\d+)"#,
            #"up to (\d+) image"#,
            #"(?:only|limit of|exceeds the limit of) (\d+) image"#,
            #"(\d+) images? (?:is|are) (?:allowed|supported|the limit)"#,
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text), let number = Int(text[range]) else { continue }
            return number
        }
        return nil
    }

    /// Whether a refusal is about how many pictures the request carried (with or without a number).
    public static func isAboutImageCount(_ text: String) -> Bool {
        let t = text.lowercased()
        guard t.contains("image") || t.contains("multimodal") || t.contains("limit-mm-per-prompt")
                || t.contains("limit_mm_per_prompt") else { return false }
        if parse(text) != nil { return true }
        // Engines word it their own way (vLLM, SGLang, TensorFold, llama.cpp, TabbyAPI): any complaint that
        // pairs pictures with a quantity counts.
        return ["too many", "at most", "more than", "limit-mm-per-prompt", "limit_mm_per_prompt", "exceed",
                "maximum", "limit"].contains { t.contains($0) }
    }

    /// The server refused a request that carried `sent` pictures: the limit to use from now on, or nil when the
    /// refusal is about something else. With no number in it, half of what was sent (never below one).
    public static func learned(from error: Error, sent: Int) -> Int? {
        guard sent > 0, let text = refusalText(error), isAboutImageCount(text) else { return nil }
        if let stated = parse(text) { return stated < sent ? max(0, stated) : max(1, sent / 2) }
        return sent > 1 ? sent / 2 : nil
    }

    /// The body of a request the server turned down (4xx); nil for anything else.
    static func refusalText(_ error: Error) -> String? {
        guard let error = error as? LLMError else { return nil }
        switch error {
        case .http(let code, let body): return (400..<500).contains(code) ? body : nil
        case .rejected(let status, let message, let body, _):
            return (400..<500).contains(status) ? message + "\n" + body : nil
        default: return nil
        }
    }
}

// MARK: - Attachments kept on disk
//
// Every file and picture a prompt carried, and every picture rolled off a request, is kept here by content: the
// prompt history can open it again long after the chat scrolled on, and the model can be pointed back at a
// picture that no longer travels with the request. `<root>/<first 16 hex of SHA-256>-<name>`: the same bytes
// are stored once however often they are sent.

public final class AttachmentStore: @unchecked Sendable {
    public let root: URL
    private let lock = NSLock()

    public init(root: URL) {
        self.root = root
    }

    public static func standard() -> AttachmentStore {
        AttachmentStore(root: AppPaths.support.appendingPathComponent("attachments", isDirectory: true))
    }

    /// The file name an attachment is kept under.
    public static func fileName(for attachment: MessageAttachment) -> String {
        let digest = SHA256.hash(data: attachment.data).prefix(8).map { String(format: "%02x", $0) }.joined()
        let cleaned = String(attachment.name.map { character -> Character in
            character.isLetter || character.isNumber || "._-".contains(character) ? character : "-"
        }.suffix(80))
        return "\(digest)-\(cleaned.isEmpty ? "attachment" : cleaned)"
    }

    /// Where an attachment is (or would be) kept.
    public func url(for attachment: MessageAttachment) -> URL {
        root.appendingPathComponent(Self.fileName(for: attachment))
    }

    /// Keep the attachment; returns where it is. Nil only when the disk refuses.
    @discardableResult
    public func save(_ attachment: MessageAttachment) -> URL? {
        let url = url(for: attachment)
        lock.lock(); defer { lock.unlock() }
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try attachment.data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// A reference to a kept attachment, for the prompt history.
    public func reference(_ attachment: MessageAttachment) -> AttachmentReference {
        let saved = save(attachment)
        return AttachmentReference(name: attachment.name, kind: attachment.kind,
                                   bytes: attachment.data.count, path: saved?.path)
    }
}

/// What the prompt history remembers of an attachment: enough to show it and open it again.
public struct AttachmentReference: Codable, Hashable, Sendable, Identifiable {
    public var name: String
    public var kind: MessageAttachment.Kind
    public var bytes: Int
    /// Where the bytes are kept (`AttachmentStore`); nil when they couldn't be kept.
    public var path: String?

    public var id: String { (path ?? "") + "|" + name }

    public init(name: String, kind: MessageAttachment.Kind, bytes: Int, path: String?) {
        self.name = name
        self.kind = kind
        self.bytes = bytes
        self.path = path
    }

    /// The kept file, when it is still there.
    public var url: URL? {
        guard let path, FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    public var isImage: Bool { kind == .image }
}
