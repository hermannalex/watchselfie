import Foundation


/// Comandos trocados entre o Apple Watch e o iPhone.
nonisolated enum WS {
    static let command      = "cmd"
    static let toggleRecord = "toggleRecord"
    static let switchCamera = "switchCamera"
    static let previewOn    = "previewOn"
    static let previewOff   = "previewOff"
    static let getState     = "getState"
    static let zoom         = "zoom"
    static let value        = "value"
}

/// Formata o zoom como "0.5", "1", "2.5"…
nonisolated enum ZoomText {
    static func format(_ z: Double) -> String {
        let s = String(format: z < 10 ? "%.1f" : "%.0f", z)
        return s.hasSuffix(".0") ? String(s.dropLast(2)) : s
    }
    static let presets: [Double] = [0.5, 1, 2, 3, 5, 10]
}

/// Estado da câmera que o iPhone envia para o Watch.
nonisolated struct RemoteState: Sendable, Equatable {
    var recording: Bool
    var elapsed: TimeInterval   // segundos de gravação até agora
    var front: Bool             // true = câmera selfie
    var ready: Bool             // câmera rodando no iPhone
    var quality: String         // ex.: "1080p · 30"
    var zoom: Double = 1
    var minZoom: Double = 1
    var maxZoom: Double = 1

    init(recording: Bool, elapsed: TimeInterval, front: Bool, ready: Bool, quality: String = "",
         zoom: Double = 1, minZoom: Double = 1, maxZoom: Double = 1) {
        self.recording = recording
        self.elapsed = elapsed
        self.front = front
        self.ready = ready
        self.quality = quality
        self.zoom = zoom
        self.minZoom = minZoom
        self.maxZoom = maxZoom
    }

    init?(_ dict: [String: Any]) {
        guard let recording = dict["recording"] as? Bool else { return nil }
        self.recording = recording
        self.elapsed = dict["elapsed"] as? TimeInterval ?? 0
        self.front = dict["front"] as? Bool ?? false
        self.ready = dict["ready"] as? Bool ?? false
        self.quality = dict["quality"] as? String ?? ""
        self.zoom = dict["zoom"] as? Double ?? 1
        self.minZoom = dict["minZoom"] as? Double ?? 1
        self.maxZoom = dict["maxZoom"] as? Double ?? 1
    }

    var dictionary: [String: Any] {
        ["recording": recording, "elapsed": elapsed, "front": front, "ready": ready, "quality": quality,
         "zoom": zoom, "minZoom": minZoom, "maxZoom": maxZoom]
    }
}
