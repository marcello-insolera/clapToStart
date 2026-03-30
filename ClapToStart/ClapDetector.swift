import AVFoundation
import Cocoa

/// Detects a double-clap via the system microphone and fires `onClapDetected`.
/// Uses AVCaptureSession (sandbox-compatible) instead of AVAudioEngine.
class ClapDetector: NSObject {

    // MARK: - Sensitivity

    enum Sensitivity: String, CaseIterable {
        case low    = "Niedrig"
        case medium = "Mittel"
        case high   = "Hoch"

        var multiplier: Float {
            switch self {
            case .low:    return 16.0
            case .medium: return  8.0
            case .high:   return  4.0
            }
        }
    }

    // MARK: - Public API

    var onClapDetected: (() -> Void)?
    var isEnabled: Bool = true
    var sensitivity: Sensitivity = .medium {
        didSet { UserDefaults.standard.set(sensitivity.rawValue, forKey: "sensitivity") }
    }

    // MARK: - Private

    private var session: AVCaptureSession?
    private var ambientRMS: Float = 0.001

    private enum ClapState {
        case idle
        case waitingForSecond(id: UUID, firstAt: Date)
    }
    private var clapState: ClapState = .idle
    private var lastSpikeAt: Date   = .distantPast
    private var lastTriggerAt: Date = .distantPast

    private let debounce:          TimeInterval = 0.15
    private let doubleClapWindow:  TimeInterval = 0.9
    private let cooldown:          TimeInterval = 2.0

    // MARK: - Init

    override init() {
        super.init()
        if let saved = UserDefaults.standard.string(forKey: "sensitivity"),
           let s = Sensitivity(rawValue: saved) {
            sensitivity = s
        }
    }

    // MARK: - Lifecycle

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.startSession() : self?.showPermissionAlert()
                }
            }
        default:
            DispatchQueue.main.async { self.showPermissionAlert() }
        }
    }

    func stop() {
        session?.stopRunning()
        session = nil
    }

    // MARK: - AVCaptureSession setup

    private func startSession() {
        let s = AVCaptureSession()

        guard let device = AVCaptureDevice.default(for: .audio) else {
            print("ClapDetector: no audio input device found")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard s.canAddInput(input) else { return }
            s.addInput(input)
        } catch {
            print("ClapDetector: failed to create audio input – \(error)")
            return
        }

        let output = AVCaptureAudioDataOutput()
        let queue  = DispatchQueue(label: "com.claptostart.audio", qos: .userInteractive)
        output.setSampleBufferDelegate(self, queue: queue)

        guard s.canAddOutput(output) else { return }
        s.addOutput(output)

        session = s
        s.startRunning()
    }

    // MARK: - Double-clap state machine (main thread)

    private func handleSpike() {
        let now = Date()
        guard now.timeIntervalSince(lastSpikeAt)    > debounce  else { return }
        guard now.timeIntervalSince(lastTriggerAt)  > cooldown  else { return }
        lastSpikeAt = now

        switch clapState {
        case .idle:
            let id = UUID()
            clapState = .waitingForSecond(id: id, firstAt: now)
            DispatchQueue.main.asyncAfter(deadline: .now() + doubleClapWindow) { [weak self] in
                guard let self else { return }
                if case .waitingForSecond(let sid, _) = self.clapState, sid == id {
                    self.clapState = .idle
                }
            }

        case .waitingForSecond(_, let firstAt):
            guard now.timeIntervalSince(firstAt) >= debounce else { return }
            clapState     = .idle
            lastTriggerAt = now
            onClapDetected?()
        }
    }

    // MARK: - Permission alert

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText     = "Mikrofonzugriff benötigt"
        alert.informativeText = """
            ClapToStart benötigt Zugriff auf das Mikrofon, \
            um doppeltes Klatschen zu erkennen.

            Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Systemeinstellungen öffnen")
        alert.addButton(withTitle: "Abbrechen")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(
                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            )
        }
    }
}

// MARK: - AVCaptureAudioDataOutputSampleBufferDelegate

extension ClapDetector: AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {

        guard isEnabled, CMSampleBufferDataIsReady(sampleBuffer) else { return }

        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        var totalLength = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(blockBuffer, atOffset: 0,
                                          lengthAtOffsetOut: nil,
                                          totalLengthOut: &totalLength,
                                          dataPointerOut: &dataPointer) == noErr,
              let ptr = dataPointer, totalLength > 0 else { return }

        // Determine sample format from the buffer's format description
        guard let fmtDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fmtDesc)?.pointee
        else { return }

        let rms: Float

        if asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 {
            // Float32 PCM
            let frameCount = totalLength / 4
            guard frameCount > 0 else { return }
            let floats = ptr.withMemoryRebound(to: Float.self, capacity: frameCount) {
                UnsafeBufferPointer(start: $0, count: frameCount)
            }
            var sumSq: Float = 0
            for f in floats { sumSq += f * f }
            rms = (sumSq / Float(frameCount)).squareRoot()

        } else {
            // Int16 PCM (common on macOS built-in mic)
            let frameCount = totalLength / 2
            guard frameCount > 0 else { return }
            let shorts = ptr.withMemoryRebound(to: Int16.self, capacity: frameCount) {
                UnsafeBufferPointer(start: $0, count: frameCount)
            }
            var sumSq: Float = 0
            for s in shorts {
                let f = Float(s) / 32768.0
                sumSq += f * f
            }
            rms = (sumSq / Float(frameCount)).squareRoot()
        }

        // Update slow-moving ambient level
        ambientRMS = ambientRMS * 0.997 + rms * 0.003

        let threshold = max(ambientRMS * sensitivity.multiplier, 0.03)

        if rms > threshold {
            DispatchQueue.main.async { [weak self] in self?.handleSpike() }
        }
    }
}
