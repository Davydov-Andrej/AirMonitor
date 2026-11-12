import SwiftUI
import AppKit
import CoreFoundation

@main
struct AirMonitorApp: App {
    @StateObject private var appModel = AppModel()
    @StateObject private var updates = AppUpdateManager()

    var body: some Scene {
        WindowGroup {
            AppAppearanceRoot(model: appModel)
                .environmentObject(updates)
                .onAppear { updates.beforeInstall = { appModel.stopCapture() } }
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            AirMonitorCommands(model: appModel, updates: updates)
            InstrumentCommands(model: appModel)
        }
    }
}

/// Read the system scheme above the app's theme override, then always pass a
/// concrete scheme to the whole scene. Passing nil when returning from a forced
/// dark scheme left some AppKit-backed views with their previous appearance.
private struct AppAppearanceRoot: View {
    @ObservedObject var model: AppModel
    @StateObject private var systemAppearance = SystemAppearanceObserver()

    private var effectiveColorScheme: ColorScheme {
        model.appTheme.resolvedColorScheme(system: systemAppearance.colorScheme)
    }

    var body: some View {
        ContentView()
            .environmentObject(model)
            .environment(\.locale, model.appLanguage.locale)
            .id(model.appLanguage)
            .preferredColorScheme(effectiveColorScheme)
            .animation(.none, value: effectiveColorScheme)
    }
}

/// Observe the OS appearance independently of the app window. Reading the
/// SwiftUI colorScheme here is unreliable because preferredColorScheme changes
/// the window itself; after choosing Dark, that value can remain Dark when the
/// user returns to System.
@MainActor
private final class SystemAppearanceObserver: ObservableObject {
    @Published private(set) var colorScheme: ColorScheme
    private var refreshTask: Task<Void, Never>?

    init() {
        colorScheme = Self.readSystemColorScheme()
        // Poll the system preference so returning from a forced app theme to
        // System takes effect immediately, without relying on a distributed
        // notification that can be missed on some macOS versions/hosts.
        refreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, let self else { return }
                self.refresh()
            }
        }
    }

    deinit {
        refreshTask?.cancel()
    }

    private func refresh() {
        let updated = Self.readSystemColorScheme()
        if colorScheme != updated { colorScheme = updated }
    }

    private static func readSystemColorScheme() -> ColorScheme {
        // Light mode is represented by an absent AppleInterfaceStyle key.
        // Synchronize before reading and do not fall back to a cached Dark value.
        CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
        let globalStyle = CFPreferencesCopyValue(
            "AppleInterfaceStyle" as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? String
        return globalStyle?.caseInsensitiveCompare("Dark") == .orderedSame ? .dark : .light
    }
}
