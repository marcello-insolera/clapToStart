import AVFoundation
import Cocoa

/// Detects a double-clap via the system microphone and fires `onClapDetected`.
class ClapDetector {

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

    private let engine = AVAudioEngine()
    private var ambientRMS: Float = 0.001

    private enum ClapState {
        case idle
        case waitingForSecond(id: UUID, firstAt: Date)
    }
    private var clapState: ClapState = .idle
    private var lastSpikeAt:   Date = .distantPast
    private var lastTriggerAt: Date = .distantPast

    private let debounce:         TimeInterval = 0.15
    private let doubleClapWindow: TimeInterval = 0.9
    private let cooldown:         TimeInterval = 2.0

    // MARK: - Init

    init() {
        if let saved = UserDefaults.standard.string(forKey: "sensitivity"),
           let s = Sensitivity(rawValue: saved) {
            sensitivity = s
        }
    }

    // MARK: - Lifecycle

    func start() {
        // Must request permission BEFORE touching AVAudioEngine.inputNode,
        // otherwise inputNode returns a dummy silent node in sandbox.
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            DispatchQueue.main.async { self.startEngine() }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.startEngine()
                    } else {
                        self?.showPermissionAlert()
                    }
                }
            }
        default:
            showPermissionAlert()
        }
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }

    // MARK: - Engine

    private func startEngine() {
        let input  = engine.inputNode
        let format = input.outputFormat(forBus: 0)

        // Guard against a dummy/silent node (format has 0 sample rate when denied)
        guard format.sampleRate > 0 else {
            showPermissionAlert()
            return
        }

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.process(buf)
        }

        do {
            try engine.start()
        } catch {
            print("ClapDetector: engine start failed – \(error)")
        }
    }

    // MARK: - Audio processing (audio thread)

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard isEnabled,
              let data = buffer.floatChannelData?[0] else { return }

        let n = Int(buffer.frameLength)
        guard n > 0 else { return }

        var sumSq: Float = 0
        for i in 0..<n { sumSq += data[i] * data[i] }
        let rms = (sumSq / Float(n)).squareRoot()

        ambientRMS = ambientRMS * 0.997 + rms * 0.003

        let threshold = max(ambientRMS * sensitivity.multiplier, 0.03)

        if rms > threshold {
            DispatchQueue.main.async { [weak self] in self?.handleSpike() }
        }
    }

    // MARK: - Double-clap state machine (main thread)

    private func handleSpike() {
        let now = Date()
        guard now.timeIntervalSince(lastSpikeAt)   > debounce else { return }
        guard now.timeIntervalSince(lastTriggerAt) > cooldown else { return }
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
