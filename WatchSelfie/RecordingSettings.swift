import AVFoundation

nonisolated enum VideoResolution: String, Codable, CaseIterable, Sendable, Identifiable {
    case hd720, hd1080, uhd4K
    var id: String { rawValue }

    var width: Int32 {
        switch self {
        case .hd720: 1280
        case .hd1080: 1920
        case .uhd4K: 3840
        }
    }
    var height: Int32 {
        switch self {
        case .hd720: 720
        case .hd1080: 1080
        case .uhd4K: 2160
        }
    }
    var label: String {
        switch self {
        case .hd720: "720p"
        case .hd1080: "1080p"
        case .uhd4K: "4K"
        }
    }
    /// Da maior para a menor, usada para cair para uma resolução suportada.
    static let descending: [VideoResolution] = [.uhd4K, .hd1080, .hd720]
}

nonisolated enum VideoCodecChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    case hevc, h264
    var id: String { rawValue }
    var label: String { self == .hevc ? "HEVC" : "H.264" }
    var detail: String { self == .hevc ? "Arquivo menor" : "Mais compatível" }
    var codecType: AVVideoCodecType { self == .hevc ? .hevc : .h264 }
}

nonisolated enum QualityLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case standard, high, max
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: "Padrão"
        case .high: "Alta"
        case .max: "Máxima"
        }
    }
    /// Bits por pixel por quadro (referência H.264).
    var bitsPerPixel: Double {
        switch self {
        case .standard: 0.12
        case .high: 0.25
        case .max: 0.45
        }
    }
}

nonisolated enum StabilizationChoice: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, standard, cinematic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: "Desligada"
        case .standard: "Padrão"
        case .cinematic: "Cinematográfica"
        }
    }
    var mode: AVCaptureVideoStabilizationMode {
        switch self {
        case .off: .off
        case .standard: .standard
        case .cinematic: .cinematic
        }
    }
}

nonisolated struct RecordingSettings: Codable, Equatable, Sendable {
    var resolution: VideoResolution = .hd1080
    var fps: Int = 30
    var codec: VideoCodecChoice = .hevc
    var quality: QualityLevel = .high
    var stabilization: StabilizationChoice = .standard

    static let fpsOptions = [24, 30, 60]

    /// Taxa de bits de vídeo em bits/s.
    static func bitrate(width: Int32, height: Int32, fps: Int,
                        quality: QualityLevel, codec: VideoCodecChoice) -> Int {
        let codecFactor = codec == .hevc ? 0.6 : 1.0
        let bits = Double(width) * Double(height) * Double(fps) * quality.bitsPerPixel * codecFactor
        return Int(min(max(bits, 2_000_000), 150_000_000))
    }

    var estimatedBitrate: Int {
        Self.bitrate(width: resolution.width, height: resolution.height,
                     fps: fps, quality: quality, codec: codec)
    }

    /// Estimativa de MB por minuto (vídeo + ~128 kbps de áudio).
    var estimatedMBPerMinute: Double {
        Double(estimatedBitrate + 128_000) * 60 / 8 / 1_000_000
    }

    var shortLabel: String { "\(resolution.label) · \(fps)" }

    // MARK: Persistência

    private static let key = "recordingSettings"

    static func load() -> RecordingSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(RecordingSettings.self, from: data) else {
            return RecordingSettings()
        }
        return s
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
