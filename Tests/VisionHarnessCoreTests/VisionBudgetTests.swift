import XCTest
import CoreGraphics
import CoreText
@testable import VisionHarnessCore

final class VisionBudgetTests: XCTestCase {

    /// A 1×1 PNG header is enough for the size reader; the bytes differ per name so each picture is distinct.
    private func picture(_ name: String) -> MessageAttachment {
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
                              0, 0, 0, 64, 0, 0, 0, 64, 8, 2, 0, 0, 0]
        bytes.append(contentsOf: Array(name.utf8))
        return MessageAttachment(kind: .image, name: name, data: Data(bytes))
    }

    private func capture(_ names: [String], by tool: String = "screenshot") -> LLMMessage {
        LLMMessage(role: .user, content: "[Automatic message: captured]",
                   attachments: names.map(picture), imageSource: tool)
    }

    private func names(_ messages: [LLMMessage]) -> [String] {
        messages.flatMap { ($0.attachments ?? []).map(\.name) }
    }

    // MARK: Roll-off

    func testUnderTheLimitNothingMoves() {
        var messages: [LLMMessage] = [.user("look", attachments: [picture("a.png"), picture("b.png")])]
        let report = ImageRollOff.fit(&messages, budget: ImageBudget(maxImages: 8))
        XCTAssertEqual(report, .init(kept: 2, rolledOff: 0))
        XCTAssertEqual(messages[0].content, "look")
    }

    func testOldestPicturesRollOffAndAreNamed() {
        var messages: [LLMMessage] = [
            .user("first", attachments: [picture("old1.png"), picture("old2.png")]),
            .assistant("ok"),
            .user("second", attachments: [picture("new1.png"), picture("new2.png")]),
        ]
        let report = ImageRollOff.fit(&messages, budget: ImageBudget(maxImages: 3))
        XCTAssertEqual(report, .init(kept: 3, rolledOff: 1))
        // The ask keeps both of its pictures; of the older pair, the later one stays.
        XCTAssertEqual(names(messages), ["old2.png", "new1.png", "new2.png"])
        XCTAssertTrue(messages[0].content?.hasPrefix("first") == true)
        XCTAssertTrue(messages[0].content?.contains("old1.png") == true, "the note names what rolled off")
        XCTAssertTrue(messages[0].content?.contains("3 pictures per request") == true)
    }

    func testTheLatestCaptureIsNeverStarvedByTheAsk() {
        // Eight attached pictures and a limit of eight: a screenshot taken afterwards must still be seen.
        var messages: [LLMMessage] = [
            .user("compare these", attachments: (1...8).map { picture("ask\($0).png") }),
            .assistant("looking"),
            capture(["screen.png"]),
        ]
        let report = ImageRollOff.fit(&messages, budget: ImageBudget(maxImages: 8))
        XCTAssertEqual(report.kept, 8)
        XCTAssertTrue(names(messages).contains("screen.png"))
        XCTAssertEqual(names(messages).filter { $0.hasPrefix("ask") }.count, 7)
    }

    func testABurstOfFramesLeavesRoomForTheAsk() {
        var messages: [LLMMessage] = [
            .user("what is on this page?", attachments: [picture("ask.png")]),
            .assistant("watching"),
            capture((1...12).map { "frame-\($0).png" }, by: "watch_screen"),
        ]
        ImageRollOff.fit(&messages, budget: ImageBudget(maxImages: 4))
        let kept = names(messages)
        XCTAssertEqual(kept.count, 4)
        XCTAssertTrue(kept.contains("ask.png"))
        // The last frames are the ones that show where things ended up.
        XCTAssertTrue(kept.contains("frame-12.png"))
        XCTAssertFalse(kept.contains("frame-1.png"))
    }

    func testOlderCapturesGoBeforeNewerOnes() {
        var messages: [LLMMessage] = [
            .user("drive the app"),
            capture(["s1.png"]), capture(["s2.png"]), capture(["s3.png"]),
        ]
        ImageRollOff.fit(&messages, budget: ImageBudget(maxImages: 2))
        XCTAssertEqual(names(messages), ["s2.png", "s3.png"])
        XCTAssertNil(messages[1].attachments)
        XCTAssertTrue(messages[1].content?.contains("rolled off") == true)
        XCTAssertTrue(messages[1].content?.contains("from screenshot") == true)
    }

    func testALimitOfOneKeepsTheNewestCapture() {
        var messages: [LLMMessage] = [
            .user("look", attachments: [picture("ask.png")]),
            capture(["s1.png"]), capture(["s2.png"]),
        ]
        ImageRollOff.fit(&messages, budget: ImageBudget(maxImages: 1))
        XCTAssertEqual(names(messages), ["s2.png"])
    }

    func testZeroSendsNoPictures() {
        var messages: [LLMMessage] = [.user("look", attachments: [picture("a.png")])]
        let report = ImageRollOff.fit(&messages, budget: ImageBudget(maxImages: 0))
        XCTAssertEqual(report, .init(kept: 0, rolledOff: 1))
        XCTAssertNil(messages[0].attachments)
        XCTAssertTrue(messages[0].content?.contains("not taking pictures") == true)
    }

    func testFilesAreNotCountedAsPictures() {
        let file = MessageAttachment(kind: .file, name: "notes.txt", data: Data("hi".utf8))
        var messages: [LLMMessage] = [.user("read", attachments: [file, picture("a.png"), picture("b.png")])]
        ImageRollOff.fit(&messages, budget: ImageBudget(maxImages: 1))
        XCTAssertEqual(names(messages), ["notes.txt", "a.png"])
    }

    func testTheTokenShareIsHonouredButOnePictureAlwaysGoes() {
        var messages: [LLMMessage] = [.user("look", attachments: [picture("a.png"), picture("b.png"), picture("c.png")])]
        // Each 64×64 picture costs 64 tokens (the floor): a cap of 100 fits one, and never zero.
        ImageRollOff.fit(&messages, budget: ImageBudget(maxImages: 8, maxImageTokens: 100))
        XCTAssertEqual(names(messages), ["a.png"])
        var tiny: [LLMMessage] = [.user("look", attachments: [picture("a.png")])]
        ImageRollOff.fit(&tiny, budget: ImageBudget(maxImages: 8, maxImageTokens: 1))
        XCTAssertEqual(names(tiny), ["a.png"])
    }

    func testRolledOffPicturesAreKeptOnDiskAndTheNoteSaysWhere() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vision-attach-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(root: root)
        var messages: [LLMMessage] = [
            .user("first", attachments: [picture("design mock.png")]),
            .user("second", attachments: [picture("b.png")]),
        ]
        ImageRollOff.fit(&messages, budget: ImageBudget(maxImages: 1), store: store)
        let kept = store.url(for: picture("design mock.png"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertEqual(try Data(contentsOf: kept), picture("design mock.png").data)
        XCTAssertTrue(messages[0].content?.contains(kept.path) == true)
        XCTAssertTrue(messages[0].content?.contains("view_image") == true)
        XCTAssertTrue(kept.lastPathComponent.hasSuffix("-design-mock.png"), "the name is made safe for a path")
    }

    func testTheSameBytesAreStoredOnce() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("vision-attach-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AttachmentStore(root: root)
        let first = store.save(picture("a.png")), second = store.save(picture("a.png"))
        XCTAssertEqual(first, second)
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: root.path))?.count, 1)
        let reference = store.reference(picture("a.png"))
        XCTAssertEqual(reference.url, first)
        XCTAssertTrue(reference.isImage)
    }

    func testRouteBudgetTakesAShareOfTheWindow() {
        XCTAssertEqual(ImageBudget.forRoute(maxImages: nil, contextWindow: nil), ImageBudget(maxImages: 8))
        XCTAssertEqual(ImageBudget.forRoute(maxImages: 3, contextWindow: 100_000),
                       ImageBudget(maxImages: 3, maxImageTokens: 40_000))
    }

    // MARK: What the server says

    func testLimitsAreReadFromRefusals() {
        XCTAssertEqual(ImageLimit.parse("At most 8 image(s) may be provided in one request."), 8)
        XCTAssertEqual(ImageLimit.parse("You set image=1 (or defaulted to 1) in `--limit-mm-per-prompt`, but found 3 items in the same prompt."), 1)
        XCTAssertEqual(ImageLimit.parse("Too many images: a maximum of 20 images is allowed per request"), 20)
        XCTAssertEqual(ImageLimit.parse("This model supports up to 10 images."), 10)
        XCTAssertNil(ImageLimit.parse("The model `qwen` does not exist."))
        XCTAssertNil(ImageLimit.parse("maximum context length is 262144 tokens"))
    }

    func testARefusalAboutPicturesTeachesTheLimit() {
        let vllm = LLMError.http(400, #"{"error":{"message":"At most 8 image(s) may be provided in one request.","type":"BadRequestError"}}"#)
        XCTAssertEqual(ImageLimit.learned(from: vllm, sent: 11), 8)
        // No number in it: half of what was sent.
        let vague = LLMError.http(400, "Too many images in the request")
        XCTAssertEqual(ImageLimit.learned(from: vague, sent: 6), 3)
        XCTAssertNil(ImageLimit.learned(from: vague, sent: 1))
        // A stated limit at or above what was sent can't be the whole story: still back off.
        XCTAssertEqual(ImageLimit.learned(from: vllm, sent: 8), 4)
    }

    func testOtherErrorsTeachNothing() {
        XCTAssertNil(ImageLimit.learned(from: LLMError.http(400, "context length exceeded"), sent: 5))
        XCTAssertNil(ImageLimit.learned(from: LLMError.http(503, "At most 8 image(s) may be provided"), sent: 9),
                     "only a refusal of the request counts")
        XCTAssertNil(ImageLimit.learned(from: LLMError.connection("timed out"), sent: 5))
        XCTAssertNil(ImageLimit.learned(from: LLMError.http(400, "At most 8 image(s) may be provided"), sent: 0))
    }

    // MARK: Attachments become text and pictures

    func testATextFileGoesInline() {
        let file = MessageAttachment(kind: .file, name: "notes.md", data: Data("# Title\nbody".utf8))
        let out = AttachmentDigest.prepare(text: "summarise this", attachments: [file])
        XCTAssertTrue(out.attachments.isEmpty)
        XCTAssertTrue(out.text.hasPrefix("summarise this\n\nAttached file notes.md:\n```\n# Title\nbody\n```"))
    }

    func testALongFileIsCutAndSaysSo() {
        let file = MessageAttachment(kind: .file, name: "big.log", data: Data(String(repeating: "x", count: 500).utf8))
        let out = AttachmentDigest.prepare(text: "", attachments: [file], options: .init(maxTextCharacters: 100))
        XCTAssertTrue(out.text.contains(String(repeating: "x", count: 100) + "\n```"))
        XCTAssertTrue(out.text.contains("400 more characters were left out"))
    }

    func testABinaryFileIsNamedNotSent() {
        let file = MessageAttachment(kind: .file, name: "blob.bin", data: Data([0x00, 0x01, 0x02, 0xFF]))
        let out = AttachmentDigest.prepare(text: "what is this", attachments: [file])
        XCTAssertTrue(out.attachments.isEmpty)
        XCTAssertTrue(out.text.contains("blob.bin"))
        XCTAssertTrue(out.text.contains("was not sent"))
    }

    func testPicturesStayAndAreDroppedWithoutVision() {
        let out = AttachmentDigest.prepare(text: "look", attachments: [picture("a.png")])
        XCTAssertEqual(out.attachments.map(\.name), ["a.png"])
        XCTAssertEqual(out.text, "look")
        let blind = AttachmentDigest.prepare(text: "look", attachments: [picture("a.png")], options: .init(vision: false))
        XCTAssertTrue(blind.attachments.isEmpty)
        XCTAssertTrue(blind.text.contains("does not take pictures"))
    }

    func testAnUnreadablePDFSaysSo() {
        let file = MessageAttachment(kind: .file, name: "broken.pdf", data: Data("%PDF-1.7 not really".utf8))
        let out = AttachmentDigest.prepare(text: "read", attachments: [file])
        XCTAssertTrue(out.attachments.isEmpty)
        XCTAssertTrue(out.text.contains("broken.pdf"))
        XCTAssertFalse(out.text.contains("%PDF"), "the raw bytes never go to the model")
    }

    #if canImport(CoreGraphics) && canImport(CoreText)
    /// A one-page PDF drawn here, with or without a line of text.
    private func pdf(text: String?) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: data),
              let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { return Data() }
        context.beginPDFPage(nil)
        if let text {
            let line = CTLineCreateWithAttributedString(NSAttributedString(
                string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String):
                                               CTFontCreateWithName("Helvetica" as CFString, 14, nil)]))
            context.textPosition = CGPoint(x: 72, y: 700)
            CTLineDraw(line, context)
        } else {
            context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: 100, y: 100, width: 300, height: 300))
        }
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    func testAPDFWithTextBecomesItsText() {
        let file = MessageAttachment(kind: .file, name: "report.pdf",
                                     data: pdf(text: "Quarterly revenue rose eleven percent over the prior year."))
        let out = AttachmentDigest.prepare(text: "summarise", attachments: [file])
        XCTAssertTrue(out.attachments.isEmpty, "a PDF with a text layer needs no pictures")
        XCTAssertTrue(out.text.contains("Attached PDF report.pdf (1 page, text extracted)"))
        XCTAssertTrue(out.text.contains("Quarterly revenue rose eleven percent"))
    }

    func testAScannedPDFBecomesPagePictures() {
        let file = MessageAttachment(kind: .file, name: "scan.pdf", data: pdf(text: nil))
        let out = AttachmentDigest.prepare(text: "what is this", attachments: [file])
        XCTAssertEqual(out.attachments.map(\.name), ["scan-page-1.png"])
        XCTAssertEqual(out.attachments.first?.kind, .image)
        let size = out.attachments.first.flatMap { ImageSize.dimensions(of: $0.data) }
        XCTAssertEqual(size.map { max($0.width, $0.height) }, 1_568)
        XCTAssertTrue(out.text.contains("scan with no text layer"))
        // Without vision the pages can't be sent, and the message says why.
        let blind = AttachmentDigest.prepare(text: "what is this", attachments: [file], options: .init(vision: false))
        XCTAssertTrue(blind.attachments.isEmpty)
        XCTAssertTrue(blind.text.contains("does not take pictures"))
    }
    #endif

    // MARK: Prompt history, out

    private func record(_ text: String, at seconds: TimeInterval, duration: TimeInterval? = nil,
                        files: [AttachmentReference]? = nil) -> PromptHistoryRecord {
        PromptHistoryRecord(chatID: "c1", chatTitle: "Website", mode: .code, text: text,
                            at: Date(timeIntervalSince1970: seconds), duration: duration,
                            outcome: .completed(evidence: 0), attachments: files?.map(\.name) ?? [],
                            model: "qwen3.8", attachmentFiles: files)
    }

    func testSortOrders() {
        let records = [record("b", at: 200, duration: 5), record("a", at: 100, duration: 90), record("c", at: 300)]
        XCTAssertEqual(PromptHistorySort.newestFirst.apply(records).map(\.text), ["c", "b", "a"])
        XCTAssertEqual(PromptHistorySort.oldestFirst.apply(records).map(\.text), ["a", "b", "c"])
        XCTAssertEqual(PromptHistorySort.longestFirst.apply(records).map(\.text), ["a", "b", "c"])
    }

    func testExportsCarryTimestampsAndAttachments() throws {
        let shot = AttachmentReference(name: "home.png", kind: .image, bytes: 2_048, path: "/tmp/x-home.png")
        let records = [record("fix the header, \"quoted\"\nsecond line", at: 0, duration: 75, files: [shot]),
                       record("ship it", at: 3_600)]
        let utc = TimeZone(identifier: "UTC")!

        let markdown = PromptHistoryExport.markdown(records, timeZone: utc)
        XCTAssertTrue(markdown.hasPrefix("# Prompts — Website\n\n2 prompts"))
        XCTAssertTrue(markdown.contains("## 1. 1970-01-01T00:00:00Z · Code · completed · 1m 15s · qwen3.8"))
        XCTAssertTrue(markdown.contains("- home.png — /tmp/x-home.png"))
        XCTAssertTrue(markdown.contains("## 2. 1970-01-01T01:00:00Z"))

        let csv = PromptHistoryExport.csv(records, timeZone: utc)
        let lines = csv.components(separatedBy: "\n")
        XCTAssertEqual(lines[0], "timestamp,chat,mode,outcome,duration_seconds,model,attachments,changed_files,prompt")
        XCTAssertTrue(csv.contains("1970-01-01T00:00:00Z,Website,code,completed,75,qwen3.8,home.png,,\"fix the header, \"\"quoted\"\"\nsecond line\""))

        let json = PromptHistoryExport.json(records, timeZone: utc)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows[0]["timestamp"] as? String, "1970-01-01T00:00:00Z")
        XCTAssertEqual((rows[0]["attachments"] as? [[String: Any]])?.first?["path"] as? String, "/tmp/x-home.png")
        XCTAssertEqual(rows[1]["prompt"] as? String, "ship it")
    }

    func testOldRecordsWithoutKeptAttachmentsStillDecode() throws {
        let old = #"[{"id":"1","chatID":"c","chatTitle":"t","mode":"chat","text":"hi","at":0,"outcome":{"kind":"stopped"},"changedFiles":[],"attachments":["a.png"]}]"#
        let decoded = try JSONDecoder().decode([PromptHistoryRecord].self, from: Data(old.utf8))
        XCTAssertNil(decoded[0].attachmentFiles)
        XCTAssertEqual(decoded[0].attachments, ["a.png"])
    }

    func testAChatsPromptsCanBeListedAndSearchedByAttachment() {
        let store = PromptHistoryStore(fileURL: nil)
        store.add(.init(chatID: "a", chatTitle: "A", mode: .chat, text: "one", attachments: ["mock.png"]))
        store.add(.init(chatID: "b", chatTitle: "B", mode: .chat, text: "two"))
        store.add(.init(chatID: "a", chatTitle: "A", mode: .chat, text: "three"))
        XCTAssertEqual(store.records(inChat: "a").map(\.text), ["one", "three"])
        XCTAssertEqual(store.search(query: "", chatID: "a").map(\.text), ["three", "one"])
        XCTAssertEqual(store.search(query: "mock").map(\.text), ["one"])
    }
}

