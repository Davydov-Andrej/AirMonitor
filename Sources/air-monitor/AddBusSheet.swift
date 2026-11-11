import SwiftUI
import yaCore

/// Диалог добавления/редактирования шины мониторинга.
struct AddBusSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.isEditingBus ? "Редактировать шину" : "Новая шина мониторинга")
                .font(.title2)

            Form {
                Section("Устройство") {
                    if model.devices.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Входные устройства не найдены", systemImage: "waveform.badge.exclamationmark")
                                .font(.headline)
                            Text("Подключите микрофон, аудиоинтерфейс или виртуальный источник (например, Loopback). Проверьте, что устройство отображается в Системных настройках → Звук → Вход.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button("Обновить список устройств") {
                                model.refreshDevices()
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Picker("Источник звука", selection: $model.draftDeviceUID) {
                            ForEach(model.devices) { device in
                                Text("\(device.name) (\(device.inputChannels) ch)")
                                    .tag(device.uid as String?)
                            }
                        }
                        .onChange(of: model.draftDeviceUID) { _, _ in
                            model.draftMonoChannels = []
                        }
                    }
                }

                if !model.devices.isEmpty {
                Section("Режим") {
                    Picker("Режим", selection: $model.draftMode) {
                        ForEach(BusDraftMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)

                    if model.draftMode == .stereo {
                        LabeledContent("Каналы L/R") {
                            HStack(spacing: 16) {
                                Picker("L", selection: $model.draftLeft) {
                                    ForEach(0..<max(model.draftChannelCount, 1), id: \.self) { i in
                                        Text("\(i + 1)").tag(i)
                                    }
                                }
                                Picker("R", selection: $model.draftRight) {
                                    ForEach(0..<max(model.draftChannelCount, 1), id: \.self) { i in
                                        Text("\(i + 1)").tag(i)
                                    }
                                }
                            }
                        }
                    } else {
                        // Выпадающий список с галочками вместо растянутой ленты.
                        MultiChannelPicker(
                            channelCount: model.draftChannelCount,
                            selected: $model.draftMonoChannels
                        )
                    }
                }

                Section("Имя") {
                    TextField("Например: Main, Monitor, Subs…", text: $model.draftName)
                }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Отмена") {
                    dismiss()
                }
                Button(model.isEditingBus ? "Сохранить" : "Добавить") {
                    model.commitDraftBus()
                    if model.errorMessage == nil {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.devices.isEmpty)
            }
        }
        .padding()
        .frame(width: 560)
        .onAppear {
            model.refreshDevices()
        }
    }
}

/// Выпадающий список с чекбоксами для выбора нескольких каналов.
struct MultiChannelPicker: View {
    let channelCount: Int
    @Binding var selected: Set<Int>

    @State private var isOpen = false

    private var summary: String {
        if selected.isEmpty { return "Выберите каналы" }
        if selected.count <= 6 {
            return selected.sorted().map { "\($0 + 1)" }.joined(separator: ", ")
        }
        return "Выбрано \(selected.count) каналов"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                isOpen.toggle()
            } label: {
                HStack {
                    Text(summary)
                        .foregroundStyle(selected.isEmpty ? .secondary : .primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.22)))
            }
            .buttonStyle(.plain)

            if isOpen {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(0..<max(channelCount, 0), id: \.self) { i in
                            Button {
                                if selected.contains(i) {
                                    selected.remove(i)
                                } else {
                                    selected.insert(i)
                                }
                            } label: {
                                HStack {
                                    Image(systemName: selected.contains(i) ? "checkmark.square.fill" : "square")
                                        .foregroundStyle(selected.contains(i) ? Color.accentColor : .secondary)
                                    Text("Канал \(i + 1)")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 220)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.primary.opacity(0.22)))
            }
        }
    }
}
