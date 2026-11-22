import SwiftUI

@main
struct ClaudeSandboxApp: App {
    var body: some Scene {
        Window("ccBox", id: "ccbox-main") {
            MainView()
                .frame(minWidth: 1120, minHeight: 720)
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
    }
}
