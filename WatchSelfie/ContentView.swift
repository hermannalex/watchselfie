import SwiftUI
import AVFoundation

struct ContentView: View {
    @EnvironmentObject private var model: CameraModel
    @State private var showSettings = false
    @State private var pinchStartZoom: Double?

    private var zoomPresets: [Double] {
        ZoomText.presets.filter { $0 >= model.state.minZoom - 0.01 && $0 <= model.state.maxZoom + 0.01 }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CameraPreview(session: model.engine.session)
                .ignoresSafeArea()
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let start = pinchStartZoom ?? model.state.zoom
                            pinchStartZoom = start
                            model.setZoom(start * value.magnification)
                        }
                        .onEnded { _ in pinchStartZoom = nil }
                )

            VStack {
                HStack {
                    Label(model.watchReachable ? "Watch conectado" : "Watch desconectado",
                          systemImage: model.watchReachable ? "applewatch.radiowaves.left.and.right"
                                                            : "applewatch.slash")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    Spacer()
                    Button { showSettings = true } label: {
                        HStack(spacing: 6) {
                            if !model.state.activeLabel.isEmpty {
                                Text(model.state.activeLabel)
                                    .font(.footnote.weight(.semibold).monospacedDigit())
                            }
                            Image(systemName: "gearshape.fill")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                    }
                    if let start = model.state.recordingStart {
                        HStack(spacing: 6) {
                            Circle().fill(.red).frame(width: 8, height: 8)
                            Text(timerInterval: start...Date.distantFuture, countsDown: false)
                                .font(.body.monospacedDigit().weight(.semibold))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.5), in: Capsule())
                    }
                }

                Spacer()

                if let message = model.state.message {
                    Text(message)
                        .font(.footnote)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 12)
                }

                if zoomPresets.count > 1 {
                    HStack(spacing: 10) {
                        ForEach(zoomPresets, id: \.self) { preset in
                            let selected = abs(model.state.zoom - preset) < 0.05
                            Button { model.setZoom(preset) } label: {
                                Text(selected ? "\(ZoomText.format(preset))×" : ZoomText.format(preset))
                                    .font(.caption.weight(.bold).monospacedDigit())
                                    .foregroundStyle(selected ? .yellow : .white)
                                    .frame(width: 40, height: 40)
                                    .background(.black.opacity(0.45), in: Circle())
                            }
                        }
                    }
                    .padding(6)
                    .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
                    .overlay(alignment: .top) {
                        if !zoomPresets.contains(where: { abs(model.state.zoom - $0) < 0.05 }) {
                            Text("\(ZoomText.format(model.state.zoom))×")
                                .font(.footnote.weight(.bold).monospacedDigit())
                                .foregroundStyle(.yellow)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.black.opacity(0.6), in: Capsule())
                                .offset(y: -30)
                        }
                    }
                    .padding(.bottom, 14)
                }

                HStack {
                    Color.clear.frame(width: 56, height: 56)
                    Spacer()
                    Button { model.engine.toggleRecording() } label: {
                        ZStack {
                            Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
                            RoundedRectangle(cornerRadius: model.state.isRecording ? 8 : 32)
                                .fill(.red)
                                .frame(width: model.state.isRecording ? 32 : 64,
                                       height: model.state.isRecording ? 32 : 64)
                        }
                        .animation(.easeInOut(duration: 0.2), value: model.state.isRecording)
                    }
                    Spacer()
                    Button { model.engine.switchCamera() } label: {
                        Image(systemName: "arrow.triangle.2.circlepath.camera")
                            .font(.title2)
                            .frame(width: 56, height: 56)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .disabled(model.state.isRecording)
                    .opacity(model.state.isRecording ? 0.4 : 1)
                }
                .padding(.horizontal, 24)
            }
            .padding()
            .foregroundStyle(.white)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(model)
                .presentationDetents([.medium, .large])
        }
    }
}

/// Prévia da câmera no iPhone.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}
