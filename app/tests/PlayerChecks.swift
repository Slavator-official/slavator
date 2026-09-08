import Foundation
import AVFoundation
import SwiftUI

enum Paths {
    static var core: URL { URL(fileURLWithPath: "/nonexistent/core.py") }
    static var venvPython: URL { URL(fileURLWithPath: "/usr/bin/python3") }
}
struct Record {
    let dir: URL
    let title: String
    let source: URL?
    let ownTrack: URL?
}

@main struct PlayerChecks {
    static func main() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("slavator-player-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func silent(_ name: String, seconds: Double) throws -> URL {
            let url = dir.appendingPathComponent(name)
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let frames = AVAudioFrameCount(16000 * seconds)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
            buffer.frameLength = frames
            buffer.floatChannelData![0].initialize(repeating: 0, count: Int(frames))
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
            return url
        }
        let source = try silent("system.wav", seconds: 2)
        let voice = try silent("voice.wav", seconds: 4)
        let record = Record(dir: dir, title: "Тест", source: source, ownTrack: voice)
        let player = Player()
        player.playMeeting(record, colour: .blue)
        if player.isPlaying { player.toggle() }
        precondition(player.isActive && player.canSeek && player.recordingID == dir)
        precondition(abs(player.length - 4) < 0.02, "Своя дорожка не должна обрезаться")
        player.setRate(1.5)
        precondition(player.rate == 1.5 && player.rateLabel == "1.5×")
        player.setRate(99)
        precondition(player.rate == 1.5)
        player.seek(to: 0.5)
        precondition(abs(player.position - 2) < 0.02)
        player.skip(seconds: -15)
        precondition(player.position == 0)
        player.skip(seconds: 15)
        precondition(player.position == player.length && player.isActive && !player.isPlaying)
        player.seek(to: .nan)
        precondition(player.position == player.length)
        player.toggle()
        precondition(player.position == 0, "Повторное воспроизведение начинается сначала")
        player.stop()
        precondition(!player.isActive && !player.canSeek && player.recordingID == nil)
        player.play(url: voice, label: "Фрагмент", colour: .blue, from: 1, to: 2)
        if player.isPlaying { player.toggle() }
        precondition(abs(player.length - 1) < 0.02)
        player.seek(to: 0.5)
        precondition(abs(player.position - 0.5) < 0.02 && player.rate == 1.5)
        player.stop()
        precondition(FileManager.default.fileExists(atPath: source.path))
        precondition(FileManager.default.fileExists(atPath: voice.path))
        print("PASS: плеер — две дорожки, перемотка, границы, скорость, повтор и сохранность исходников")
    }
}
