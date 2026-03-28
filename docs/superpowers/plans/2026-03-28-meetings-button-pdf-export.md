# Meetings Button + PDF Export Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rename the popover "Open" button to "Meetings" with a clearer icon, and add PDF export (save to disk + share sheet) of meeting summaries via the ⋯ menu in MeetingDetailView.

**Architecture:** A new `PDFExporter` service converts a meeting's Markdown summary to HTML and renders it to PDF data via an off-screen `WKWebView`. `MeetingDetailView` gains two new menu items ("Export PDF…" and "Share…") that call `PDFExporter` and present `NSSavePanel` / `NSSharingServicePicker` respectively. The button rename is a one-line change in `PopoverView`.

**Tech Stack:** SwiftUI, AppKit, WebKit (`WKWebView.createPDF`), no new package dependencies.

---

## File Structure

| File | Action | Responsibility |
|------|--------|---------------|
| `Memgram/UI/MenuBar/PopoverView.swift` | Modify | Change button label + icon |
| `Memgram/Export/PDFExporter.swift` | Create | HTML generation, Markdown→HTML, WKWebView PDF rendering |
| `Memgram/UI/MainWindow/MeetingDetailView.swift` | Modify | Add `isExporting` state, Export PDF… and Share… menu items, call PDFExporter |

---

## Task 1: Rename "Open" Button to "Meetings"

**Files:**
- Modify: `Memgram/UI/MenuBar/PopoverView.swift` (the `Label("Open", systemImage: "macwindow")` line)

- [ ] **Step 1: Open the file and find the button**

Run: `grep -n "Open\|macwindow" Memgram/UI/MenuBar/PopoverView.swift`
Expected: a line like `Label("Open", systemImage: "macwindow")` and `.help("Open main window")`

- [ ] **Step 2: Replace label and icon**

Change:
```swift
Label("Open", systemImage: "macwindow")
```
to:
```swift
Label("Meetings", systemImage: "rectangle.stack")
```

And change the `.help` modifier from:
```swift
.help("Open main window")
```
to:
```swift
.help("Open meetings list")
```

