import SwiftUI
import AppKit
import yaCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            TabView {
                DashboardView()
                    .tabItem { Label("Дашборд", systemImage: "square.grid.2x2") }
                MonitorView()
                    .tabItem { Label("Монитор", systemImage: "waveform") }
                SpectrumView()
                    .tabItem { Label("Спектр (АЧХ)", systemImage: "chart.bar.xaxis") }
                BalanceView()
                    .tabItem {
                        VStack(spacing: 1) {
                            Label("Баланс микса", systemImage: "slider.horizontal.3")
                            Text("В разработке")
                                .font(.system(size: 7, weight: .medium))
                                .foregroundStyle(.orange)
                        }
                    }
                SettingsView()
                    .tabItem { Label("О приложении", systemImage: "info.circle") }
            }
        }
        .onAppear {
            model.refreshDevices()
            model.startObservingDeviceChanges()
            updateDockIcon(for: colorScheme)
        }
        .onChange(of: colorScheme) { _, newScheme in
            updateDockIcon(for: newScheme)
        }
        .onDisappear {
            model.stopObservingDeviceChanges()
        }
        .alert("Ошибка", isPresented: .init(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var header: some View {
        HStack {
            Text("AirMonitor")
                .font(.headline)
            Text(devicesSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
            Menu {
                Picker("Тема приложения", selection: $model.appTheme) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.title).tag(theme)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Image(systemName: "circle.lefthalf.filled")
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: true, vertical: false)
            .help("Тема: как в системе, светлая или тёмная")
            Spacer()
            if model.isCapturing {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 8, height: 8)
                    Text("REC · \(model.buses.count)")
                        .font(.caption)
                }
            } else if model.buses.isEmpty {
                Text("Добавьте шину, чтобы начать мониторинг")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Добавление шин доступно всегда, в т.ч. во время мониторинга.
            Button {
                model.beginAddBus()
            } label: {
                Label("Шина", systemImage: "plus")
            }
            Button(model.isCapturing ? "Стоп" : "Старт") {
                if model.isCapturing {
                    model.stopCapture()
                } else {
                    model.startCapture()
                }
            }
            .keyboardShortcut(.space, modifiers: [])
            .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private func updateDockIcon(for scheme: ColorScheme) {
        let resource = scheme == .dark ? "AirMonitor_black" : "AirMonitor_white"
        guard let url = Bundle.main.url(forResource: resource, withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return }
        NSApp.applicationIconImage = image
    }

    private var devicesSummary: String {
        let input = model.devices.filter { $0.inputChannels > 0 }
        if input.isEmpty { return "Нет устройств" }
        return "Устройств: \(input.count)"
    }
}
