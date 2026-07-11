//
//  ReaderView.swift
//  Annote
//
//  Created by Raymus Lim on 30/5/24.
//

import SwiftUI
import SwiftData
import PencilKit
import PDFKit
import PhotosUI
import Vision
import SwiftSoup
import CoreTransferable
import UniformTypeIdentifiers

// =========================================================================
// MARK: - Virtual Page & Compile Engine
// =========================================================================

struct VirtualPage: Identifiable, Equatable {
    let id = UUID()
    let sourceDocumentId: UUID
    let sourceTitle: String
    let fileType: String
    let fileData: Data
    let pageIndex: Int
    let isMerged: Bool
    
    static func == (lhs: VirtualPage, rhs: VirtualPage) -> Bool {
        lhs.sourceDocumentId == rhs.sourceDocumentId &&
        lhs.pageIndex == rhs.pageIndex &&
        lhs.isMerged == rhs.isMerged
    }
}

struct TransferableImage: Transferable {
    let image: UIImage

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(importedContentType: .image) { data in
            guard let image = UIImage(data: data) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return TransferableImage(image: image)
        }
    }
}

// ponytail: cache page counts in memory to prevent heavy PDFDocument instantiation on every render
private var pageCountCache: [UUID: Int] = [:]

func nativePageCount(for document: AnnoteDocument) -> Int {
    if let cached = pageCountCache[document.id] {
        return cached
    }
    let count: Int
    if document.fileType == "pdf" {
        if let pdfDoc = PDFDocument(data: document.fileData) {
            count = pdfDoc.pageCount
        } else {
            count = 0
        }
    } else {
        count = 1
    }
    pageCountCache[document.id] = count
    return count
}

func resolveVirtualPages(for document: AnnoteDocument, allDocuments: [AnnoteDocument]) -> [VirtualPage] {
    var defaultPages: [VirtualPage] = []
    let deletedKeys = document.deletedPageKeys
    
    let count = nativePageCount(for: document)
    for i in 0..<count {
        let key = "\(document.id)-\(i)"
        if deletedKeys.contains(key) { continue }
        defaultPages.append(VirtualPage(
            sourceDocumentId: document.id,
            sourceTitle: document.title,
            fileType: document.fileType,
            fileData: document.fileData,
            pageIndex: i,
            isMerged: false
        ))
    }
    
    let sortedMerges = document.merges.sorted(by: { $0.insertAfterPageIndex < $1.insertAfterPageIndex })
    for merge in sortedMerges {
        guard let sourceDoc = allDocuments.first(where: { $0.id == merge.sourceDocumentId }) else { continue }
        let sourcePageCount = nativePageCount(for: sourceDoc)
        
        var sourcePages: [VirtualPage] = []
        for i in 0..<sourcePageCount {
            let key = "\(sourceDoc.id)-\(i)"
            if deletedKeys.contains(key) { continue }
            sourcePages.append(VirtualPage(
                sourceDocumentId: sourceDoc.id,
                sourceTitle: sourceDoc.title,
                fileType: sourceDoc.fileType,
                fileData: sourceDoc.fileData,
                pageIndex: i,
                isMerged: true
            ))
        }
        
        let insertIndex = min(merge.insertAfterPageIndex + 1, defaultPages.count)
        defaultPages.insert(contentsOf: sourcePages, at: insertIndex)
    }
    
    let order = document.pageOrder
    if order.isEmpty {
        return defaultPages
    }
    
    var pageMap: [String: VirtualPage] = [:]
    for page in defaultPages {
        let key = "\(page.sourceDocumentId)-\(page.pageIndex)"
        pageMap[key] = page
    }
    
    var orderedPages: [VirtualPage] = []
    for key in order {
        if let page = pageMap.removeValue(forKey: key) {
            orderedPages.append(page)
        }
    }
    
    for page in defaultPages {
        let key = "\(page.sourceDocumentId)-\(page.pageIndex)"
        if pageMap[key] != nil {
            orderedPages.append(page)
            var newOrder = document.pageOrder
            newOrder.append(key)
            document.pageOrder = newOrder
        }
    }
    
    return orderedPages
}

// =========================================================================
// MARK: - Reader View
// =========================================================================

struct ReaderView: View {
    let document: AnnoteDocument
    @Environment(\.modelContext) private var modelContext
    @Environment(\.colorScheme) var colorScheme
    @Query(sort: \AnnoteDocument.createdAt) private var allDocuments: [AnnoteDocument]
    
    @State private var currentPage: Int = 0
    @State private var isDrawingEnabled: Bool = true
    @State private var isHighlightAssistEnabled: Bool = true
    @State private var isUiVisible: Bool = true
    @State private var isExporting: Bool = false
    
    // Sheets & Pickers
    @State private var isMergePickerPresented = false
    @State private var isPageOverlayPickerPresented = false
    @State private var selectedPhotoItem: PhotosPickerItem? = nil
    @State private var isOutlinePresented = false
    
    // OCR scanned PDF state
    @State private var ocrTexts: [Int: String] = [:]
    @State private var showOcrSheet = false
    @State private var selectedOcrText = ""
    
    // Page renaming state
    @State private var isRenameAlertPresented = false
    @State private var pageNameToRename = ""
    @State private var showAddPageButton = false
    @State private var showAddPageBeforeButton = false
    
    private var virtualPages: [VirtualPage] {
        resolveVirtualPages(for: document, allDocuments: allDocuments)
    }
    
    private var totalPages: Int {
        virtualPages.count
    }
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Theme.backgroundColor(for: colorScheme)
                    .ignoresSafeArea()
                
