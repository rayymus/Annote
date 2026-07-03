//
//  ContentView.swift
//  Annote
//
//  Created by Raymus Lim on 30/5/24.
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import PhotosUI
import Vision
import SwiftSoup

// =========================================================================
// MARK: - Article Parsing Data Models
// =========================================================================

struct RichBlock: Codable {
    let id: String
    let type: String // "h1", "h2", "h3", "p", "code", "image"
    let text: String
    var imageUrl: String?
}

struct RichArticle: Codable {
    let title: String
    let author: String?
    let publication: String?
    let sourceURL: String
    let blocks: [RichBlock]
}

func parseMarkdownToHTML(_ md: String) -> String {
    // Basic Markdown to HTML converter
    var html = md
    
    // Bold
    html = html.replacingOccurrences(of: "\\*\\*(.*?)\\*\\*", with: "<b>$1</b>", options: .regularExpression)
    html = html.replacingOccurrences(of: "__(.*?)__", with: "<b>$1</b>", options: .regularExpression)
    
    // Italic
    html = html.replacingOccurrences(of: "\\*(.*?)\\*", with: "<i>$1</i>", options: .regularExpression)
    html = html.replacingOccurrences(of: "_(.*?)_", with: "<i>$1</i>", options: .regularExpression)
    
    // Headings
    html = html.replacingOccurrences(of: "^### (.*?)$", with: "<h3>$1</h3>", options: [.regularExpression, .anchored])
    html = html.replacingOccurrences(of: "^## (.*?)$", with: "<h2>$1</h2>", options: [.regularExpression, .anchored])
    html = html.replacingOccurrences(of: "^# (.*?)$", with: "<h1>$1</h1>", options: [.regularExpression, .anchored])
    
    // Replace newline blocks with paragraph breaks
    let paragraphs = html.components(separatedBy: "\n\n")
    html = paragraphs.map { p -> String in
        let trimmed = p.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        if trimmed.hasPrefix("<h") { return trimmed }
        return "<p>\(trimmed.replacingOccurrences(of: "\n", with: "<br>"))</p>"
    }.joined(separator: "\n")
    
    return html
}

// =========================================================================
// MARK: - Dashboard & Library
// =========================================================================

enum SortOption: String, CaseIterable, Identifiable {
    case lastOpened = "Last Opened"
    case name = "Name"
    case lastModified = "Last Modified"
    case fileType = "File Type"
    
    var id: String { self.rawValue }
}

