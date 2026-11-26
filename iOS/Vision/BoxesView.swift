import SwiftUI
import UIKit
import VisionHarnessCore

// MARK: - The boxes

/// The Spark Swapper boxes this phone knows: what each serves now, and the way in to switch it.
struct BoxesView: View {
    @Environment(MobileModel.self) private var model
    @State private var adding = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.connections.isEmpty {
                    ContentUnavailableView {
                        Label("No Spark Swapper yet", systemImage: "server.rack")
                    } description: {
                        Text("Add your DGX Spark or Strix Halo box to chat with the model it serves and switch models from your phone.")
                    } actions: {
                        Button("Add a Box") { adding = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    List {
                        ForEach(model.connections) { connection in
                            NavigationLink(value: connection.id) {
                                BoxRow(connection: connection)
                            }
                        }
                        .onDelete { offsets in
                            for id in offsets.map({ model.connections[$0].id }) { model.removeBox(id) }
                        }
                    }
                    .refreshable { await model.refreshAll() }
                }
            }
            .navigationTitle("Boxes")
            .navigationDestination(for: String.self) { id in
                BoxDetailView(boxID: id)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add a box")
                }
            }
            .sheet(isPresented: $adding) { AddBoxSheet() }
            .onAppear {
                // A demo run can open straight on a box.
                if model.demoScreen == "box", path.isEmpty, let first = model.connections.first { path = [first.id] }
            }
        }
    }
}

private struct BoxRow: View {
    @Environment(MobileModel.self) private var model
    let connection: SwapperConnection

