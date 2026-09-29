import Foundation

enum Log {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static func emit(_ level: String, _ message: String) {
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)"
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    static func info(_ m: String)  { emit("info", m) }
    static func warn(_ m: String)  { emit("warn", m) }
    static func error(_ m: String) { emit("err ", m) }
}