func getCGImage(from image: UIImage) -> CGImage? {
    if let cgImage = image.cgImage {
        return cgImage
    }
    if let ciImage = image.ciImage {
        let context = CIContext()
        return context.createCGImage(ciImage, from: ciImage.extent)
    }
    
    // Draw into graphics context as fallback
    UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
    defer { UIGraphicsEndImageContext() }
    image.draw(in: CGRect(origin: .zero, size: image.size))
    return UIGraphicsGetImageFromCurrentImageContext()?.cgImage
}

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \AnnoteDocument.createdAt, order: .reverse) private var documents: [AnnoteDocument]
    @Query(sort: \AnnoteFolder.createdAt, order: .reverse) private var folders: [AnnoteFolder]
    @Environment(\.colorScheme) var colorScheme
    
    @State private var isFileImporterPresented = false
    @State private var isCameraScannerPresented = false
    @State private var isClipBoardImportAlertPresented = false
    @State private var ocrResultText = ""
    @State private var isOcrDocCreatorPresented = false
    @State private var isWebImportPresented = false
    
    // Search & Sort properties
    @State private var searchQuery = ""
    @State private var sortOption: SortOption = .lastOpened
    
    // Rename properties
    @State private var isRenamePresented = false
    @State private var docToRename: AnnoteDocument? = nil
    @State private var renameTitle = ""
    
    // Folder properties
    @State private var currentFolder: AnnoteFolder? = nil
    @State private var isCreateFolderPresented = false
    @State private var newFolderName = ""
    @State private var isRenameFolderPresented = false
    @State private var folderToRename: AnnoteFolder? = nil
    @State private var renameFolderName = ""
    
    var sortedDocuments: [AnnoteDocument] {
        switch sortOption {
        case .lastOpened:
            return documents.sorted { ($0.lastOpenedAt ?? $0.createdAt) > ($1.lastOpenedAt ?? $1.createdAt) }
        case .name:
            return documents.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .lastModified:
            return documents.sorted { $0.createdAt > $1.createdAt }
        case .fileType:
            return documents.sorted { $0.fileType < $1.fileType }
        }
    }
    
    var folderFilteredDocuments: [AnnoteDocument] {
        if let folder = currentFolder {
            return sortedDocuments.filter { $0.folder?.id == folder.id }
        } else {
            return sortedDocuments.filter { $0.folder == nil }
        }
    }
    
    var filteredDocuments: [AnnoteDocument] {
        if searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return folderFilteredDocuments
        } else {
            let query = searchQuery.lowercased()
            return folderFilteredDocuments.filter { doc in
                doc.title.lowercased().contains(query) ||
                (doc.author?.lowercased().contains(query) ?? false) ||
                (doc.extractedOCRText?.lowercased().contains(query) ?? false)
            }
        }
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundColor(for: colorScheme)
                    .ignoresSafeArea()
                
                VStack(spacing: 20) {
                    // Header Bar
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            if let folder = currentFolder {
                                HStack(spacing: 8) {
                                    Button(action: { currentFolder = nil }) {
                                        Image(systemName: "chevron.left")
                                            .font(.system(size: 18, weight: .semibold))
                                            .foregroundColor(Theme.textColor(for: colorScheme))
                                    }
                                    Image(systemName: "folder.fill")
                                        .font(.system(size: 22))
                                        .foregroundColor(.accentColor)
                                    Text(folder.name)
                                        .font(.system(size: 28, weight: .bold, design: .serif))
                                        .foregroundColor(Theme.textColor(for: colorScheme))
                                }
                            } else {
                                Text("Annote")
                                    .font(.system(size: 34, weight: .bold, design: .serif))
                                    .foregroundColor(Theme.textColor(for: colorScheme))
                                Text("Just read, just notes.")
                                    .font(.system(size: 14, weight: .regular))
                                    .foregroundColor(Theme.textColor(for: colorScheme).opacity(0.6))
                            }
                        }
                        Spacer()
                        
                        Menu {
                            Button(action: { createBlankPage() }) {
                                Label("Create Blank Page", systemImage: "square.dashed")
                            }
                            Button(action: { isCreateFolderPresented = true }) {
                                Label("Create Folder", systemImage: "folder.badge.plus")
                            }
                            Divider()
                            Button(action: { isFileImporterPresented = true }) {
                                Label("Import File", systemImage: "doc.badge.plus")
                            }
                            Button(action: { isWebImportPresented = true }) {
                                Label("Import Web Article", systemImage: "globe")
                            }
                            Button(action: { isCameraScannerPresented = true }) {
                                Label("Camera OCR Scan", systemImage: "camera")
                            }
                            Button(action: { checkAndImportClipboard() }) {
                                Label("Paste Clipboard", systemImage: "doc.on.clipboard")
                            }
                            Button(action: { createSampleDocuments() }) {
                                Label("Add Samples", systemImage: "sparkles")
                            }
                        } label: {
                            Image(systemName: "plus.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(Theme.textColor(for: colorScheme))
                        }
                    }
                    .padding(.horizontal)
                    .padding(.top)
                    
                    // Search & Sort Bar
                    HStack(spacing: 12) {
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(Theme.textColor(for: colorScheme).opacity(0.4))
                            TextField("Search documents...", text: $searchQuery)
                                .textFieldStyle(.plain)
                                .autocorrectionDisabled()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Theme.textColor(for: colorScheme).opacity(0.04))
                        .cornerRadius(8)
                        
                        Picker("Sort by", selection: $sortOption) {
                            ForEach(SortOption.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        .pickerStyle(.menu)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Theme.textColor(for: colorScheme).opacity(0.04))
                        .cornerRadius(8)
                        .tint(Theme.textColor(for: colorScheme))
                    }
                    .padding(.horizontal)
                    
                    if filteredDocuments.isEmpty {
                        Spacer()
                        VStack(spacing: 16) {
                            Image(systemName: "doc.plaintext")
                                .font(.system(size: 64))
                                .foregroundColor(Theme.textColor(for: colorScheme).opacity(0.3))
                            Text(searchQuery.isEmpty ? "No Documents Yet" : "No Results Found")
                                .font(.system(size: 20, weight: .semibold, design: .serif))
                                .foregroundColor(Theme.textColor(for: colorScheme))
                            Text(searchQuery.isEmpty ? "Import a document or create a blank page.\nSupported: PDF, DOCX, EPUB, TXT, MD, PNG, JPG" : "Try modifying your search query.")
                                .font(.system(size: 14))
                                .foregroundColor(Theme.textColor(for: colorScheme).opacity(0.6))
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: 320)
                            
                            if searchQuery.isEmpty {
                                Button(action: { createSampleDocuments() }) {
                                    Text("Load Sample Workspace")
                                        .font(.system(size: 16, weight: .medium))
                                        .padding(.horizontal, 24)
                                        .padding(.vertical, 12)
                                        .background(Theme.textColor(for: colorScheme).opacity(0.08))
                                        .cornerRadius(8)
                                        .foregroundColor(Theme.textColor(for: colorScheme))
                                }
                                .padding(.top, 8)
                            }
                        }
                        Spacer()
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 20)], spacing: 20) {
                                // Show folders at root level
                                if currentFolder == nil && searchQuery.isEmpty {
                                    ForEach(folders) { folder in
                                        Button(action: { currentFolder = folder }) {
                                            VStack(spacing: 8) {
                                                Image(systemName: "folder.fill")
                                                    .font(.system(size: 44))
                                                    .foregroundColor(.accentColor)
                                                Text(folder.name)
                                                    .font(.system(size: 14, weight: .medium, design: .serif))
                                                    .foregroundColor(Theme.textColor(for: colorScheme))
                                                    .lineLimit(2)
                                                Text("\(folder.documents.count) items")
                                                    .font(.system(size: 11))
                                                    .foregroundColor(.secondary)
                                            }
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 20)
                                            .background(Theme.textColor(for: colorScheme).opacity(0.04))
                                            .cornerRadius(12)
                                        }
                                        .contextMenu {
                                            Button {
                                                folderToRename = folder
                                                renameFolderName = folder.name
                                                isRenameFolderPresented = true
                                            } label: {
                                                Label("Rename", systemImage: "pencil")
                                            }
                                            Button(role: .destructive) {
                                                // Move documents out before deleting
                                                for doc in folder.documents {
                                                    doc.folder = nil
                                                }
                                                modelContext.delete(folder)
                                                try? modelContext.save()
                                            } label: {
                                                Label("Delete Folder", systemImage: "trash")
                                            }
                                        }
                                    }
                                }
                                
                                ForEach(filteredDocuments) { doc in
                                    NavigationLink(destination: ReaderView(document: doc)) {
                                        DocumentCard(document: doc)
                                    }
                                    .contextMenu {
                                        Button {
                                            docToRename = doc
                                            renameTitle = doc.title
                                            isRenamePresented = true
                                        } label: {
                                            Label("Rename", systemImage: "pencil")
                                        }
                                        
                                        // Move to folder
                                        if !folders.isEmpty {
                                            Menu {
                                                if doc.folder != nil {
                                                    Button {
                                                        doc.folder = nil
                                                        try? modelContext.save()
                                                    } label: {
                                                        Label("Remove from Folder", systemImage: "folder.badge.minus")
                                                    }
                                                }
                                                ForEach(folders.filter { $0.id != doc.folder?.id }) { folder in
                                                    Button {
                                                        doc.folder = folder
                                                        try? modelContext.save()
                                                    } label: {
                                                        Label(folder.name, systemImage: "folder")
                                                    }
                                                }
                                            } label: {
                                                Label("Move to Folder", systemImage: "folder")
                                            }
                                        }
                                        
                                        Button(role: .destructive) {
                                            modelContext.delete(doc)
                                            try? modelContext.save()
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            }
                            .padding()
                        }
                    }
                }
            }
            .fileImporter(
                isPresented: $isFileImporterPresented,
                allowedContentTypes: [.pdf, .plainText, .image, .markdown, UTType.docx, UTType.epub],
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case .success(let urls):
                    guard let url = urls.first else { return }
                    if url.startAccessingSecurityScopedResource() {
                        defer { url.stopAccessingSecurityScopedResource() }
                        importFile(at: url)
                    } else {
                        importFile(at: url)
                    }
                case .failure(let error):
                    print("Import failed: \(error.localizedDescription)")
                }
            }
            .sheet(isPresented: $isCameraScannerPresented) {
                CameraScannerView(isPresented: $isCameraScannerPresented) { text in
                    self.ocrResultText = text
                    // Delay presentation of the next sheet to allow dismiss transition to complete fully
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.isOcrDocCreatorPresented = true
                    }
                }
            }
            .sheet(isPresented: $isOcrDocCreatorPresented) {
                OCRDocumentCreationView(isPresented: $isOcrDocCreatorPresented, text: $ocrResultText)
            }
            .sheet(isPresented: $isWebImportPresented) {
                WebArticleImportView(isPresented: $isWebImportPresented)
            }
            .alert(isPresented: $isClipBoardImportAlertPresented) {
                Alert(
                    title: Text("Clipboard Content Found"),
                    message: Text("Would you like to import plain text or PDF data found in your clipboard?"),
                    primaryButton: .default(Text("Import")) { pasteFromClipboard() },
                    secondaryButton: .cancel()
                )
            }
            .alert("Rename Document", isPresented: $isRenamePresented) {
                TextField("Document Title", text: $renameTitle)
                Button("Save") {
                    if let doc = docToRename, !renameTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        doc.title = renameTitle
                        try? modelContext.save()
                    }
                    docToRename = nil
                }
                Button("Cancel", role: .cancel) {
                    docToRename = nil
                }
            }
            .alert("Create Folder", isPresented: $isCreateFolderPresented) {
                TextField("Folder Name", text: $newFolderName)
                Button("Create") {
                    let name = newFolderName.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !name.isEmpty {
                        let folder = AnnoteFolder(name: name)
                        modelContext.insert(folder)
                        try? modelContext.save()
                    }
                    newFolderName = ""
                }
                Button("Cancel", role: .cancel) { newFolderName = "" }
            }
            .alert("Rename Folder", isPresented: $isRenameFolderPresented) {
                TextField("Folder Name", text: $renameFolderName)
                Button("Save") {
                    if let folder = folderToRename, !renameFolderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        folder.name = renameFolderName
                        try? modelContext.save()
                    }
                    folderToRename = nil
                }
                Button("Cancel", role: .cancel) { folderToRename = nil }
            }
        }
    }

    
    private func createBlankPage() {
        let newDoc = AnnoteDocument(
            title: "Blank Page \(Date().formatted(date: .abbreviated, time: .shortened))",
            fileType: "blank",
            fileData: Data()
        )
        modelContext.insert(newDoc)
        try? modelContext.save()
    }
    
    private func importFile(at url: URL) {
        guard let fileData = try? Data(contentsOf: url) else { return }
        let title = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        
        let fileType: String
        if ext == "png" || ext == "jpg" || ext == "jpeg" {
            fileType = "image"
        } else if ext == "md" || ext == "markdown" {
            fileType = "md"
        } else if ext == "docx" {
            fileType = "docx"
        } else if ext == "epub" {
            fileType = "epub"
        } else if ext == "pdf" {
            fileType = "pdf"
        } else {
            fileType = "txt"
        }
        
        let newDoc = AnnoteDocument(title: title, fileType: fileType, fileData: fileData)
        modelContext.insert(newDoc)
        
        if fileType == "image" {
            Task {
                let ocrText = await runOCRForImportedImage(imageData: fileData)
                await MainActor.run {
                    newDoc.extractedOCRText = ocrText
                    try? modelContext.save()
                }
            }
        } else {
            try? modelContext.save()
        }
    }
    
    private func runOCRForImportedImage(imageData: Data) async -> String {
        guard let image = UIImage(data: imageData) else { return "" }
        guard let finalCGImage = getCGImage(from: image) else { return "" }
        
        return await withCheckedContinuation { continuation in
            let requestHandler = VNImageRequestHandler(cgImage: finalCGImage, options: [:])
            let request = VNRecognizeTextRequest { request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: "")
                    return
                }
                let recognizedStrings = observations.compactMap { $0.topCandidates(1).first?.string }
                let fullText = recognizedStrings.joined(separator: "\n")
                continuation.resume(returning: fullText)
            }
            request.recognitionLevel = .accurate
            try? requestHandler.perform([request])
        }
    }
    
    private func checkAndImportClipboard() {
        if UIPasteboard.general.hasStrings || UIPasteboard.general.data(forPasteboardType: UTType.pdf.identifier) != nil {
            isClipBoardImportAlertPresented = true
        }
    }
    
    private func pasteFromClipboard() {
        if let pdfData = UIPasteboard.general.data(forPasteboardType: UTType.pdf.identifier) {
            let title = "Imported PDF \(Date().formatted(date: .abbreviated, time: .shortened))"
            let newDoc = AnnoteDocument(title: title, fileType: "pdf", fileData: pdfData)
            modelContext.insert(newDoc)
            try? modelContext.save()
        } else if let text = UIPasteboard.general.string, let textData = text.data(using: .utf8) {
            let title = "Pasted Text \(Date().formatted(date: .abbreviated, time: .shortened))"
            let newDoc = AnnoteDocument(title: title, fileType: "txt", fileData: textData)
            modelContext.insert(newDoc)
            try? modelContext.save()
        }
    }
    
    private func createSampleDocuments() {
        let samplePDFData = createSamplePDFData()
        let pdfDoc = AnnoteDocument(title: "Getting Started with Annote (PDF)", fileType: "pdf", fileData: samplePDFData)
        modelContext.insert(pdfDoc)
        
        let essayText = """
        Focus
        An Essay on Minimalist Reading in a Digital Age
        
        We live in an age of constant notification, colorful prompts, and dynamic distractions. Annote is designed as an antidote: a calm, paper-like reading interface where your focus remains undisturbed.
        
        By eliminating all color from the source text and document pages, your cognitive load is lessened. Contrast becomes comfortable. Shadows are soft. 
        
        Only your thoughts, highlighted in clean and vibrant vector strokes, break the monochrome plane.
        
        To begin reading:
        1. Tap near the left or right edges of the screen to hide all toolbars for immersive reading.
        2. Tap the pencil icon in the top right to enable PencilKit tools.
        3. Draw, underline, highlight, or scribble. 
        4. Turn pages. Your ink is locked in space, persisting perfectly per-page.
        
        Return to the calm of paper. Enjoy your space.
        """
        
        if let textData = essayText.data(using: .utf8) {
            let txtDoc = AnnoteDocument(title: "Annote Manifesto (TXT)", fileType: "txt", fileData: textData)
            modelContext.insert(txtDoc)
        }
        
        try? modelContext.save()
    }
    
    private func createSamplePDFData() -> Data {
        let pdfRenderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        return pdfRenderer.pdfData { context in
            context.beginPage()
            
            let boldFont = UIFont.systemFont(ofSize: 28, weight: .bold)
            let regularFont = UIFont.systemFont(ofSize: 15)
            
            let titleAttributes: [NSAttributedString.Key: Any] = [
                .font: boldFont,
                .foregroundColor: UIColor.black
            ]
            let bodyAttributes: [NSAttributedString.Key: Any] = [
                .font: regularFont,
                .foregroundColor: UIColor.darkGray
            ]
            
            "1. THE MONOCHROME PRINCIPLE".draw(at: CGPoint(x: 72, y: 100), withAttributes: titleAttributes)
            
            let text1 = "In Annote, all imported documents are parsed and visual elements are stripped of their hue, leaving only gray tones. This creates a comfortable reading layout modeled after physical journals.\n\nDraw anything with your Apple Pencil: you will note that drawings stand out in fully colorful vector ink. When you are done, tap Share to flatten your drawings over the grayscale pages."
            text1.draw(in: CGRect(x: 72, y: 160, width: 468, height: 400), withAttributes: bodyAttributes)
            
            context.beginPage()
            "2. MARGIN NOTE STRUCTURE".draw(at: CGPoint(x: 72, y: 100), withAttributes: titleAttributes)
            
            let text2 = "A generous layout leaves sufficient margin for annotations. PencilKit offers pen, highlighter, and eraser options.\n\nEverything is stored locally on device using SwiftData external block blobs, allowing you to read offline in remote, tranquil places."
            text2.draw(in: CGRect(x: 72, y: 160, width: 468, height: 400), withAttributes: bodyAttributes)
        }
    }
}

