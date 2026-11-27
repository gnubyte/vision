import SwiftUI
import VisionHarnessCore

/// Vision on iPhone: chat with the model your own Spark Swapper box serves, switch what it serves, and keep a
/// history of every prompt with what it carried. The same harness code as the Mac app talks to the box.
@main
struct VisionApp: App {
    @State private var model = MobileModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
        }
    }
}

struct RootView: View {
    @Environment(MobileModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @State private var tab = Tab.chats

    enum Tab: Hashable { case chats, boxes, settings }

    var body: some View {
        TabView(selection: $tab) {
            ChatListView(openBoxes: { tab = .boxes })
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
                .tag(Tab.chats)
            BoxesView()
                .tabItem { Label("Boxes", systemImage: "server.rack") }
                .tag(Tab.boxes)
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
                .tag(Tab.settings)
        }
        .task {
            // With no box yet, the first thing to do is add one.
            if model.connections.isEmpty { tab = .boxes }
            switch model.demoScreen {
            case "boxes", "box": tab = .boxes
            case "settings": tab = .settings
            default: break
            }
            await model.refreshAll()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.refreshAll() } }
        }
    }
}
