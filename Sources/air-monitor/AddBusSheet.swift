import SwiftUI
import yaCore

/// Диалог добавления новой шины мониторинга.
/// Позволяет выбрать устройство, режим (стерео/моно), каналы и имя.
struct AddBusSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Новая шина мониторинга")
                .font(.title2)

            Form {
                Section("Устройство") {
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
                        let count = model.draftChannelCount
                        if count == 0 {
                            Text("Выберите устройство")
                                .foregroundStyle(.secondary)
                        } else {
                            HStack(spacing: 8) {
                                ForEach(0..<count, id: \.self) { i in
                                    Button {
                                        if model.draftMonoChannels.contains(i) {
                                            model.draftMonoChannels.remove(i)
                                        } else {
                                            model.draftMonoChannels.insert(i)
                                        }
                                    } label: {
                                        Text("\(i + 1)")
                                            .font(.system(.body, design: .monospaced))
                                            .frame(width: 34, height: 34)
                                            .background(
                                                Circle().fill(model.draftMonoChannels.contains(i) ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
                                            )
                                            .foregroundStyle(model.draftMonoChannels.contains(i) ? .white : .primary)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }

                Section("Имя") {
                    TextField("Например: Main, Monitor, Subs…", text: $model.draftName)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Отмена") {
                    dismiss()
                }
                Button("Добавить") {
                    model.commitDraftBus()
                    if model.errorMessage == nil {
                        dismiss()
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(width: 560)
    }
}