// =========================================================================
// MARK: - Supporting Views
// =========================================================================

struct DocumentCard: View {
    let document: AnnoteDocument
    @Environment(\.colorScheme) var colorScheme
    
    private var systemIcon: String {
        switch document.fileType {
        case "pdf": return "doc.richtext"
        case "article": return "globe"
        case "blank": return "square.dashed"
        case "docx", "epub": return "book.closed"
        default: return "doc.text"
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: systemIcon)
                    .font(.system(size: 28))
                    .foregroundColor(Theme.textColor(for: colorScheme).opacity(0.7))
                Spacer()
                Text(document.fileType.uppercased())
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.textColor(for: colorScheme).opacity(0.08))
                    .cornerRadius(4)
                    .foregroundColor(Theme.textColor(for: colorScheme).opacity(0.6))
            }
            
            Spacer()
            
            VStack(alignment: .leading, spacing: 4) {
                Text(document.title)
                    .font(.system(size: 16, weight: .semibold, design: .serif))
                    .foregroundColor(Theme.textColor(for: colorScheme))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                Text(document.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textColor(for: colorScheme).opacity(0.4))
            }
        }
        .padding()
        .frame(height: 150)
        .background(Theme.textColor(for: colorScheme).opacity(0.03))
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Theme.textColor(for: colorScheme).opacity(0.06), lineWidth: 1)
        )
    }
}

