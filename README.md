# Annote

A calm reading, annotation, and sketching app for iPad — built with SwiftUI, PencilKit, and SwiftData.

---

## Features

- **PDF, Markdown, TXT, EPUB, DOCX, Image, Article** document support
- **PencilKit annotations** with per-page persistence
- **Highlight Assist** — draw over text with a marker, it snaps to word boundaries
- **Hold-to-Straighten** — hold the end of a stroke to preview and commit a perfectly straight line
- **Image overlays** with drag, scale, and color/grayscale toggle
- **Page overlays** — pin any page from another document as a floating reference
- **Folders** — organise documents into folders; move docs between folders
- **Document merging** — splice pages from other documents inline
- **Page management** — add blank pages, delete pages, reorder via the Navigator
- **Bookmarks** — bookmark pages and jump to them from the Navigator
- **Outline / TOC** — auto-extracted from PDFs, articles, EPUB/DOCX headings; add manual outline items per-page
- **Custom page names**
- **Web article import** — paste a URL, fetch and parse the article into a clean reading view
- **Camera OCR scan** — scan physical pages and import as text
- **PDF export** — flatten annotations and overlays to a shareable PDF

---

## Requirements

- iOS/iPadOS 17+
- Xcode 16+
- Swift 5.10+

---

## Setup

1. Clone the repo
2. Open `Annote.xcodeproj` in Xcode
3. Set your development team in the target's Signing & Capabilities
4. Build and run on a simulator or device

---

## Architecture

| File | Role |
|---|---|
| `AnnoteApp.swift` | App entry point, SwiftData container |
| `Document.swift` | SwiftData models: `AnnoteDocument`, `AnnoteFolder`, `PageAnnotation`, `DocumentImage`, `DocumentMerge`, `PageImageOverlay`, `ManualOutlineItem` |
| `ContentView.swift` | Library grid, folder navigation, import flows |
| `ReaderView.swift` | Per-document reading view, toolbar, virtual page resolution, OutlineView |
| `PDFDocumentView.swift` | Core `ZoomablePageView` UIViewRepresentable — page rendering, PencilKit canvas, overlays, OCR, highlight assist, straightening |
| `Theme.swift` | Color/font theme helpers |

---

## License

MIT
