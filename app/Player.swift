import AVFoundation
import SwiftUI

/// One shared player for whole recordings and evidence clips.
@Observable
final class Player {
    private(set) var label = ""
    private(set) var subtitle = ""
    private(set) var colour: Color = .gray
    private(set) var position: Double = 0
    private(set) var length: Double = 0
    private(set) var isPlaying = false
    private(set) var isActive = false
    private(set) var isPreparing = false
    private(set) var rate: Double = 1
    private(set) var recordingID: URL?
    var canSeek: Bool { engine != nil && length > 0 && !isPreparing }
    static let speeds: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 1.75, 2]
    var rateLabel: String { String(format: "%g×", rate) }

    private var engine: AVAudioPlayer?
    private var companion: AVAudioPlayer?
    private var ticker: Timer?
    private var decoder: Process?
    private var temporaryAudio: URL?
    private var segment: ClosedRange<Double>?

    /// Identity uses the source and requested range, never the display name:
    /// different speakers can share a name and clips can share an audio file.
    private struct Selection: Equatable {
        let url: URL
        let from: Double?
        let to: Double?
        let voice: URL?
    }
    private var selection: Selection?

    func isPlaying(url: URL, from: Double? = nil, to: Double? = nil,
                   voice: URL? = nil) -> Bool {
        isPlaying && selection == Selection(url: url, from: from, to: to, voice: voice)
    }

    func playMeeting(_ record: Record, colour: Color) {
        if recordingID == record.dir && (canSeek || isPreparing) {
            if isPreparing { stop() } else { toggle() }
            return
        }
        guard let source = record.source ?? record.ownTrack else { return }
        play(url: source, label: record.title, subtitle: "Запись встречи", colour: colour,
             voice: record.ownTrack == source ? nil : record.ownTrack)
        recordingID = record.dir
    }

    func play(url: URL, label: String, subtitle: String = "",
              colour: Color, from: Double? = nil, to: Double? = nil, voice: URL? = nil) {
        let requested = Selection(url: url, from: from, to: to, voice: voice)
        if selection == requested {
            if isPreparing { stop(); return }
            if canSeek { toggle(); return }
        }
        stop()
        selection = requested
        self.label = label; self.subtitle = subtitle; self.colour = colour
        isActive = true
        if let audio = try? AVAudioPlayer(contentsOf: url) {
            start(audio, voice: voice, from: from, to: to)
        } else {
            decode(url: url, label: label, from: from, to: to, voice: voice)
        }
    }

    private func start(_ audio: AVAudioPlayer, voice: URL?, from: Double?, to: Double?) {
        engine = audio
        if let voice {
            companion = try? AVAudioPlayer(contentsOf: voice)
            if companion == nil { subtitle += " · микрофонная дорожка недоступна" }
        }
        // Use the longer track as the clock, so neither side is cut off.
        if let other = companion, other.duration > audio.duration {
            engine = other; companion = audio
        }
        guard let player = engine else { return }
        for track in [engine, companion].compactMap({ $0 }) {
            track.enableRate = true; track.rate = Float(rate); track.prepareToPlay()
        }
        if let from, let to {
            let start = min(max(0, from), player.duration)
            let end = min(max(start, to), player.duration)
            segment = start...end; length = end - start
        } else {
            segment = nil; length = player.duration
        }
        position = 0
        seek(to: 0)
        resume()
    }

    private func resume() {
        guard let player = engine else { return }
        if position >= length - 0.01 { seek(to: 0) }
        let start = player.deviceCurrentTime + 0.05
        isPlaying = player.play(atTime: start)
        if let companion, companion.currentTime < companion.duration {
            _ = companion.play(atTime: start)
        }
        if isPlaying { startTicker() }
        else { subtitle = "Не удалось начать воспроизведение. Проверьте аудиовыход." }
    }

    /// Unsupported containers are decoded locally, in bounded-memory chunks.
    private func decode(url: URL, label: String, from: Double?, to: Double?, voice: URL?) {
        let target = FileManager.default.temporaryDirectory.appending(path: "slavator-play-\(UUID()).wav")
        let process = Process()
        process.executableURL = Paths.venvPython
        var args = ["-B", Paths.core.deletingLastPathComponent().appending(path: "audio_preview.py").path,
                    "--input", url.path, "--output", target.path]
        if let from { args += ["--start", String(max(0, from))] }
        if let from, let to { args += ["--end", String(max(from + 0.2, to))] }
        process.arguments = args
        process.environment = AppConfiguration.environment()
        let pipe = Pipe()
        process.standardOutput = FileHandle.nullDevice; process.standardError = pipe
        decoder = process; isPreparing = true
        self.label = from == nil ? "Подготавливаю запись…" : "Подготавливаю фрагмент…"
        do {
            try process.run()
            ProcessOutput.read(pipe, process: process, onLine: { _ in }, onExit: { [weak self] status in
                guard let self, self.decoder === process else {
                    try? FileManager.default.removeItem(at: target); return
                }
                self.decoder = nil; self.isPreparing = false
                guard status == 0, let audio = try? AVAudioPlayer(contentsOf: target) else {
                    try? FileManager.default.removeItem(at: target)
                    self.label = "Не удалось подготовить аудио"
                    self.subtitle = "Проверьте исходную запись и окружение обработки звука"
                    return
                }
                self.temporaryAudio = target; self.label = label
                // A decoded clip already starts at zero. Whole recordings may
                // also have an aligned microphone WAV from live capture.
                self.start(audio, voice: from == nil ? voice : nil, from: nil, to: nil)
            })
        } catch {
            decoder = nil; isPreparing = false
            self.label = "Не удалось открыть запись"; self.subtitle = error.localizedDescription
            try? FileManager.default.removeItem(at: target)
        }
    }

    func toggle() {
        guard engine != nil else { return }
        if isPlaying {
            engine?.pause(); companion?.pause(); isPlaying = false; stopTicker()
        } else { resume() }
    }

    func setRate(_ value: Double) {
        guard Self.speeds.contains(value) else { return }
        rate = value
        engine?.rate = Float(value); companion?.rate = Float(value)
    }

    func skip(seconds: Double) {
        guard length > 0, seconds.isFinite else { return }
        seek(to: (position + seconds) / length)
    }

    func seek(to fraction: Double) {
        guard let player = engine, fraction.isFinite else { return }
        position = min(max(fraction, 0), 1) * length
        let time = (segment?.lowerBound ?? 0) + position
        player.currentTime = min(time, player.duration)
        companion?.currentTime = min(time, companion?.duration ?? 0)
        if position >= length {
            finishPlayback()
        } else if isPlaying {
            // Restart both tracks against the same hardware clock after seek.
            resume()
        }
    }

    func stop() {
        if let decoder, decoder.isRunning { decoder.terminate() }
        decoder = nil; isPreparing = false
        engine?.stop(); companion?.stop(); engine = nil; companion = nil
        stopTicker()
        isPlaying = false; isActive = false; position = 0; length = 0
        segment = nil; recordingID = nil; selection = nil
        if let temporaryAudio { try? FileManager.default.removeItem(at: temporaryAudio) }
        temporaryAudio = nil
    }

    private func finishPlayback() {
        engine?.pause(); companion?.pause()
        position = length; isPlaying = false; stopTicker()
        // Keep the controls visible for replay or seeking after the end.
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let player = self.engine else { return }
            let end = self.segment?.upperBound ?? player.duration
            if player.currentTime >= end || (!player.isPlaying && self.isPlaying) {
                self.finishPlayback()
            } else {
                self.position = max(0, player.currentTime - (self.segment?.lowerBound ?? 0))
            }
        }
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }
}