struct OCRDocumentCreationView: View {
    @Binding var isPresented: Bool
    @Binding var text: String
    @Environment(\.modelContext) private var modelContext
    @State private var documentTitle = "OCR Scanned Doc"
    
    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Document Details")) {
                    TextField("Document Title", text: $documentTitle)
                }
                
                Section(header: Text("Extracted Text Content")) {
                    TextEditor(text: $text)
                        .frame(minHeight: 250)
                        .font(.system(size: 14, design: .monospaced))
                }
            }
            .navigationTitle("Save OCR Document")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if let textData = text.data(using: .utf8) {
                            let newDoc = AnnoteDocument(title: documentTitle, fileType: "txt", fileData: textData)
                            modelContext.insert(newDoc)
                            try? modelContext.save()
                        }
                        isPresented = false
                    }
                }
            }
        }
    }
}

struct CameraScannerView: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onRecognizedText: (String) -> Void
    
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        if UIImagePickerController.isSourceTypeAvailable(.camera) {
            picker.sourceType = .camera
        } else {
            picker.sourceType = .photoLibrary
        }
        return picker
    }
    
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var parent: CameraScannerView
        
        init(_ parent: CameraScannerView) {
            self.parent = parent
        }
        
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            picker.dismiss(animated: true) { [weak self] in
                self?.parent.isPresented = false
            }

            if let image = info[.originalImage] as? UIImage {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.recognizeText(in: image)
                }
            }
        }
        
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            picker.dismiss(animated: true) { [weak self] in
                self?.parent.isPresented = false
            }
        }
        
        private func recognizeText(in image: UIImage) {
            guard let finalCG = getCGImage(from: image) else {
                DispatchQueue.main.async {
                    self.parent.onRecognizedText("")
                }
                return
            }
            
            let requestHandler = VNImageRequestHandler(cgImage: finalCG, options: [:])
            let request = VNRecognizeTextRequest { [weak self] request, error in
                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    DispatchQueue.main.async {
                        self?.parent.onRecognizedText("")
                    }
                    return
                }
                
                let recognizedStrings = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }
                
                let fullText = recognizedStrings.joined(separator: "\n")
                DispatchQueue.main.async {
                    self?.parent.onRecognizedText(fullText)
                }
            }
            
            request.recognitionLevel = .accurate
            try? requestHandler.perform([request])
        }
    }
}

