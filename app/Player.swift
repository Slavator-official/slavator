import AVFoundation
import SwiftUI

/// Воспроизведение образцов и фрагментов встреч.
///
/// В прежней версии звук уходил в `afplay` подпроцессом: нельзя было ни
/// узнать позицию, ни перемотать, ни понять, играет ли ещё. AVAudioPlayer
/// даёт всё это, и панель плеера наконец показывает правду.
@Observable
final class Player {
    private(set) var label = ""
    private(set) var subtitle = ""
    private(set) var colour: Color = .gray
    private(set) var position: Double = 0
    private(set) var length: Double = 0
    private(set) var isPlaying = false
    private(set) var isActive = false

    private var engine: AVAudioPlayer?
    private var ticker: Timer?
    /// Для фрагмента встречи: играем кусок общего файла, а не весь час.
    private var segment: ClosedRange<Double>?

    func play(url: URL, label: String, subtitle: String = "",
              colour: Color, from: Double? = nil, to: Double? = nil) {
        stopTicker()
        guard let player = try? AVAudioPlayer(contentsOf: url) else {
            self.label = "Не удалось открыть файл"
            self.subtitle = url.lastPathComponent
            self.colour = colour
            isActive = true; isPlaying = false
            return
        }

        engine = player
        player.prepareToPlay()

        if let from, let to {
            segment = from...max(from + 0.2, to)
            player.currentTime = from
            length = to - from
        } else {
            segment = nil
            length = player.duration
        }

        self.label = label
        self.subtitle = subtitle
        self.colour = colour
        position = 0
        isActive = true
        player.play()
        isPlaying = true
        startTicker()
    }

    func toggle() {
        guard let player = engine else { return }
        if player.isPlaying {
            player.pause(); isPlaying = false; stopTicker()
        } else {
            player.play(); isPlaying = true; startTicker()
        }
    }

    func seek(to fraction: Double) {
        guard let player = engine else { return }
        let clamped = min(max(fraction, 0), 1)
        if let segment {
            player.currentTime = segment.lowerBound + clamped * length
        } else {
            player.currentTime = clamped * length
        }
        position = clamped * length
    }

    func stop() {
        engine?.stop()
        engine = nil
        stopTicker()
        isPlaying = false
        isActive = false
        position = 0
        segment = nil
    }

    private func startTicker() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self, let player = self.engine else { return }
            if let segment {
                position = player.currentTime - segment.lowerBound
                // Фрагмент кончился — дальше идёт чужая речь, останавливаем.
                if player.currentTime >= segment.upperBound { stop(); return }
            } else {
                position = player.currentTime
            }
            if !player.isPlaying && isPlaying { stop() }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

/// Панель воспроизведения внизу окна. Появляется только когда что-то звучит:
/// полоса с прочерками читается как поломка, а не как пустое состояние.
struct PlayerBar: View {
    @Environment(\.palette) private var p
    var player: Player

    var body: some View {
        HStack(spacing: 14) {
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

            VStack(alignment: .leading, spacing: 1) {
                Text(player.label).font(Kind.strong(13.5)).foregroundStyle(p.text).lineLimit(1)
                if !player.subtitle.isEmpty {
                    Text(player.subtitle).font(Kind.body(12)).foregroundStyle(p.muted).lineLimit(1)
                }
            }
            .frame(width: 210, alignment: .leading)

            Scrubber(player: player)

            Text("\(hms(player.position)) / \(hms(player.length))")
                .font(Kind.mono(12)).foregroundStyle(p.muted)

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
        GeometryReader { geo in
            let done = player.length > 0 ? player.position / player.length : 0
            ZStack(alignment: .leading) {
                Capsule().fill(p.line).frame(height: 5)
                Capsule().fill(player.colour)
                    .frame(width: max(0, geo.size.width * done), height: 5)
            }
            .frame(height: geo.size.height, alignment: .center)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onEnded { value in
                player.seek(to: value.location.x / geo.size.width)
            })
        }
        .frame(height: 26)
    }
}
