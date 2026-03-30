import AVFoundation
import Cocoa

/// Detects a double-clap via the system microphone and fires `onClapDetected`.
class ClapDetector {

    // MARK: - Sensitivity

    enum Sensitivity: String, CaseIterable {
        case low    = "Niedrig"
        case medium = "Mittel"
        case high   = "Hoch"

        /// How many times louder than the ambient RMS a spike must be to count as a clap.
        var multiplier: Float {
            switch self {
            case .low:    return 16.0
            case .medium: return  9.0
            case .high:   return  4.5
            }
        }
    }

    // MARK: - Public API

    var onClapDetected: (() -> Void)?
    var isEnabled: Bool = true
    var sensitivity: Sensitivity = .medium {
        didSet { UserDefaults.standard.set(sensitivity.rawValue, forKey: "sensitivity") }
    }

    // MARK: - Private state

    private let audioEngine = AVAudioEngine()

    /// Slow-moving ambient noise level — adapts to the room over time.
    private var ambientRMS: Float = 0.001

    // Double-clap state machine
    private enum ClapState {
        case idle
        case waitingForSecond(id: UUID, firstAt: Date)
    }
    private var clapState: ClapState = .idle

    private var lastSpikeAt: Date = .distantPast
    private var lastTriggerAt: Date = .distantPast

    /// Minimum gap between two buffers counted as separate events (debounce).
    private let debounce: TimeInterval = 0.15
    /// Maximum gap between first and second clap to count as a double-clap.
    private let doubleClapWindow: TimeInterval = 0.9
    /// Quiet period after a successful trigger.
    private let cooldown: TimeInterval = 2.0

    // MARK: - Lifecycle

    init() {
        if let saved = UserDefaults.standard.string(forKey: "sensitivity"),
           let s = Sensitivity(rawValue: saved) {
            sensitivity = s
        }
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startEngine()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                DispatchQueue.main.async {
                    granted ? self?.startEngine() : self?.showPermissionAlert()
                }
            }
        default:
            DispatchQueue.main.async { self.showPermissionAlert() }
        }
    }

    func stop() {
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
    }

    // MARK: - Audio engine

    private func startEngine() {
        let input = audioEngine.inputNode
        let format = input.outputFormat(forBus: 0)

        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            self?.process(buf)
        }

        do {
            try audioEngine.start()
        } catch {
            print("ClapDetector: audio engine failed – \(error)")
        }
    }

    // MARK: - Buffer processing (runs on audio thread)

    private func process(_ buffer: AVAudioPCMBuffer) {
        guard isEnabled,
              let data = buffer.floatChannelData?[0] else { return }

        let n = Int(buffer.frameLength)
        guard n > 0 else { return }

        // Root-mean-square of this buffer
        var sumSq: Float = 0
        for i in 0..<n { sumSq += data[i] * data[i] }
        let rms = (sumSq / Float(n)).squareRoot()

        // Update ambient level (very slow moving average)
        ambientRMS = ambientRMS * 0.998 + rms * 0.002

        let threshold = max(ambientRMS * sensitivity.multiplier, 0.04)

        if rms > threshold {
            DispatchQueue.main.async { [weak self] in self?.handleSpike() }
        }
    }

    // MARK: - Double-clap state machine (runs on main thread)

    private func handleSpike() {
        let now = Date()

        // Debounce — ignore subsequent spikes from the same physical clap
        guard now.timeIntervalSince(lastSpikeAt) > debounce else { return }
        lastSpikeAt = now

        // Cooldown after a successful trigger
        guard now.timeIntervalSince(lastTriggerAt) > cooldown else { return }

        switch clapState {
        case .idle:
            // First clap detected — start timer for second
            let id = UUID()
            clapState = .waitingForSecond(id: id, firstAt: now)

            DispatchQueue.main.asyncAfter(deadline: .now() + doubleClapWindow) { [weak self] in
                guard let self else { return }
                if case .waitingForSecond(let sid, _) = self.clapState, sid == id {
                    self.clapState = .idle   // Timed out — reset
                }
            }

        case .waitingForSecond(_, let firstAt):
            guard now.timeIntervalSince(firstAt) >= debounce else { return }
            // Second clap — fire!
            clapState = .idle
            lastTriggerAt = now
            onClapDetected?()
        }
    }

    // MARK: - Permission alert

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Mikrofonzugriff benötigt"
        alert.informativeText = """
            ClapToStart benötigt Zugriff auf das Mikrofon, \
            um doppeltes Klatschen zu erkennen.

            Bitte aktiviere den Zugriff unter:
            Systemeinstellungen → Datenschutz & Sicherheit → Mikrofon
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Systemeinstellungen öffnen")
        alert.addButton(withTitle: "Abbrechen")

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            NSWorkspace.shared.open(url)
        }
    }
}