// =========================================================================
// MARK: - Article Extraction Engine
// =========================================================================

struct RichArticleContent {
    let title: String
    let author: String?
    let publication: String?
    let sourceURL: String
    let blocks: [RichBlock]
    let images: [(url: String, data: Data)]
}

class ArticleExtractor {
    static func extract(from url: URL) async throws -> RichArticleContent {
        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.timeoutInterval = 15
        
        let (data, _) = try await URLSession.shared.data(for: request)
        guard let html = String(data: data, encoding: .utf8) else {
            throw ArticleExtractorError.encodingFailed
        }
        
        let articleContent = try await Task.detached {
            try Self.parse(html: html, sourceURL: url.absoluteString)
        }.value
        
        // Download inline images
        var downloadedImages: [(url: String, data: Data)] = []
        for block in articleContent.blocks {
            if block.type == "image", let imageUrlStr = block.imageUrl, let imageUrl = URL(string: imageUrlStr) {
                var imgReq = URLRequest(url: imageUrl)
                imgReq.setValue(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15",
                    forHTTPHeaderField: "User-Agent"
                )
                imgReq.timeoutInterval = 10
                if let (imgData, _) = try? await URLSession.shared.data(for: imgReq) {
                    downloadedImages.append((url: imageUrlStr, data: imgData))
                }
            }
        }
        
        return RichArticleContent(
            title: articleContent.title,
            author: articleContent.author,
            publication: articleContent.publication,
            sourceURL: articleContent.sourceURL,
            blocks: articleContent.blocks,
            images: downloadedImages
        )
    }
    
