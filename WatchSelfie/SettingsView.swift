import SwiftUI

/// Tela de ajustes de qualidade de gravação.
struct SettingsView: View {
    @EnvironmentObject private var model: CameraModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Resolução", selection: $model.settings.resolution) {
                        ForEach(VideoResolution.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Resolução")
                }

                Section {
                    Picker("Quadros por segundo", selection: $model.settings.fps) {
                        ForEach(RecordingSettings.fpsOptions, id: \.self) { Text("\($0) fps").tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Quadros por segundo")
                } footer: {
                    Text("60 fps deixa movimentos mais suaves. 24 fps dá um visual de cinema.")
                }

                Section {
                    Picker("Qualidade", selection: $model.settings.quality) {
                        ForEach(QualityLevel.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Qualidade (taxa de bits)")
                } footer: {
                    Text("Mais qualidade = mais detalhes e arquivos maiores.")
                }

                Section("Formato") {
                    Picker("Formato", selection: $model.settings.codec) {
                        ForEach(VideoCodecChoice.allCases) { codec in
                            VStack(alignment: .leading) {
                                Text(codec.label)
                                Text(codec.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(codec)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section {
                    Picker("Estabilização", selection: $model.settings.stabilization) {
                        ForEach(StabilizationChoice.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("A cinematográfica é a mais suave, mas corta um pouco a imagem e aumenta o atraso da prévia no Watch.")
                }

                Section("Estimativa") {
                    LabeledContent("Taxa de bits",
                                   value: String(format: "%.0f Mbps", Double(model.settings.estimatedBitrate) / 1_000_000))
                    LabeledContent("Espaço por minuto",
                                   value: String(format: "≈ %.0f MB", model.settings.estimatedMBPerMinute))
                    if !model.state.activeLabel.isEmpty {
                        LabeledContent("Em uso agora", value: model.state.activeLabel)
                    }
                    if let note = model.state.settingsNote {
                        Label(note, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .disabled(model.state.isRecording)
            .navigationTitle("Qualidade de gravação")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("OK") { dismiss() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if model.state.isRecording {
                    Text("Pare a gravação para mudar os ajustes.")
                        .font(.footnote)
                        .padding(10)
                        .frame(maxWidth: .infinity)
                        .background(.orange.opacity(0.2))
                }
            }
        }
    }
}
