import Foundation
import WatchConnectivity
import CoreImage
import ImageIO

/// Envia quadros JPEG pequenos para o Watch, um de cada vez
/// (só manda o próximo quando o Watch confirma o anterior).
nonisolated final class FrameSender: @unchecked Sendable {
    /// Ajustes de qualidade x fluidez da prévia no Watch.
    var maxFPS: Double = 15
    var longSide: CGFloat = 360
    var jpegQuality: CGFloat = 0.5

    private let ciContext = CIContext()
    private let encodeQueue = DispatchQueue(label: "watchselfie.preview", qos: .utility)
    private let lock = NSLock()
    private var enabled = false
    private var inFlightSince: CFAbsoluteTime?
    private var lastSent: CFAbsoluteTime = 0

    func setEnabled(_ on: Bool) {
        lock.withLock {
            enabled = on
            inFlightSince = nil
        }
    }

    func send(_ pixelBuffer: CVPixelBuffer) {
        let now = CFAbsoluteTimeGetCurrent()
        let go: Bool = lock.withLock {
            guard enabled, now - lastSent >= 1 / maxFPS else { return false }
            if let since = inFlightSince, now - since < 1.0 { return false } // ainda aguardando o Watch
            inFlightSince = now
            lastSent = now
            return true
        }
        guard go else { return }

        // Codifica fora da fila de vídeo para não atrasar a gravação.
        nonisolated(unsafe) let buffer = pixelBuffer
        encodeQueue.async {
            let session = WCSession.default
            guard session.activationState == .activated, session.isReachable,
                  let data = self.encode(buffer) else {
                self.finished()
                return
            }
            session.sendMessageData(data,
                                    replyHandler: { [weak self] _ in self?.finished() },
                                    errorHandler: { [weak self] _ in self?.finished() })
        }
    }

    private func finished() {
        lock.withLock { inFlightSince = nil }
    }

    private func encode(_ pixelBuffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = longSide / max(image.extent.width, image.extent.height)
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        return ciContext.jpegRepresentation(of: scaled,
                                            colorSpace: CGColorSpaceCreateDeviceRGB(),
                                            options: [quality: jpegQuality])
    }
}

/// Conexão do iPhone com o Watch.
@MainActor
final class PhoneConnectivity: NSObject, WCSessionDelegate {
    nonisolated let frameSender = FrameSender()

    var onCommand: ((String, Double?) -> Void)?
    var onReachabilityChange: ((Bool) -> Void)?

    override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    func push(_ state: RemoteState) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else { return }
        session.sendMessage(state.dictionary, replyHandler: nil, errorHandler: nil)
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let reachable = session.isReachable
        Task { @MainActor in self.onReachabilityChange?(reachable) }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        if !reachable { frameSender.setEnabled(false) }
        Task { @MainActor in self.onReachabilityChange?(reachable) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let cmd = message[WS.command] as? String else { return }
        let value = message[WS.value] as? Double
        Task { @MainActor in self.onCommand?(cmd, value) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        replyHandler([:])
        guard let cmd = message[WS.command] as? String else { return }
        let value = message[WS.value] as? Double
        Task { @MainActor in self.onCommand?(cmd, value) }
    }
}