- [ ] **Step 3: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add Memgram/UI/MenuBar/PopoverView.swift
git commit -m "fix: rename Open button to Meetings with rectangle.stack icon"
```

---

## Task 2: Create PDFExporter

**Files:**
- Create: `Memgram/Export/PDFExporter.swift`

- [ ] **Step 1: Create the directory and file**

```bash
mkdir -p Memgram/Export
```

Create `Memgram/Export/PDFExporter.swift` with this complete content:

```swift
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
```

- [ ] **Step 2: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

If the build fails with "No such module 'WebKit'", run `xcodegen generate` first (new file needs project registration).

- [ ] **Step 3: Commit**

```bash
git add Memgram/Export/PDFExporter.swift
git commit -m "feat: add PDFExporter with WKWebView-based PDF generation"
```

---

## Task 3: Add Export PDF… and Share… to MeetingDetailView

**Files:**
- Modify: `Memgram/UI/MainWindow/MeetingDetailView.swift`

- [ ] **Step 1: Add `import WebKit` and `isExporting` state**

At the top of the file, after `import MarkdownUI`, add:
```swift
import WebKit
import UniformTypeIdentifiers
```

In the `MeetingDetailView` struct body, after `@State private var copiedFeedback = false`, add:
```swift
@State private var isExporting = false
@State private var exportError: String?
```

- [ ] **Step 2: Replace the ⋯ menu with a spinner-or-menu toggle**

Find this block in `headerView`:
```swift
Menu {
    Button {
        copyTranscriptText()
        giveCopyFeedback()
    } label: { Label("Copy Transcript", systemImage: "doc.on.doc") }

    Button {
        copySummaryText()
        giveCopyFeedback()
    } label: { Label("Copy Summary", systemImage: "sparkles") }
    .disabled(meeting?.summary == nil)

    Divider()

    Button(role: .destructive) {
        showDeleteConfirm = true
    } label: { Label("Delete Meeting", systemImage: "trash") }
} label: {
    Image(systemName: "ellipsis.circle")
        .foregroundColor(.secondary)
}
.buttonStyle(.plain)
.menuStyle(.borderlessButton)
.frame(width: 28)
.help("More actions")
```

Replace it with:
```swift
if isExporting {
    ProgressView()
        .controlSize(.small)
        .frame(width: 28)
} else {
    Menu {
        Button {
            copyTranscriptText()
            giveCopyFeedback()
        } label: { Label("Copy Transcript", systemImage: "doc.on.doc") }

        Button {
            copySummaryText()
            giveCopyFeedback()
        } label: { Label("Copy Summary", systemImage: "sparkles") }
        .disabled(meeting?.summary == nil)

        Divider()

        Button {
            Task { await exportPDF() }
        } label: { Label("Export PDF…", systemImage: "arrow.down.doc") }
        .disabled(meeting?.summary == nil)

        Button {
            Task { await sharePDF() }
        } label: { Label("Share…", systemImage: "square.and.arrow.up") }
        .disabled(meeting?.summary == nil)

        Divider()

        Button(role: .destructive) {
            showDeleteConfirm = true
        } label: { Label("Delete Meeting", systemImage: "trash") }
    } label: {
        Image(systemName: "ellipsis.circle")
            .foregroundColor(.secondary)
    }
    .buttonStyle(.plain)
    .menuStyle(.borderlessButton)
    .frame(width: 28)
    .help("More actions")
}
```

- [ ] **Step 3: Add `exportError` alert**

Find the existing `.alert` for delete confirmation in the file. After it, add:
```swift
.alert("Export Failed", isPresented: Binding(
    get: { exportError != nil },
    set: { if !$0 { exportError = nil } }
)) {
    Button("OK", role: .cancel) { exportError = nil }
} message: {
    Text(exportError ?? "")
}
```

- [ ] **Step 4: Add `exportPDF()` and `sharePDF()` methods**

Add these two private methods to `MeetingDetailView`, alongside the existing `copyTranscriptText()` and `copySummaryText()` methods:

```swift
private func exportPDF() async {
    guard let meeting else { return }
    isExporting = true
    defer { isExporting = false }
    do {
        let data = try await PDFExporter.export(meeting: meeting)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType.pdf]
        panel.nameFieldStringValue = PDFExporter.suggestedFilename(for: meeting)
        let response = await panel.beginSheetModal(for: NSApp.keyWindow ?? NSWindow())
        guard response == .OK, let url = panel.url else { return }
        try data.write(to: url)
    } catch {
        exportError = error.localizedDescription
    }
}

private func sharePDF() async {
    guard let meeting else { return }
    isExporting = true
    defer { isExporting = false }
    do {
        let data = try await PDFExporter.export(meeting: meeting)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("pdf")
        try data.write(to: tempURL)
        // Note: do NOT delete tempURL here — the share sheet reads it asynchronously.
        // The OS will clean up the temp directory eventually.
        let picker = NSSharingServicePicker(items: [tempURL])
        if let contentView = NSApp.keyWindow?.contentView {
            await MainActor.run {
                picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
            }
        }
    } catch {
        exportError = error.localizedDescription
    }
}
```

- [ ] **Step 5: Build to verify**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Debug build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

If build fails with "cannot find PDFExporter", run `xcodegen generate` first.

- [ ] **Step 6: Commit**

```bash
git add Memgram/UI/MainWindow/MeetingDetailView.swift
git commit -m "feat: add Export PDF and Share actions to meeting detail ⋯ menu"
```

---

## Task 4: Register New File with xcodegen and Final Build

**Files:**
- Modify: none (xcodegen auto-discovers `Memgram/Export/PDFExporter.swift` via the recursive `Memgram/` source path in `project.yml`)

- [ ] **Step 1: Regenerate project to ensure new file is registered**

Run: `xcodegen generate`
Expected: `Created project at .../Memgram.xcodeproj`

- [ ] **Step 2: Full Release build**

Run: `xcodebuild -project Memgram.xcodeproj -scheme Memgram -configuration Release build 2>&1 | tail -3`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 3: Commit project file if changed**

```bash
git status
```

If `Memgram.xcodeproj/project.pbxproj` is modified:
```bash
git add Memgram.xcodeproj/project.pbxproj
git commit -m "chore: regenerate project to register PDFExporter"
```

- [ ] **Step 4: Push**

```bash
git push
```