    private static func parse(html: String, sourceURL: String) throws -> (title: String, author: String?, publication: String?, sourceURL: String, blocks: [RichBlock]) {
        let doc = try SwiftSoup.parse(html)
        
        let title = (try? doc.title()) ?? "Untitled Article"
        
        // Metadata byline extraction
        let author = (try? doc.select("meta[name=author]").attr("content")).flatMap(\.presence) ??
                     (try? doc.select("meta[property=og:article:author]").attr("content")).flatMap(\.presence) ??
                     (try? doc.select("meta[name=twitter:creator]").attr("content")).flatMap(\.presence)
                     
        let publication = (try? doc.select("meta[property=og:site_name]").attr("content")).flatMap(\.presence) ??
                           (try? doc.select("meta[name=publisher]").attr("content")).flatMap(\.presence) ??
                           URL(string: sourceURL)?.host
        
        var blocks: [RichBlock] = []
        
        if let article = try? doc.select("article").first() {
            blocks = try parseBlocks(from: article)
        } else if let main = try? doc.select("main").first() {
            blocks = try parseBlocks(from: main)
        } else {
            let divs = try doc.select("div")
            var bestDiv: SwiftSoup.Element?
            var bestLength = 0
            for div in divs {
                let text = try div.text()
                if text.count > bestLength {
                    bestLength = text.count
                    bestDiv = div
                }
            }
            if let best = bestDiv {
                blocks = try parseBlocks(from: best)
            } else if let body = doc.body() {
                blocks = try parseBlocks(from: body)
            }
        }
        
        return (title: title, author: author, publication: publication, sourceURL: sourceURL, blocks: blocks)
    }
    
