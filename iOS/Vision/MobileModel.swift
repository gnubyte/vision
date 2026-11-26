import Foundation
import SwiftUI
import Observation
import UIKit
import VisionHarnessCore

// MARK: - What a chat holds

/// One row of a chat as it is shown.
struct ChatEntry: Codable, Identifiable, Hashable {
    enum Role: String, Codable { case user, assistant, notice, error }

    var id: String = UUID().uuidString
    var role: Role
    var text: String
    var at: Date = Date()
    /// What a prompt carried, kept on disk so it can be opened again.
    var attachments: [AttachmentReference] = []
}

/// A chat: what is on screen (`entries`) and what the model is sent (`transcript`). They differ on purpose — a
/// PDF is one chip on screen and pages of text in the transcript, and pictures roll off the transcript while
/// staying in the chat.
struct MobileChat: Codable, Identifiable {
    var id: String = UUID().uuidString
    var title: String = "New chat"
    /// The Spark Swapper box this chat talks to (nil: the first one).
    var boxID: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var entries: [ChatEntry] = []
    var transcript: [LLMMessage] = []

    var promptCount: Int { entries.filter { $0.role == .user }.count }
}

/// What adding a box by address and login came to.
enum BoxLoginResult {
    case added
    /// The box's certificate isn't trusted yet: show this fingerprint and ask.
    case needsTrust(fingerprint: String)
}

// MARK: - The app's state

@MainActor
@Observable
final class MobileModel {
    // Boxes.
    var connections: [SwapperConnection] = []
    var statuses: [String: SwapperStatus] = [:]
    var boxErrors: [String: String] = [:]
    /// Boxes with a switch this app started, until the box says it is done.
    var switching: Set<String> = []

    // Chats.
    var chats: [MobileChat] = []
    /// The reply being streamed, by chat.
    var streaming: [String: String] = [:]
    /// The model's reasoning while it streams, by chat (shown live, never kept).
    var thinking: [String: String] = [:]
    var running: Set<String> = []

    // Settings.
    var maxImages: Int = ImageBudget.defaultMaxImages {
        didSet { if !isDemo { defaults.set(maxImages, forKey: Keys.maxImages) } }
    }
    var systemPrompt: String = MobileModel.defaultSystemPrompt {
        didSet { if !isDemo { defaults.set(systemPrompt, forKey: Keys.systemPrompt) } }
    }
    /// What servers said they take, by route id.
    var learnedImageLimits: [String: Int] = [:] {
        didSet { if !isDemo { defaults.set(learnedImageLimits, forKey: Keys.learnedLimits) } }
    }

    /// A demo run (`-VisionDemo YES` on the command line): a made-up box and chat, nothing read from or written
    /// to the phone, no network. For screenshots and for checking the app in the simulator.
    @ObservationIgnored let isDemo: Bool
    /// The screen a demo run opens on (`-VisionDemoScreen chats|chat|boxes|box|history|settings`).
    @ObservationIgnored let demoScreen: String?

    @ObservationIgnored let secrets: any SecretStore
    @ObservationIgnored let history: PromptHistoryStore
    @ObservationIgnored let attachments: AttachmentStore
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var polls: [String: Task<Void, Never>] = [:]

    private enum Keys {
        static let maxImages = "images.perRequest.v1"
        static let systemPrompt = "chat.systemPrompt.v1"
        static let learnedLimits = "images.learnedLimits.v1"
    }

    static let defaultSystemPrompt = """
    You are Vision, a helpful assistant on the user's iPhone, running on a model their own Spark Swapper box \
    serves. Answer directly and keep it readable on a small screen: short paragraphs, lists where they help, \
    code in fenced blocks. When the user attaches pictures or files, work from what is in them.
    """

    private var chatsFolder: URL { AppPaths.support.appendingPathComponent("mobile-chats", isDirectory: true) }

