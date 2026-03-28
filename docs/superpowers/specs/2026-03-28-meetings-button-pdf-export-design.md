# Meetings Button Rename + PDF Export Design

## Goal

Two independent UI improvements:
1. Rename the popover "Open" button to "Meetings" with a clearer icon
2. Add PDF export of meeting summaries (save to disk + share sheet)

---

## Feature 1: "Meetings" Button

**File:** `Memgram/UI/MenuBar/PopoverView.swift`

Change the existing button label and icon:

| | Before | After |
|---|---|---|
| Label | `"Open"` | `"Meetings"` |
| SF Symbol | `macwindow` | `rectangle.stack` |
| Action | unchanged | unchanged |
| `.help` | `"Open main window"` | `"Open meetings list"` |

`rectangle.stack` conveys "a collection of records" rather than a generic OS window, which matches what the main window shows.

---

## Feature 2: PDF Export

### Architecture

One new file, one modified file.

**New: `Memgram/Export/PDFExporter.swift`**

```
final class PDFExporter: NSObject, WKNavigationDelegate
```

Single public entry point:

```swift
static func export(meeting: Meeting) async throws -> Data
```

Steps inside `export`:
1. Build an HTML string from meeting metadata + summary Markdown
2. Create an off-screen `WKWebView` (zero frame, not in any view hierarchy)
3. Load HTML via `loadHTMLString(_:baseURL: nil)`
4. Bridge `webView(_:didFinish:)` to `async/await` using `CheckedContinuation`
5. Call `webView.createPDF(configuration: WKPDFConfiguration())` → returns `Data`
6. Release the WKWebView

The `PDFExporter` instance is kept alive for the duration of the async call by capturing `self` in the continuation closure.

**Modified: `Memgram/UI/MainWindow/MeetingDetailView.swift`**

Two new items added to the existing `⋯` (`ellipsis.circle`) menu, above the `Divider()` before Delete:

```
Copy Transcript
Copy Summary
──────────────   ← existing divider
Export PDF…      ← new
Share…           ← new
──────────────   ← existing divider
Delete Meeting
```

Both items are `.disabled` when `meeting?.summary == nil`.

While PDF generation is in progress, the `⋯` button is replaced with a `ProgressView()` spinner. State variable: `@State private var isExporting = false`.

### HTML Template

```html
<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>
  body { font-family: -apple-system, sans-serif; font-size: 13px;
         color: #000; margin: 40px 48px; line-height: 1.6; }
  h1   { font-size: 22px; margin-bottom: 4px; }
  .meta { color: #555; font-size: 12px; margin-bottom: 20px; }
  hr   { border: none; border-top: 1px solid #ddd; margin: 20px 0; }
  h2   { font-size: 16px; margin-top: 24px; margin-bottom: 6px; }
  h3   { font-size: 14px; margin-top: 16px; margin-bottom: 4px; }
  ul, ol { padding-left: 20px; }
  li   { margin-bottom: 2px; }
  strong { font-weight: 600; }
  code { font-family: monospace; background: #f4f4f4;
         padding: 1px 4px; border-radius: 3px; }
</style>
</head>
<body>
  <h1>{title}</h1>
  <p class="meta">{date} · {duration}</p>
  <hr>
  {summaryHTML}
</body>
</html>
```

### Markdown → HTML Conversion

A private `static func markdownToHTML(_ markdown: String) -> String` method handles exactly the patterns the LLM produces. Applied in order:

| Pattern | Input | Output |
|---------|-------|--------|
| H2 heading | `## Text` | `<h2>Text</h2>` |
| H3 heading | `### Text` | `<h3>Text</h3>` |
| Bold | `**text**` | `<strong>text</strong>` |
| Inline code | `` `code` `` | `<code>code</code>` |
| Bullet line | `- text` or `* text` | collected into `<ul><li>text</li>…</ul>` |
| Blank line | empty line between paragraphs | `<p>` break |
| Plain line | any other line | wrapped in `<p>` |

Bullet lines are accumulated and wrapped in a single `<ul>` block when a non-bullet line follows. This handles the nested bullet patterns in Topics Discussed sections.

No attempt is made to handle tables, blockquotes, or nested lists — these do not appear in Memgram's LLM output format.

### Export PDF… Flow

1. User selects "Export PDF…" from ⋯ menu
2. `isExporting = true` (spinner shown)
3. `PDFExporter.export(meeting:)` called in a `Task`
4. On success: `NSSavePanel` opens with:
   - Allowed file type: `UTType.pdf`
   - Suggested filename: `"{title} {yyyy-MM-dd}.pdf"` (title sanitised — `/` replaced with `-`)
5. User chooses location → `Data` written to URL via `Data.write(to:)`
6. `isExporting = false`
7. On error: show an alert ("Could not generate PDF")

### Share… Flow

1. User selects "Share…" from ⋯ menu
2. `isExporting = true`
3. `PDFExporter.export(meeting:)` called in a `Task`
4. On success: write `Data` to a temp file at `FileManager.default.temporaryDirectory / "{uuid}.pdf"`
5. `NSSharingServicePicker(items: [tempURL])` shown relative to the ⋯ button
6. After picker dismisses: delete temp file
7. `isExporting = false`

### Error Handling

- PDF generation failure (WKWebView error): propagated as `throw`, caught in `MeetingDetailView`, shown as `Alert`
- `NSSavePanel` cancel: silently ignored (no error)
- Temp file write failure: shown as Alert

### NSSharingServicePicker Anchor

`NSSharingServicePicker` requires an `NSView` anchor. Since the ⋯ menu action runs in a SwiftUI context with no direct view reference, use `NSApp.keyWindow?.contentView` as the anchor view and `NSZeroRect` as the anchor rect. This is the standard fallback for menu-triggered share sheets in macOS SwiftUI apps.

### What Is Not in Scope

- Transcript in PDF (summary only)
- Branding / Memgram logo in PDF
- Custom CSS themes or fonts
- Batch export of multiple meetings
- Automatic export on meeting completion
