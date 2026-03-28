import WebKit
import AppKit

/// Renders a meeting summary to PDF data via an off-screen WKWebView.
final class PDFExporter: NSObject {

    /// Generate PDF data for the given meeting's summary.
    /// Must be called on the main actor (WKWebView requirement).
    @MainActor
    static func export(meeting: Meeting) async throws -> Data {
        let html = buildHTML(meeting: meeting)
        return try await withCheckedThrowingContinuation { continuation in
            // A4 dimensions in points (72 dpi): 595 × 842
            let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 595, height: 842))
            let delegate = NavigationDelegate(continuation: continuation, webView: webView)
            webView.navigationDelegate = delegate
            webView.loadHTMLString(html, baseURL: nil)
        }
    }

    // MARK: - Navigation delegate (kept alive by webView reference)

    private final class NavigationDelegate: NSObject, WKNavigationDelegate {
        private let continuation: CheckedContinuation<Data, Error>
        private var webView: WKWebView?  // strong ref keeps webView alive during load

        init(continuation: CheckedContinuation<Data, Error>, webView: WKWebView) {
            self.continuation = continuation
            self.webView = webView
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let config = WKPDFConfiguration()
            webView.createPDF(configuration: config) { [weak self] result in
                self?.webView = nil  // release after use
                switch result {
                case .success(let data):
                    self?.continuation.resume(returning: data)
                case .failure(let error):
                    self?.continuation.resume(throwing: error)
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            self.webView = nil
            continuation.resume(throwing: error)
        }
    }

    // MARK: - HTML generation

    static func buildHTML(meeting: Meeting) -> String {
        let title = meeting.title
        let dateStr = DateFormatter.localizedString(
            from: meeting.startedAt, dateStyle: .long, timeStyle: .short)
        let durationStr: String
        if let dur = meeting.durationSeconds, dur > 0 {
            durationStr = " · " + formatDuration(dur)
        } else {
            durationStr = ""
        }
        let summaryHTML = markdownToHTML(meeting.summary ?? "")

        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <style>
          body     { font-family: -apple-system, sans-serif; font-size: 13px;
                     color: #000; margin: 40px 48px; line-height: 1.6; }
          h1       { font-size: 22px; margin-bottom: 4px; }
          .meta    { color: #555; font-size: 12px; margin-bottom: 20px; }
          hr       { border: none; border-top: 1px solid #ddd; margin: 20px 0; }
          h2       { font-size: 16px; margin-top: 24px; margin-bottom: 6px; }
          h3       { font-size: 14px; margin-top: 16px; margin-bottom: 4px; }
          ul, ol   { padding-left: 20px; }
          li       { margin-bottom: 2px; }
          strong   { font-weight: 600; }
          code     { font-family: monospace; background: #f4f4f4;
                     padding: 1px 4px; border-radius: 3px; }
        </style>
        </head>
        <body>
          <h1>\(escapeHTML(title))</h1>
          <p class="meta">\(escapeHTML(dateStr))\(escapeHTML(durationStr))</p>
          <hr>
          \(summaryHTML)
        </body>
        </html>
        """
    }

    // MARK: - Markdown → HTML

    /// Convert Markdown to HTML, handling the patterns Memgram's LLM produces:
    /// ## headings, ### subheadings, **bold**, `code`, - bullet lists, blank lines.
    static func markdownToHTML(_ markdown: String) -> String {
        var html = ""
        var inList = false

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("### ") {
                if inList { html += "</ul>\n"; inList = false }
                html += "<h3>\(applyInline(String(trimmed.dropFirst(4))))</h3>\n"
            } else if trimmed.hasPrefix("## ") {
                if inList { html += "</ul>\n"; inList = false }
                html += "<h2>\(applyInline(String(trimmed.dropFirst(3))))</h2>\n"
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                if !inList { html += "<ul>\n"; inList = true }
                html += "<li>\(applyInline(String(trimmed.dropFirst(2))))</li>\n"
            } else if trimmed.isEmpty {
                if inList { html += "</ul>\n"; inList = false }
                // blank line = paragraph break (skip, surrounding elements provide spacing)
            } else {
                if inList { html += "</ul>\n"; inList = false }
                html += "<p>\(applyInline(trimmed))</p>\n"
            }
        }
        if inList { html += "</ul>\n" }
        return html
    }

    /// Apply inline Markdown transforms to an already HTML-escaped string.
    /// HTML-escape first, then apply bold/code regex (safe because * and ` are not HTML-special).
    private static func applyInline(_ text: String) -> String {
        var result = escapeHTML(text)
        result = result.replacingOccurrences(
            of: #"\*\*(.+?)\*\*"#, with: "<strong>$1</strong>",
            options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"`(.+?)`"#, with: "<code>$1</code>",
            options: .regularExpression)
        return result
    }

    private static func escapeHTML(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }

    // MARK: - Suggested filename

    /// A safe filename: title with filesystem-unsafe chars replaced, plus date.
    static func suggestedFilename(for meeting: Meeting) -> String {
        let safeTitle = meeting.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: meeting.startedAt)
        return "\(safeTitle) \(dateStr).pdf"
    }
}