    init() {
        isDemo = UserDefaults.standard.bool(forKey: "VisionDemo")
        demoScreen = isDemo ? UserDefaults.standard.string(forKey: "VisionDemoScreen") : nil
        if isDemo {
            secrets = MemorySecretStore()
            history = PromptHistoryStore(fileURL: nil)
            attachments = AttachmentStore(root: FileManager.default.temporaryDirectory
                .appendingPathComponent("vision-demo-attachments", isDirectory: true))
            seedDemo()
            return
        }
        secrets = KeychainSecretStore()
        history = PromptHistoryStore.standard()
        attachments = AttachmentStore.standard()
        maxImages = defaults.object(forKey: Keys.maxImages) as? Int ?? ImageBudget.defaultMaxImages
        systemPrompt = defaults.string(forKey: Keys.systemPrompt) ?? Self.defaultSystemPrompt
        learnedImageLimits = defaults.dictionary(forKey: Keys.learnedLimits) as? [String: Int] ?? [:]
        connections = SwapperConnectionStore.load(defaults: defaults, secrets: secrets)
        loadChats()
    }

    // MARK: - Boxes

    func connection(_ id: String?) -> SwapperConnection? {
        guard let id else { return connections.first }
        return connections.first { $0.id == id } ?? connections.first
    }

    private func client(for connection: SwapperConnection) -> SparkSwapperClient? {
        SwapperConnectionStore.client(for: connection, secrets: secrets)
    }

    private func keep(_ connection: SwapperConnection, secret: String, apiKey: String?) {
        var kept = connection
        // The same box added again replaces its earlier entry.
        if let existing = connections.firstIndex(where: { SwapperConnection.sameAddress($0.url, connection.url) }) {
            kept.id = connections[existing].id
            connections[existing] = kept
        } else {
            connections.append(kept)
        }
        SwapperConnectionStore.setSecret(secret, for: kept, secrets: secrets)
        if let apiKey, !apiKey.isEmpty {
            secrets.write(apiKey, service: AppIdentity.KeychainService.provider, account: kept.id)
        }
        if !isDemo { SwapperConnectionStore.save(connections, defaults: defaults) }
    }

    /// Add a box from the connection code on its Connect tab. The code carries the box's certificate, so the
    /// connection is checked against exactly that certificate before anything is kept.
    func addBox(code text: String) async throws {
        let code = try SwapperConnectionCode.decode(text)
        let status = try await SwapperConnect.check(code)
        let connection = SwapperConnect.connection(for: code)
        keep(connection, secret: code.token, apiKey: code.apiKey)
        if let kept = connections.first(where: { SwapperConnection.sameAddress($0.url, connection.url) }) {
            statuses[kept.id] = status
            boxErrors[kept.id] = nil
        }
    }

    /// Add a box with its address and the web page's login. `trusted` is the certificate fingerprint the user
    /// approved, once they have.
    func addBox(address: String, username: String, password: String, trusted: String?) async throws -> BoxLoginResult {
        switch try await SwapperConnect.login(address: address, username: username, password: password, pinned: trusted) {
        case .needsTrust(let fingerprint):
            return .needsTrust(fingerprint: fingerprint)
        case .connected(let connection, let secret, let connect, let credentials):
            let label = "\(AppIdentity.name) on \(UIDevice.current.name)"
            let kept = try await SwapperConnect.keep(connection, password: secret, label: label)
            keep(kept.connection, secret: kept.secret, apiKey: connect?.apiKey ?? credentials?.apiKey)
            await refreshAll()
            return .added
        }
    }

    func removeBox(_ id: String) {
        if isDemo { connections.removeAll { $0.id == id }; return }
        guard let connection = connections.first(where: { $0.id == id }) else { return }
        polls[id]?.cancel()
        polls[id] = nil
        SwapperConnectionStore.setSecret(nil, for: connection, secrets: secrets)
        secrets.write(nil, service: AppIdentity.KeychainService.provider, account: id)
        connections.removeAll { $0.id == id }
        statuses[id] = nil
        boxErrors[id] = nil
        SwapperConnectionStore.save(connections, defaults: defaults)
    }

