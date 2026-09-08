import AppKit
import SwiftUI

/// Привязка голосов к человеку.
///
/// Диаризация регулярно дробит одного человека на несколько голосов — из-за
/// смены громкости, пауз или того, что он отходил от микрофона. Поэтому
/// главное здесь — выбрать сразу несколько записей и сказать «это один
/// человек»: профиль, построенный по обрывку, потом никого не узнаёт.
@Observable
final class Enrollment {
    private(set) var isRunning = false
    private(set) var failure: String?

    /// Завести человека или дополнить существующего.
    func enroll(name: String, position: String, company: String,
                samples: [URL], library: Library, done: @escaping () -> Void) {
        guard !isRunning, !samples.isEmpty else { return }
        let clean = name.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else {
            failure = "Впишите имя человека."
            return
        }

        isRunning = true
        failure = nil

        let process = Process()
        process.executableURL = Paths.venvPython
        var arguments = ["-B", Paths.core.path, "--enroll", clean]
        if !position.isEmpty { arguments += ["--position", position] }
        if !company.isEmpty { arguments += ["--company", company] }
        arguments.append("--samples")
        arguments += samples.map(\.path)
        process.arguments = arguments
        process.currentDirectoryURL = Paths.core.deletingLastPathComponent()
        process.environment = AppConfiguration.environment(settings: library.settings)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
            var lines: [String] = []
            ProcessOutput.read(pipe, process: process, onLine: { line in
                lines.append(line)
                if lines.count > 100 { lines.removeFirst(lines.count - 100) }
            }, onExit: { status in
                self.isRunning = false
                if status == 0 {
                    // Записи, ставшие профилем, больше не «новые голоса».
                    for url in samples { try? FileManager.default.removeItem(at: url) }
                    library.reload()
                    done()
                } else {
                    self.failure = lines.last(where: { $0.contains("ОШИБКА") })
                        ?? lines.suffix(3).joined(separator: "\n")
                }
            })
        } catch {
            isRunning = false
            failure = error.localizedDescription
        }
    }
}

/// Окно привязки: либо к уже заведённому человеку, либо к новому.
struct EnrollSheet: View {
    @Environment(\.palette) private var p
    @Environment(\.dismiss) private var dismiss

    var library: Library
    let samples: [URL]
    var onDone: () -> Void

    @State private var enrollment = Enrollment()
    @State private var mode = "new"
    @State private var name = ""
    @State private var position = ""
    @State private var company = ""
    @State private var existing: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(samples.count == 1 ? "Чей это голос?" : "Кому принадлежат эти голоса?")
                .font(Kind.title(19))
            Text(samples.count == 1
                 ? "Один образец"
                 : "\(samples.count) записи объединятся в один профиль")
                .font(Kind.body(13)).foregroundStyle(p.muted)
                .padding(.top, 3).padding(.bottom, 18)

            if !library.speakers.isEmpty {
                Segmented(options: [("new", "Новый человек"), ("old", "Уже есть в списке")],
                          selection: $mode)
                    .padding(.bottom, 16)
            }

            if mode == "old" && !library.speakers.isEmpty {
                // Значение берётся из идентификатора ForEach, а не из .tag():
                // тот тянет за собой символ из SwiftUICore, которого нет в
                // macOS 14, и окно объединения там падало бы.
                Picker("", selection: $existing) {
                    ForEach(library.speakers.map(\.name), id: \.self) { name in
                        Text(name)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("Образцы добавятся к этому человеку, и отпечаток пересчитается по всем сразу.")
                    .font(Kind.body(12)).foregroundStyle(p.muted).padding(.top, 8)
            } else {
                VStack(spacing: 10) {
                    field("Имя и фамилия", text: $name)
                    field("Должность", text: $position)
                    field("Компания", text: $company)
                }
            }

            if let failure = enrollment.failure {
                Text(failure).font(Kind.body(12)).foregroundStyle(p.warn)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.top, 12)
            }

            HStack(spacing: 8) {
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(QuietButton()).disabled(enrollment.isRunning)
                Button(enrollment.isRunning ? "Сохраняю…" : "Сохранить") { save() }
                    .buttonStyle(PrimaryButton())
                    .disabled(enrollment.isRunning || !canSave)
            }
            .padding(.top, 20)
        }
        .padding(24)
        .frame(width: 460)
        .background(p.surface)
        .interactiveDismissDisabled(enrollment.isRunning)
        .environment(\.palette, library.palette)
        .onAppear { existing = library.speakers.first?.name ?? "" }
    }

    private var canSave: Bool {
        mode == "old" ? !existing.isEmpty
                      : !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func field(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Kind.body(12)).foregroundStyle(p.muted)
            TextField("", text: text).textFieldStyle(.roundedBorder)
        }
    }

    private func save() {
        let target = mode == "old" ? existing : name
        let person = library.speakers.first { $0.name == target }
        enrollment.enroll(name: target,
                          position: mode == "old" ? (person?.position ?? "") : position,
                          company: mode == "old" ? (person?.company ?? "") : company,
                          samples: samples, library: library) {
            onDone()
            dismiss()
        }
    }
}
