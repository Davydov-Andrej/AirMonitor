import SwiftUI
import AppKit

struct AirMonitorCommands: Commands {
    @ObservedObject var model: AppModel
    @ObservedObject var updates: AppUpdateManager

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L("О приложении AirMonitor")) { show(.about) }
        }
        CommandGroup(after: .appInfo) {
            Button(L("Проверить обновления…")) { Task { await updates.checkForUpdates() } }
                .disabled(!updates.canCheck || updates.isChecking)
            Divider()
            Button(L("Репозиторий на GitHub")) {
                NSWorkspace.shared.open(AirMonitorInfo.repositoryURL)
            }
        }
        CommandMenu(L("Мониторинг")) {
            Button(L("Добавить шину…")) {
                show(.dashboard)
                model.beginAddBus()
            }
            .keyboardShortcut("n", modifiers: .command)
            Button(L("Обновить список устройств")) { model.refreshDevices() }
            Divider()
            Button(model.isCapturing ? L("Остановить анализ") : L("Начать анализ")) {
                if model.isCapturing { model.stopCapture() } else { model.startCapture() }
            }
            .disabled(!model.isCapturing && model.buses.isEmpty)
            Divider()
            Button(L("Сохранить сцену как…")) {
                show(.dashboard)
                model.sceneSaveName = model.currentSceneName ?? ""
                model.isPresentingSaveScene = true
            }
            .disabled(model.buses.isEmpty)
            if !model.scenes.isEmpty {
                Menu(L("Открыть сцену")) {
                    ForEach(model.scenes) { scene in
                        Button(scene.name) { model.restoreScene(named: scene.name) }
                    }
                }
            }
        }
        CommandGroup(after: .toolbar) {
            Button(L("Дашборд")) { show(.dashboard) }
                .keyboardShortcut("1", modifiers: .command)
            Button(L("Монитор")) { show(.monitor) }
                .keyboardShortcut("2", modifiers: .command)
            Button(L("Спектр (АЧХ)")) { show(.spectrum) }
                .keyboardShortcut("3", modifiers: .command)
            Button(L("Баланс микса")) { show(.balance) }
                .keyboardShortcut("4", modifiers: .command)
            Button(L("О приложении")) { show(.about) }
                .keyboardShortcut("5", modifiers: .command)
            Divider()
            Menu(L("Тема приложения")) {
                ForEach(AppTheme.allCases) { theme in
                    Button {
                        model.appTheme = theme
                    } label: {
                        if model.appTheme == theme { Label(theme.title, systemImage: "checkmark") }
                        else { Text(theme.title) }
                    }
                }
            }
            Menu(L("Язык приложения")) {
                ForEach(AppLanguage.allCases) { language in
                    Button {
                        model.appLanguage = language
                    } label: {
                        if model.appLanguage == language { Label(language.title, systemImage: "checkmark") }
                        else { Text(language.title) }
                    }
                }
            }
            Divider()
            Menu(L("Компоновка дашборда")) {
                ForEach(DashboardColumnLayout.allCases) { layout in
                    Button(layout.title) { model.dashboardColumns = layout }
                }
            }
            Menu(L("Размер карточек")) {
                ForEach(DashboardCardSize.allCases) { size in
                    Button(size.title) { model.dashboardCardSize = size }
                }
            }
            Toggle(L("Автоперенос инструментов по ширине"), isOn: $model.dashboardAutoWrapModules)
            Toggle(L("Растягивать графики на свободное место"), isOn: $model.dashboardAutoStretchGraphs)
            Toggle(L("Пояснения к метрикам"), isOn: $model.showMetricHints)
        }
    }

    private func show(_ tab: AppTab) {
        model.selectedTab = tab
        NSApp.activate(ignoringOtherApps: true)
    }
}
