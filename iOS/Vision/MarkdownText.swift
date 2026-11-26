import SwiftUI
import UIKit
import VisionHarnessCore

/// A reply rendered as markdown: the same block parser as the Mac app (fences, headings, lists, quotes, tables),
/// laid out for a narrow screen.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Markdown.parse(text).enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func view(for block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            Text(Markdown.inline(text))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let level, let text):
            Text(Markdown.inline(text))
                .font(level <= 1 ? .title3 : (level == 2 ? .headline : .subheadline))
                .bold()
                .padding(.top, 2)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .code(let language, let text):
            CodeBlock(language: language, text: text)

        case .listItem(let marker, let text, let depth):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(Markdown.inline(text))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(depth) * 14)
            .frame(maxWidth: .infinity, alignment: .leading)

        case .quote(let text):
            HStack(spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.4)).frame(width: 3)
                Text(Markdown.inline(text))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .table(let header, let rows):
            TableBlock(header: header, rows: rows)

        case .rule:
            Divider().padding(.vertical, 2)
        }
    }
}

private struct CodeBlock: View {
    let language: String?
    let text: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    UIPasteboard.general.string = text
                    copied = true
                    Task {
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        copied = false
                    }
                } label: {
                    Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                Text(text)
                    .font(.footnote.monospaced())
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// A pipe table; it scrolls sideways rather than squeezing its columns.
private struct TableBlock: View {
    let header: [String]
    let rows: [[String]]

    private var columnCount: Int {
        max(header.count, rows.map(\.count).max() ?? 0)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        Text(Markdown.inline(header.indices.contains(column) ? header[column] : ""))
                            .font(.callout.weight(.semibold))
                    }
                }
                Divider().gridCellColumns(max(1, columnCount))
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            Text(Markdown.inline(row.indices.contains(column) ? row[column] : ""))
                                .font(.callout)
                        }
                    }
                }
            }
            .padding(10)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}
