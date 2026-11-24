import SwiftUI

@main
struct CCBoxApp: App {
    var body: some Scene {
        Window("ccbox", id: "ccbox-main") {
            MainView()
                .frame(minWidth: 1120, minHeight: 720)
        }
        .defaultSize(width: 1280, height: 820)
        .windowStyle(.hiddenTitleBar)
    }
}
