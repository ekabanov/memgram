import UIKit
import OSLog

private let log = Logger.make("Export")

/// Renders a meeting summary to PDF data using UIKit.
/// Mirrors the Mac `PDFExporter` (NSTextView + dataWithPDF): same line-by-line
/// Markdown parsing and a single tall page sized to content.
enum MobilePDFExporter {

    enum ExportError: LocalizedError {
        case noSummary
        var errorDescription: String? { "No summary available to export." }
    }

    // MARK: - Public API

    @MainActor
    static func export(meeting: Meeting) throws -> Data {
        guard let summary = meeting.summary, !summary.isEmpty else {
            throw ExportError.noSummary
        }

        log.info("PDF export started — summary \(summary.count) chars")
        let attrString = buildAttributedString(meeting: meeting, summary: summary)

        // Lay out text to determine required height
        let contentWidth: CGFloat = 500
        let bounds = attrString.boundingRect(
            with: CGSize(width: contentWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil)
        let usedHeight = ceil(bounds.height)
        log.debug("PDF layout: width=\(Int(contentWidth))pt height=\(Int(usedHeight))pt")

        // Single tall page sized to content
        let inset: CGFloat = 48
        let pageWidth = contentWidth + inset * 2
        let pageHeight = usedHeight + inset * 2
        let pageRect = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)
        let pdfData = renderer.pdfData { context in
            context.beginPage()
            UIColor.white.setFill()
            context.fill(pageRect)
            attrString.draw(with: CGRect(x: inset, y: inset,
                                         width: contentWidth, height: usedHeight),
                            options: [.usesLineFragmentOrigin, .usesFontLeading],
                            context: nil)
        }
        log.info("PDF export complete — \(pdfData.count) bytes")
        return pdfData
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

        let bodyFont = UIFont.systemFont(ofSize: 13)
        let h1Font  = UIFont.boldSystemFont(ofSize: 22)
        let h2Font  = UIFont.boldSystemFont(ofSize: 16)
        let h3Font  = UIFont.boldSystemFont(ofSize: 14)
        let metaColor = UIColor(white: 0.45, alpha: 1)

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
        result.append(plain(dateStr + durationStr + "\n\n", font: UIFont.systemFont(ofSize: 11),
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

    private static func plain(_ text: String, font: UIFont,
                              color: UIColor, spacing: CGFloat) -> NSAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = spacing
        return NSAttributedString(string: text,
                                  attributes: [.font: font, .foregroundColor: color,
                                               .paragraphStyle: style])
    }

    /// Build an attributed line applying **bold** and `code` inline spans.
    private static func richLine(_ text: String, font: UIFont,
                                 topSpacing: CGFloat, bottomSpacing: CGFloat) -> NSMutableAttributedString {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = topSpacing
        style.paragraphSpacing = bottomSpacing

        let result = NSMutableAttributedString(string: text + "\n", attributes: [
            .font: font,
            .foregroundColor: UIColor.black,
            .paragraphStyle: style
        ])
        applyBold(to: result, baseFont: font)
        applyCode(to: result)
        return result
    }

    private static func bulletLine(_ text: String, font: UIFont) -> NSMutableAttributedString {
        let style = NSMutableParagraphStyle()
        style.headIndent = 14
        style.firstLineHeadIndent = 0
        style.paragraphSpacing = 2

        let result = NSMutableAttributedString(string: "• " + text + "\n", attributes: [
            .font: font,
            .foregroundColor: UIColor.black,
            .paragraphStyle: style
        ])
        applyBold(to: result, baseFont: font)
        applyCode(to: result)
        return result
    }

    // MARK: - Inline span applicators

    private static let boldRegex = try! NSRegularExpression(pattern: #"\*\*(.+?)\*\*"#)
    private static let codeRegex = try! NSRegularExpression(pattern: #"`(.+?)`"#)

    private static func applyBold(to attrStr: NSMutableAttributedString, baseFont: UIFont) {
        let boldFont: UIFont
        if let descriptor = baseFont.fontDescriptor.withSymbolicTraits(
            baseFont.fontDescriptor.symbolicTraits.union(.traitBold)) {
            boldFont = UIFont(descriptor: descriptor, size: baseFont.pointSize)
        } else {
            boldFont = UIFont.boldSystemFont(ofSize: baseFont.pointSize)
        }
        let plain = attrStr.string
        var offset = 0
        for match in boldRegex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let innerRange = Range(match.range(at: 1), in: plain) else { continue }
            let inner = String(plain[innerRange])
            let adjustedFull = NSRange(location: match.range.location + offset, length: match.range.length)
            attrStr.replaceCharacters(in: adjustedFull, with:
                NSAttributedString(string: inner, attributes: [.font: boldFont, .foregroundColor: UIColor.black]))
            offset += inner.count - match.range.length
        }
    }

    private static func applyCode(to attrStr: NSMutableAttributedString) {
        let codeFont = UIFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        let codeBG = UIColor(white: 0.94, alpha: 1)
        let plain = attrStr.string
        var offset = 0
        for match in codeRegex.matches(in: plain, range: NSRange(plain.startIndex..., in: plain)) {
            guard let innerRange = Range(match.range(at: 1), in: plain) else { continue }
            let inner = String(plain[innerRange])
            let adjustedFull = NSRange(location: match.range.location + offset, length: match.range.length)
            attrStr.replaceCharacters(in: adjustedFull, with:
                NSAttributedString(string: inner, attributes: [
                    .font: codeFont, .backgroundColor: codeBG, .foregroundColor: UIColor.black]))
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
