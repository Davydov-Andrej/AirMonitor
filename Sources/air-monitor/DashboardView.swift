import SwiftUI
import yaCore

/// Дашборд: каждая шина — отдельная строка-блок. Внутри: мониторы,
/// громкость (с историей), спектр, баланс.
struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Дашборд")
                    .font(.title2)
                if let scene = model.currentSceneName {
                    Text("Сцена: \(scene)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                sceneMenu
                Button {
                    model.beginAddBus()
                } label: {
                    Label("Добавить шину", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }

            if model.buses.isEmpty {
                ContentUnavailableView(
                    "Нет шин мониторинга",
                    systemImage: "waveform",
                    description: Text("Нажмите «Добавить шину», выберите устройство и каналы (Main, Monitor и др.), а затем «Старт»")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 14) {
                        ForEach(model.buses) { bus in
                            BusDashboardCard(
                                id: bus.id,
                                name: bus.config.name,
                                mode: bus.config.mode,
                                snapshot: model.busPreview(for: bus),
                                onDelete: { model.removeBus(id: bus.id) },
                                onRename: { newName in model.renameBus(id: bus.id, to: newName) },
                                onEdit: { model.beginEditBus(id: bus.id) }
                            )
                        }
                    }
                }
            }
        }
        .padding()
        .sheet(isPresented: $model.isPresentingAddBus) {
            AddBusSheet()
        }
        .sheet(isPresented: $model.isPresentingSaveScene) {
            SaveSceneSheet()
        }
    }

    private var sceneMenu: some View {
        Menu {
            Button("Сохранить сцену как…") {
                model.sceneSaveName = model.currentSceneName ?? ""
                model.isPresentingSaveScene = true
            }
            Divider()
            ForEach(model.scenes) { scene in
                Button {
                    model.restoreScene(named: scene.name)
                } label: {
                    HStack {
                        Text(scene.name)
                        if scene.name == model.currentSceneName {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
            if !model.scenes.isEmpty {
                Divider()
                Menu("Удалить сцену…") {
                    ForEach(model.scenes) { scene in
                        Button(scene.name, role: .destructive) {
                            model.deleteScene(named: scene.name)
                        }
                    }
                }
            }
        } label: {
            Label("Сцены", systemImage: "square.stack.3d.up")
        }
    }
}

/// Диалог сохранения сцены.
struct SaveSceneSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Text("Сохранить сцену").font(.title3)
            TextField("Имя сцены", text: $model.sceneSaveName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 300)
            HStack {
                Button("Отмена") { dismiss() }
                Button("Сохранить") {
                    model.saveScene(named: model.sceneSaveName)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.sceneSaveName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding()
    }
}

/// Карточка шины: строка-блок.
struct BusDashboardCard: View {
    let id: BusID
    let name: String
    let mode: BusMode
    let snapshot: BusSnapshot?
    let onDelete: () -> Void
    let onRename: (String) -> Void
    var onEdit: () -> Void = {}

    @State private var isRenaming = false
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            channelMeters
            Divider()
            loudnessHistory
            Divider()
            spectrumRow
            Divider()
            balanceRow
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.gray.opacity(0.2)))
        .alert("Переименовать", isPresented: $isRenaming) {
            TextField("Имя шины", text: $renameText)
            Button("OK") { onRename(renameText) }
            Button("Отмена", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Text(name)
                .font(.headline)
            Text(modeLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.gray.opacity(0.15)))
            if snapshot == nil {
                Text("ожидает «Старт»")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer()
            if let correlation = snapshot?.correlation {
                Text(String(format: "Кор: %.2f", correlation))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(correlation > 0.7 ? .green : (correlation > 0.3 ? .orange : .red))
            }
            Menu {
                Button("Переименовать") {
                    renameText = name
                    isRenaming = true
                }
                Button("Изменить источник…") { onEdit() }
                Divider()
                Button("Удалить", role: .destructive) { onDelete() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
        }
    }

    /// Мини-мониторы каналов в одну строку.
    private var channelMeters: some View {
        HStack(alignment: .top, spacing: 16) {
            ForEach(channelLabels, id: \.self) { label in
                let ch = snapshot?.displayChannels.first { $0.label == label }
                VStack(alignment: .leading, spacing: 3) {
                    Text(label)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    VUMeterView(valueDB: ch?.vuDB ?? -Float.infinity,
                                peakDB: ch?.peakDB ?? -Float.infinity)
                    HStack(spacing: 10) {
                        metric("Peak", ch?.peakDB)
                        metric("RMS", ch?.rmsDB)
                        metric("LUFS M", ch?.momentaryLUFS)
                        metric("LUFS S", ch?.shortTermLUFS)
                    }
                }
            }
        }
    }

    /// Бегущий график громкости (Youlean-стиль): momentary + short-term.
    private var loudnessHistory: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Громкость (история)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let integrated = snapshot?.displayChannels.first?.integratedLUFS, integrated.isFinite {
                    Text(String(format: "Integrated: %.1f LUFS", integrated))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            LoudnessHistoryChart(
                history: snapshot?.displayChannels.first?.loudnessHistory ?? [],
                target: -23
            )
            .frame(height: 80)
        }
    }

    private var spectrumRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Спектр")
                .font(.caption)
                .foregroundStyle(.secondary)
            SpectrumCurveChart(
                fine: snapshot?.displayChannels.first?.fineCurve ?? [],
                bands: snapshot?.displayChannels.first?.rtaBands ?? []
            )
            .frame(height: 110)
        }
    }

    private var balanceRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Тональный баланс")
                .font(.caption)
                .foregroundStyle(.secondary)
            InstrumentBalanceStrip(
                spectrum: snapshot?.displayChannels.first?.spectrum ?? [],
                sampleRate: Float(snapshot?.sampleRate ?? 48000)
            )
            if let tips = snapshot?.displayChannels.first, !balanceTips.isEmpty {
                ForEach(balanceTips, id: \.self) { tip in
                    HStack(alignment: .top, spacing: 4) {
                        Image(systemName: "lightbulb")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                        Text(tip)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var balanceTips: [String] {
        guard let first = snapshot?.displayChannels.first else { return [] }
        return InstrumentBalanceAnalyzer(
            spectrum: first.spectrum,
            sampleRate: Float(snapshot?.sampleRate ?? 48000)
        ).tips
    }

    private var channelLabels: [String] {
        if let snapshot, !snapshot.displayChannels.isEmpty {
            return snapshot.displayChannels.map { $0.label }
        }
        switch mode {
        case .stereo(let l, let r): return ["L \(l + 1)", "R \(r + 1)"]
        case .mono(let ch): return ch.map { "Ch \($0 + 1)" }
        }
    }

    private var modeLabel: String {
        switch mode {
        case .stereo(let l, let r): return "Стерео \(l + 1)/\(r + 1)"
        case .mono(let ch): return "Моно " + ch.map { "\($0 + 1)" }.joined(separator: "+")
        }
    }

    private func metric(_ title: String, _ value: Float?, suffix: String = " dB") -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            if let value, value.isFinite {
                Text(String(format: "%.1f%@", value, suffix))
                    .font(.system(size: 11, design: .monospaced).weight(.medium))
            } else {
                Text("--")
                    .font(.system(size: 11, design: .monospaced).weight(.medium))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}