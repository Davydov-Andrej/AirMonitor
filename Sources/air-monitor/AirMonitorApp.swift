import SwiftUI

@main
struct AirMonitorApp: App {
    @StateObject private var appModel = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appModel)
                .frame(minWidth: 900, minHeight: 560)
        }
    }
}
