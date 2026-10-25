import Foundation

/// Запуск встроенных инструментов (whisper-cli, llama-completion, afconvert).
/// stdout и stderr читаются параллельно с работой процесса: буфер pipe ~64 КБ,
/// и если ждать выхода до чтения, процесс, заполнивший его логами, висит вечно.
enum ProcessRunner {
    struct Output {
        let status: Int32
        let stdout: Data
        let stderr: Data
        var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
    }

    static func run(_ executable: URL, _ arguments: [String]) throws -> Output {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()

        var stdout = Data(), stderr = Data()
        let group = DispatchGroup()
        for (pipe, isOut) in [(out, true), (err, false)] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if isOut { stdout = data } else { stderr = data }
                group.leave()
            }
        }
        group.wait()
        process.waitUntilExit()
        return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
