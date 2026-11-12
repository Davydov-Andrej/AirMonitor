import SwiftUI

/// Mirrors the per-tab controls in the macOS menu without duplicating their state.
struct InstrumentCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandMenu(L("Инструменты")) {
            Menu(L("Монитор")) {
                Menu(L("Окно S")) {
                    option("S: 0.4 с", model.rtaSettings.shortTermSeconds == 0.4) { model.rtaSettings.shortTermSeconds = 0.4 }
                    option("S: 1 с", model.rtaSettings.shortTermSeconds == 1) { model.rtaSettings.shortTermSeconds = 1 }
                    option("S: 2 с", model.rtaSettings.shortTermSeconds == 2) { model.rtaSettings.shortTermSeconds = 2 }
                    option("S: 3 с (по умолчанию, стандарт EBU)", model.rtaSettings.shortTermSeconds == 3) { model.rtaSettings.shortTermSeconds = 3 }
                }
                Menu(L("Сглаживание графика LUFS")) {
                    option("Выкл", model.rtaSettings.loudnessSmoothing == 1) { model.rtaSettings.loudnessSmoothing = 1 }
                    option("Лёгкое (0.15)", model.rtaSettings.loudnessSmoothing == 0.15) { model.rtaSettings.loudnessSmoothing = 0.15 }
                    option("Слабое (0.05)", model.rtaSettings.loudnessSmoothing == 0.05) { model.rtaSettings.loudnessSmoothing = 0.05 }
                    option("Среднее (0.02) — стандарт", model.rtaSettings.loudnessSmoothing == 0.02) { model.rtaSettings.loudnessSmoothing = 0.02 }
                    option("Сильное (0.008)", model.rtaSettings.loudnessSmoothing == 0.008) { model.rtaSettings.loudnessSmoothing = 0.008 }
                    option("Максимальное (0.003)", model.rtaSettings.loudnessSmoothing == 0.003) { model.rtaSettings.loudnessSmoothing = 0.003 }
                }
                Menu(L("Сглаживание чисел M/S")) {
                    option("Выкл — точные значения (для сверки)", model.rtaSettings.numberSmoothing == 1) { model.rtaSettings.numberSmoothing = 1 }
                    option("Лёгкое (0.3)", model.rtaSettings.numberSmoothing == 0.3) { model.rtaSettings.numberSmoothing = 0.3 }
                    option("Слабое (0.12)", model.rtaSettings.numberSmoothing == 0.12) { model.rtaSettings.numberSmoothing = 0.12 }
                    option("Среднее (0.05) — стандарт", model.rtaSettings.numberSmoothing == 0.05) { model.rtaSettings.numberSmoothing = 0.05 }
                    option("Сильное (0.02)", model.rtaSettings.numberSmoothing == 0.02) { model.rtaSettings.numberSmoothing = 0.02 }
                    option("Максимальное (0.008)", model.rtaSettings.numberSmoothing == 0.008) { model.rtaSettings.numberSmoothing = 0.008 }
                }
                Menu(L("LUFS-офсет")) {
                    option("Калибровка: −1 дБ", model.lufsOffset == -1) { model.lufsOffset = -1 }
                    option("Калибровка: −0.5 дБ", model.lufsOffset == -0.5) { model.lufsOffset = -0.5 }
                    option("Калибровка: 0 (по стандарту)", model.lufsOffset == 0) { model.lufsOffset = 0 }
                    option("Калибровка: +0.5 дБ", model.lufsOffset == 0.5) { model.lufsOffset = 0.5 }
                    option("Калибровка: +1 дБ", model.lufsOffset == 1) { model.lufsOffset = 1 }
                }
            }
            Menu(L("Спектр (АЧХ)")) {
                Menu(L("Полос на октаву")) {
                    option("1/1 октавы (9 полос)", model.rtaSettings.bandsPerOctave == 1) { model.rtaSettings.bandsPerOctave = 1 }
                    option("1/3 октавы (31) — как на пультах", model.rtaSettings.bandsPerOctave == 3) { model.rtaSettings.bandsPerOctave = 3 }
                    option("1/6 октавы (61)", model.rtaSettings.bandsPerOctave == 6) { model.rtaSettings.bandsPerOctave = 6 }
                    option("1/12 октавы (121)", model.rtaSettings.bandsPerOctave == 12) { model.rtaSettings.bandsPerOctave = 12 }
                }
                Toggle(L("Пик-холд"), isOn: Binding(
                    get: { model.rtaSettings.peakHoldSeconds > 0 },
                    set: { model.rtaSettings.peakHoldSeconds = $0 ? 1.5 : 0 }
                ))
                Toggle(L("Тонкая кривая (детальные пики EQ)"), isOn: Binding(
                    get: { model.rtaSettings.showFineCurve },
                    set: { model.rtaSettings.showFineCurve = $0 }
                ))
                Toggle(L("Авто-снижение разрешения при нагрузке"), isOn: Binding(
                    get: { model.rtaSettings.autoDowngrade },
                    set: { model.rtaSettings.autoDowngrade = $0 }
                ))
                Divider()
                Menu(L("Атака")) {
                    option("Мгновенная (0.95)", model.rtaSettings.attack == 0.95) { model.rtaSettings.attack = 0.95 }
                    option("Очень быстрая (0.85)", model.rtaSettings.attack == 0.85) { model.rtaSettings.attack = 0.85 }
                    option("Быстрая (0.70)", model.rtaSettings.attack == 0.70) { model.rtaSettings.attack = 0.70 }
                    option("Средняя (0.55)", model.rtaSettings.attack == 0.55) { model.rtaSettings.attack = 0.55 }
                    option("Плавная (0.40)", model.rtaSettings.attack == 0.40) { model.rtaSettings.attack = 0.40 }
                    option("Медленная (0.25)", model.rtaSettings.attack == 0.25) { model.rtaSettings.attack = 0.25 }
                    option("Усреднение (0.12)", model.rtaSettings.attack == 0.12) { model.rtaSettings.attack = 0.12 }
                }
                Menu(L("Спад")) {
                    option("Мгновенный (0.60)", model.rtaSettings.release == 0.60) { model.rtaSettings.release = 0.60 }
                    option("Очень быстрый (0.40)", model.rtaSettings.release == 0.40) { model.rtaSettings.release = 0.40 }
                    option("Быстрый (0.25)", model.rtaSettings.release == 0.25) { model.rtaSettings.release = 0.25 }
                    option("Средне-быстрый (0.14)", model.rtaSettings.release == 0.14) { model.rtaSettings.release = 0.14 }
                    option("Средний (0.08)", model.rtaSettings.release == 0.08) { model.rtaSettings.release = 0.08 }
                    option("Медленный (0.04)", model.rtaSettings.release == 0.04) { model.rtaSettings.release = 0.04 }
                    option("Очень медленный (0.02)", model.rtaSettings.release == 0.02) { model.rtaSettings.release = 0.02 }
                    option("Усреднение (0.01)", model.rtaSettings.release == 0.01) { model.rtaSettings.release = 0.01 }
                }
                Menu(L("Сглаживание")) {
                    option("Нет — мелкие пики, точные узкие полосы", model.rtaSettings.neighborSmoothing == 0) { model.rtaSettings.neighborSmoothing = 0 }
                    option("Лёгкое (0.5)", model.rtaSettings.neighborSmoothing == 0.5) { model.rtaSettings.neighborSmoothing = 0.5 }
                    option("Соседние ±1", model.rtaSettings.neighborSmoothing == 1) { model.rtaSettings.neighborSmoothing = 1 }
                    option("±1.5", model.rtaSettings.neighborSmoothing == 1.5) { model.rtaSettings.neighborSmoothing = 1.5 }
                    option("Соседние ±2", model.rtaSettings.neighborSmoothing == 2) { model.rtaSettings.neighborSmoothing = 2 }
                    option("±2.5", model.rtaSettings.neighborSmoothing == 2.5) { model.rtaSettings.neighborSmoothing = 2.5 }
                    option("Соседние ±3 — ровная кривая", model.rtaSettings.neighborSmoothing == 3) { model.rtaSettings.neighborSmoothing = 3 }
                    option("±4", model.rtaSettings.neighborSmoothing == 4) { model.rtaSettings.neighborSmoothing = 4 }
                    option("Соседние ±5 — общая картина", model.rtaSettings.neighborSmoothing == 5) { model.rtaSettings.neighborSmoothing = 5 }
                    option("Сильное ±8 — только общий контур", model.rtaSettings.neighborSmoothing == 8) { model.rtaSettings.neighborSmoothing = 8 }
                }
            }
        }
    }

    private func option(_ title: String, _ selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(L(title), systemImage: "checkmark") }
            else { Text(L(title)) }
        }
    }
}