                let vPages = virtualPages
                if !vPages.isEmpty {
                    let activePageIndex = min(currentPage, vPages.count - 1)
                    let vPage = vPages[activePageIndex]
                    
                    // Unified zoomable page view (loads/saves drawings internally via modelContext)
                    ZStack(alignment: .trailing) {
                        ZoomablePageView(
                            documentId: vPage.sourceDocumentId,
                            documentData: vPage.fileData,
                            fileType: vPage.fileType,
                            pageIndex: vPage.pageIndex,
                            isMerged: vPage.isMerged,
                            sourceTitle: vPage.sourceTitle,
                            isDrawingEnabled: isDrawingEnabled,
                            isHighlightAssistEnabled: isHighlightAssistEnabled,
                            colorScheme: colorScheme,
                            allDocuments: allDocuments,
                            modelContext: modelContext,
                            onSwipeLeft: {
                                if currentPage < vPages.count - 1 {
                                    withAnimation { currentPage += 1 }
                                } else {
                                    withAnimation(.spring(response: 0.3)) {
                                        showAddPageButton = true
                                    }
                                }
                            },
                            onSwipeRight: {
                                if currentPage > 0 {
                                    withAnimation { currentPage -= 1 }
                                } else {
                                    withAnimation(.spring(response: 0.3)) {
                                        showAddPageBeforeButton = true
                                    }
                                }
                            }
                        )
                        .id("\(vPage.sourceDocumentId)-\(vPage.pageIndex)") // Force recreate view when page changes
                        .offset(x: showAddPageButton ? -80 : (showAddPageBeforeButton ? 80 : 0))
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: showAddPageButton)
                        .animation(.spring(response: 0.4, dampingFraction: 0.7), value: showAddPageBeforeButton)
                        .onAppear {
                            checkAndRunOcrIfNeeded(for: vPage)
                        }
                        .onChange(of: currentPage) { oldPage, newPage in
                            let pages = virtualPages
                            if newPage < pages.count {
                                checkAndRunOcrIfNeeded(for: pages[newPage])
                            }
                            showAddPageButton = false
                            showAddPageBeforeButton = false
                        }
                        .overlay(
                            Group {
                                if showAddPageButton || showAddPageBeforeButton {
                                    Color.clear
                                        .contentShape(Rectangle())
                                        .onTapGesture {
                                            withAnimation(.spring(response: 0.3)) {
                                                showAddPageButton = false
                                                showAddPageBeforeButton = false
                                            }
                                        }
                                }
                            }
                        )
                        
                        // Right edge append button
                        if showAddPageButton {
                            Button(action: {
                                appendBlankPage()
                                withAnimation {
                                    showAddPageButton = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                        currentPage = virtualPages.count - 1
                                    }
                                }
                            }) {
                                ZStack {
                                    Circle()
                                        .fill(Theme.textColor(for: colorScheme))
                                        .frame(width: 56, height: 56)
                                    Image(systemName: "plus")
                                        .font(.system(size: 24, weight: .bold))
                                        .foregroundColor(Theme.backgroundColor(for: colorScheme))
                                }
                                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                            }
                            .padding(.trailing, 12)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                    .overlay(
                        ZStack(alignment: .leading) {
                            Color.clear
                            
                            // Left edge prepend button
                            if showAddPageBeforeButton {
                                Button(action: {
                                    prependBlankPage()
                                    withAnimation {
                                        showAddPageBeforeButton = false
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                            currentPage = 0
                                        }
                                    }
                                }) {
                                    ZStack {
                                        Circle()
                                            .fill(Theme.textColor(for: colorScheme))
                                            .frame(width: 56, height: 56)
                                        Image(systemName: "plus")
                                            .font(.system(size: 24, weight: .bold))
                                            .foregroundColor(Theme.backgroundColor(for: colorScheme))
                                    }
                                    .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
                                }
                                .padding(.leading, 12)
                                .transition(.move(edge: .leading).combined(with: .opacity))
                            }
                        }
                    )
                }
                
                // Edge tap zones for UI toggle
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 50)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { isUiVisible.toggle() } }
                    Spacer()
                    Color.clear
                        .frame(width: 50)
                        .contentShape(Rectangle())
                        .onTapGesture { withAnimation { isUiVisible.toggle() } }
                }
                .allowsHitTesting(!isDrawingEnabled)
                
                // Page navigation
                if totalPages > 1 && isUiVisible {
                    VStack {
                        Spacer()
                        HStack {
                            Button(action: { if currentPage > 0 { currentPage -= 1 } }) {
                                Image(systemName: "chevron.left.circle.fill")
                                    .font(.system(size: 36))
                                    .foregroundColor(Theme.textColor(for: colorScheme).opacity(currentPage > 0 ? 0.7 : 0.2))
                            }
                            .disabled(currentPage == 0)
                            
                            Text(pageTitle(for: currentPage, in: vPages))
                                .font(.system(size: 14, weight: .semibold, design: .serif))
                                .foregroundColor(Theme.textColor(for: colorScheme).opacity(0.7))
                                .padding(.horizontal, 16)
                                .onLongPressGesture {
                                    pageNameToRename = document.customPageNames[currentPage] ?? ""
                                    isRenameAlertPresented = true
                                }
                            
                            Button(action: { if currentPage < totalPages - 1 { currentPage += 1 } }) {
                                Image(systemName: "chevron.right.circle.fill")
                                    .font(.system(size: 36))
                                    .foregroundColor(Theme.textColor(for: colorScheme).opacity(currentPage < totalPages - 1 ? 0.7 : 0.2))
                            }
                            .disabled(currentPage >= totalPages - 1)
                        }
                        .padding(.bottom, 24)
                    }
                }
                
                if isExporting {
                    ZStack {
                        Color.black.opacity(0.4)
                            .ignoresSafeArea()
                        VStack(spacing: 16) {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                .scaleEffect(1.5)
                            Text("Exporting PDF...")
                                .font(.headline)
                                .foregroundColor(.white)
                        }
                        .padding(24)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(Color(white: 0.15).opacity(0.85))
                        )
                    }
                    .transition(.opacity)
                }
            }
        }

        .toolbar(isUiVisible ? .visible : .hidden, for: .navigationBar)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                // PDF Render Mode Toggle (Paper tint vs Dark inversion)
                if document.fileType == "pdf" {
                    Button(action: {
                        let currentMode = document.pdfRenderMode ?? (colorScheme == .dark ? "dark" : "paper")
                        document.pdfRenderMode = (currentMode == "paper") ? "dark" : "paper"
                        try? modelContext.save()
                    }) {
                        let currentMode = document.pdfRenderMode ?? (colorScheme == .dark ? "dark" : "paper")
                        Image(systemName: currentMode == "paper" ? "doc.viewfinder" : "doc.viewfinder.fill")
                            .accessibilityLabel("Toggle PDF Reading Mode")
                    }
                }
                
                // OCR Text Sheet overlay button for scanned PDFs
                let vPages = virtualPages
                if currentPage < vPages.count {
                    let vPage = vPages[currentPage]
                    if vPage.fileType == "pdf" && ocrTexts[vPage.pageIndex] != nil {
                        Button(action: {
                            if let text = ocrTexts[vPage.pageIndex] {
                                selectedOcrText = text
                                showOcrSheet = true
                            }
                        }) {
                            Label("OCR Text", systemImage: "doc.text.magnifyingglass")
                        }
                    }
                }
                
                // Bookmark Toggle Button
                Button(action: {
                    var bookmarks = document.bookmarkedPages
                    if bookmarks.contains(currentPage) {
                        bookmarks.remove(currentPage)
                    } else {
                        bookmarks.insert(currentPage)
                    }
                    document.bookmarkedPages = bookmarks
                    try? modelContext.save()
                }) {
                    let isBookmarked = document.bookmarkedPages.contains(currentPage)
                    Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
                        .accessibilityLabel(isBookmarked ? "Remove Bookmark" : "Add Bookmark")
                }
                
                // Document Outline/TOC Button
                Button(action: { isOutlinePresented = true }) {
                    Label("Outline", systemImage: "list.bullet.indent")
                }
                
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images,
                    photoLibrary: .shared()
                ) {
                    Image(systemName: "photo.badge.plus")
                        .accessibilityLabel("Add Image Overlay")
                }

                Button(action: { isPageOverlayPickerPresented = true }) {
                    Image(systemName: "doc.on.doc")
                        .accessibilityLabel("Add Page Overlay")
                }
                
                // Insert pages button
                Button(action: { isMergePickerPresented = true }) {
                    Label("Insert Pages", systemImage: "doc.badge.gearshape")
                }
                
                Button(action: { isDrawingEnabled.toggle() }) {
                    Label(
                        isDrawingEnabled ? "Disable Drawing" : "Enable Drawing",
                        systemImage: isDrawingEnabled ? "pencil.and.outline" : "hand.draw"
                    )
                }

                Button(action: { isHighlightAssistEnabled.toggle() }) {
                    Image(systemName: "highlighter")
                        .foregroundColor(isHighlightAssistEnabled ? .accentColor : .secondary)
                        .padding(4)
                        .background(isHighlightAssistEnabled ? Color.accentColor.opacity(0.15) : Color.clear)
                        .cornerRadius(4)
                }
                .accessibilityLabel(isHighlightAssistEnabled ? "Disable Highlight Assist" : "Enable Highlight Assist")
                
                Button(action: { shareDocument() }) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
            }
        }
        .sheet(isPresented: $isMergePickerPresented) {
            MergeDocumentPickerView(isPresented: $isMergePickerPresented, currentDocument: document) { selectedDoc in
                let newMerge = DocumentMerge(
                    sourceDocumentId: selectedDoc.id,
                    insertAfterPageIndex: currentPage,
                    sourceTitle: selectedDoc.title
                )
                document.merges.append(newMerge)
                modelContext.insert(newMerge)
                try? modelContext.save()
            }
        }
        .sheet(isPresented: $isPageOverlayPickerPresented) {
            PageOverlayPickerView(isPresented: $isPageOverlayPickerPresented, currentDocument: document, allDocuments: allDocuments) { selectedDoc, pageIdx in
                let overlay = PageImageOverlay(
                    parentPageIndex: currentPage,
                    x: 0.15,
                    y: 0.15,
                    width: 0.4,
                    height: 0.3,
                    sourceDocumentId: selectedDoc.id,
                    sourcePageIndex: pageIdx
                )
                document.overlays.append(overlay)
                modelContext.insert(overlay)
                try? modelContext.save()
            }
        }
        .sheet(isPresented: $showOcrSheet) {
            PDFExtractedOCROverlaySheet(isPresented: $showOcrSheet, text: selectedOcrText)
        }
        .sheet(isPresented: $isOutlinePresented) {
            OutlineView(isPresented: $isOutlinePresented, document: document, virtualPages: virtualPages, allDocuments: allDocuments, currentPage: $currentPage, modelContext: modelContext)
        }
        .onAppear {
            document.lastOpenedAt = Date()
            try? modelContext.save()
        }
        .onChange(of: selectedPhotoItem) { oldItem, newItem in
            guard let newItem = newItem else { return }
            Task {
                var finalData: Data? = nil
                if let data = try? await newItem.loadTransferable(type: Data.self) {
                    finalData = data
                } else if let transferableImage = try? await newItem.loadTransferable(type: TransferableImage.self) {
                    finalData = transferableImage.image.jpegData(compressionQuality: 0.8)
                }
                
                if let data = finalData {
                    await MainActor.run {
                        let overlay = PageImageOverlay(
                            parentPageIndex: currentPage,
                            x: 0.2,
                            y: 0.2,
                            width: 0.5,
                            height: 0.35,
                            imageData: data
                        )
                        document.overlays.append(overlay)
                        modelContext.insert(overlay)
                        try? modelContext.save()
                        selectedPhotoItem = nil
                    }
                } else {
                    await MainActor.run {
                        selectedPhotoItem = nil
                    }
                }
            }
        }
        .alert("Rename Page", isPresented: $isRenameAlertPresented) {
            TextField("Page Name", text: $pageNameToRename)
            Button("Save") {
                var dict = document.customPageNames
                if pageNameToRename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    dict.removeValue(forKey: currentPage)
                } else {
                    dict[currentPage] = pageNameToRename
                }
                document.customPageNames = dict
                try? modelContext.save()
            }
            Button("Cancel", role: .cancel) {}
        }
    }
    
    // MARK: - Page Title Resolver
    
    private func pageTitle(for index: Int, in pages: [VirtualPage]) -> String {
        if let customName = document.customPageNames[index] {
            return customName
        }
        let pageNum = index + 1
        let total = pages.count
        return "\(pageNum) / \(total)"
    }
    
    // MARK: - Drawing & OCR Management
    
    private func checkAndRunOcrIfNeeded(for vPage: VirtualPage) {
        guard vPage.fileType == "pdf",
              let pdfDoc = PDFDocument(data: vPage.fileData),
              vPage.pageIndex < pdfDoc.pageCount,
              let page = pdfDoc.page(at: vPage.pageIndex) else { return }
        
        let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            let pageIdx = vPage.pageIndex
            if ocrTexts[pageIdx] == nil {
                Task {
                    let rect = page.bounds(for: .mediaBox)
                    let renderer = UIGraphicsImageRenderer(size: rect.size)
                    let img = renderer.image { ctx in
                        let cg = ctx.cgContext
                        cg.translateBy(x: 0, y: rect.size.height)
                        cg.scaleBy(x: 1.0, y: -1.0)
                        page.draw(with: .mediaBox, to: cg)
                    }
                    
                    let imageOCRText = await performOCROnImage(imageData: img.pngData() ?? Data())
                    await MainActor.run {
                        if !imageOCRText.isEmpty {
                            ocrTexts[pageIdx] = imageOCRText
                        }
                    }
                }
            }
        }
    }
    
    private func performOCROnImage(imageData: Data) async -> String {
        guard let image = UIImage(data: imageData), let cgImage = image.cgImage else { return "" }
        return await withCheckedContinuation { continuation in
            let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
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
    
    // MARK: - Export Annotated PDF
    
    private func exportFlattenedPDF() {
        guard document.fileType == "pdf",
              let pdfDoc = PDFDocument(data: document.fileData) else { return }
        
        isExporting = true
        
        let colorSchemeVal = colorScheme
        let docTitle = document.title
        
        struct PageExportData {
            let index: Int
            let annotationDrawingData: Data?
            let overlays: [PDFOverlayData]
        }
        
        struct PDFOverlayData {
            let x: Double
            let y: Double
            let width: Double
            let height: Double
            let imageData: Data?
            let sourceDocumentTitle: String?
            let sourcePageIndex: Int?
            let isColored: Bool
        }
        
        var exportPages: [PageExportData] = []
        let pageCount = pdfDoc.pageCount
        
        for index in 0..<pageCount {
            let annoData = document.annotations.first(where: { $0.pageIndex == index })?.drawingData
            let overlaysData = document.overlays.filter({ $0.parentPageIndex == index }).map { overlay in
                var sourceTitle: String? = nil
                if let sourceDocId = overlay.sourceDocumentId,
                   let sourceDoc = allDocuments.first(where: { $0.id == sourceDocId }) {
                    sourceTitle = sourceDoc.title
                }
                return PDFOverlayData(
                    x: overlay.x,
                    y: overlay.y,
                    width: overlay.width,
                    height: overlay.height,
                    imageData: overlay.imageData,
                    sourceDocumentTitle: sourceTitle,
                    sourcePageIndex: overlay.sourcePageIndex,
                    isColored: overlay.isColored
                )
            }
            exportPages.append(PageExportData(index: index, annotationDrawingData: annoData, overlays: overlaysData))
        }
        
        let renderMode = document.pdfRenderMode ?? (colorScheme == .dark ? "dark" : "paper")
        
        DispatchQueue.global(qos: .userInitiated).async {
            let outputPDF = PDFDocument()
            let ciContext = CIContext(options: nil)
            
            for pageData in exportPages {
                autoreleasepool {
                guard let page = pdfDoc.page(at: pageData.index) else { return }
                let pageRect = page.bounds(for: .mediaBox)
                
                let pageRenderer = UIGraphicsImageRenderer(size: pageRect.size)
                let rawPageImage = pageRenderer.image { context in
                    let cgContext = context.cgContext
                    cgContext.translateBy(x: 0, y: pageRect.size.height)
                    cgContext.scaleBy(x: 1.0, y: -1.0)
                    page.draw(with: .mediaBox, to: cgContext)
                }
                
                var processedImage = rawPageImage
                if let ciImage = CIImage(image: rawPageImage) {
                    var filteredCI: CIImage?
                    if renderMode == "dark" {
                        if let invertFilter = CIFilter(name: "CIColorInvert") {
                            invertFilter.setValue(ciImage, forKey: kCIInputImageKey)
                            filteredCI = invertFilter.outputImage
                        }
                    } else {
                        if let monoFilter = CIFilter(name: "CIPhotoEffectMono") {
                            monoFilter.setValue(ciImage, forKey: kCIInputImageKey)
                            if let mono = monoFilter.outputImage, let matrixFilter = CIFilter(name: "CIColorMatrix") {
                                let isDark = colorSchemeVal == .dark
                                let bgR: CGFloat = isDark ? 0.12 : 0.96
                                let bgG: CGFloat = isDark ? 0.12 : 0.94
                                let bgB: CGFloat = isDark ? 0.12 : 0.91
                                let txtR: CGFloat = isDark ? 0.91 : 0.11
                                let txtG: CGFloat = isDark ? 0.91 : 0.11
                                let txtB: CGFloat = isDark ? 0.91 : 0.11
                                
                                  matrixFilter.setValue(mono, forKey: kCIInputImageKey)
                                  matrixFilter.setValue(CIVector(x: bgR - txtR, y: 0, z: 0, w: 0), forKey: "inputRVector")
                                  matrixFilter.setValue(CIVector(x: 0, y: bgG - txtG, z: 0, w: 0), forKey: "inputGVector")
                                  matrixFilter.setValue(CIVector(x: 0, y: 0, z: bgB - txtB, w: 0), forKey: "inputBVector")
                                  matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
                                  matrixFilter.setValue(CIVector(x: txtR, y: txtG, z: txtB, w: 0), forKey: "inputBiasVector")
                                  filteredCI = matrixFilter.outputImage
                            }
                        }
                    }
                    
                    if let out = filteredCI,
                       let cgImage = ciContext.createCGImage(out, from: out.extent) {
                        processedImage = UIImage(cgImage: cgImage)
                    }
                }
                
                let compositeRenderer = UIGraphicsImageRenderer(size: pageRect.size)
                let compositeImage = compositeRenderer.image { context in
                    processedImage.draw(in: pageRect)
                    
                    for overlay in pageData.overlays {
                        let overlayRect = CGRect(
                            x: overlay.x * pageRect.width,
                            y: overlay.y * pageRect.height,
                            width: overlay.width * pageRect.width,
                            height: overlay.height * pageRect.height
                        )
                        
                        if let imgData = overlay.imageData, let img = UIImage(data: imgData) {
                            var drawImg = img
                            if !overlay.isColored, let ci = CIImage(image: img) {
                                if let filter = CIFilter(name: "CIPhotoEffectMono") {
                                    filter.setValue(ci, forKey: kCIInputImageKey)
                                    if let out = filter.outputImage,
                                       let cg = ciContext.createCGImage(out, from: out.extent) {
                                        drawImg = UIImage(cgImage: cg)
                                    }
                                }
                            }
                            drawImg.draw(in: overlayRect)
                        } else if let sourceTitle = overlay.sourceDocumentTitle {
                            let text = "📄 \(sourceTitle)\nPage \( (overlay.sourcePageIndex ?? 0) + 1 )"
                            let textRect = overlayRect.insetBy(dx: 4, dy: 4)
                            let paragraphStyle = NSMutableParagraphStyle()
                            paragraphStyle.alignment = .center
                            
                            let attributes: [NSAttributedString.Key: Any] = [
                                .font: UIFont.systemFont(ofSize: 10, weight: .medium),
                                .foregroundColor: Theme.textColorUIColor(for: colorSchemeVal),
                                .paragraphStyle: paragraphStyle
                            ]
                            
                            let path = UIBezierPath(roundedRect: overlayRect, cornerRadius: 4)
                            Theme.textColorUIColor(for: colorSchemeVal).withAlphaComponent(0.06).setFill()
                            path.fill()
                            Theme.textColorUIColor(for: colorSchemeVal).withAlphaComponent(0.2).setStroke()
                            path.lineWidth = 1
                            path.stroke()
                            
                            text.draw(in: textRect, withAttributes: attributes)
                        }
                    }
                    
                    if let drawingData = pageData.annotationDrawingData,
                       let drawing = try? PKDrawing(data: drawingData) {
                        let drawingBounds = pageRect.offsetBy(dx: ZoomablePageView.pageHorizontalMargin, dy: 0)
                        let drawingImage = drawing.image(from: drawingBounds, scale: 4.0)
                        drawingImage.draw(in: pageRect)
                    }
                }
                
                if let newPage = PDFPage(image: compositeImage) {
                    outputPDF.insert(newPage, at: outputPDF.pageCount)
                }
                } // autoreleasepool
            }
            
            if let pdfData = outputPDF.dataRepresentation() {
                let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(docTitle)_annotated.pdf")
                try? pdfData.write(to: tempURL)
                
                DispatchQueue.main.async {
                    self.isExporting = false
                    self.shareFile(url: tempURL)
                }
            } else {
                DispatchQueue.main.async {
                    self.isExporting = false
                }
            }
        }
    }
    
    // ponytail: share raw file for non-PDFs, flattened export for PDFs
    private func shareDocument() {
        if document.fileType == "pdf" {
            exportFlattenedPDF()
            return
        }
        
        // Share raw file data with appropriate extension
        let ext: String
        switch document.fileType {
        case "txt": ext = "txt"
        case "md": ext = "md"
        case "docx": ext = "docx"
        case "epub": ext = "epub"
        case "image": ext = "jpg"
        case "article": ext = "html"
        default: ext = "dat"
        }
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(document.title).\(ext)")
        
        let dataToShare: Data
        if document.fileType == "article" {
            // Convert article JSON to readable HTML
            if let article = try? JSONDecoder().decode(RichArticle.self, from: document.fileData) {
                var html = "<html><body><h1>\(article.title)</h1>"
                for block in article.blocks {
                    switch block.type {
                    case "h1", "h2", "h3": html += "<\(block.type)>\(block.text)</\(block.type)>"
                    case "p": html += "<p>\(block.text)</p>"
                    case "code": html += "<pre><code>\(block.text)</code></pre>"
                    default: break
                    }
                }
                html += "</body></html>"
                dataToShare = Data(html.utf8)
            } else {
                dataToShare = document.fileData
            }
        } else {
            dataToShare = document.fileData
        }
        
        try? dataToShare.write(to: tempURL)
        shareFile(url: tempURL)
    }
    
    private func appendBlankPage() {
        let blankDoc = AnnoteDocument(title: "Blank Page", fileType: "blank", fileData: Data(), isSecondary: true)
        modelContext.insert(blankDoc)
        let merge = DocumentMerge(
            sourceDocumentId: blankDoc.id,
            insertAfterPageIndex: currentPage,
            sourceTitle: "Blank Page"
        )
        document.merges.append(merge)
        modelContext.insert(merge)
        try? modelContext.save()
    }
    
    private func prependBlankPage() {
        let blankDoc = AnnoteDocument(title: "Blank Page", fileType: "blank", fileData: Data(), isSecondary: true)
        modelContext.insert(blankDoc)
        let merge = DocumentMerge(
            sourceDocumentId: blankDoc.id,
            insertAfterPageIndex: -1,
            sourceTitle: "Blank Page"
        )
        document.merges.append(merge)
        modelContext.insert(merge)
        
        // Update pageOrder to place new page first
        let currentPages = resolveVirtualPages(for: document, allDocuments: allDocuments)
        let newKey = "\(blankDoc.id)-0"
        var order = document.pageOrder
        if order.isEmpty {
            order = currentPages.map { "\($0.sourceDocumentId)-\($0.pageIndex)" }
        }
        order.insert(newKey, at: 0)
        document.pageOrder = order
        try? modelContext.save()
    }
    
    private func shareFile(url: URL) {
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootVC = windowScene.windows.first?.rootViewController {
            if let popover = activityVC.popoverPresentationController {
                popover.sourceView = rootVC.view
                popover.sourceRect = CGRect(x: rootVC.view.bounds.midX, y: rootVC.view.bounds.midY, width: 0, height: 0)
                popover.permittedArrowDirections = []
            }
            rootVC.present(activityVC, animated: true, completion: nil)
        }
    }
}


// =========================================================================
// MARK: - Picker & Overlay Selection Supporting Views
// =========================================================================

struct PageOverlayPickerView: View {
    @Binding var isPresented: Bool
    let currentDocument: AnnoteDocument
    let allDocuments: [AnnoteDocument]
    var onSelect: (AnnoteDocument, Int) -> Void
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(allDocuments.filter { $0.id != currentDocument.id }) { doc in
                    let pageCount = nativePageCount(for: doc)
                    if pageCount > 0 {
                        Section(header: Text(doc.title)) {
                            ForEach(0..<pageCount, id: \.self) { idx in
                                Button(action: {
                                    onSelect(doc, idx)
                                    isPresented = false
                                }) {
                                    HStack {
                                        Image(systemName: "doc.text")
                                            .foregroundColor(.secondary)
                                        Text("Page \(idx + 1)")
                                            .font(.system(size: 15, weight: .medium, design: .serif))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Page to Overlay")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}

struct MergeDocumentPickerView: View {
    @Binding var isPresented: Bool
    let currentDocument: AnnoteDocument
    @Query(sort: \AnnoteDocument.createdAt, order: .reverse) private var allDocuments: [AnnoteDocument]
    var onSelect: (AnnoteDocument) -> Void
    
    var body: some View {
        NavigationStack {
            List {
                ForEach(allDocuments.filter { $0.id != currentDocument.id }) { doc in
                    Button(action: {
                        onSelect(doc)
                        isPresented = false
                    }) {
                        HStack {
                            Image(systemName: doc.fileType == "pdf" ? "doc.richtext" : (doc.fileType == "article" ? "globe" : "doc.text"))
                                .font(.system(size: 20))
                                .foregroundColor(.secondary)
                            VStack(alignment: .leading) {
                                Text(doc.title)
                                    .font(.system(size: 16, weight: .semibold, design: .serif))
                                Text("\(doc.fileType.uppercased()) • \(doc.createdAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.system(size: 12))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Select Document to Insert")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isPresented = false }
                }
            }
        }
    }
}

struct PDFExtractedOCROverlaySheet: View {
    @Binding var isPresented: Bool
    let text: String
    @State private var searchQuery = ""
    
    var body: some View {
        NavigationStack {
            VStack {
                TextField("Search in extracted text...", text: $searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .padding()
                
                ScrollView {
                    Text(text)
                        .font(.system(size: 14, design: .monospaced))
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .navigationTitle("Scanned Page Extracted OCR Text")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { isPresented = false }
                }
            }
        }
    }
}

struct OutlineItem: Identifiable {
    let id = UUID()
    let title: String
    let pageIndex: Int
    let indentLevel: Int
}

enum OutlineTab: String, CaseIterable {
    case pages = "Pages"
    case outline = "Outline"
    case bookmarks = "Bookmarks"
}

struct OutlineView: View {
    @Binding var isPresented: Bool
    let document: AnnoteDocument
    let virtualPages: [VirtualPage]
    let allDocuments: [AnnoteDocument]
    @Binding var currentPage: Int
    let modelContext: ModelContext
    @Environment(\.colorScheme) var colorScheme
    
    @State private var selectedTab: OutlineTab = .pages
    @State private var isAddOutlinePresented = false
    @State private var newOutlineTitle = ""
    @State private var isMergeWarningPresented = false
    @State private var pendingMergeDoc: AnnoteDocument? = nil
    @State private var isInsertPickerPresented = false
    @State private var editingOutlineIndex: Int? = nil
    @State private var editOutlineTitle = ""
    @State private var isEditOutlinePresented = false
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Tab", selection: $selectedTab) {
                    ForEach(OutlineTab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .padding()
                
                switch selectedTab {
                case .pages:
                    pagesTab
                case .outline:
                    outlineTab
                case .bookmarks:
                    bookmarksTab
                }
            }
            .navigationTitle("Navigator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { isPresented = false }
                }
            }
        }
    }
    
    // MARK: - Pages Tab
    
    private var pagesTab: some View {
        VStack(spacing: 0) {
            // Insert actions
            HStack(spacing: 12) {
                Button(action: { insertBlankPage() }) {
                    Label("Add Blank Page", systemImage: "plus.square.dashed")
                        .font(.system(size: 14, weight: .medium))
                }
                Button(action: { isInsertPickerPresented = true }) {
                    Label("Merge Document", systemImage: "doc.on.doc")
                        .font(.system(size: 14, weight: .medium))
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            
            HStack {
                EditButton()
                    .font(.system(size: 14, weight: .medium))
                Spacer()
            }
            .padding(.horizontal)
            .padding(.bottom, 4)
            
            List {
                ForEach(Array(virtualPages.enumerated()), id: \.offset) { idx, vPage in
                    Button(action: {
                        currentPage = idx
                        isPresented = false
                    }) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                let customName = document.customPageNames[idx]
                                Text(customName ?? "Page \(idx + 1)")
                                    .font(.system(size: 15, weight: currentPage == idx ? .bold : .regular, design: .serif))
                                    .foregroundColor(Theme.textColor(for: colorScheme))
                                HStack(spacing: 4) {
                                    Text(vPage.fileType.uppercased())
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                    if vPage.isMerged {
                                        Text("• \(vPage.sourceTitle)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                    if document.bookmarkedPages.contains(idx) {
                                        Image(systemName: "bookmark.fill")
                                            .font(.system(size: 10))
                                            .foregroundColor(.orange)
                                    }
                                }
                            }
                            Spacer()
                            if currentPage == idx {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                                    .font(.system(size: 14))
                            }
                        }
                    }
                    .contextMenu {
                        Button {
                            insertBlankPageAt(index: idx)
                        } label: {
                            Label("Insert Blank Before", systemImage: "plus.square.dashed")
                        }
                        Button {
                            insertBlankPageAt(index: idx + 1)
                        } label: {
                            Label("Insert Blank After", systemImage: "plus.square.dashed")
                        }
                        Divider()
                        Button(role: .destructive) {
                            deletePage(at: idx, vPage: vPage)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(role: .destructive) {
                            deletePage(at: idx, vPage: vPage)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
                .onMove(perform: movePages)
            }
            .listStyle(.plain)
        }
        .sheet(isPresented: $isInsertPickerPresented) {
            MergeDocumentPickerView(isPresented: $isInsertPickerPresented, currentDocument: document) { selectedDoc in
                pendingMergeDoc = selectedDoc
                isMergeWarningPresented = true
            }
        }
        .alert("Merge Document", isPresented: $isMergeWarningPresented) {
            Button("Cancel", role: .cancel) { pendingMergeDoc = nil }
            Button("Merge") {
                if let doc = pendingMergeDoc {
                    let newMerge = DocumentMerge(
                        sourceDocumentId: doc.id,
                        insertAfterPageIndex: currentPage,
                        sourceTitle: doc.title
                    )
                    document.merges.append(newMerge)
                    modelContext.insert(newMerge)
                    try? modelContext.save()
                    pendingMergeDoc = nil
                }
            }
        } message: {
            Text("⚠️ Merging pages from another document connects them. Annotations will sync between both documents.")
        }
    }
    
    // MARK: - Outline Tab
    
    private var outlineTab: some View {
        let autoItems = buildDocumentOutline(virtualPages: virtualPages, allDocuments: allDocuments)
        let manualItems = document.manualOutline
        
        return Group {
            if autoItems.isEmpty && manualItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "list.bullet.rectangle.portrait")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No outline available.")
                        .font(.serifFont(size: 16))
                        .foregroundColor(.secondary)
                    Button(action: { isAddOutlinePresented = true }) {
                        Label("Add Outline Item", systemImage: "plus")
                    }
                }
            } else {
                List {
                    if !autoItems.isEmpty {
                        Section("Document Outline") {
                            ForEach(autoItems) { item in
                                Button(action: {
                                    currentPage = item.pageIndex
                                    isPresented = false
                                }) {
                                    HStack {
                                        Text(item.title)
                                            .font(.system(size: 16 - CGFloat(item.indentLevel) * 1.0, weight: item.indentLevel == 0 ? .bold : .medium, design: .serif))
                                            .foregroundColor(Theme.textColor(for: colorScheme))
                                            .padding(.leading, CGFloat(item.indentLevel) * 16)
                                        Spacer()
                                        Text("Page \(item.pageIndex + 1)")
                                            .font(.system(size: 12))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }
                    
                    Section {
                        ForEach(Array(manualItems.enumerated()), id: \.element.id) { idx, item in
                            Button(action: {
                                currentPage = item.pageIndex
                                isPresented = false
                            }) {
                                HStack {
                                    Text(item.title)
                                        .font(.system(size: 16, weight: .medium, design: .serif))
                                        .foregroundColor(Theme.textColor(for: colorScheme))
                                    Spacer()
                                    Text("Page \(item.pageIndex + 1)")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    var outline = document.manualOutline
                                    outline.remove(at: idx)
                                    document.manualOutline = outline
                                    try? modelContext.save()
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    editingOutlineIndex = idx
                                    editOutlineTitle = item.title
                                    isEditOutlinePresented = true
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.orange)
                            }
                        }
                        
                        Button(action: { isAddOutlinePresented = true }) {
                            Label("Add Outline for Current Page (\(currentPage + 1))", systemImage: "plus.circle")
                                .font(.system(size: 14, weight: .medium))
                        }
                    } header: {
                        Text("My Outlines")
                    }
                }
                .listStyle(.plain)
            }
        }
        .alert("New Outline Item", isPresented: $isAddOutlinePresented) {
            TextField("Title", text: $newOutlineTitle)
            Button("Cancel", role: .cancel) { newOutlineTitle = "" }
            Button("Add") {
                let item = ManualOutlineItem(title: newOutlineTitle, pageIndex: currentPage)
                var outline = document.manualOutline
                outline.append(item)
                document.manualOutline = outline
                try? modelContext.save()
                newOutlineTitle = ""
            }
        } message: {
            Text("Enter a title for the outline item on page \(currentPage + 1).")
        }
        .alert("Edit Outline Item", isPresented: $isEditOutlinePresented) {
            TextField("Title", text: $editOutlineTitle)
            Button("Cancel", role: .cancel) { editingOutlineIndex = nil }
            Button("Save") {
                if let idx = editingOutlineIndex {
                    var outline = document.manualOutline
                    if idx < outline.count {
                        outline[idx] = ManualOutlineItem(title: editOutlineTitle, pageIndex: outline[idx].pageIndex, indentLevel: outline[idx].indentLevel)
                        document.manualOutline = outline
                        try? modelContext.save()
                    }
                }
                editingOutlineIndex = nil
            }
        }
    }
    
    // MARK: - Bookmarks Tab
    
    private var bookmarksTab: some View {
        let bookmarks = document.bookmarkedPages.sorted()
        
        return Group {
            if bookmarks.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 48))
                        .foregroundColor(.secondary)
                    Text("No bookmarks yet.")
                        .font(.serifFont(size: 16))
                        .foregroundColor(.secondary)
                    Text("Tap the bookmark icon in the toolbar to bookmark the current page.")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 280)
                }
            } else {
                List(bookmarks, id: \.self) { pageIdx in
                    Button(action: {
                        currentPage = pageIdx
                        isPresented = false
                    }) {
                        HStack {
                            Image(systemName: "bookmark.fill")
                                .foregroundColor(.orange)
                            let customName = document.customPageNames[pageIdx]
                            Text(customName ?? "Page \(pageIdx + 1)")
                                .font(.system(size: 15, weight: .medium, design: .serif))
                                .foregroundColor(Theme.textColor(for: colorScheme))
                            Spacer()
                            if currentPage == pageIdx {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.accentColor)
                                    .font(.system(size: 14))
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }
    
    // MARK: - Helpers
    
    private func insertBlankPage() {
        // Create a new blank document and merge it at current position
        let blankDoc = AnnoteDocument(title: "Blank Page", fileType: "blank", fileData: Data())
        modelContext.insert(blankDoc)
        let merge = DocumentMerge(
            sourceDocumentId: blankDoc.id,
            insertAfterPageIndex: currentPage,
            sourceTitle: "Blank Page"
        )
        document.merges.append(merge)
        modelContext.insert(merge)
        try? modelContext.save()
    }
    
    private func deletePage(at virtualIdx: Int, vPage: VirtualPage) {
        let key = "\(vPage.sourceDocumentId)-\(vPage.pageIndex)"
        var keys = document.deletedPageKeys
        keys.insert(key)
        document.deletedPageKeys = keys
        if currentPage >= virtualPages.count - 1 {
            currentPage = max(0, currentPage - 1)
        }
        try? modelContext.save()
    }
    
    private func movePages(from source: IndexSet, to destination: Int) {
        let pages = virtualPages
        var keys = pages.map { "\($0.sourceDocumentId)-\($0.pageIndex)" }
        keys.move(fromOffsets: source, toOffset: destination)
        document.pageOrder = keys
        try? modelContext.save()
    }
    
    private func insertBlankPageAt(index: Int) {
        let blankDoc = AnnoteDocument(title: "Blank Page", fileType: "blank", fileData: Data(), isSecondary: true)
        modelContext.insert(blankDoc)
        let merge = DocumentMerge(
            sourceDocumentId: blankDoc.id,
            insertAfterPageIndex: max(0, index - 1),
            sourceTitle: "Blank Page"
        )
        document.merges.append(merge)
        modelContext.insert(merge)
        
        // Update pageOrder to place new page at the specified index
        let currentPages = virtualPages
        let newKey = "\(blankDoc.id)-0"
        var order = document.pageOrder
        if order.isEmpty {
            order = currentPages.map { "\($0.sourceDocumentId)-\($0.pageIndex)" }
        }
        let insertIdx = min(index, order.count)
        order.insert(newKey, at: insertIdx)
        document.pageOrder = order
        try? modelContext.save()
    }
    
    private func parsePDFOutline(pdfDoc: PDFDocument) -> [OutlineItem] {
        guard let root = pdfDoc.outlineRoot else { return [] }
        var items: [OutlineItem] = []
        
        func traverse(node: PDFOutline, level: Int) {
            if let title = node.label {
                if let page = node.destination?.page {
                    let pageIdx = pdfDoc.index(for: page)
                    items.append(OutlineItem(title: title, pageIndex: pageIdx, indentLevel: level))
                }
            }
            for i in 0..<node.numberOfChildren {
                if let child = node.child(at: i) {
                    traverse(node: child, level: level + 1)
                }
            }
        }
        
        for i in 0..<root.numberOfChildren {
            if let child = root.child(at: i) {
                traverse(node: child, level: 0)
            }
        }
        return items
    }
    
    private func buildDocumentOutline(virtualPages: [VirtualPage], allDocuments: [AnnoteDocument]) -> [OutlineItem] {
        var outline: [OutlineItem] = []
        
        for (vIdx, vPage) in virtualPages.enumerated() {
            if vPage.fileType == "pdf", let pdfDoc = PDFDocument(data: vPage.fileData) {
                if vPage.pageIndex == 0 {
                    let pdfItems = parsePDFOutline(pdfDoc: pdfDoc)
                    for item in pdfItems {
                        let globalIdx = vIdx + item.pageIndex
                        outline.append(OutlineItem(title: item.title, pageIndex: globalIdx, indentLevel: item.indentLevel))
                    }
                }
            } else if vPage.fileType == "article" {
                if let article = try? JSONDecoder().decode(RichArticle.self, from: vPage.fileData) {
                    for block in article.blocks {
                        if block.type == "h1" || block.type == "h2" || block.type == "h3" {
                            let level = block.type == "h1" ? 0 : (block.type == "h2" ? 1 : 2)
                            outline.append(OutlineItem(title: block.text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression), pageIndex: vIdx, indentLevel: level))
                        }
                    }
                }
            } else if vPage.fileType == "docx" || vPage.fileType == "epub" {
                let html = vPage.fileType == "docx" ? 
                    DocxEpubParser.parseDocx(data: vPage.fileData, isDarkMode: colorScheme == .dark) : 
                    DocxEpubParser.parseEpub(data: vPage.fileData, isDarkMode: colorScheme == .dark)
                if let parsed = try? SwiftSoup.parse(html), let headers = try? parsed.select("h1, h2, h3") {
                    for header in headers {
                        let tag = header.tagName().lowercased()
                        let level = tag == "h1" ? 0 : (tag == "h2" ? 1 : 2)
                        if let text = try? header.text(), !text.isEmpty {
                            outline.append(OutlineItem(title: text, pageIndex: vIdx, indentLevel: level))
                        }
                    }
                }
            }
        }
        return outline
    }
}
