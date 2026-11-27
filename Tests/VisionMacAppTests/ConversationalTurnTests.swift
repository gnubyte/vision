import XCTest
@testable import VisionMacApp
@testable import VisionHarnessCore

/// A two-item step list, as `todo_write` takes it.
private let twoStepPlan = #"{"todos":[{"content":"Read the code","status":"in_progress"},{"content":"Change it","status":"pending"}]}"#

/// A question or a small task is answered like a conversation; the plan card is for work that is planned. And
/// what a prompt carried is kept, so the prompt history can open it again.
@MainActor
final class ConversationalTurnTests: XCTestCase {
    private var dir: URL!
    private var defaultsSuite: String!
    private var config: AppConfig!
    private var transport: AppTransport!
    private var support: URL { dir.appendingPathComponent("support", isDirectory: true) }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("vision-turns-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        OpenAIClient.protocolClassesForTesting = [FakeModelServer.self]
        FakeModelServer.reset { _, _ in .text("Hello!") }
        defaultsSuite = "vision-turns-tests-\(UUID().uuidString)"
        config = AppConfig(defaults: UserDefaults(suiteName: defaultsSuite)!, secrets: MemorySecretStore())
        config.activate(.init(kind: .openAICompat, name: "stub", baseURL: "http://stub.test/v1", model: "stub-model"))
        config.preset = PermissionPreset.fullAccess.rawValue
        config.computerToolsEnabled = false
        transport = AppTransport(config: config, log: ConversationLog(dir: dir.appendingPathComponent("log", isDirectory: true)),
                                 queueFile: dir.appendingPathComponent("task-queue.json"),
                                 skillLocations: SkillLocations(home: dir, appSupport: support),
                                 vault: CredentialVault(directory: dir.appendingPathComponent("vault"), store: MemoryBlobStore()))
        transport.retryPolicy = RetryPolicy(delay: { _ in 0.02 })
        transport.goalErrorBackoff = { _ in 0.02 }
    }

    override func tearDown() async throws {
        transport?.stopAll()
        try? await Task.sleep(nanoseconds: 50_000_000)
        OpenAIClient.protocolClassesForTesting = nil
        if let defaultsSuite { UserDefaults.standard.removePersistentDomain(forName: defaultsSuite) }
        try? FileManager.default.removeItem(at: dir)
        transport = nil
        config = nil
    }

