import SwiftUI

@main
struct AirMonitorApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 1280, minHeight: 800)
        }
    }
}
