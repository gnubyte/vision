import SwiftUI
import VisionHarnessCore

struct SettingsView: View {
    @Environment(MobileModel.self) private var model
    @State private var showHistory = false

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Stepper("Pictures per request: \(model.maxImages)", value: $model.maxImages, in: 1...32)
                    if !model.learnedImageLimits.isEmpty {
                        ForEach(model.learnedImageLimits.sorted(by: { $0.key < $1.key }), id: \.key) { route, limit in
                            LabeledContent(route.split(separator: "|").last.map(String.init) ?? route,
                                           value: "takes \(limit)")
                                .font(.footnote)
                        }
                        Button("Forget Learned Limits") { model.learnedImageLimits = [:] }
                    }
                } header: {
                    Text("Pictures")
                } footer: {
                    Text("How many photos, screenshots and PDF pages travel with one request. The newest stay in view and older ones roll off — they remain in the chat and its prompt history. A model that takes fewer says so once and Vision remembers it.")
                }

                Section {
                    TextField("Instructions", text: $model.systemPrompt, axis: .vertical)
                        .lineLimit(4...12)
                        .font(.footnote)
                    Button("Reset to Default") { model.systemPrompt = MobileModel.defaultSystemPrompt }
                        .disabled(model.systemPrompt == MobileModel.defaultSystemPrompt)
                } header: {
                    Text("Instructions for the model")
                }

                Section {
                    Button {
                        showHistory = true
                    } label: {
                        LabeledContent("Prompt History", value: "\(model.history.count)")
                    }
                    .tint(.primary)
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                    LabeledContent("Boxes", value: "\(model.connections.count)")
                } header: {
                    Text("About")
                } footer: {
                    Text("Vision talks only to the Spark Swapper boxes you add. Tokens and keys are kept in the iPhone's Keychain.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showHistory) { PromptHistoryView(chatID: nil) }
        }
    }
}