    private static func parseBlocks(from element: SwiftSoup.Element) throws -> [RichBlock] {
        try element.select("script, style, nav, footer, aside, header, form, iframe, noscript").remove()
        
        let items = try element.select("p, h1, h2, h3, h4, h5, h6, li, blockquote, pre, img")
        var blocks: [RichBlock] = []
        
        for item in items {
            let tag = item.tagName().lowercased()
            if tag == "img" {
                let src = try item.absUrl("src")
                if !src.isEmpty {
                    blocks.append(RichBlock(id: UUID().uuidString, type: "image", text: "", imageUrl: src))
                }
            } else if tag == "pre" || tag == "code" {
                let text = try item.text().trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    blocks.append(RichBlock(id: UUID().uuidString, type: "code", text: text))
                }
            } else if tag.hasPrefix("h") {
                let text = try item.html().trimmingCharacters(in: .whitespacesAndNewlines)
                let clean = cleanHTMLFormatting(text)
                if !clean.isEmpty {
                    let type: String
                    if tag == "h1" { type = "h1" }
                    else if tag == "h2" { type = "h2" }
                    else { type = "h3" }
                    blocks.append(RichBlock(id: UUID().uuidString, type: type, text: clean))
                }
            } else {
                let text = try item.html().trimmingCharacters(in: .whitespacesAndNewlines)
                let clean = cleanHTMLFormatting(text)
                if !clean.isEmpty {
                    blocks.append(RichBlock(id: UUID().uuidString, type: "p", text: clean))
                }
            }
        }
        
