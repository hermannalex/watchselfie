import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var link: WatchLink
    @Environment(\.scenePhase) private var scenePhase

    // Rotação da imagem (graus). Sempre começa em 90° ao abrir o app;
    // o botão ⟳ ajusta só durante o uso (separado para cada câmera).
    @State private var rotationBack = 90
    @State private var rotationFront = 90

    /// Posição da Digital Crown em escala logarítmica: zoom = 2^crown.
    @State private var crown: Double = 0

    private var crownRange: (from: Double, through: Double) {
        let from = log2(max(link.minZoom, 0.1))
        let through = max(log2(max(link.maxZoom, 0.1)), from + 0.01)
        return (from, through)
    }

    private var rotation: Int { link.isFront ? rotationFront : rotationBack }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black
                preview(in: geo.size)
                controls
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .ignoresSafeArea()
        .persistentSystemOverlays(.hidden)
        .focusable()
        .focusEffectDisabled()
        .digitalCrownRotation($crown,
                              from: crownRange.from,
                              through: crownRange.through,
                              sensitivity: .medium,
                              isContinuous: false,
                              isHapticFeedbackEnabled: true)
        .onChange(of: crown) { _, value in
            let zoom = pow(2, value)
            if abs(zoom - link.zoom) > 0.01 { link.setZoom(zoom) }
        }
        .onChange(of: link.isFront) { _, _ in crown = 0 }   // trocou de câmera: volta para 1×
        .onChange(of: link.zoom) { _, value in
            // mantém a coroa em sincronia quando o zoom muda pelo iPhone
            let target = log2(max(value, 0.1))
            if abs(target - crown) > 0.05 { crown = target }
        }
        .onAppear { link.setPreview(true) }
        .onDisappear { link.setPreview(false) }
        .onChange(of: scenePhase) { _, phase in
            link.setPreview(phase == .active)
        }
    }

    // MARK: Imagem em tela cheia, girada

    @ViewBuilder
    private func preview(in size: CGSize) -> some View {
        if let image = link.frame {
            let swap = rotation % 180 != 0
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                // antes de girar, a caixa tem as dimensões invertidas…
                .frame(width: swap ? size.height : size.width,
                       height: swap ? size.width : size.height)
                .clipped()
                .scaleEffect(x: link.isFront ? -1 : 1, y: 1) // selfie espelhada como num espelho
                .rotationEffect(.degrees(Double(rotation)))
                // …e depois de girar ela ocupa a tela inteira
                .frame(width: size.width, height: size.height)
                .clipped()
        } else {
            VStack(spacing: 8) {
                if link.isReachable {
                    ProgressView()
                } else {
                    Image(systemName: "iphone.slash").font(.title2)
                }
                Text(link.isReachable ? "Toque no aviso do iPhone para abrir a câmera"
                                      : "iPhone fora de alcance")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    // MARK: Controles

    private var controls: some View {
        VStack {
            HStack {
                if let start = link.recordingStart {
                    HStack(spacing: 4) {
                        Circle().fill(.red).frame(width: 7, height: 7)
                        Text(timerInterval: start...Date.distantFuture, countsDown: false)
                            .font(.footnote.monospacedDigit().weight(.semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: Capsule())
                }
                if !link.quality.isEmpty && link.frame != nil {
                    Text(link.quality)
                        .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                Spacer()
            }
            .padding(.top, 8)
            .padding(.leading, 14)

            Spacer()

            if link.cameraReady && link.frame != nil {
                Button(action: nextZoomPreset) {
                    Text("\(ZoomText.format(link.zoom))×")
                        .font(.system(size: 13, weight: .bold).monospacedDigit())
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 4)
            }

            HStack {
                smallButton("rotate.right") { rotate() }

                Spacer()

                Button { link.send(WS.toggleRecord) } label: {
                    ZStack {
                        Circle().stroke(.white, lineWidth: 3).frame(width: 52, height: 52)
                        RoundedRectangle(cornerRadius: link.isRecording ? 5 : 21)
                            .fill(.red)
                            .frame(width: link.isRecording ? 22 : 42,
                                   height: link.isRecording ? 22 : 42)
                    }
                    .animation(.easeInOut(duration: 0.2), value: link.isRecording)
                }
                .buttonStyle(.plain)
                .disabled(!link.cameraReady)
                .opacity(link.cameraReady ? 1 : 0.4)

                Spacer()

                smallButton("arrow.triangle.2.circlepath.camera") { link.send(WS.switchCamera) }
                    .disabled(link.isRecording || !link.cameraReady)
                    .opacity(link.isRecording || !link.cameraReady ? 0.4 : 1)
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 10)
        }
    }

    private func smallButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 38, height: 38)
                .background(.black.opacity(0.5), in: Circle())
        }
        .buttonStyle(.plain)
    }

    /// Toque no indicador de zoom: pula para o próximo atalho (0.5× → 1× → 2× → …).
    private func nextZoomPreset() {
        let presets = ZoomText.presets.filter { $0 >= link.minZoom - 0.01 && $0 <= link.maxZoom + 0.01 }
        guard !presets.isEmpty else { return }
        let next = presets.first { $0 > link.zoom + 0.05 } ?? presets[0]
        crown = log2(next)
        link.setZoom(next)
    }

    private func rotate() {
        if link.isFront {
            rotationFront = (rotationFront + 90) % 360
        } else {
            rotationBack = (rotationBack + 90) % 360
        }
    }
}
