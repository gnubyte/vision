import XCTest
import UIKit
import VisionHarnessCore
@testable import Vision

/// The iPhone app's own model against a real Spark Swapper — the Swapper's own code, running in its demo mode
/// with its self-signed certificate — and a stand-in model server that takes only two pictures a request.
/// `iOS/live-check.sh` starts both and runs this in the simulator; without them the test is skipped.
///
///   VISION_SWAPPER_URL   https://127.0.0.1:<port>   (the demo signs in as admin/admin)
///   VISION_MODEL_API     http://127.0.0.1:<port>/v1
@MainActor
final class LiveSwapperTests: XCTestCase {
    private var folder: URL!
    private var suite: String!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("vision-live-\(UUID().uuidString)")
        suite = "vision-live-\(UUID().uuidString)"
    }

    override func tearDown() async throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
        if let suite { UserDefaults.standard.removePersistentDomain(forName: suite) }
    }

    private func makeModel() -> MobileModel {
        MobileModel(defaults: UserDefaults(suiteName: suite)!, secrets: MemorySecretStore(), storage: folder)
    }

    private func swapperAddress() throws -> String {
        guard let address = ProcessInfo.processInfo.environment["VISION_SWAPPER_URL"], !address.isEmpty else {
            throw XCTSkip("set VISION_SWAPPER_URL to a running Spark Swapper (iOS/live-check.sh does)")
        }
        return address
    }

    private func picture(_ hue: CGFloat) -> MessageAttachment {
        let size = CGSize(width: 64, height: 64)
        let image = UIGraphicsImageRenderer(size: size).image { context in
            UIColor(hue: hue, saturation: 0.7, brightness: 0.9, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        return MessageAttachment(kind: .image, name: "picture-\(Int(hue * 100)).png", data: image.pngData()!)
    }

    private func pdf(_ text: String) -> MessageAttachment {
        let page = CGRect(x: 0, y: 0, width: 612, height: 792)
        let data = UIGraphicsPDFRenderer(bounds: page).pdfData { context in
            context.beginPage()
            (text as NSString).draw(in: page.insetBy(dx: 72, dy: 72),
                                    withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
        }
        return MessageAttachment(kind: .file, name: "brief.pdf", data: data)
    }

    private func wait(_ what: String, seconds: TimeInterval = 30, until done: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while !done() {
            if Date() > deadline { return XCTFail("timed out waiting for \(what)") }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: Adding a box

    /// The address-and-login way: the box's certificate is shown first, nothing is sent until it is trusted, and
    /// the login is traded for an app token.
    func testAddingABoxBySigningIn() async throws {
        let address = try swapperAddress()
        let model = makeModel()

        guard case .needsTrust(let fingerprint) = try await model.addBox(address: address, username: "admin",
                                                                         password: "admin", trusted: nil) else {
            return XCTFail("a box with its own certificate must ask for trust first")
        }
        XCTAssertEqual(fingerprint.split(separator: ":").count, 32, "a SHA-256 fingerprint")
        XCTAssertTrue(model.connections.isEmpty, "nothing is kept before the certificate is trusted")

        guard case .added = try await model.addBox(address: address, username: "admin", password: "admin",
                                                   trusted: fingerprint) else {
            return XCTFail("signing in with the certificate trusted adds the box")
        }
        let box = try XCTUnwrap(model.connections.first)
        XCTAssertEqual(box.authKind, "token", "the password is traded for an app token")
        XCTAssertTrue(CertificatePin.matches(box.pinnedFingerprint, fingerprint))
        let status = try XCTUnwrap(model.statuses[box.id], model.boxErrors[box.id] ?? "no status")
        XCTAssertFalse(status.installedModels.isEmpty)
        XCTAssertNotNil(status.activeModel)
        print("LIVE: signed in to \(box.name) (Swapper \(status.version ?? "?")), serving \(status.activeModel?.title ?? "-"), \(status.installedModels.count) models installed")

        // Trusting some other certificate doesn't get in: the box's real one is shown again and nothing is kept.
        let other = makeModel()
        let wrong = String(fingerprint.reversed())
        XCTAssertFalse(CertificatePin.matches(wrong, fingerprint))
        guard case .needsTrust(let shown) = try await other.addBox(address: address, username: "admin",
                                                                   password: "admin", trusted: wrong) else {
            return XCTFail("a box presenting another certificate than the trusted one must not be added")
        }
        XCTAssertTrue(CertificatePin.matches(shown, fingerprint))
        XCTAssertTrue(other.connections.isEmpty)
    }

    /// The connection-code way, then a chat with too many pictures and a PDF, then a switch.
    func testAConnectionCodeAChatAndASwitch() async throws {
        let address = try swapperAddress()
        let url = try XCTUnwrap(SparkSwapperClient.normalizedURL(address))

        // The code the Swapper's Connect tab hands out (made here the way the page makes it: sign in, create a token).
        let probed = await SparkSwapperClient.probeFingerprint(url)
        let fingerprint = try XCTUnwrap(probed, "the Swapper's certificate")
        let admin = SparkSwapperClient(baseURL: url, username: "admin", password: "admin", pinnedFingerprint: fingerprint)
        let grant = try await admin.createToken(label: "Vision live check")
        let code = try XCTUnwrap(grant.code)
        XCTAssertTrue(code.hasPrefix("SSC1:"))

        let model = makeModel()
        try await model.addBox(code: code)
        var box = try XCTUnwrap(model.connections.first)
        XCTAssertEqual(box.authKind, "token")
        XCTAssertTrue(CertificatePin.matches(box.pinnedFingerprint, fingerprint), "the code carries the certificate")
        let status = try XCTUnwrap(model.statuses[box.id])
        let serving = try XCTUnwrap(status.activeModel)
        print("LIVE: connected by code to \(box.name), serving \(serving.title) (\(serving.served_id))")

        // A fresh model reads the same box back from what was kept.
        await model.refreshAll()
        XCTAssertNil(model.boxErrors[box.id])

        // Chat. The demo Swapper serves no model, so the model API is the stand-in that takes two pictures.
        if let api = ProcessInfo.processInfo.environment["VISION_MODEL_API"], !api.isEmpty {
            let index = try XCTUnwrap(model.connections.firstIndex { $0.id == box.id })
            model.connections[index].apiBase = api
            box = model.connections[index]
            let chat = model.newChat(boxID: box.id)

            // Three pictures to a server that takes two: refused once, the limit learned, the turn answered.
            model.send("Compare these three.", attachments: [picture(0.1), picture(0.4), picture(0.7)], in: chat)
            try await wait("the first reply") { !model.running.contains(chat) }
            var entries = try XCTUnwrap(model.chat(chat)).entries
            XCTAssertEqual(entries.last?.role, .assistant, entries.last?.text ?? "")
            XCTAssertTrue(entries.last?.text.contains("saw 2 picture(s)") == true, entries.last?.text ?? "")
            XCTAssertTrue(entries.last?.text.contains("model \(serving.served_id)") == true, "it asks for the model the box serves")
            XCTAssertTrue(entries.contains { $0.role == .notice && $0.text.contains("takes 2 pictures per request") })
            XCTAssertEqual(model.learnedImageLimits.values.first, 2)
            XCTAssertEqual(entries.first?.attachments.count, 3, "all three stay in the chat")

            // Two more: with the limit known, the request is not refused again — the oldest roll off.
            model.send("And these two?", attachments: [picture(0.2), picture(0.9)], in: chat)
            try await wait("the second reply") { !model.running.contains(chat) }
            entries = try XCTUnwrap(model.chat(chat)).entries
            XCTAssertTrue(entries.last?.text.contains("saw 2 picture(s)") == true, entries.last?.text ?? "")
            XCTAssertFalse(entries.contains { $0.role == .error }, entries.filter { $0.role == .error }.map(\.text).joined())

            // A PDF goes as its text, not as a file part the server would refuse.
            model.send("Summarise the brief.", attachments: [pdf("The launch moves to the ninth of March.")], in: chat)
            try await wait("the PDF reply") { !model.running.contains(chat) }
            entries = try XCTUnwrap(model.chat(chat)).entries
            XCTAssertTrue(entries.last?.text.contains("pdf text: yes") == true, entries.last?.text ?? "")
            let sent = try XCTUnwrap(model.chat(chat)).transcript.last { $0.role == .user }
            XCTAssertTrue(sent.content?.contains("The launch moves to the ninth of March.") == true)

            // The prompt history has all three, with what they carried still on disk.
            let prompts = model.history.records(inChat: chat)
            XCTAssertEqual(prompts.map(\.text), ["Compare these three.", "And these two?", "Summarise the brief."])
            XCTAssertEqual(prompts.first?.attachmentFiles?.compactMap(\.url).count, 3)
            XCTAssertTrue(prompts.allSatisfy { if case .completed = $0.outcome { return true } else { return false } })
            print("LIVE: chat answered — \(entries.last?.text ?? "")")
        } else {
            print("LIVE: VISION_MODEL_API not set — chat not checked")
        }

        // Switch to another installed model: the box takes the request and reports the job.
        let target = try XCTUnwrap(status.installedModels.first { $0.key != status.active })
        await model.swap(box.id, to: target.key)
        XCTAssertNil(model.boxErrors[box.id], model.boxErrors[box.id] ?? "")
        for _ in 0..<40 where model.statuses[box.id]?.job?.target != target.key {
            try await Task.sleep(nanoseconds: 250_000_000)
            await model.refresh(box.id)
        }
        XCTAssertEqual(model.statuses[box.id]?.job?.target, target.key, "the box reports the switch it was asked for")
        XCTAssertTrue(model.summary(for: box.id).contains("Loading") || model.statuses[box.id]?.isSwitching == false)
        print("LIVE: switch to \(target.title) accepted — \(model.summary(for: box.id))")
    }
}