/// Панель воспроизведения внизу окна. Появляется только когда что-то звучит:
/// полоса с прочерками читается как поломка, а не как пустое состояние.
#if !PLAYER_TESTING
struct PlayerBar: View {
    @Environment(\.palette) private var p
    var player: Player

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(player.colour).frame(width: 3, height: 34)

            Button { player.toggle() } label: {
                ZStack {
                    Circle().fill(p.accent).frame(width: 34, height: 34)
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
            .buttonStyle(.plain)
            .disabled(!player.canSeek)
            .accessibilityLabel(player.isPlaying ? "Пауза" : "Продолжить воспроизведение")

            VStack(alignment: .leading, spacing: 1) {
                Text(player.label).font(Kind.strong(13.5)).foregroundStyle(p.text).lineLimit(1)
                if !player.subtitle.isEmpty {
                    Text(player.subtitle).font(Kind.body(12)).foregroundStyle(p.muted).lineLimit(1)
                }
            }
            .frame(width: 180, alignment: .leading)

            Button { player.skip(seconds: -15) } label: { Image(systemName: "gobackward.15") }
                .buttonStyle(.plain).help("Назад на 15 секунд").accessibilityLabel("Назад на 15 секунд")
                .disabled(!player.canSeek)
            Scrubber(player: player).frame(minWidth: 80)
            Button { player.skip(seconds: 15) } label: { Image(systemName: "goforward.15") }
                .buttonStyle(.plain).help("Вперёд на 15 секунд").accessibilityLabel("Вперёд на 15 секунд")
                .disabled(!player.canSeek)

            Text("\(hms(player.position)) / \(hms(player.length))")
                .font(Kind.mono(12)).foregroundStyle(p.muted)

            Menu(player.rateLabel) {
                ForEach(Player.speeds, id: \.self) { speed in
                    Button(String(format: "%g×", speed)) { player.setRate(speed) }
                }
            }.frame(width: 70).help("Скорость воспроизведения")
                .accessibilityLabel("Скорость воспроизведения: " + player.rateLabel)
            Button("Закрыть") { player.stop() }
                .buttonStyle(.plain)
                .font(Kind.body(13))
                .foregroundStyle(p.muted)
        }
        .padding(.horizontal, 28).padding(.vertical, 12)
        .background(p.raised)
        .overlay(Rectangle().frame(height: 1).foregroundStyle(p.line), alignment: .top)
    }
}

/// Полоса перемотки в цвете говорящего.
private struct Scrubber: View {
    @Environment(\.palette) private var p
    var player: Player

    var body: some View {
        Slider(value: Binding(
            get: { player.length > 0 ? player.position / player.length : 0 },
            set: { player.seek(to: $0) }), in: 0...1)
            .tint(player.colour)
            .disabled(!player.canSeek)
            .accessibilityLabel("Позиция воспроизведения")
    }
}
#endif
