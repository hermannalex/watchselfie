import AVFoundation
import Photos

nonisolated struct CaptureState: Sendable, Equatable {
    var isRunning = false
    var isRecording = false
    var recordingStart: Date?
    var isFront = false
    var message: String?
    /// Resolução/fps realmente em uso (ex.: "1080p · 30").
    var activeLabel = ""
    /// Aviso quando a câmera não suporta o ajuste escolhido.
    var settingsNote: String?
    /// Zoom como no app Câmera (0.5 = ultra-angular, 1 = principal…)
    var zoom: Double = 1
    var minZoom: Double = 1
    var maxZoom: Double = 1
}

/// Captura da câmera + gravação (AVAssetWriter) + entrega de quadros para o Watch.
/// Roda inteiramente em filas próprias (fora da main thread).
nonisolated final class CaptureEngine: NSObject, @unchecked Sendable,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureAudioDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()

    /// Chamado sempre que o estado muda (em qualquer fila).
    var onStateChange: (@Sendable (CaptureState) -> Void)?
    /// Chamado na fila de vídeo com cada quadro (orientação nativa do sensor, paisagem).
    var onFrame: (@Sendable (CVPixelBuffer) -> Void)?

    private let sessionQueue = DispatchQueue(label: "watchselfie.session")
    private let dataQueue = DispatchQueue(label: "watchselfie.data", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()

    // Somente na sessionQueue
    private var videoInput: AVCaptureDeviceInput?
    private var configured = false

    // Protegidos pelo lock
    private let lock = NSLock()
    private var _state = CaptureState()
    private var _settings = RecordingSettings()
    private var _activeFPS = 30
    private var _rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var _hasAudio = false
    private var _zoom: Double = 1            // zoom "de exibição" (1 = câmera principal)
    private var _zoomMultiplier: Double = 1  // exibição = videoZoomFactor × multiplicador

    // Somente na dataQueue
    private var wantsRecording = false
    private var writer: AVAssetWriter?
    private var writerVideo: AVAssetWriterInput?
    private var writerAudio: AVAssetWriterInput?

    var state: CaptureState { lock.withLock { _state } }

    // MARK: - Ajustes de gravação

    /// Aplica os ajustes (ignorado durante a gravação — aplicado na próxima).
    func apply(_ settings: RecordingSettings) {
        lock.withLock { _settings = settings }
        sessionQueue.async {
            guard self.configured, !self.state.isRecording,
                  let device = self.videoInput?.device else { return }
            self.session.beginConfiguration()
            self.configureFormat(device)
            self.configureVideoConnection()
            self.session.commitConfiguration()
            self.applyZoom(device)
        }
    }

    // MARK: - Zoom

    /// Define o zoom (0.5×, 1×, 2×…). Pode ser chamado a qualquer momento, inclusive gravando.
    func setZoom(_ display: Double) {
        lock.withLock { _zoom = display }
        sessionQueue.async {
            guard let device = self.videoInput?.device else { return }
            self.applyZoom(device)
        }
    }

    private func resetZoom(for device: AVCaptureDevice) {
        let multiplier = Self.zoomMultiplier(for: device)
        lock.withLock {
            _zoomMultiplier = multiplier
            _zoom = 1
        }
        applyZoom(device)
    }

    private func applyZoom(_ device: AVCaptureDevice) {
        let (wanted, multiplier) = lock.withLock { (_zoom, _zoomMultiplier) }
        let minZoom = Double(device.minAvailableVideoZoomFactor) * multiplier
        let maxZoom = min(Double(device.maxAvailableVideoZoomFactor) * multiplier, 15)
        let zoom = min(max(wanted, minZoom), maxZoom)
        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = CGFloat(zoom / multiplier)
            device.unlockForConfiguration()
        } catch {
            return
        }
        lock.withLock { _zoom = zoom }
        let current = state
        guard abs(current.zoom - zoom) > 0.005 || current.minZoom != minZoom || current.maxZoom != maxZoom else { return }
        updateState {
            $0.zoom = zoom
            $0.minZoom = minZoom
            $0.maxZoom = maxZoom
        }
    }

    /// Em câmeras com ultra-angular, o fator 1.0 do sistema é a ultra-angular (0.5× para o usuário).
    private static func zoomMultiplier(for device: AVCaptureDevice) -> Double {
        let hasUltraWide = device.constituentDevices.contains { $0.deviceType == .builtInUltraWideCamera }
        if hasUltraWide, let firstSwitch = device.virtualDeviceSwitchOverVideoZoomFactors.first {
            return 1.0 / firstSwitch.doubleValue
        }
        return 1
    }

    /// Escolhe o formato da câmera com a resolução/fps pedidos.
    /// Se a câmera não suportar, cai para a combinação mais próxima.
    private func configureFormat(_ device: AVCaptureDevice) {
        let wanted = lock.withLock { _settings }

        var candidates: [(VideoResolution, Int)] = [(wanted.resolution, wanted.fps)]
        if wanted.fps != 30 { candidates.append((wanted.resolution, 30)) }
        for res in VideoResolution.descending where res.width < wanted.resolution.width {
            candidates.append((res, wanted.fps))
            if wanted.fps != 30 { candidates.append((res, 30)) }
        }

        for (res, fps) in candidates {
            guard let format = Self.bestFormat(device, res, fps) else { continue }
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
                device.activeVideoMinFrameDuration = duration
                device.activeVideoMaxFrameDuration = duration
                device.unlockForConfiguration()
            } catch {
                continue
            }
            lock.withLock { _activeFPS = fps }
            let exact = res == wanted.resolution && fps == wanted.fps
            updateState {
                $0.activeLabel = "\(res.label) · \(fps)"
                $0.settingsNote = exact ? nil
                    : "Esta câmera não suporta \(wanted.shortLabel). Usando \(res.label) · \(fps)."
            }
            return
        }
        updateState { $0.settingsNote = "Não foi possível aplicar os ajustes nesta câmera." }
    }

    private static func bestFormat(_ device: AVCaptureDevice,
                                   _ res: VideoResolution, _ fps: Int) -> AVCaptureDevice.Format? {
        let matches = device.formats.filter { format in
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            guard dims.width == res.width, dims.height == res.height else { return false }
            return format.videoSupportedFrameRateRanges.contains {
                $0.minFrameRate <= Double(fps) && $0.maxFrameRate >= Double(fps) - 0.01
            }
        }
        let videoRange = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        return matches.first {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == videoRange && !$0.isVideoBinned
        } ?? matches.first {
            CMFormatDescriptionGetMediaSubType($0.formatDescription) == videoRange
        } ?? matches.first
    }

    // MARK: - Sessão

    func start() {
        AVCaptureDevice.requestAccess(for: .video) { videoOK in
            AVCaptureDevice.requestAccess(for: .audio) { audioOK in
                guard videoOK else {
                    self.updateState { $0.message = "Permita o acesso à câmera em Ajustes." }
                    return
                }
                self.sessionQueue.async {
                    if !self.configured { self.configure(withAudio: audioOK) }
                    guard self.configured else { return }
                    if !self.session.isRunning { self.session.startRunning() }
                    let running = self.session.isRunning
                    self.updateState { $0.isRunning = running }
                }
            }
        }
    }

    func stop() {
        stopRecording()
        sessionQueue.async {
            if self.session.isRunning { self.session.stopRunning() }
            self.updateState { $0.isRunning = false }
        }
    }

    private func configure(withAudio: Bool) {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard let device = Self.camera(.back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            updateState { $0.message = "Câmera indisponível." }
            return
        }
        session.addInput(input)
        videoInput = input
        lock.withLock { _rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil) }

        // 4:2:0 nativo: mais leve que BGRA, importante em 4K/60.
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ]
        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.setSampleBufferDelegate(self, queue: dataQueue)
        guard session.canAddOutput(videoOutput) else {
            updateState { $0.message = "Não foi possível configurar a câmera." }
            return
        }
        session.addOutput(videoOutput)

        if withAudio,
           let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput),
           session.canAddOutput(audioOutput) {
            session.addInput(micInput)
            audioOutput.setSampleBufferDelegate(self, queue: dataQueue)
            session.addOutput(audioOutput)
            lock.withLock { _hasAudio = true }
        }

        configureFormat(device)
        configureVideoConnection()
        configured = true
        resetZoom(for: device)
    }

    /// Quadros na orientação nativa (paisagem) e sem espelhamento.
    /// O Watch gira/espelha na exibição; o vídeo gravado recebe a rotação correta via metadado.
    private func configureVideoConnection() {
        guard let connection = videoOutput.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        if connection.isVideoStabilizationSupported, let device = videoInput?.device {
            let wanted = lock.withLock { _settings.stabilization.mode }
            let format = device.activeFormat
            if format.isVideoStabilizationModeSupported(wanted) {
                connection.preferredVideoStabilizationMode = wanted
            } else if wanted != .off, format.isVideoStabilizationModeSupported(.standard) {
                connection.preferredVideoStabilizationMode = .standard
            } else {
                connection.preferredVideoStabilizationMode = .off
            }
        }
    }

    /// Traseira: usa a câmera "virtual" com todas as lentes (troca sozinha entre
    /// ultra-angular, principal e teleobjetiva conforme o zoom). Frontal: câmera única.
    private static func camera(_ position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInWideAngleCamera]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: position) { return device }
        }
        return nil
    }

    // MARK: - Trocar câmera

    func switchCamera() {
        sessionQueue.async {
            guard self.configured, !self.state.isRecording else { return }
            let toFront = !self.state.isFront
            guard let device = Self.camera(toFront ? .front : .back),
                  let newInput = try? AVCaptureDeviceInput(device: device) else { return }

            self.session.beginConfiguration()
            let old = self.videoInput
            if let old { self.session.removeInput(old) }
            var switched = false
            if self.session.canAddInput(newInput) {
                self.session.addInput(newInput)
                self.videoInput = newInput
                switched = true
            } else if let old {
                self.session.addInput(old)
            }
            if let active = self.videoInput?.device { self.configureFormat(active) }
            self.configureVideoConnection()
            self.session.commitConfiguration()

            guard switched else { return }
            self.lock.withLock {
                self._rotationCoordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
            }
            self.updateState { $0.isFront = toFront }
            self.resetZoom(for: device)
        }
    }

    // MARK: - Gravação

    func toggleRecording() {
        dataQueue.async {
            if self.wantsRecording { self.finishRecording() } else { self.beginRecording() }
        }
    }

    func stopRecording() {
        dataQueue.async { if self.wantsRecording { self.finishRecording() } }
    }

    private func beginRecording() {
        guard state.isRunning else { return }
        wantsRecording = true   // o writer é criado no próximo quadro de vídeo
    }

    private func startWriter(with sampleBuffer: CMSampleBuffer) {
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }
        let dims = CMVideoFormatDescriptionGetDimensions(format)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WatchSelfie-\(UUID().uuidString).mov")

        func fail(_ text: String) {
            wantsRecording = false
            updateState { $0.message = text }
        }

        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            return fail("Erro ao iniciar a gravação.")
        }

        let (settings, fps, angle, hasAudio) = lock.withLock {
            (_settings, _activeFPS,
             _rotationCoordinator?.videoRotationAngleForHorizonLevelCapture ?? 90, _hasAudio)
        }

        let bitrate = RecordingSettings.bitrate(width: dims.width, height: dims.height, fps: fps,
                                                quality: settings.quality, codec: settings.codec)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: bitrate,
            AVVideoExpectedSourceFrameRateKey: fps,
            AVVideoMaxKeyFrameIntervalKey: fps,
        ]
        if settings.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
        }

        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec.codecType,
            AVVideoWidthKey: Int(dims.width),
            AVVideoHeightKey: Int(dims.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        video.expectsMediaDataInRealTime = true
        // Rotação do vídeo final conforme o iPhone está posicionado (de pé, deitado…)
        video.transform = CGAffineTransform(rotationAngle: angle * .pi / 180)
        guard w.canAdd(video) else { return fail("Este iPhone não suporta esse formato de vídeo.") }
        w.add(video)

        var audio: AVAssetWriterInput?
        if hasAudio,
           let audioSettings = audioOutput.recommendedAudioSettingsForAssetWriter(writingTo: .mov) {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            a.expectsMediaDataInRealTime = true
            if w.canAdd(a) { w.add(a); audio = a }
        }

        guard w.startWriting() else {
            return fail("Erro ao gravar: \(w.error?.localizedDescription ?? "desconhecido")")
        }
        w.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))

        writer = w
        writerVideo = video
        writerAudio = audio
        updateState {
            $0.isRecording = true
            $0.recordingStart = Date()
            $0.message = nil
        }
    }

    private func finishRecording() {
        wantsRecording = false
        guard let w = writer else {
            updateState { $0.isRecording = false; $0.recordingStart = nil }
            return
        }
        writerVideo?.markAsFinished()
        writerAudio?.markAsFinished()
        writer = nil
        writerVideo = nil
        writerAudio = nil
        updateState {
            $0.isRecording = false
            $0.recordingStart = nil
            $0.message = "Salvando vídeo…"
        }

        nonisolated(unsafe) let finishing = w
        finishing.finishWriting {
            if finishing.status == .completed {
                self.saveToPhotos(finishing.outputURL)
            } else {
                self.updateState {
                    $0.message = "Falha ao gravar: \(finishing.error?.localizedDescription ?? "desconhecido")"
                }
            }
        }
        // Ajustes alterados durante a gravação passam a valer agora.
        apply(lock.withLock { _settings })
    }

    private func saveToPhotos(_ url: URL) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                try? FileManager.default.removeItem(at: url)
                self.updateState { $0.message = "Sem permissão para salvar na Fotos." }
                return
            }
            PHPhotoLibrary.shared().performChanges({
                _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }) { ok, error in
                try? FileManager.default.removeItem(at: url)
                self.updateState {
                    $0.message = ok ? "Vídeo salvo na Fotos ✓"
                                    : "Erro ao salvar: \(error?.localizedDescription ?? "")"
                }
            }
        }
    }

    // MARK: - Amostras de vídeo/áudio

    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        if output === videoOutput {
            if wantsRecording && writer == nil { startWriter(with: sampleBuffer) }
            if let input = writerVideo, input.isReadyForMoreMediaData { input.append(sampleBuffer) }
            if let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) { onFrame?(pixelBuffer) }
        } else if output === audioOutput {
            if let input = writerAudio, input.isReadyForMoreMediaData { input.append(sampleBuffer) }
        }
    }

    // MARK: - Estado

    private func updateState(_ change: (inout CaptureState) -> Void) {
        let snapshot: CaptureState = lock.withLock {
            change(&_state)
            return _state
        }
        onStateChange?(snapshot)
    }
}