    private func ask(_ text: String, in vm: SessionVM, attachments: [MessageAttachment] = []) async throws {
        let before = vm.entries.filter { $0.message?.role == .assistant }.count
        transport.send(text, sessionID: vm.id, attachments: attachments)
        let deadline = Date().addingTimeInterval(15)
        while !(vm.entries.filter({ $0.message?.role == .assistant }).count > before && !vm.running) {
            if Date() > deadline { return XCTFail("no reply") }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        // Events hop to the main actor one by one; let the last of them land.
        try await Task.sleep(nanoseconds: 60_000_000)
    }

    func testAQuestionIsJustAnswered() async throws {
        let vm = transport.newSession(cwd: nil)
        try await ask("what is a monad, roughly?", in: vm)
        XCTAssertFalse(vm.turnPlanned)
        XCTAssertNil(vm.visibleTurnPhase, "no plan card for a question")
        // The turn is still timed and lands in the prompt history as completed.
        XCTAssertEqual(vm.turnPhase?.phase, .results)
        guard case .completed = transport.promptHistory.records(inChat: vm.id).last?.outcome else {
            return XCTFail("the prompt history marks the turn completed")
        }
    }

    func testASmallTaskWithToolCallsStillGetsNoPlanCard() async throws {
        FakeModelServer.reset { seen, _ in
            seen.fresh ? .toolCall("write_file", #"{"file_path":"notes.txt","content":"draft"}"#) : .text("Saved notes.txt.")
        }
        let vm = transport.newSession(cwd: nil)
        try await ask("jot that down in notes.txt", in: vm)
        XCTAssertNil(vm.visibleTurnPhase)
        XCTAssertFalse(config.planPanelOpen, "and the plan panel stays shut")
    }

    func testAStepListMakesItPlannedWork() async throws {
        FakeModelServer.reset { seen, _ in
            seen.fresh ? .toolCall("todo_write", twoStepPlan) : .text("Both steps are done.")
        }
        let vm = transport.newSession(cwd: nil)
        transport.selectedID = vm.id
        try await ask("refactor the parser and its tests", in: vm)
        XCTAssertTrue(vm.turnPlanned)
        XCTAssertNotNil(vm.visibleTurnPhase, "the plan card shows once the agent lays out steps")
        // The next plain question starts over without one.
        FakeModelServer.reset { _, _ in .text("Yes.") }
        try await ask("was that all?", in: vm)
        XCTAssertNil(vm.visibleTurnPhase)
    }

    func testAOneItemListIsNotAPlan() async throws {
        FakeModelServer.reset { seen, _ in
            seen.fresh ? .toolCall("todo_write", #"{"todos":[{"content":"Answer","status":"in_progress"}]}"#) : .text("Done.")
        }
        let vm = transport.newSession(cwd: nil)
        try await ask("rename the file", in: vm)
        XCTAssertNil(vm.visibleTurnPhase)
    }

    func testAlwaysPlanShowsTheCardForEverything() async throws {
        config.turnStyle = .alwaysPlan
        let vm = transport.newSession(cwd: nil)
        try await ask("hi", in: vm)
        XCTAssertNotNil(vm.visibleTurnPhase)
    }

    func testJustTalkNeverShowsIt() async throws {
        config.turnStyle = .conversational
        FakeModelServer.reset { seen, _ in
            seen.fresh ? .toolCall("todo_write", twoStepPlan) : .text("Both steps are done.")
        }
        let vm = transport.newSession(cwd: nil)
        try await ask("refactor the parser and its tests", in: vm)
        XCTAssertNil(vm.visibleTurnPhase)
    }

    func testTheStyleSurvivesARestart() {
        config.turnStyle = .conversational
        config.editorPane = .hidden
        config.maxImagesPerRequest = 4
        config.learnedImageLimits = ["stub|stub-model": 2]
        let again = AppConfig(defaults: UserDefaults(suiteName: defaultsSuite)!, secrets: MemorySecretStore())
        XCTAssertEqual(again.turnStyle, .conversational)
        XCTAssertEqual(again.editorPane, .hidden)
        XCTAssertEqual(again.maxImagesPerRequest, 4)
        XCTAssertEqual(again.learnedImageLimits, ["stub|stub-model": 2])
    }

    func testWhatAPromptCarriedIsKeptForItsHistory() async throws {
        let vm = transport.newSession(cwd: nil)
        let note = MessageAttachment(kind: .file, name: "brief.txt", data: Data("make it blue".utf8))
        try await ask("follow the brief", in: vm, attachments: [note])
        let record = try XCTUnwrap(transport.promptHistory.records(inChat: vm.id).last)
        XCTAssertEqual(record.attachments, ["brief.txt"])
        let kept = try XCTUnwrap(record.attachmentFiles?.first?.url, "the file itself is on disk")
        XCTAssertEqual(try Data(contentsOf: kept), note.data)
        XCTAssertTrue(kept.path.hasPrefix(support.appendingPathComponent("attachments").path))
        // And the model got the file as text, not as a `file` part a local server would refuse.
        XCTAssertTrue(FakeModelServer.seen.last?.lastUser.contains("Attached file brief.txt:\n```\nmake it blue\n```") == true)
    }

    func testALearnedPictureLimitLowersTheRoutesBudget() {
        let route = ProviderProfile(kind: .openAICompat, name: "stub", baseURL: "http://stub.test/v1", model: "stub-model")
        XCTAssertEqual(transport.imageLimit(for: route), 8)
        transport.learnImageLimit(2, routeID: route.routeID)
        XCTAssertEqual(transport.imageLimit(for: route), 2)
        XCTAssertEqual(config.learnedImageLimits[route.routeID], 2)
        // The setting still caps it from above.
        config.maxImagesPerRequest = 1
        XCTAssertEqual(transport.imageLimit(for: route), 1)
    }

    // MARK: The editor pane

    func testTheEditorPaneIsOptional() {
        XCTAssertFalse(CodeModeView.editorVisible(mode: .whenFileOpen, openFiles: 0), "no empty pane by default")
        XCTAssertTrue(CodeModeView.editorVisible(mode: .whenFileOpen, openFiles: 2))
        XCTAssertFalse(CodeModeView.editorVisible(mode: .hidden, openFiles: 2), "hidden stays hidden with files open")
        XCTAssertTrue(CodeModeView.editorVisible(mode: .always, openFiles: 0))
    }

    func testTheEditorButtonAlwaysTogglesWhatIsOnScreen() {
        XCTAssertEqual(CodeModeView.toggledEditorMode(from: .whenFileOpen, openFiles: 2), .hidden)
        XCTAssertEqual(CodeModeView.toggledEditorMode(from: .always, openFiles: 0), .hidden)
        XCTAssertEqual(CodeModeView.toggledEditorMode(from: .hidden, openFiles: 2), .whenFileOpen)
        XCTAssertEqual(CodeModeView.toggledEditorMode(from: .hidden, openFiles: 0), .always)
        XCTAssertEqual(CodeModeView.toggledEditorMode(from: .whenFileOpen, openFiles: 0), .always)
    }
}

/// Small windows: panes step aside or shorten instead of being cut off at the window's edges.
final class SmallWindowLayoutTests: XCTestCase {
    func testTheFileTreeStepsAsideBeforeThePanesOverflow() {
        // The smallest window (900 wide) with the 200-point sidebar leaves about 700 for code mode.
        XCTAssertTrue(CodeModeView.treeFits(width: 700, centerVisible: true), "tree + editor + agent fit at the minimum")
        XCTAssertFalse(CodeModeView.treeFits(width: 640, centerVisible: true))
        XCTAssertTrue(CodeModeView.treeFits(width: 640, centerVisible: false), "with no editor the tree stays")
        XCTAssertFalse(CodeModeView.treeFits(width: 400, centerVisible: false))
        XCTAssertLessThanOrEqual(CodePaneWidths.tree + CodePaneWidths.center + CodePaneWidths.chat, 700)
    }

    func testThePlanSitsBesideTheWorkOnlyWhenBothFit() {
        XCTAssertTrue(RootView.planFitsBeside(width: 1_200, planWidth: 320, codeMode: false))
        XCTAssertTrue(RootView.planFitsBeside(width: 1_200, planWidth: 320, codeMode: true))
        XCTAssertFalse(RootView.planFitsBeside(width: 700, planWidth: 320, codeMode: false), "it goes over the chat instead")
        XCTAssertFalse(RootView.planFitsBeside(width: 900, planWidth: 320, codeMode: true))
    }
}
