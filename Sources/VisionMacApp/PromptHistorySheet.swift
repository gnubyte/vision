import SwiftUI
import AppKit
import VisionHarnessCore

/// The prompt history: every prompt the harness has taken, with when it was sent, how long its turn took, how it
/// ended, and what it carried in (files, screenshots) and produced (files changed).
///
/// It opens on one chat's prompts (from the chat's own "N prompts" line, or ⇧⌘H) or on all of them (the
/// sidebar, ⌃⌘P), and can be switched between the two. The list sorts by time either way or by how long the
/// turns ran, and the prompts shown — whatever the scope, search and order — copy out or export as Markdown,
/// CSV or JSON with their timestamps. A prompt's attachments are kept on disk, so they open again from here and
/// can be attached to a new prompt.
struct PromptHistorySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var modeFilter: PromptHistoryRecord.Mode?
    @State private var sort: PromptHistorySort = .newestFirst
    /// The chat whose prompts are listed; nil lists every chat's.
    @State private var chatID: String?
    @State private var expanded: String?
    @State private var copied: String?
    /// Re-reads on change (records land as turns finish).
    @State private var revision = 0

    private var store: PromptHistoryStore { model.transport.promptHistory }

    private var records: [PromptHistoryRecord] {
        _ = revision
        let found = store.search(query: query, mode: chatID == nil ? modeFilter : nil, chatID: chatID, limit: 2_000)
        return sort.apply(found)
    }

    /// The chat the sheet can be scoped to: the one it was opened on, else the selected one.
    private var scopeChat: (id: String, title: String)? {
        let id = model.promptHistoryChatID ?? model.selectedSession?.id
        guard let id else { return nil }
        let title = model.transport.sessions.first { $0.id == id }?.title
            ?? store.records(inChat: id).last?.chatTitle
        return title.map { (id, $0) }
    }

    var body: some View {
        let shown = records
        VStack(spacing: 0) {
            header(shown)
            Divider()
            filterBar
            Divider()
            if shown.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(shown) { record in
                        row(record)
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 1, leading: 6, bottom: 1, trailing: 6))
                    }
                }
                .listStyle(.plain)
            }
            Divider()
            footer(shown)
        }
        .frame(minWidth: 680, idealWidth: 780, minHeight: 480, idealHeight: 660)
        .onAppear { chatID = model.promptHistoryChatID }
        .task {
            // Records land as turns finish; re-read gently while open.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                revision += 1
            }
        }
    }

    // MARK: Header

    private func header(_ shown: [PromptHistoryRecord]) -> some View {
        HStack(spacing: 10) {
            Label("Prompt History", systemImage: "clock.arrow.circlepath")
                .font(.headline)
            if let chat = scopeChat {
                Picker("", selection: $chatID) {
                    Text("This chat").tag(String?.some(chat.id))
                    Text("All chats").tag(String?.none)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("“\(chat.title)” only, or every chat")
            }
            Spacer()
            Picker("Sort", selection: $sort) {
                ForEach(PromptHistorySort.allCases, id: \.self) { order in
                    Text(order.label).tag(order)
                }
            }
            .labelsHidden()
            .fixedSize()
            .help("Order by when each prompt was sent, or by how long its turn ran")
            Menu {
                ForEach(PromptHistoryExport.Format.allCases, id: \.self) { format in
                    Button("Copy as \(format.label)") { copy(shown, as: format) }
                }
                Divider()
                ForEach(PromptHistoryExport.Format.allCases, id: \.self) { format in
                    Button("Save as \(format.label)…") { export(shown, as: format) }
                }
            } label: {
                Label(copied ?? "Copy All", systemImage: copied == nil ? "doc.on.doc" : "checkmark")
            }
            .fixedSize()
            .disabled(shown.isEmpty)
            .help("Copy or save the prompts listed below, in this order, with their timestamps")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var filterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField(chatID == nil ? "Search prompts, chats and attachment names" : "Search this chat's prompts",
                          text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
            if chatID == nil {
                Picker("", selection: $modeFilter) {
                    Text("All modes").tag(PromptHistoryRecord.Mode?.none)
                    ForEach(PromptHistoryRecord.Mode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(PromptHistoryRecord.Mode?.some(mode))
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 330)
            }
        }
        .padding(10)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(query.isEmpty ? "No prompts yet" : "No prompts match")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text(chatID == nil
                 ? "Every prompt sent in chat, code, agent and automations lands here, with when it was sent, how long it took and what it carried."
                 : "Prompts sent in this chat land here, with when they were sent, how long they took and what they carried.")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 60)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func footer(_ shown: [PromptHistoryRecord]) -> some View {
        HStack {
            Text(summary(shown))
                .font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func summary(_ shown: [PromptHistoryRecord]) -> String {
        var parts = ["\(shown.count) prompt\(shown.count == 1 ? "" : "s")"]
        if let first = shown.map(\.at).min(), let last = shown.map(\.at).max(), shown.count > 1 {
            parts.append("\(Self.day.string(from: first)) – \(Self.day.string(from: last))")
        }
        let total = shown.compactMap(\.duration).reduce(0, +)
        if total > 0 { parts.append("\(total.formattedDuration) of work") }
        let files = shown.reduce(0) { $0 + ($1.attachmentFiles?.count ?? $1.attachments.count) }
        if files > 0 { parts.append("\(files) attachment\(files == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    // MARK: Rows

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return formatter
    }()

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy  HH:mm:ss"
        return formatter
    }()

    @ViewBuilder
    private func row(_ record: PromptHistoryRecord) -> some View {
        let isOpen = expanded == record.id
        let attached = record.attachmentFiles?.count ?? record.attachments.count
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.12)) { expanded = isOpen ? nil : record.id }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Self.stamp.string(from: record.at))
                        .font(Theme.mono(10))
                        .foregroundStyle(.secondary)
                        .frame(width: 138, alignment: .leading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.text)
                            .font(.system(size: 12))
                            .lineLimit(isOpen ? 1 : 2)
                            .multilineTextAlignment(.leading)
                        if chatID == nil {
                            HStack(spacing: 4) {
                                modeChip(record.mode)
                                Text(record.chatTitle).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    if attached > 0 {
                        Label("\(attached)", systemImage: "paperclip")
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                            .help(record.attachments.joined(separator: ", "))
                    }
                    if let duration = record.duration {
                        Text(duration.formattedDuration)
                            .font(Theme.mono(9.5)).foregroundStyle(.tertiary)
                    }
                    outcomeChip(record.outcome)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen { detail(record) }
        }
        .background(isOpen ? Theme.surface.opacity(0.5) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
    }

    private func detail(_ record: PromptHistoryRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(record.text)
                .font(.system(size: 11.5))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.surface.opacity(0.7), in: RoundedRectangle(cornerRadius: 6))
            if let files = record.attachmentFiles, !files.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(files) { file in AttachmentTile(file: file) }
                    }
                }
            } else if !record.attachments.isEmpty {
                // A prompt from before attachments were kept: only their names are known.
                Label(record.attachments.joined(separator: ", "), systemImage: "paperclip")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(2)
            }
            if !record.changedFiles.isEmpty {
                Label(record.changedFiles.joined(separator: ", "), systemImage: "doc.badge.gearshape")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(3)
            }
            HStack(spacing: 12) {
                Button("Copy") { Self.copyToPasteboard(record.text) }
                Button("Copy with details") {
                    Self.copyToPasteboard(PromptHistoryExport.markdown([record]))
                }
                Button("Reuse in composer") {
                    model.pendingComposerText = record.text
                    dismiss()
                }
                if let files = record.attachmentFiles, files.contains(where: { $0.url != nil }) {
                    Button("Attach again") {
                        model.pendingComposerAttachments = files.compactMap { file in
                            guard let url = file.url, let data = try? Data(contentsOf: url) else { return nil }
                            return MessageAttachment(kind: file.kind, name: file.name, data: data)
                        }
                        dismiss()
                    }
                    .help("Put these files back on the composer for a new prompt")
                }
                if model.transport.sessions.contains(where: { $0.id == record.chatID }),
                   record.chatID != model.selectedSession?.id {
                    Button("Open its chat") {
                        model.openSession(record.chatID)
                        dismiss()
                    }
                }
                Spacer()
                if let name = record.model, !name.isEmpty {
                    Text(name).font(Theme.mono(9.5)).foregroundStyle(.tertiary)
                }
            }
            .font(Theme.metaFont)
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
        }
        .padding(.leading, 156)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
    }

    // MARK: Copying out

    private static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copy(_ shown: [PromptHistoryRecord], as format: PromptHistoryExport.Format) {
        Self.copyToPasteboard(PromptHistoryExport.render(shown, as: format))
        copied = "Copied \(shown.count)"
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copied = nil
        }
    }

    private func export(_ shown: [PromptHistoryRecord], as format: PromptHistoryExport.Format) {
        let panel = NSSavePanel()
        let scope = chatID.flatMap { _ in scopeChat?.title } ?? "all chats"
        let cleaned = scope.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        panel.nameFieldStringValue = "prompts-\(String(cleaned).prefix(40)).\(format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try PromptHistoryExport.render(shown, as: format).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.transport.banner = "Couldn't save the prompts: \(error.localizedDescription)"
        }
    }

    // MARK: Chips

    private func modeChip(_ mode: PromptHistoryRecord.Mode) -> some View {
        let (icon, tint): (String, Color) = switch mode {
        case .chat: ("bubble.left", .secondary)
        case .code: ("chevron.left.forwardslash.chevron.right", .orange)
        case .agent: ("brain.head.profile", .accentColor)
        case .automation: ("clock.badge.checkmark", Theme.successTint)
        }
        return Image(systemName: icon)
            .font(.system(size: 9))
            .foregroundStyle(tint)
            .help(mode.label)
    }

    @ViewBuilder
    private func outcomeChip(_ outcome: PromptHistoryRecord.Outcome) -> some View {
        switch outcome {
        case .working:
            Label("working", systemImage: "hourglass")
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
        case .completed:
            Label("done", systemImage: "checkmark.circle.fill")
                .font(.system(size: 9.5)).foregroundStyle(Theme.successTint)
        case .blocked:
            Label("needs you", systemImage: "pause.circle")
                .font(.system(size: 9.5)).foregroundStyle(Theme.noticeTint)
        case .failed:
            Label("failed", systemImage: "xmark.circle")
                .font(.system(size: 9.5)).foregroundStyle(Theme.errorTint)
        case .stopped:
            Label("stopped", systemImage: "stop.circle")
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
        }
    }
}

