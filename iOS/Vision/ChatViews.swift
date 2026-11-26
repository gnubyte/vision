import SwiftUI
import UIKit
import PhotosUI
import QuickLook
import UniformTypeIdentifiers
import VisionHarnessCore

// MARK: - The list of chats

struct ChatListView: View {
    @Environment(MobileModel.self) private var model
    let openBoxes: () -> Void
    @State private var path: [String] = []
    @State private var showHistory = false

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.connections.isEmpty {
                    ContentUnavailableView {
                        Label("Add a Spark Swapper first", systemImage: "server.rack")
                    } description: {
                        Text("Vision chats with the model your own box serves.")
                    } actions: {
                        Button("Go to Boxes", action: openBoxes).buttonStyle(.borderedProminent)
                    }
                } else if model.chats.isEmpty {
                    ContentUnavailableView {
                        Label("No chats yet", systemImage: "bubble.left.and.bubble.right")
                    } description: {
                        Text("Ask something, attach a photo or a PDF.")
                    } actions: {
                        Button("New Chat") { open(model.newChat()) }.buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(model.chats) { chat in
                            NavigationLink(value: chat.id) { ChatRow(chat: chat) }
                        }
                        .onDelete { offsets in
                            for id in offsets.map({ model.chats[$0].id }) { model.deleteChat(id) }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Chats")
            .navigationDestination(for: String.self) { id in
                ChatView(chatID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                        .accessibilityLabel("Prompt history")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { open(model.newChat()) } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel("New chat")
                        .disabled(model.connections.isEmpty)
                }
            }
            .sheet(isPresented: $showHistory) {
                PromptHistoryView(chatID: nil)
            }
        }
    }

    private func open(_ id: String) {
        path = [id]
    }
}

private struct ChatRow: View {
    @Environment(MobileModel.self) private var model
    let chat: MobileChat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(chat.title).font(.body.weight(.medium)).lineLimit(1)
                Spacer()
                if model.running.contains(chat.id) {
                    ProgressView().controlSize(.mini)
                } else {
                    Text(chat.updatedAt, format: .relative(presentation: .named))
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }
            if let last = chat.entries.last(where: { $0.role == .assistant || $0.role == .user }) {
                Text(last.text.isEmpty ? "\(last.attachments.count) attachment\(last.attachments.count == 1 ? "" : "s")" : last.text)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - One chat

struct ChatView: View {
    @Environment(MobileModel.self) private var model
    let chatID: String
    @State private var draft = ""
    @State private var staged: [MessageAttachment] = []
    @State private var pickingPhotos = false
    @State private var pickedPhotos: [PhotosPickerItem] = []
    @State private var pickingFiles = false
    @State private var showHistory = false
    @State private var preview: URL?
    @State private var problem: String?
    @FocusState private var composing: Bool

    private static let bottom = "bottom"

    var body: some View {
        let chat = model.chat(chatID)
        let running = model.running.contains(chatID)
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        if let chat, chat.entries.isEmpty, !running {
                            starter
                        }
                        ForEach(chat?.entries ?? []) { entry in
                            EntryRow(entry: entry, preview: $preview)
                        }
                        if running {
                            LiveReply(text: model.streaming[chatID] ?? "", thinking: model.thinking[chatID])
                        }
                        Color.clear.frame(height: 1).id(Self.bottom)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: model.streaming[chatID]) { _, _ in
                    proxy.scrollTo(Self.bottom, anchor: .bottom)
                }
                .onChange(of: chat?.entries.count) { _, _ in
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                }
                .onAppear { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            Divider()
            composer(running: running)
        }
        .navigationTitle(chat?.title ?? "Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { titleMenu(chat) }
            ToolbarItem(placement: .topBarTrailing) {
                Button { showHistory = true } label: { Image(systemName: "clock.arrow.circlepath") }
                    .accessibilityLabel("This chat's prompts")
            }
        }
        .sheet(isPresented: $showHistory) { PromptHistoryView(chatID: chatID) }
        .quickLookPreview($preview)
        .photosPicker(isPresented: $pickingPhotos, selection: $pickedPhotos, maxSelectionCount: 8, matching: .images)
        .fileImporter(isPresented: $pickingFiles,
                      allowedContentTypes: [.pdf, .text, .plainText, .sourceCode, .json, .commaSeparatedText, .image],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result { urls.forEach(stage(file:)) }
        }
        .onChange(of: pickedPhotos) { _, items in
            guard !items.isEmpty else { return }
            pickedPhotos = []
            Task { await stage(photos: items) }
        }
        .alert("Couldn't attach that", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: Title: the chat, and the box behind it

    private func titleMenu(_ chat: MobileChat?) -> some View {
        let connection = model.connection(chat?.boxID)
        return Menu {
            if model.connections.count > 1 {
                Section("Box") {
                    ForEach(model.connections) { box in
                        Button {
                            model.setBox(box.id, for: chatID)
                        } label: {
                            if box.id == connection?.id {
                                Label(box.name, systemImage: "checkmark")
                            } else {
                                Text(box.name)
                            }
                        }
                    }
                }
            }
            if let connection {
                Section("Serving") {
                    Text(model.summary(for: connection.id))
                }
            }
        } label: {
            VStack(spacing: 0) {
                Text(chat?.title ?? "Chat").font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(subtitle(connection)).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .tint(.primary)
    }

    private func subtitle(_ connection: SwapperConnection?) -> String {
        guard let connection else { return "No box" }
        let status = model.statuses[connection.id]
        if status?.isSwitching == true { return "\(connection.name) · switching…" }
        return status?.activeModel.map { "\($0.title) · \(connection.name)" } ?? connection.name
    }

    private var starter: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles").font(.title).foregroundStyle(.tint)
            Text("Ask anything").font(.headline)
            Text("Attach photos, screenshots or a PDF with the + button. Vision keeps the newest pictures in view and remembers the rest in this chat's prompt history.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 60)
        .padding(.horizontal, 24)
    }

    // MARK: Composer

    private func composer(running: Bool) -> some View {
        VStack(spacing: 6) {
            if !staged.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(staged.enumerated()), id: \.offset) { index, attachment in
                            StagedChip(attachment: attachment) { staged.remove(at: index) }
                        }
                    }
                    .padding(.horizontal, 12)
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Menu {
                    Button { pickingPhotos = true } label: { Label("Photos", systemImage: "photo.on.rectangle") }
                    Button { pickingFiles = true } label: { Label("Files & PDFs", systemImage: "doc") }
                    Button { pasteImage() } label: { Label("Paste Picture", systemImage: "doc.on.clipboard") }
                        .disabled(!UIPasteboard.general.hasImages)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                }
                .accessibilityLabel("Attach")

                TextField("Message", text: $draft, axis: .vertical)
                    .lineLimit(1...6)
                    .focused($composing)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))

                if running {
                    Button { model.stop(chatID) } label: {
                        Image(systemName: "stop.circle.fill").font(.title).foregroundStyle(.red)
                    }
                    .accessibilityLabel("Stop")
                } else {
                    Button(action: send) {
                        Image(systemName: "arrow.up.circle.fill").font(.title)
                    }
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && staged.isEmpty)
                    .accessibilityLabel("Send")
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func send() {
        model.send(draft, attachments: staged, in: chatID)
        draft = ""
        staged = []
    }

    // MARK: Attaching

    private func stage(_ attachment: MessageAttachment) {
        guard !staged.contains(attachment) else { return }
        staged.append(attachment)
    }

    private func stage(photos items: [PhotosPickerItem]) async {
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                problem = "One of the photos couldn't be read."
                continue
            }
            stage(Self.picture(from: data, name: "photo-\(Self.stamp()).jpg"))
        }
    }

    /// A picture as a model server reads it: PNG as it is, anything else (HEIC from the camera roll included)
    /// as JPEG.
    private static func picture(from data: Data, name: String) -> MessageAttachment {
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return MessageAttachment(kind: .image, name: (name as NSString).deletingPathExtension + ".png", data: data)
        }
        if data.starts(with: [0xFF, 0xD8]) {
            return MessageAttachment(kind: .image, name: name, data: data)
        }
        let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85)
        return MessageAttachment(kind: .image, name: name, data: jpeg ?? data)
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }

