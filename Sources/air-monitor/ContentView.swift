import SwiftUI
import yaCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel

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
                    .tabItem { Label("Баланс микса", systemImage: "slider.horizontal.3") }
                SettingsView()
                    .tabItem { Label("Настройки", systemImage: "gearshape") }
            }
        }
        .onAppear {
            model.refreshDevices()
            model.startObservingDeviceChanges()
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

    private var devicesSummary: String {
        let input = model.devices.filter { $0.inputChannels > 0 }
        if input.isEmpty { return "Нет устройств" }
        return "Устройств: \(input.count)"
    }
}