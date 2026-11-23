import AVFoundation

final class AudioManager {
    private var ambient: AVAudioPlayer?
    private var effects: [String: AVAudioPlayer] = [:]
    private var sessionReady = false

    var sfxEnabled = true
    var hoverEnabled = true
    var envSoundsEnabled = true { didSet { applyAmbient() } }
    var volume: Float = 0.8 {
        didSet { ambient?.volume = 0.6 * volume }
    }

    private func configureSession() {
        if sessionReady { return }
        sessionReady = true
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
    }

    /// Troca o som de fundo para o do ambiente `env` (Resources/<env>/ambient.m4a).
    func setEnvironment(_ env: String) {
        configureSession()
        ambient?.stop()
        ambient = nil
        if let url = Bundle.main.url(forResource: "ambient", withExtension: "m4a", subdirectory: env) {
            ambient = try? AVAudioPlayer(contentsOf: url)
            ambient?.numberOfLoops = -1
            ambient?.volume = 0.6 * volume
            ambient?.prepareToPlay()
        }
        applyAmbient()
    }

    private func applyAmbient() {
        guard let a = ambient else { return }
        if envSoundsEnabled {
            if !a.isPlaying { a.play() }
        } else {
            a.pause()
        }
    }

    func play(_ name: String, hover: Bool = false) {
        if !sfxEnabled { return }
        if hover && !hoverEnabled { return }
        if effects[name] == nil {
            if let url = Bundle.main.url(forResource: name, withExtension: "m4a", subdirectory: "sfx") {
                let p = try? AVAudioPlayer(contentsOf: url)
                p?.prepareToPlay()
                effects[name] = p
            }
        }
        if let p = effects[name] {
            p.volume = volume
            p.currentTime = 0
            p.play()
        }
    }
}
