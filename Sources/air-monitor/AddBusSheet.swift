import SwiftUI
import yaCore

/// Диалог добавления/редактирования шины мониторинга.
struct AddBusSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.isEditingBus ? L("Редактировать шину") : L("Новая шина мониторинга"))
                .font(.title2)

            Form {
                Section(L("Устройство")) {
                    if model.devices.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Label(L("Входные устройства не найдены"), systemImage: "waveform.badge.exclamationmark")
                                .font(.headline)
                            Text(L("Подключите микрофон, аудиоинтерфейс или виртуальный источник (например, Loopback). Проверьте, что устройство отображается в Системных настройках → Звук → Вход."))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button(L("Обновить список устройств")) {
                                model.refreshDevices()
                            }
                        }
                        .padding(.vertical, 4)
                    } else {
                        Picker(L("Источник звука"), selection: $model.draftDeviceUID) {
                            ForEach(model.devices) { device in
                                Text("\(device.name) (\(device.inputChannels) ch)")
                                    .tag(device.uid as String?)
                            }
                        }
                        .onChange(of: model.draftDeviceUID) { _, _ in
                            model.draftMonoChannels = []
                            model.prepareDraftForSelectedDevice()
                        }
                    }
                }

                if !model.devices.isEmpty {
                Section(L("Режим")) {
                    Picker(L("Режим"), selection: $model.draftMode) {
                        ForEach(BusDraftMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                                .disabled(mode == .stereo && model.draftChannelCount < 2)
                        }
                    }
                    .pickerStyle(.segmented)

                    if model.draftMode == .stereo {
                        LabeledContent(L("Каналы L/R")) {
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

                Section(L("Имя")) {
                    TextField(L("Например: Main, Monitor, Subs…"), text: $model.draftName)
                }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button(L("Отмена")) {
                    dismiss()
                }
                Button(model.isEditingBus ? L("Сохранить") : L("Добавить")) {
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
            model.prepareDraftForSelectedDevice()
        }
    }
}

/// Выпадающий список с чекбоксами для выбора нескольких каналов.
struct MultiChannelPicker: View {
    let channelCount: Int
    @Binding var selected: Set<Int>

    @State private var isOpen = false

    private var summary: String {
        if selected.isEmpty { return L("Выберите каналы") }
        if selected.count <= 6 {
            return selected.sorted().map { "\($0 + 1)" }.joined(separator: ", ")
        }
        return LF("Выбрано %d каналов", selected.count)
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
                                    Text(LF("Канал %d", i + 1))
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
