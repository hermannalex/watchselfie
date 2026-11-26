import Foundation
import UIKit
import WatchKit
import WatchConnectivity

/// Conexão do Watch com o iPhone: recebe os quadros e o estado, envia os comandos.
@MainActor
final class WatchLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published private(set) var frame: UIImage?
    @Published private(set) var isRecording = false
    @Published private(set) var recordingStart: Date?
    @Published private(set) var isFront = false
    @Published private(set) var isReachable = false
    @Published private(set) var cameraReady = false
    @Published private(set) var quality = ""
    @Published private(set) var zoom: Double = 1
    @Published private(set) var minZoom: Double = 1
    @Published private(set) var maxZoom: Double = 1

    private var wantsPreview = false
    private var pendingZoom: Double?
    private var zoomTask: Task<Void, Never>?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func send(_ command: String, value: Double? = nil) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        var message: [String: Any] = [WS.command: command]
        if let value { message[WS.value] = value }
        session.sendMessage(message, replyHandler: nil, errorHandler: nil)
    }

    /// Envia o zoom no máximo ~12×/s enquanto a coroa gira.
    func setZoom(_ value: Double) {
        zoom = min(max(value, minZoom), maxZoom)
        pendingZoom = zoom
        guard zoomTask == nil else { return }
        zoomTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            if let z = self.pendingZoom { self.send(WS.zoom, value: z) }
            self.pendingZoom = nil
            self.zoomTask = nil
        }
    }

    func setPreview(_ on: Bool) {
        wantsPreview = on
        send(on ? WS.previewOn : WS.previewOff)
    }

    private func apply(_ s: RemoteState) {
        if s.recording != isRecording {
            WKInterfaceDevice.current().play(s.recording ? .start : .stop)
        }
        if s.recording {
            let start = Date().addingTimeInterval(-s.elapsed)
            if !isRecording || abs((recordingStart ?? start).timeIntervalSince(start)) > 1.5 {
                recordingStart = start
            }
        } else {
            recordingStart = nil
        }
        isRecording = s.recording
        isFront = s.front
        cameraReady = s.ready
        if !s.ready { frame = nil } // app do iPhone saiu da tela: limpa a imagem congelada
        quality = s.quality
        minZoom = s.minZoom
        maxZoom = s.maxZoom
        if pendingZoom == nil { zoom = s.zoom }
    }

    private func reachabilityChanged(_ reachable: Bool) {
        isReachable = reachable
        if !reachable {
            frame = nil
            cameraReady = false
        } else if wantsPreview {
            send(WS.previewOn)
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachabilityChanged(reachable) }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in self.reachabilityChanged(reachable) }
    }

    // Quadros da câmera (JPEG)
    nonisolated func session(_ session: WCSession,
                             didReceiveMessageData messageData: Data,
                             replyHandler: @escaping (Data) -> Void) {
        replyHandler(Data()) // libera o iPhone para mandar o próximo quadro
        Task { @MainActor in self.frame = UIImage(data: messageData) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor in self.frame = UIImage(data: messageData) }
    }

    // Estado (gravando, câmera, tempo)
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let state = RemoteState(message) else { return }
        Task { @MainActor in self.apply(state) }
    }
}
