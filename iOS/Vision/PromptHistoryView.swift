import SwiftUI
import UIKit
import QuickLook
import VisionHarnessCore

/// The prompt history: one chat's prompts or every chat's, ordered by when they were sent (or how long they
/// ran), searchable, and copyable as Markdown, CSV or JSON with their timestamps. What a prompt carried — a
/// screenshot, a PDF — is kept on the phone and opens again from here.
struct PromptHistoryView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    /// The chat it was opened from (nil: opened on every chat).
    let chatID: String?
    @State private var allChats = false
    @State private var sort = PromptHistorySort.newestFirst
    @State private var query = ""
    @State private var expanded: String?
    @State private var preview: URL?
    @State private var copied = false

    private var scope: String? { allChats ? nil : chatID }

    private var records: [PromptHistoryRecord] {
        sort.apply(model.history.search(query: query, chatID: scope, limit: 2_000))
    }

    var body: some View {
        let shown = records
        NavigationStack {
            List {
                if chatID != nil {
                    Picker("Scope", selection: $allChats) {
                        Text("This chat").tag(false)
                        Text("All chats").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .listRowSeparator(.hidden)
                }
                if shown.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No prompts yet" : "No prompts match",
                                           systemImage: "clock.arrow.circlepath",
                                           description: Text("Every prompt you send lands here with when it was sent, how long it took and what it carried."))
                        .listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(shown) { record in
                            row(record)
                        }
                    } footer: {
                        Text(summary(shown))
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Search prompts and attachments")
            .navigationTitle("Prompt History")
            .navigationBarTitleDisplayMode(.inline)
            .quickLookPreview($preview)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Menu {
                        Picker("Order", selection: $sort) {
                            ForEach(PromptHistorySort.allCases, id: \.self) { order in
                                Text(order.label).tag(order)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Sort")
                    Menu {
                        ForEach(PromptHistoryExport.Format.allCases, id: \.self) { format in
                            Button("Copy as \(format.label)") {
                                UIPasteboard.general.string = PromptHistoryExport.render(shown, as: format)
                                copied = true
                            }
                        }
                        Divider()
                        ForEach(PromptHistoryExport.Format.allCases, id: \.self) { format in
                            ShareLink("Share as \(format.label)", item: PromptHistoryExport.render(shown, as: format))
                        }
                    } label: {
                        Image(systemName: copied ? "checkmark" : "square.and.arrow.up")
                    }
                    .accessibilityLabel("Copy or share these prompts")
                    .disabled(shown.isEmpty)
                }
            }
            .onChange(of: copied) { _, now in
                guard now else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            }
        }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy · HH:mm:ss"
        return formatter
    }()

    private func summary(_ shown: [PromptHistoryRecord]) -> String {
        var parts = ["\(shown.count) prompt\(shown.count == 1 ? "" : "s")"]
        let files = shown.reduce(0) { $0 + ($1.attachmentFiles?.count ?? $1.attachments.count) }
        if files > 0 { parts.append("\(files) attachment\(files == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func row(_ record: PromptHistoryRecord) -> some View {
        let isOpen = expanded == record.id
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(Self.stamp.string(from: record.at))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                if let duration = record.duration {
                    Text(PromptHistoryView.duration(duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                outcome(record.outcome)
            }
            Text(record.text.isEmpty ? "(attachments only)" : record.text)
                .font(.subheadline)
                .lineLimit(isOpen ? nil : 2)
                .textSelection(.enabled)
            if scope == nil {
                Text(record.chatTitle).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
            }
            if let files = record.attachmentFiles, !files.isEmpty {
                if isOpen {
                    AttachmentStrip(files: files, preview: $preview)
                } else {
                    Label(files.map(\.name).joined(separator: ", "), systemImage: "paperclip")
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            if isOpen {
                HStack(spacing: 16) {
                    Button {
                        UIPasteboard.general.string = record.text
                    } label: {
                        Label("Copy", systemImage: "doc.on.doc")
                    }
                    Button {
                        UIPasteboard.general.string = PromptHistoryExport.markdown([record])
                    } label: {
                        Label("Copy with details", systemImage: "doc.text")
                    }
                    Spacer()
                    if let name = record.model {
                        Text(name).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.15)) { expanded = isOpen ? nil : record.id }
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole)s" }
        return "\(whole / 60)m \(whole % 60)s"
    }

    @ViewBuilder
    private func outcome(_ outcome: PromptHistoryRecord.Outcome) -> some View {
        switch outcome {
        case .working: Image(systemName: "hourglass").foregroundStyle(.secondary).font(.caption2)
        case .completed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption2)
        case .blocked: Image(systemName: "pause.circle").foregroundStyle(.orange).font(.caption2)
        case .failed: Image(systemName: "xmark.circle").foregroundStyle(.red).font(.caption2)
        case .stopped: Image(systemName: "stop.circle").foregroundStyle(.secondary).font(.caption2)
        }
    }
}