// MARK: - The engine against a server that takes only so many pictures

/// A model server that, like vLLM with `--limit-mm-per-prompt`, refuses any request carrying more than `limit`
/// pictures, and otherwise answers from its script.
private final class PictureLimitedClient: LLMClient, @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var turns: [ScriptedClient.Turn]
    private(set) var imageCounts: [Int] = []
    private(set) var refusals = 0
    private(set) var accepted: [LLMRequest] = []

    init(limit: Int, turns: [ScriptedClient.Turn]) {
        self.limit = limit
        self.turns = turns
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let count = ImageRollOff.imageCount(request.messages)
        lock.lock()
        imageCounts.append(count)
        if count > limit {
            refusals += 1
            lock.unlock()
            let limit = self.limit
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: LLMError.http(400,
                    #"{"error":{"message":"At most \#(limit) image(s) may be provided in one request.","code":400}}"#))
            }
        }
        accepted.append(request)
        let turn = turns.isEmpty ? ScriptedClient.Turn(text: "done") : turns.removeFirst()
        lock.unlock()
        return AsyncThrowingStream { continuation in
            continuation.yield(.text(turn.text))
            continuation.yield(.done(calls: turn.calls, finish: "stop", usage: turn.usage))
            continuation.finish()
        }
    }

    func listModels() async throws -> [String] { ["limited"] }
}

