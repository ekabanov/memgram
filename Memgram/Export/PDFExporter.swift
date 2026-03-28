import AppKit

/// Renders a meeting summary to PDF data using AppKit.
/// Uses NSTextView + dataWithPDF — no WebKit, no entitlements required.
final class PDFExporter: NSObject {

    enum ExportError: LocalizedError {
        case noSummary
        var errorDescription: String? { "No summary available to export." }
    }

    // MARK: - Public API

    @MainActor
    static func export(meeting: Meeting) async throws -> Data {
        guard let summary = meeting.summary, !summary.isEmpty else {
            throw ExportError.noSummary
        }

        let attrString = buildAttributedString(meeting: meeting, summary: summary)

        // Lay out text to determine required height
        let contentWidth: CGFloat = 500
        let textStorage = NSTextStorage(attributedString: attrString)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        let textContainer = NSTextContainer(containerSize: NSSize(width: contentWidth, height: 1_000_000))
        textContainer.lineFragmentPadding = 0
        layoutManager.addTextContainer(textContainer)
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = layoutManager.usedRect(for: textContainer).height

        // Create off-screen text view sized to content
        let inset: CGFloat = 48
        let viewWidth = contentWidth + inset * 2
        let viewHeight = usedHeight + inset * 2
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: viewWidth, height: viewHeight))
        textView.textContainerInset = NSSize(width: inset, height: inset)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: contentWidth, height: 1_000_000)
        textView.backgroundColor = .white
        textView.drawsBackground = true
        textView.isEditable = false
        textView.textStorage?.setAttributedString(attrString)

        return textView.dataWithPDF(inside: textView.bounds)
    }

    static func suggestedFilename(for meeting: Meeting) -> String {
        let safeTitle = meeting.title
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return "\(safeTitle) \(formatter.string(from: meeting.startedAt)).pdf"
    }

    // MARK: - Attributed string builder

    private static func buildAttributedString(meeting: Meeting, summary: String) -> NSAttributedString {
        let result = NSMutableAttributedString()

        let bodyFont = NSFont.systemFont(ofSize: 13)
        let h1Font  = NSFont.boldSystemFont(ofSize: 22)
        let h2Font  = NSFont.boldSystemFont(ofSize: 16)
        let h3Font  = NSFont.boldSystemFont(ofSize: 14)
        let metaColor = NSColor(white: 0.45, alpha: 1)

        // Title
        result.append(plain(meeting.title + "\n", font: h1Font, color: .black, spacing: 4))

        // Date + duration
        let dateStr = DateFormatter.localizedString(
            from: meeting.startedAt, dateStyle: .long, timeStyle: .short)
        let durationStr: String
        if let dur = meeting.durationSeconds, dur > 0 {
            durationStr = " · " + formatDuration(dur)
        } else {
            durationStr = ""
        }
        result.append(plain(dateStr + durationStr + "\n\n", font: NSFont.systemFont(ofSize: 11),
                            color: metaColor, spacing: 8))

        // Summary body — parse Markdown line by line
        for line in summary.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("### ") {
                result.append(richLine(String(trimmed.dropFirst(4)),
                                       font: h3Font, topSpacing: 12, bottomSpacing: 3))
            } else if trimmed.hasPrefix("## ") {
                result.append(richLine(String(trimmed.dropFirst(3)),
                                       font: h2Font, topSpacing: 18, bottomSpacing: 4))
            } else if trimmed.hasPrefix("# ") {
                result.append(richLine(String(trimmed.dropFirst(2)),
                                       font: h1Font, topSpacing: 20, bottomSpacing: 4))
            } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                result.append(bulletLine(String(trimmed.dropFirst(2)), font: bodyFont))
            } else if trimmed.isEmpty {
                result.append(plain("\n", font: bodyFont, color: .black, spacing: 0))
            } else {
                result.append(richLine(trimmed, font: bodyFont, topSpacing: 0, bottomSpacing: 2))
            }
        }

        return result
    }

    // MARK: - Line builders

    private static func plain(_ text: String, font: NSFont,
                               color: NSColor, spacing: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing
        return NSAttributedString(string: text,
                                  attributes: [.font: font, .foregroundColor: color,
                                               .paragraphStyle: style])
    }

    /// Build an attributed line applying **bold** and `code` inline spans.
    private static func richLine(_ text: String, font: NSFont,
                                  topSpacing: CGFloat, bottomSpacing: CGFloat) -> NSMutableAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = topSpacing
        style.paragraphSpacing = bottomSpacing

        let result = NSMutableAttributedString(string: text + "\n", attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: style
        ])
        applyBold(to: result, baseFont: font)
        applyCode(to: result)
        return result
    }

    private static func bulletLine(_ text: String, font: NSFont) -> NSMutableAttributedString {
        let style = NSMutableParagraphStyle()
        style.headIndent = 14
        style.firstLineHeadIndent = 0
        style.paragraphSpacing = 2

        let result = NSMutableAttributedString(string: "• " + text + "\n", attributes: [
            .font: font,
            .foregroundColor: NSColor.black,
            .paragraphStyle: style
        ])
        applyBold(to: result, baseFont: font)
        applyCode(to: result)
        return result
    }

    // MARK: - Inline span applicators

    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
    private static let codeRegex = try! NSRegularExpression(pattern: #"`(.+?)`"#)

    private static func applyBold(to attrStr: NSMutableAttributedString, baseFont: NSFont) {
        let boldFont = NSFontManager.shared.convert(baseFont, toHaveTrait: .boldFontMask)
        let plain = attrStr.string
        var offset = 0
        for match in boldRegex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let innerRange = Range(match.range(at: 1), in: plain) else { continue }
            let inner = String(plain[innerRange])
            let adjustedFull = NSRange(location: match.range.location + offset, length: match.range.length)
            attrStr.replaceCharacters(in: adjustedFull, with:
                NSAttributedString(string: inner, attributes: [.font: boldFont, .foregroundColor: NSColor.black]))
            offset += inner.count - match.range.length
        }
    }

    private static func applyCode(to attrStr: NSMutableAttributedString) {
        let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let codeBG = NSColor(white: 0.94, alpha: 1)
        let plain = attrStr.string
        var offset = 0
        for match in codeRegex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let innerRange = Range(match.range(at: 1), in: plain) else { continue }
            let inner = String(plain[innerRange])
            let adjustedFull = NSRange(location: match.range.location + offset, length: match.range.length)
            attrStr.replaceCharacters(in: adjustedFull, with:
                NSAttributedString(string: inner, attributes: [
                    .font: codeFont, .backgroundColor: codeBG, .foregroundColor: NSColor.black]))
            offset += inner.count - match.range.length
        }
    }

    // MARK: - Helpers

    private static func formatDuration(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        return h > 0 ? "\(h)h \(m)m" : "\(m)m"
    }
}