    private func stage(file url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            problem = "\(url.lastPathComponent) couldn't be read."
            return
        }
        guard data.count <= 40 * 1_048_576 else {
            problem = "\(url.lastPathComponent) is larger than 40 MB."
            return
        }
        let isImage = UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
        stage(isImage ? Self.picture(from: data, name: url.lastPathComponent)
                      : MessageAttachment(kind: .file, name: url.lastPathComponent, data: data))
    }

    private func pasteImage() {
        guard let image = UIPasteboard.general.image, let data = image.pngData() else { return }
        stage(MessageAttachment(kind: .image, name: "pasted-\(Self.stamp()).png", data: data))
    }
}

// MARK: - Rows

private struct EntryRow: View {
    let entry: ChatEntry
    @Binding var preview: URL?

    var body: some View {
        switch entry.role {
        case .user:
            VStack(alignment: .trailing, spacing: 6) {
                if !entry.attachments.isEmpty {
                    AttachmentStrip(files: entry.attachments, preview: $preview)
                }
                if !entry.text.isEmpty {
                    Text(entry.text)
                        .textSelection(.enabled)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.leading, 40)
            .contextMenu { copyButton }

        case .assistant:
            MarkdownText(text: entry.text)
                .contextMenu { copyButton }

        case .notice:
            Text(entry.text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .error:
            Label(entry.text, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private var copyButton: some View {
        Button {
            UIPasteboard.general.string = entry.text
        } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
    }
}

/// The reply as it streams, or what the model is thinking before it starts.
private struct LiveReply: View {
    let text: String
    let thinking: String?

    var body: some View {
        if text.isEmpty {
            HStack(alignment: .top, spacing: 8) {
                ProgressView().controlSize(.small)
                Text(thinking.map { String($0.suffix(160)) } ?? "Thinking…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        } else {
            MarkdownText(text: text)
        }
    }
}

/// What a prompt carried: thumbnails for pictures, chips for files. A tap opens it.
struct AttachmentStrip: View {
    let files: [AttachmentReference]
    @Binding var preview: URL?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(files) { file in
                    Button {
                        preview = file.url
                    } label: {
                        AttachmentThumbnail(file: file)
                    }
                    .buttonStyle(.plain)
                    .disabled(file.url == nil)
                }
            }
        }
    }
}

struct AttachmentThumbnail: View {
    let file: AttachmentReference
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 72, height: 72)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            } else {
                VStack(spacing: 4) {
                    Image(systemName: file.isImage ? "photo" : "doc.text")
                        .font(.title3)
                    Text(file.name)
                        .font(.caption2)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding(6)
                .frame(width: file.isImage ? 72 : 110, height: 72)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 10))
            }
        }
        .task(id: file.id) {
            guard file.isImage, let url = file.url else { return }
            image = await Task.detached(priority: .utility) {
                UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 216, height: 216))
            }.value
        }
    }
}

private struct StagedChip: View {
    let attachment: MessageAttachment
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if attachment.kind == .image, let image = UIImage(data: attachment.data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: "doc.text").foregroundStyle(.secondary)
            }
            Text(attachment.name).font(.caption).lineLimit(1).frame(maxWidth: 120)
            Button(action: remove) {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color(.secondarySystemBackground), in: Capsule())
    }
}