    var body: some View {
        let status = model.statuses[connection.id]
        HStack(spacing: 12) {
            StatusDot(status: status, failed: model.boxErrors[connection.id] != nil)
            VStack(alignment: .leading, spacing: 3) {
                Text(connection.name).font(.headline)
                Text(model.summary(for: connection.id))
                    .font(.subheadline)
                    .foregroundStyle(model.boxErrors[connection.id] != nil && status == nil ? Color.red : Color.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

struct StatusDot: View {
    let status: SwapperStatus?
    let failed: Bool

    var body: some View {
        Group {
            if status?.isSwitching == true {
                ProgressView().controlSize(.small)
            } else {
                Circle().fill(color).frame(width: 10, height: 10)
            }
        }
        .frame(width: 18)
    }

    private var color: Color {
        if failed { return .red }
        guard let status else { return .gray }
        return status.activeModel?.healthy == true ? .green : (status.activeModel == nil ? .gray : .orange)
    }
}

// MARK: - One box

struct BoxDetailView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let boxID: String
    @State private var target: SwapperStatus.Model?
    @State private var removing = false

    var body: some View {
        let connection = model.connections.first { $0.id == boxID }
        let status = model.statuses[boxID]
        List {
            if let connection {
                Section {
                    LabeledContent("Address", value: connection.host ?? connection.url)
                    LabeledContent("Kind", value: connection.platformName)
                    if let version = status?.version ?? connection.version {
                        LabeledContent("Swapper", value: version)
                    }
                    if let memory = status?.memory?.value?.summary {
                        LabeledContent("Memory", value: memory)
                    }
                    if let error = model.boxErrors[boxID] {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
            }

            if let status, status.isSwitching {
                Section("Switching") {
                    SwitchProgress(status: status)
                }
            }

            if let status {
                Section {
                    ForEach(status.installedModels) { item in
                        ModelRow(model: item, isActive: status.active == item.key, busy: status.isSwitching) {
                            target = item
                        }
                    }
                } header: {
                    Text("Models")
                } footer: {
                    Text("Switching stops what the box serves and loads the model you pick. Chats on this box follow it.")
                }
                let missing = status.ordered.filter { !$0.isInstalled }
                if !missing.isEmpty {
                    Section {
                        ForEach(missing) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                if let install = item.install?.summary {
                                    Text(install).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    } header: {
                        Text("Not installed")
                    } footer: {
                        Text("Install these from the Swapper's Models page.")
                    }
                }
            } else if model.boxErrors[boxID] == nil {
                Section { ProgressView("Asking the box…") }
            }

            Section {
                Button("Remove This Box", role: .destructive) { removing = true }
            }
        }
        .navigationTitle(connection?.name ?? "Box")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await model.refresh(boxID) }
        .task {
            await model.refresh(boxID)
            if model.statuses[boxID]?.isSwitching == true { model.watch(boxID) }
        }
        .confirmationDialog(target.map { "Switch to \($0.title)?" } ?? "", isPresented: Binding(
            get: { target != nil }, set: { if !$0 { target = nil } }), titleVisibility: .visible) {
            if let item = target {
                Button("Switch (\(item.switchDuration))") {
                    Task { await model.swap(boxID, to: item.key) }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let item = target {
                Text("\(status?.activeModel.map { "\($0.title) stops, then " } ?? "")\(item.title) loads with a \(SwapperStatus.shortWindow(item.window)) context. If it fails to load, the box brings the previous model back.")
            }
        }
        .confirmationDialog("Remove this box from Vision?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                model.removeBox(boxID)
                dismiss()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its chats stay. The box itself isn't changed; its app token can be revoked on the Swapper's Connect tab.")
        }
    }
}

private struct ModelRow: View {
    let model: SwapperStatus.Model
    let isActive: Bool
    let busy: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isActive ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isActive ? Color.green : Color.secondary)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(model.title).font(.body.weight(isActive ? .semibold : .regular))
                        if model.vision == true {
                            Image(systemName: "photo").font(.caption).foregroundStyle(.secondary)
                                .accessibilityLabel("Reads pictures")
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let tagline = model.tagline, !tagline.isEmpty {
                        Text(tagline).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isActive || busy)
    }

    private var detail: String {
        var parts = ["\(SwapperStatus.shortWindow(model.window)) context"]
        if let speed = model.speedText(roomForEstimate: true) { parts.append(speed) }
        if let engine = model.engine, !engine.isEmpty { parts.append(engine) }
        return parts.joined(separator: " · ")
    }
}

private struct SwitchProgress: View {
    let status: SwapperStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let target = status.loading.flatMap { status.models[$0]?.title } ?? "the model"
            Label("Loading \(target)", systemImage: "arrow.triangle.2.circlepath")
                .font(.subheadline.weight(.semibold))
            if let job = status.job {
                ForEach(Array(job.steps.enumerated()), id: \.offset) { _, step in
                    HStack(spacing: 8) {
                        switch step.state {
                        case "done": Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                        case "running": ProgressView().controlSize(.mini)
                        case "failed": Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
                        default: Image(systemName: "circle").foregroundStyle(.tertiary)
                        }
                        Text(step.label).font(.caption)
                            .foregroundStyle(step.state == "running" ? Color.primary : Color.secondary)
                    }
                }
                if let line = job.lastLogLine {
                    Text(line).font(.caption2.monospaced()).foregroundStyle(.tertiary).lineLimit(2)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Adding a box

struct AddBoxSheet: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var way = Way.code
    @State private var code = ""
    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    /// The certificate the box showed, waiting for the user's word.
    @State private var fingerprint: String?
    @State private var working = false
    @State private var problem: String?

    enum Way: Hashable { case code, login }

    var body: some View {
        NavigationStack {
            Form {
                Picker("How", selection: $way) {
                    Text("Connection code").tag(Way.code)
                    Text("Address & login").tag(Way.login)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)

                switch way {
                case .code:
                    Section {
                        TextField("SSC1:…", text: $code, axis: .vertical)
                            .lineLimit(3...8)
                            .font(.footnote.monospaced())
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        Button {
                            if let text = UIPasteboard.general.string { code = text }
                        } label: {
                            Label("Paste from Clipboard", systemImage: "doc.on.clipboard")
                        }
                    } header: {
                        Text("Connection code")
                    } footer: {
                        Text("On the Swapper's web page open Connect, choose Connect Vision and copy the code. It carries the box's address, its certificate and an app token — no password is stored on this phone.")
                    }
                case .login:
                    Section {
                        TextField("192.168.1.42 or spark.local", text: $address)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        TextField("Username", text: $username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Password", text: $password)
                    } header: {
                        Text("The Swapper's address and login")
                    } footer: {
                        Text("The same login as the Swapper's web page. On Swapper 2.0 and later Vision trades it for an app token and doesn't keep the password.")
                    }
                    if let fingerprint {
                        Section {
                            Text(fingerprint)
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                            Button("Trust This Box and Sign In") { Task { await signIn(trusting: fingerprint) } }
                                .disabled(working)
                        } header: {
                            Text("Is this your box?")
                        } footer: {
                            Text("The box uses its own certificate. Compare this fingerprint with the one on the Swapper's Connect tab; nothing has been sent to it yet.")
                        }
                    }
                }

                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add a Box")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if working {
                        ProgressView()
                    } else {
                        Button("Connect") { Task { await connect() } }
                            .disabled(!ready)
                    }
                }
            }
            .onChange(of: way) { _, _ in problem = nil }
        }
    }

    private var ready: Bool {
        switch way {
        case .code: !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .login: !address.trimmingCharacters(in: .whitespaces).isEmpty && !username.isEmpty && !password.isEmpty
        }
    }

    private func connect() async {
        switch way {
        case .code:
            working = true
            problem = nil
            defer { working = false }
            do {
                try await model.addBox(code: code)
                dismiss()
            } catch {
                problem = MobileModel.describe(error)
            }
        case .login:
            await signIn(trusting: nil)
        }
    }

    private func signIn(trusting trusted: String?) async {
        working = true
        problem = nil
        defer { working = false }
        do {
            switch try await model.addBox(address: address, username: username, password: password, trusted: trusted) {
            case .added: dismiss()
            case .needsTrust(let shown): fingerprint = shown
            }
        } catch {
            problem = MobileModel.describe(error)
        }
    }
}
