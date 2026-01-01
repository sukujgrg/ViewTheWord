import Foundation
import OSLog

/// File-based logger that writes logs to ~/Library/Logs/ViewTheWord/viewtheword.log
class FileLogger {
    static let shared = FileLogger()

    private let logFileURL: URL
    private let fileHandle: FileHandle?
    private let queue = DispatchQueue(label: "com.viewtheword.filelogger", qos: .utility)

    private init() {
        // Use standard macOS Logs directory
        // This works with sandboxing and is accessible via Console.app
        let logsDirectory: URL
        if let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first {
            logsDirectory = libraryURL.appendingPathComponent("Logs/ViewTheWord", isDirectory: true)
        } else {
            // Fallback to home directory if Library not accessible
            logsDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".viewtheword", isDirectory: true)
        }

        // Create logs directory if it doesn't exist
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)

        logFileURL = logsDirectory.appendingPathComponent("viewtheword.log")

        // Create or open log file
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }

        // Open file handle for appending
        fileHandle = try? FileHandle(forWritingTo: logFileURL)
        fileHandle?.seekToEndOfFile()

        // Log startup
        log("ViewTheWord started", level: "INFO")
        log("Log file: \(logFileURL.path)", level: "INFO")
        log("You can view logs with: tail -f '\(logFileURL.path)'", level: "INFO")
        log("Or open in Console.app: open '\(logFileURL.path)'", level: "INFO")
    }

    deinit {
        fileHandle?.closeFile()
    }

    /// Log a message to file
    func log(_ message: String, level: String = "INFO", file: String = #file, function: String = #function, line: Int = #line) {
        queue.async { [weak self] in
            guard let self = self, let fileHandle = self.fileHandle else { return }

            let timestamp = ISO8601DateFormatter().string(from: Date())
            let fileName = URL(fileURLWithPath: file).lastPathComponent
            let logMessage = "[\(timestamp)] [\(level)] [\(fileName):\(line)] \(message)\n"

            if let data = logMessage.data(using: .utf8) {
                fileHandle.write(data)
            }
        }
    }

    /// Clear the log file
    func clearLog() {
        queue.async { [weak self] in
            guard let self = self else { return }
            try? "".write(to: self.logFileURL, atomically: true, encoding: .utf8)
        }
    }

    /// Get log file path
    func getLogPath() -> String {
        return logFileURL.path
    }
}

/// Extension to OSLog.Logger to add file logging
extension Logger {
    func fileInfo(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        self.info("\(message)")
        FileLogger.shared.log(message, level: "INFO", file: file, function: function, line: line)
    }

    func fileError(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        self.error("\(message)")
        FileLogger.shared.log(message, level: "ERROR", file: file, function: function, line: line)
    }

    func fileWarning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        self.warning("\(message)")
        FileLogger.shared.log(message, level: "WARNING", file: file, function: function, line: line)
    }

    func fileDebug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        self.debug("\(message)")
        FileLogger.shared.log(message, level: "DEBUG", file: file, function: function, line: line)
    }
}