    func refresh(_ id: String) async {
        if isDemo { return }
        guard let connection = connections.first(where: { $0.id == id }), let client = self.client(for: connection) else { return }
        do {
            let status = try await client.status()
            statuses[id] = status
            boxErrors[id] = nil
            if !status.isSwitching { switching.remove(id) }
        } catch {
            boxErrors[id] = Self.describe(error)
        }
    }

    func refreshAll() async {
        for connection in connections { await refresh(connection.id) }
    }

    /// Stop what the box serves and load `key`. The box takes minutes; its status is polled until it is done.
    func swap(_ id: String, to key: String) async {
        if isDemo { demoSwap(id, to: key); return }
        guard let connection = connections.first(where: { $0.id == id }), let client = self.client(for: connection) else { return }
        do {
            try await client.swap(to: key)
            switching.insert(id)
            boxErrors[id] = nil
            await refresh(id)
            watch(id)
        } catch {
            boxErrors[id] = Self.describe(error)
        }
    }

    /// Follow a box while it is switching.
    func watch(_ id: String) {
        guard !isDemo, polls[id] == nil else { return }
        polls[id] = Task { [weak self] in
            var quiet = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard let self else { return }
                await self.refresh(id)
                let busy = self.statuses[id]?.isSwitching ?? false
                // A swap takes a moment to show up as busy: give it a few polls before believing it is over.
                quiet = busy ? 0 : quiet + 1
                if !busy, quiet >= 3 { break }
            }
            self?.switching.remove(id)
            self?.polls[id] = nil
        }
    }

    /// One line on what a box is doing.
    func summary(for id: String) -> String {
        if let status = statuses[id] {
            if status.isSwitching {
                let target = status.loading.flatMap { status.models[$0]?.title } ?? status.job?.target ?? "a model"
                let step = status.job?.currentStep?.label
                return "Loading \(target)" + (step.map { " — \($0)" } ?? "…")
            }
            if let model = status.activeModel {
                var parts = [model.title, "\(SwapperStatus.shortWindow(model.window)) context"]
                if let speed = model.speedText() { parts.append(speed) }
                return parts.joined(separator: " · ")
            }
            return "Nothing is being served"
        }
        return boxErrors[id] ?? "Checking…"
    }

    // MARK: - Chats

    private func loadChats() {
        let files = (try? FileManager.default.contentsOfDirectory(at: chatsFolder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        chats = files.filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(MobileChat.self, from: Data(contentsOf: $0)) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func save(_ chat: MobileChat) {
        if isDemo { return }
        let url = chatsFolder.appendingPathComponent("\(chat.id).json")
        guard let data = try? JSONEncoder().encode(chat) else { return }
        try? FileManager.default.createDirectory(at: chatsFolder, withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    func chat(_ id: String) -> MobileChat? { chats.first { $0.id == id } }

    @discardableResult
    func newChat(boxID: String? = nil) -> String {
        // An untouched new chat is reused instead of piling up empty ones.
        if let empty = chats.first(where: { $0.entries.isEmpty && !running.contains($0.id) }) {
            if let boxID, let index = chats.firstIndex(where: { $0.id == empty.id }) { chats[index].boxID = boxID }
            return empty.id
        }
        var chat = MobileChat()
        chat.boxID = boxID ?? connections.first?.id
        chats.insert(chat, at: 0)
        return chat.id
    }

    func deleteChat(_ id: String) {
        stop(id)
        chats.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: chatsFolder.appendingPathComponent("\(id).json"))
    }

    func setBox(_ boxID: String, for chatID: String) {
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[index].boxID = boxID
        save(chats[index])
    }

    func rename(_ chatID: String, to title: String) {
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty, let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[index].title = cleaned
        save(chats[index])
        history.retitle(chatID: chatID, title: cleaned)
    }

    private func append(_ entry: ChatEntry, to chatID: String) {
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        chats[index].entries.append(entry)
        chats[index].updatedAt = Date()
    }

    func stop(_ chatID: String) {
        tasks[chatID]?.cancel()
    }

    // MARK: - Sending

    /// How many pictures a request to this route may carry: what its server said, else the setting.
    private func imageLimit(for profile: ProviderProfile) -> Int {
        let setting = max(1, maxImages)
        guard let learned = learnedImageLimits[profile.routeID] else { return setting }
        return min(setting, max(0, learned))
    }

    private func profile(for connection: SwapperConnection, model: SwapperStatus.Model) -> ProviderProfile? {
        guard let base = connection.apiBase, !base.isEmpty else { return nil }
        return ProviderProfile(kind: .openAICompat, name: connection.name, baseURL: base,
                               apiKey: secrets.read(service: AppIdentity.KeychainService.provider, account: connection.id),
                               model: model.served_id, contextWindow: model.window, vision: model.vision,
                               pinnedCertificate: connection.pinnedFingerprint)
    }

    func send(_ text: String, attachments items: [MessageAttachment], in chatID: String) {
        guard !running.contains(chatID), let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty || !items.isEmpty else { return }

        let files = items.map { attachments.reference($0) }
        chats[index].entries.append(ChatEntry(role: .user, text: prompt, attachments: files))
        chats[index].updatedAt = Date()
        if chats[index].title == "New chat" {
            let first = prompt.split(separator: "\n").first.map(String.init) ?? items.first?.name ?? "Chat"
            chats[index].title = String(first.prefix(48))
        }
        let turnID = UUID().uuidString
        history.add(.init(chatID: chatID, chatTitle: chats[index].title, mode: .chat, text: prompt, turnID: turnID,
                          attachments: items.map(\.name), attachmentFiles: files.isEmpty ? nil : files))
        running.insert(chatID)
        streaming[chatID] = ""
        thinking[chatID] = nil
        chats.sort { $0.updatedAt > $1.updatedAt }

        tasks[chatID] = Task { [weak self] in
            await self?.run(chatID: chatID, prompt: prompt, items: items, turnID: turnID, started: Date())
        }
    }

    private func run(chatID: String, prompt: String, items: [MessageAttachment], turnID: String, started: Date) async {
        var outcome: PromptHistoryRecord.Outcome = .stopped
        var servedModel: String?
        defer {
            running.remove(chatID)
            streaming[chatID] = nil
            thinking[chatID] = nil
            tasks[chatID] = nil
            history.finish(turnID: turnID, outcome: outcome, duration: Date().timeIntervalSince(started), model: servedModel)
            if let chat = self.chat(chatID) { save(chat) }
        }
        func fail(_ message: String) {
            append(ChatEntry(role: .error, text: message), to: chatID)
            outcome = .failed(reason: message)
        }

        if isDemo {
            outcome = await demoReply(in: chatID)
            return
        }
        guard let connection = self.connection(self.chat(chatID)?.boxID) else {
            return fail("Add a Spark Swapper box first (the Boxes tab), then send this again.")
        }
        // What the box serves can change between prompts: ask it.
        await refresh(connection.id)
        guard let status = statuses[connection.id] else {
            return fail("Couldn't reach \(connection.name): \(boxErrors[connection.id] ?? "no answer").")
        }
        if status.isSwitching {
            let target = status.loading.flatMap { status.models[$0]?.title } ?? "another model"
            watch(connection.id)
            return fail("\(connection.name) is loading \(target). Send this again when it is ready.")
        }
        guard let model = status.activeModel else {
            return fail("\(connection.name) isn't serving a model. Pick one on the Boxes tab.")
        }
        guard let profile = self.profile(for: connection, model: model) else {
            return fail("\(connection.name) didn't say where its model API is. Remove the box and add it again with its connection code.")
        }
        servedModel = model.served_id

        // Files become text and scanned pages become pictures, once; then the request is kept inside the
        // model's picture limit, the oldest pictures rolling off to disk.
        let digest = AttachmentDigest.prepare(text: prompt, attachments: items, options: .init(vision: model.vision ?? true))
        var transcript = self.chat(chatID)?.transcript ?? []
        transcript.append(.user(digest.text, attachments: digest.attachments.isEmpty ? nil : digest.attachments))
        var budget = ImageBudget.forRoute(maxImages: imageLimit(for: profile), contextWindow: profile.contextWindow)
        let client = OpenAIClient(profile: profile)
        var reply = ""
        var corrections = 0

        attempt: while true {
            if ImageRollOff.fit(&transcript, budget: budget, store: attachments).rolledOff > 0, corrections == 0 {
                append(ChatEntry(role: .notice, text: "Older pictures were rolled off to fit \(model.title)'s limit of \(budget.maxImages) per request. They are still in this chat and its prompt history."), to: chatID)
            }
            let request = LLMRequest(systemPrompt: systemPrompt, messages: transcript, tools: [], model: profile.model)
            reply = ""
            streaming[chatID] = ""
            do {
                for try await event in client.stream(request) {
                    if Task.isCancelled { break }
                    switch event {
                    case .text(let delta):
                        reply += delta
                        streaming[chatID] = reply
                        thinking[chatID] = nil
                    case .reasoning(let delta):
                        let so = (thinking[chatID] ?? "") + delta
                        thinking[chatID] = String(so.suffix(600))
                    case .done:
                        break
                    }
                }
                break attempt
            } catch {
                if Task.isCancelled || error is CancellationError { break attempt }
                // The server takes fewer pictures than were sent: learn its limit and ask again with fewer.
                let sent = ImageRollOff.imageCount(transcript)
                if corrections < 4, let limit = ImageLimit.learned(from: error, sent: sent), limit < sent {
                    corrections += 1
                    budget.maxImages = limit
                    learnedImageLimits[profile.routeID] = limit
                    append(ChatEntry(role: .notice, text: limit > 0
                        ? "\(model.title) takes \(limit) picture\(limit == 1 ? "" : "s") per request. The newest stay in view; the rest are kept in this chat's history."
                        : "\(model.title) refused pictures, so they are no longer sent to it."), to: chatID)
                    continue attempt
                }
                return fail(Self.describe(error))
            }
        }

        let answered = !reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard let index = chats.firstIndex(where: { $0.id == chatID }) else { return }
        if answered {
            transcript.append(.assistant(reply))
            chats[index].transcript = transcript
            chats[index].entries.append(ChatEntry(role: .assistant, text: reply))
            chats[index].updatedAt = Date()
            outcome = Task.isCancelled ? .stopped : .completed(evidence: 0)
        }
        if Task.isCancelled {
            chats[index].entries.append(ChatEntry(role: .notice, text: "Stopped."))
        } else if !answered {
            fail("\(model.title) sent back an empty reply. Try again.")
        }
    }

    static func describe(_ error: Error) -> String {
        if let known = error as? LocalizedError, let text = known.errorDescription, !text.isEmpty { return text }
        return error.localizedDescription
    }
}

// MARK: - The demo run
//
// `-VisionDemo YES` opens the app on a made-up box and chat: nothing is read from or written to the phone and
// nothing goes over the network. It is how the screenshots are made and how the app is checked in the
// simulator; `-VisionDemoScreen <name>` chooses the screen it opens on.

extension MobileModel {
    private static let demoBoxID = "demo-box"

    private func seedDemo() {
        let box = SwapperConnection(id: Self.demoBoxID, name: "DGX Spark (spark-3f2a)",
                                    url: "https://spark-3f2a.local:8999", platform: "nvidia-gb10",
                                    hostname: "spark-3f2a", version: "2.2.0", auth: .token,
                                    apiBase: "https://spark-3f2a.local:11443/v1")
        connections = [box]
        statuses[box.id] = Self.demoStatus(active: "tfflash")

        let shot = attachments.reference(MessageAttachment(kind: .image, name: "checkout-screen.png", data: Self.demoPicture()))
        let spec = attachments.reference(MessageAttachment(kind: .file, name: "payments-spec.pdf",
                                                           data: Data("Payments spec (demo)".utf8)))
        let now = Date()
        var chat = MobileChat()
        chat.id = "demo-chat"
        chat.title = "Checkout screen review"
        chat.boxID = box.id
        chat.createdAt = now.addingTimeInterval(-1_900)
        chat.updatedAt = now.addingTimeInterval(-60)
        chat.entries = [
            ChatEntry(role: .user, text: "What stands out in this checkout screen, and what should I fix first?",
                      at: now.addingTimeInterval(-1_900), attachments: [shot]),
            ChatEntry(role: .assistant, text: """
                Three things stand out, most important first:

                1. **The total is below the fold.** On a small phone the Pay button shows before the amount does.
                2. **Two primary buttons.** "Pay" and "Apply code" share the same weight.
                3. The error text is red on a red-tinted field, which is hard to read.

                A quick fix for the first one:

                ```swift
                ScrollView { summary }
                    .safeAreaInset(edge: .bottom) { payBar(total: total) }
                ```
                """, at: now.addingTimeInterval(-1_860)),
            ChatEntry(role: .user, text: "Summarise the attached spec and list the open questions.",
                      at: now.addingTimeInterval(-300), attachments: [spec]),
            ChatEntry(role: .assistant, text: """
                The spec covers card and wallet payments, refunds within 30 days and a retry queue for failed captures.

                Open questions:
                - Who owns partial refunds after a currency change?
                - Is the retry queue per merchant or global?
                """, at: now.addingTimeInterval(-240)),
        ]
        var older = MobileChat()
        older.id = "demo-chat-2"
        older.title = "Tailscale exit node on the Spark"
        older.boxID = box.id
        older.updatedAt = now.addingTimeInterval(-86_400)
        older.entries = [
            ChatEntry(role: .user, text: "How do I make the Spark an exit node?", at: now.addingTimeInterval(-86_500)),
            ChatEntry(role: .assistant, text: "Run `sudo tailscale up --advertise-exit-node`, then approve it in the admin console.",
                      at: now.addingTimeInterval(-86_400)),
        ]
        chats = [chat, older]

        let model = "qwen3.8-flash-next"
        history.add(.init(chatID: older.id, chatTitle: older.title, mode: .chat, text: older.entries[0].text,
                          at: now.addingTimeInterval(-86_500), duration: 9, outcome: .completed(evidence: 0), model: model))
        history.add(.init(chatID: chat.id, chatTitle: chat.title, mode: .chat, text: chat.entries[0].text,
                          at: now.addingTimeInterval(-1_900), duration: 38, outcome: .completed(evidence: 0),
                          attachments: [shot.name], model: model, attachmentFiles: [shot]))
        history.add(.init(chatID: chat.id, chatTitle: chat.title, mode: .chat, text: "Show me the same fix for iPad.",
                          at: now.addingTimeInterval(-1_200), duration: 4, outcome: .stopped, model: model))
        history.add(.init(chatID: chat.id, chatTitle: chat.title, mode: .chat, text: chat.entries[2].text,
                          at: now.addingTimeInterval(-300), duration: 61, outcome: .completed(evidence: 0),
                          attachments: [spec.name], model: model, attachmentFiles: [spec]))
    }

    /// What the made-up box reports: serving `active`, or loading `loading`.
    static func demoStatus(active: String, loading: String? = nil) -> SwapperStatus {
        typealias Model = SwapperStatus.Model
        let serving = loading == nil ? active : ""
        let models = [
            Model(key: "tfflash", title: "Qwen3.8 Flash Next", tagline: "Fast, reads pictures, 256K context.",
                  engine: "TensorFold", context: 262_144, served_id: "qwen3.8-flash-next", vision: true,
                  running: serving == "tfflash", healthy: serving == "tfflash", order: 1, installed: true,
                  perf: .init(decode: 58)),
            Model(key: "inkling", title: "Inkling 2 Mini", tagline: "Reads pictures; takes eight per request.",
                  engine: "vLLM", context: 262_144, served_id: "inkling-2-mini", vision: true,
                  running: serving == "inkling", healthy: serving == "inkling", order: 2, installed: true,
                  perf: .init(decode: 41)),
            Model(key: "tf27b", title: "Qwen3.8 27B", tagline: "The larger Qwen, for careful work.",
                  engine: "TensorFold", context: 131_072, served_id: "qwen3.8-27b", vision: true,
                  running: serving == "tf27b", healthy: serving == "tf27b", order: 3, installed: true,
                  perf: .init(decode: 27)),
            Model(key: "ornith", title: "Ornith 1.5 122B", engine: "ExLlamaV3", context: 262_144,
                  served_id: "ornith-1.5", vision: false, order: 4, installed: false,
                  install: .init(size_gb: 65, time: "30–50 minutes")),
        ]
        var status = SwapperStatus(active: loading == nil ? active : nil, loading: loading, busy: loading != nil,
                                   models: Dictionary(uniqueKeysWithValues: models.map { ($0.key, $0) }),
                                   version: "2.2.0", platform: "nvidia-gb10", hostname: "spark-3f2a")
        status.memory = Lenient(SwapperStatus.Memory(total: 128, available: 71))
        if let loading {
            let title = status.models[loading]?.title ?? loading
            status.job = SwapperStatus.Job(id: "demo", target: loading, state: "running",
                                           started: Date().timeIntervalSince1970, steps: [
                .init(key: "stop", label: "Stop the serving model", state: "done"),
                .init(key: "start", label: "Start \(title)", state: "running"),
                .init(key: "health", label: "Wait until it answers", state: "pending"),
            ])
        }
        return status
    }

    private func demoSwap(_ id: String, to key: String) {
        statuses[id] = Self.demoStatus(active: key, loading: key)
        switching.insert(id)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self?.statuses[id] = Self.demoStatus(active: key)
            self?.switching.remove(id)
        }
    }

    private func demoReply(in chatID: String) async -> PromptHistoryRecord.Outcome {
        let reply = "This is a demo run, so nothing was sent to a model. On a real box the reply streams in here — **Markdown**, lists and code blocks included."
        var shown = ""
        for word in reply.split(separator: " ") {
            if Task.isCancelled { break }
            try? await Task.sleep(nanoseconds: 45_000_000)
            shown += (shown.isEmpty ? "" : " ") + word
            streaming[chatID] = shown
        }
        append(ChatEntry(role: .assistant, text: shown), to: chatID)
        return Task.isCancelled ? .stopped : .completed(evidence: 0)
    }

    /// A small picture for the demo chat's attachment: a card on a tinted background.
    private static func demoPicture() -> Data {
        let size = CGSize(width: 360, height: 640)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(red: 0.93, green: 0.95, blue: 0.99, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            UIBezierPath(roundedRect: CGRect(x: 24, y: 80, width: 312, height: 300), cornerRadius: 18).fill()
            UIColor(red: 0.23, green: 0.51, blue: 0.96, alpha: 1).setFill()
            UIBezierPath(roundedRect: CGRect(x: 24, y: 420, width: 312, height: 52), cornerRadius: 14).fill()
            UIColor(white: 0.85, alpha: 1).setFill()
            for row in 0..<4 {
                UIBezierPath(roundedRect: CGRect(x: 48, y: 112 + row * 58, width: row == 3 ? 150 : 264, height: 18),
                             cornerRadius: 6).fill()
            }
        }
        return image.pngData() ?? Data()
    }
}