/// A screenshot tool that returns a distinct picture on every call.
private struct CountingShotTool: ToolExecutor {
    static let name = "screenshot"
    static let spec = ToolSpec(name: name, description: "capture", parameters: #"{"type":"object","properties":{}}"#)
    let counter = Counter()

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
    }

    func execute(args: JSONString, in context: ToolContext) async -> ToolResult {
        let n = counter.next()
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
                              0, 0, 0, 64, 0, 0, 0, 64, 8, 2, 0, 0, 0]
        bytes.append(UInt8(n & 0xFF))
        return ToolResult(output: "captured \(n)",
                          images: [MessageAttachment(kind: .image, name: "shot-\(n).png", data: Data(bytes))])
    }
}

final class PictureLimitEngineTests: XCTestCase {
    private final class Learned: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [Int] = []
        func note(_ value: Int) { lock.lock(); values.append(value); lock.unlock() }
        var all: [Int] { lock.lock(); defer { lock.unlock() }; return values }
    }

    private func engine(_ client: any LLMClient, maxImages: Int, learned: Learned? = nil) -> Engine {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
        var config = EngineConfig(maxIterations: 12, toolTimeout: 5, model: "t", maxToolImageMessages: 50,
                                  retry: RetryPolicy(delay: { _ in 0 }))
        config.imageBudget = ImageBudget(maxImages: maxImages)
        if let learned { config.onImageLimit = { learned.note($0) } }
        return Engine(client: client, registry: ToolRegistry(tools: [CountingShotTool()]), systemPrompt: "s",
                      config: config, workspace: root,
                      policy: PermissionPolicy(preset: .fullAccess, workspaceRoot: root),
                      permissionGate: { _, _, _ in true })
    }

    private func shots(_ count: Int) -> [ScriptedClient.Turn] {
        (0..<count).map { .init(text: "step \($0)", calls: [ToolCall(id: "c\($0)", name: "screenshot", arguments: "{}")]) }
            + [.init(text: "finished")]
    }

    func testDrivingTheDesktopNeverSendsMoreThanTheBudget() async throws {
        // Six screenshots in a row with a budget of two: every request stays inside it, no refusals.
        let client = PictureLimitedClient(limit: 2, turns: shots(6))
        let result = try await engine(client, maxImages: 2).run(messages: [], userText: "click through the wizard",
                                                                sink: { _ in })
        XCTAssertEqual(result.finalText, "finished")
        XCTAssertEqual(client.refusals, 0)
        XCTAssertEqual(client.imageCounts.max(), 2)
        // The last request sees the two newest screenshots.
        let last = client.accepted.last?.messages.flatMap { ($0.attachments ?? []).map(\.name) }
        XCTAssertEqual(last, ["shot-5.png", "shot-6.png"])
    }

    func testAServersLowerLimitIsLearnedAndTheTurnCarriesOn() async throws {
        // The harness thinks eight fit; the server takes two. The first over-limit request is refused once,
        // the limit is learned, and the run finishes instead of failing.
        let client = PictureLimitedClient(limit: 2, turns: shots(5))
        let learned = Learned()
        let result = try await engine(client, maxImages: 8, learned: learned)
            .run(messages: [], userText: "click through the wizard", sink: { _ in })
        XCTAssertEqual(result.finalText, "finished")
        XCTAssertEqual(client.refusals, 1, "refused once, then never again in this run")
        XCTAssertEqual(learned.all, [2])
        XCTAssertLessThanOrEqual(client.accepted.map { ImageRollOff.imageCount($0.messages) }.max() ?? 0, 2)
    }

    func testAttachedPicturesOverTheLimitDoNotStickTheChat() async throws {
        // Three pictures attached to one prompt, a server that takes one: the request goes through with the
        // first, and the message says what happened to the others.
        let client = PictureLimitedClient(limit: 1, turns: [.init(text: "I can see the first one.")])
        let pictures = (1...3).map { n -> MessageAttachment in
            var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52,
                                  0, 0, 0, 64, 0, 0, 0, 64, 8, 2, 0, 0, 0]
            bytes.append(UInt8(n))
            return MessageAttachment(kind: .image, name: "mock-\(n).png", data: Data(bytes))
        }
        let result = try await engine(client, maxImages: 8)
            .run(messages: [], userText: "compare these", userAttachments: pictures, sink: { _ in })
        XCTAssertEqual(result.finalText, "I can see the first one.")
        let sent = try XCTUnwrap(client.accepted.first?.messages.first)
        XCTAssertEqual(sent.attachments?.map(\.name), ["mock-1.png"])
        XCTAssertTrue(sent.content?.contains("mock-2.png") == true)
        XCTAssertTrue(sent.content?.contains("mock-3.png") == true)
    }

    func testAFileAttachmentReachesTheModelAsText() async throws {
        let client = ScriptedClient(turns: [.init(text: "It says hello.")])
        let file = MessageAttachment(kind: .file, name: "note.txt", data: Data("hello there".utf8))
        _ = try await engine(client, maxImages: 8).run(messages: [], userText: "what does it say?",
                                                       userAttachments: [file], sink: { _ in })
        let sent = try XCTUnwrap(client.requests.first?.messages.first)
        XCTAssertNil(sent.attachments, "no `file` part: local servers refuse it")
        XCTAssertTrue(sent.content?.contains("Attached file note.txt:\n```\nhello there\n```") == true)
    }
}
