import Foundation

/// Pipe режет поток в любом байте, в том числе посреди UTF-8 и JSON.
struct LineBuffer {
    private var pending = Data()

    mutating func append(_ data: Data, endOfFile: Bool = false) -> [String] {
        pending.append(data)
        var lines: [String] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = String(decoding: pending[..<newline], as: UTF8.self)
                .trimmingCharacters(in: .newlines)
            if !line.isEmpty { lines.append(line) }
            pending.removeSubrange(...newline)
        }
        if endOfFile, !pending.isEmpty {
            lines.append(String(decoding: pending, as: UTF8.self))
            pending.removeAll()
        }
        return lines
    }
}

/// Единственный фоновый читатель дренирует pipe ДО ожидания завершения.
/// Обработчики строк и завершения доставляются на главную очередь по порядку.
enum ProcessOutput {
    static func read(_ pipe: Pipe, process: Process,
                     onLine: @escaping (String) -> Void,
                     onExit: @escaping (Int32) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            var buffer = LineBuffer()
            let handle = pipe.fileHandleForReading
            while true {
                let data = handle.availableData
                let lines = buffer.append(data, endOfFile: data.isEmpty)
                for line in lines { DispatchQueue.main.async { onLine(line) } }
                if data.isEmpty { break }
            }
            process.waitUntilExit()
            let status = process.terminationStatus
            try? handle.close()
            DispatchQueue.main.async { onExit(status) }
        }
    }
}
