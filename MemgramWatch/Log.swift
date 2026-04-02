import OSLog

struct PublicLogger {
    private let logger: Logger

    init(_ logger: Logger) { self.logger = logger }

    func info(_ message: @autoclosure () -> String)     { let m = message(); logger.info("\(m, privacy: .public)") }
    func error(_ message: @autoclosure () -> String)    { let m = message(); logger.error("\(m, privacy: .public)") }
    func warning(_ message: @autoclosure () -> String)  { let m = message(); logger.warning("\(m, privacy: .public)") }
    func debug(_ message: @autoclosure () -> String)    { let m = message(); logger.debug("\(m, privacy: .public)") }
    func fault(_ message: @autoclosure () -> String)    { let m = message(); logger.fault("\(m, privacy: .public)") }
    func notice(_ message: @autoclosure () -> String)   { let m = message(); logger.notice("\(m, privacy: .public)") }
    func critical(_ message: @autoclosure () -> String) { let m = message(); logger.critical("\(m, privacy: .public)") }
}

extension Logger {
    static func make(_ category: String) -> PublicLogger {
        PublicLogger(Logger(subsystem: "com.memgram.app", category: category))
    }
}