/// One attachment a prompt carried: a thumbnail for a picture, an icon for a file. Click opens it; the menu
/// reveals it in Finder or copies its path.
private struct AttachmentTile: View {
    let file: AttachmentReference
    @State private var thumbnail: NSImage?

    var body: some View {
        Button {
            if let url = file.url { NSWorkspace.shared.open(url) }
        } label: {
            VStack(spacing: 3) {
                Group {
                    if let thumbnail {
                        Image(nsImage: thumbnail)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: file.isImage ? "photo" : "doc.text")
                            .font(.system(size: 20))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 96, height: 64)
                .background(Theme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.hairline, lineWidth: 1))
                Text(file.name)
                    .font(.system(size: 9.5))
                    .foregroundStyle(file.url == nil ? HierarchicalShapeStyle.tertiary : HierarchicalShapeStyle.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 96)
            }
        }
        .buttonStyle(.plain)
        .disabled(file.url == nil)
        .help(file.url.map { "\(file.name) — click to open\n\($0.path)" } ?? "\(file.name) is no longer on disk")
        .contextMenu {
            if let url = file.url {
                Button("Open") { NSWorkspace.shared.open(url) }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            }
        }
        .task(id: file.id) {
            guard file.isImage, let url = file.url else { return }
            let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
            thumbnail = data.flatMap { ImageThumbnails.make(from: $0) }.flatMap { NSImage(data: $0) }
                ?? data.flatMap { NSImage(data: $0) }
        }
    }
}
