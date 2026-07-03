import Foundation
import OSLog

/// Rate-limits repeated identical log lines — e.g. an error fired by a 10s
/// poll loop that would otherwise drown the log in hundreds of copies.
/// Logs the first occurrence immediately, then at most once per interval,
/// annotating how many repeats were suppressed in between.
final class LogThrottle: @unchecked Sendable {
    static let shared = LogThrottle()

    private var lastLogged: [String: Date] = [:]
    private var suppressed: [String: Int] = [:]
    private let lock = NSLock()

    /// Returns whether the caller should emit the line, plus the number of
    /// occurrences suppressed since the last emitted one.
    func shouldLog(key: String, interval: TimeInterval) -> (emit: Bool, suppressed: Int) {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if let last = lastLogged[key], now.timeIntervalSince(last) < interval {
            suppressed[key, default: 0] += 1
            return (false, suppressed[key] ?? 0)
        }
        let count = suppressed[key] ?? 0
        lastLogged[key] = now
        suppressed[key] = 0
        return (true, count)
    }
}

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

    /// Error that repeats identically (poll loops, retry cycles): logs the
    /// first occurrence, then at most once per `interval`, with a
    /// suppressed-repeat count so the log stays readable AND the frequency
    /// of the problem remains visible.
    func errorThrottled(key: String, interval: TimeInterval = 600,
                        _ message: @autoclosure () -> String) {
        let (emit, count) = LogThrottle.shared.shouldLog(key: key, interval: interval)
        guard emit else { return }
        let suffix = count > 0 ? " [\(count) identical error(s) suppressed in the last \(Int(interval))s]" : ""
        let m = message() + suffix
        logger.error("\(m, privacy: .public)")
    }

    /// Warning counterpart of errorThrottled.
    func warningThrottled(key: String, interval: TimeInterval = 600,
                          _ message: @autoclosure () -> String) {
        let (emit, count) = LogThrottle.shared.shouldLog(key: key, interval: interval)
        guard emit else { return }
        let suffix = count > 0 ? " [\(count) identical warning(s) suppressed in the last \(Int(interval))s]" : ""
        let m = message() + suffix
        logger.warning("\(m, privacy: .public)")
    }
}

extension Logger {
    static func make(_ category: String) -> PublicLogger {
        PublicLogger(Logger(subsystem: "com.memgram.app", category: category))
    }
}
