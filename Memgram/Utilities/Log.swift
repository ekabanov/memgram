import OSLog

extension Logger {
    static func make(_ category: String) -> Logger {
        Logger(subsystem: "com.memgram.app", category: category)
    }
}
