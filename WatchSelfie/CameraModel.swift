import Foundation
import Combine
import UIKit
import UserNotifications

/// Liga a câmera (CaptureEngine) à conexão com o Watch e à interface do iPhone.
@MainActor
final class CameraModel: ObservableObject {
    @Published private(set) var state = CaptureState()
    @Published private(set) var watchReachable = false

    /// Ajustes de gravação (salvos automaticamente).
    @Published var settings: RecordingSettings {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            engine.apply(settings)
        }
    }

    let engine = CaptureEngine()
    let link = PhoneConnectivity()

    init() {
        let saved = RecordingSettings.load()
        settings = saved
        engine.apply(saved)

        let sender = link.frameSender
        engine.onFrame = { pixelBuffer in sender.send(pixelBuffer) }
        engine.onStateChange = { newState in
            Task { @MainActor in self.apply(newState) }
        }
        link.onCommand = { cmd, value in self.handle(cmd, value: value) }
        link.onReachabilityChange = { reachable in
            self.watchReachable = reachable
            if reachable { self.pushState() }
        }
    }

    private func apply(_ newState: CaptureState) {
        state = newState
        pushState()
    }

    func setZoom(_ zoom: Double) {
        engine.setZoom(zoom)
    }

    private func handle(_ cmd: String, value: Double?) {
        switch cmd {
        case WS.zoom:
            if let value { engine.setZoom(value) }
        case WS.toggleRecord:
            engine.toggleRecording()
        case WS.switchCamera:
            engine.switchCamera()
        case WS.previewOn:
            link.frameSender.setEnabled(true)
            engine.start()
            pushState()
            askToOpenAppIfNeeded()
        case WS.previewOff:
            link.frameSender.setEnabled(false)
        default:
            pushState()
        }
    }

    // MARK: Abrir o app pelo Watch

    static let openNotificationID = "openCamera"
    private var lastNudge = Date.distantPast

    /// O iOS não deixa o Watch trazer o app do iPhone para a tela, e a câmera só
    /// funciona com o app aberto. Então avisamos o usuário com uma notificação.
    private func askToOpenAppIfNeeded() {
        guard UIApplication.shared.applicationState != .active,
              Date().timeIntervalSince(lastNudge) > 15 else { return }
        lastNudge = Date()
        let content = UNMutableNotificationContent()
        content.title = "WatchSelfie"
        content.body = "O Apple Watch quer usar a câmera. Toque para abrir."
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: Self.openNotificationID,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    func pushState() {
        let elapsed = state.recordingStart.map { Date().timeIntervalSince($0) } ?? 0
        link.push(RemoteState(recording: state.isRecording,
                              elapsed: elapsed,
                              front: state.isFront,
                              ready: state.isRunning,
                              quality: state.activeLabel,
                              zoom: state.zoom,
                              minZoom: state.minZoom,
                              maxZoom: state.maxZoom))
    }
}
