import SwiftUI
import Combine
import Sparkle

enum AirMonitorInfo {
    static let repositoryURL = URL(string: "https://github.com/Davydov-Andrej/AirMonitor")!
    static let releasesURL = repositoryURL.appendingPathComponent("releases")
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Dev"
}

/// Sparkle owns scheduling, signature validation, installation and relaunch.
/// The GitHub metadata check also handles releases published before the updater
/// existed, which do not contain an appcast or a signed update archive.
@MainActor
final class AppUpdateManager: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private var statusTemplate = "Автоматическая проверка выполняется раз в сутки."
    @Published private var statusArguments: [String] = []
    var status: String {
        String(format: L(statusTemplate), locale: AppLanguage.current.locale,
               arguments: statusArguments.map { $0 as CVarArg })
    }
    @Published private(set) var isChecking = false
    @Published private(set) var canCheck = false
    @Published private(set) var automaticallyChecks = false
    @Published private(set) var automaticallyDownloads = false
    @Published private(set) var lastChecked: Date?
    var beforeInstall: (() -> Void)?

    private var controller: SPUStandardUpdaterController?

    override init() {
        super.init()
        guard Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") != nil else {
            setStatus("Проверка обновлений доступна в собранном AirMonitor.app.")
            return
        }
        let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheck)
        updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecks)
        updater.publisher(for: \.automaticallyDownloadsUpdates).assign(to: &$automaticallyDownloads)
        updater.publisher(for: \.lastUpdateCheckDate).assign(to: &$lastChecked)
        controller.startUpdater()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller?.updater.automaticallyChecksForUpdates = enabled
    }

    func setAutomaticDownloads(_ enabled: Bool) {
        controller?.updater.automaticallyDownloadsUpdates = enabled
    }

    func checkForUpdates() async {
        guard canCheck, !isChecking else { return }
        isChecking = true
        setStatus("Проверяем последний релиз на GitHub…")
        defer { isChecking = false }
        do {
            let release = try await Self.latestRelease()
            lastChecked = Date()
            let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
            let comparison = SUStandardVersionComparator.default.compareVersion(version, toVersion: AirMonitorInfo.version)
            guard comparison == .orderedDescending else {
                if comparison == .orderedAscending {
                    setStatus("Установлена версия %@. Последний опубликованный релиз — %@.", AirMonitorInfo.version, version)
                } else {
                    setStatus("Установлена последняя версия %@.", AirMonitorInfo.version)
                }
                return
            }
            guard release.assets.contains(where: { $0.name == "appcast.xml" }) else {
                setStatus("Доступна версия %@. В этом релизе ещё нет пакета автообновления. Скачать её можно на странице релизов.", version)
                return
            }
            setStatus("Найдена версия %@. Проверяем подписанный пакет…", version)
            controller?.checkForUpdates(nil)
        } catch {
            setStatus("Не удалось проверить обновления. %@", error.localizedDescription)
        }
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        setStatus("Доступна версия %@. Установку можно выполнить в окне обновления.", item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        setStatus("Совместимых обновлений для версии %@ не найдено.", AirMonitorInfo.version)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        let failure = error as NSError
        if failure.domain == SUSparkleErrorDomain {
            if failure.code == SUError.noUpdateError.rawValue { return }
            if failure.code == SUError.installationCanceledError.rawValue {
                setStatus("Установка обновления отменена.")
                return
            }
        }
        setStatus("Не удалось получить пакет обновления. %@", error.localizedDescription)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        beforeInstall?()
    }

    private func setStatus(_ template: String, _ arguments: String...) {
        statusTemplate = template
        statusArguments = arguments
    }

    private struct Release: Decodable {
        let tagName: String
        let assets: [Asset]
        struct Asset: Decodable { let name: String }
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private static func latestRelease() async throws -> Release {
        let url = URL(string: "https://api.github.com/repos/Davydov-Andrej/AirMonitor/releases/latest")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("AirMonitor/\(AirMonitorInfo.version)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(Release.self, from: data)
    }
}
