import Foundation

/// Простой асинхронно-безопасный файловый логгер для аудио-движка.
/// Пишет в ~/Library/Logs/AirMonitor/engine.log. Не блокирует аудио-поток:
/// вызывается ТОЛЬКО из потока, который не поставляет аудио (start/stop),
/// а из render-колбэка применять не рекомендуется.
public enum EngineLog {
    private static let lock = NSLock()

    private static var fileURL: URL {
        let dir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/AirMonitor")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("engine.log")
    }

    public static func log(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = "[\(Date())] \(message)\n"
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            handle.seekToEndOfFile()
            handle.write(line.data(using: .utf8) ?? Data())
            try? handle.close()
        } else {
            try? line.data(using: .utf8)?.write(to: fileURL)
        }
    }

    public static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