        return blocks
    }
    
    private static func cleanHTMLFormatting(_ html: String) -> String {
        let clean = (try? SwiftSoup.clean(html, Whitelist.simpleText())) ?? html
        return clean
    }
}

enum ArticleExtractorError: LocalizedError {
    case encodingFailed
    
    var errorDescription: String? {
        switch self {
        case .encodingFailed: return "Could not decode the page content as text."
        }
    }
}

// =========================================================================
// MARK: - Web Article Import View
// =========================================================================

struct WebArticleImportView: View {
    @Binding var isPresented: Bool
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) var colorScheme
    
    @State private var urlString = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    var body: some View {
        NavigationStack {
            ZStack {
                Theme.backgroundColor(for: colorScheme)
                    .ignoresSafeArea()
                
                VStack(spacing: 24) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paste a web article URL")
                            .font(.system(size: 16, weight: .medium, design: .serif))
                            .foregroundColor(Theme.textColor(for: colorScheme))
                        
                        TextField("https://example.com/article", text: $urlString)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .autocorrectionDisabled()
                    }
                    .padding(.horizontal)
                    
                    if let error = errorMessage {
                        Text(error)
                            .font(.system(size: 13))
                            .foregroundColor(.red.opacity(0.8))
                            .padding(.horizontal)
                    }
                    
                    Button(action: { importArticle() }) {
                        HStack {
                            if isLoading {
                                ProgressView()
                                    .tint(Theme.backgroundColor(for: colorScheme))
                            }
                            Text(isLoading ? "Extracting…" : "Import Article")
                        }
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.textColor(for: colorScheme))
                        .foregroundColor(Theme.backgroundColor(for: colorScheme))
                        .cornerRadius(10)
                    }
                    .disabled(urlString.isEmpty || isLoading)
                    .padding(.horizontal)
                    
                    Spacer()
                }
                .padding(.top, 24)
            }
            .navigationTitle("Import Web Article")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
    
    private func importArticle() {
        guard let url = URL(string: urlString), url.scheme != nil else {
            guard let url = URL(string: "https://\(urlString)"), url.host != nil else {
                errorMessage = "Please enter a valid URL."
                return
            }
            urlString = "https://\(urlString)"
            importFromURL(url)
            return
        }
        importFromURL(url)
    }
    
    private func importFromURL(_ url: URL) {
        isLoading = true
        errorMessage = nil
        
        Task {
            do {
                let article = try await ArticleExtractor.extract(from: url)
                
                let richArticle = RichArticle(
                    title: article.title,
                    author: article.author,
                    publication: article.publication,
                    sourceURL: article.sourceURL,
                    blocks: article.blocks
                )
                
                let jsonData = try JSONEncoder().encode(richArticle)
                
                await MainActor.run {
                    let newDoc = AnnoteDocument(
                        title: article.title,
                        fileType: "article",
                        fileData: jsonData,
                        sourceURL: article.sourceURL,
                        author: article.author,
                        publication: article.publication
                    )
                    
                    // Attach downloaded images
                    for downloadedImg in article.images {
                        let imgEntity = DocumentImage(urlString: downloadedImg.url, rawData: downloadedImg.data)
                        newDoc.images.append(imgEntity)
                        modelContext.insert(imgEntity)
                    }
                    
                    modelContext.insert(newDoc)
                    try? modelContext.save()
                    isLoading = false
                    isPresented = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isLoading = false
                }
            }
        }
    }
}

struct ContentViewPreviews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
