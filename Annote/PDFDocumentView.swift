//
//  PDFDocumentView.swift
//  Annote
//
//  Created by Raymus Lim on 30/5/24.
//

import SwiftUI
import PDFKit
import PencilKit
import SwiftData
import SwiftSoup
import ZIPFoundation
import Vision
import VisionKit

final class PageAnnotationCanvasView: PKCanvasView {
    weak var documentView: UIView?
    weak var overlayControlsView: UIView?

    var isDrawingActive: Bool = true

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if !isDrawingActive { return nil }

        // If event or touches are empty (e.g. system hit test pass), we must return the canvas to be a candidate
        guard let touches = event?.allTouches, !touches.isEmpty else {
            return super.hitTest(point, with: event)
        }

        // If a finger touch hits a UIControl underneath (or any subview inside it), let it pass through.
        let controlViews = [overlayControlsView, documentView]
        for view in controlViews {
            guard let view else { continue }
            let convertedPoint = convert(point, to: view)
            if let hitView = view.hitTest(convertedPoint, with: event) {
                var current: UIView? = hitView
                while current != nil && current != view {
                    if current is UIControl {
                        return nil
                    }
                    current = current?.superview
                }
            }
        }

        // If any of the touches is a pencil, the canvas must handle it to draw.
        if touches.contains(where: { $0.type == .pencil }) {
            return super.hitTest(point, with: event)
        }
        
        // If pencil-only drawing is active, pass ALL finger touches through so the outer scrollView can pan/zoom/swipe
        // This fixes the issue where swipe gestures and text selection were blocked by the canvas.
        if drawingPolicy == .pencilOnly {
            return nil
        }
        
        // Otherwise, the canvas intercepts the touch
        return super.hitTest(point, with: event)
    }
}

final class PassthroughOverlayView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hitView = super.hitTest(point, with: event)
        return hitView === self ? nil : hitView
    }
}

final class NonAutoScrollingScrollView: UIScrollView {
    override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
        // No-op: prevent auto-scrolling when subviews become first responder
    }
}

// =========================================================================
// MARK: - Zoomable Page View (PencilKit + Document Rendering + Overlays)
// =========================================================================

struct ZoomablePageView: UIViewRepresentable {
    static let pageHorizontalMargin: CGFloat = 120

    let documentId: UUID
    let documentData: Data
    let fileType: String
    let pageIndex: Int
    let isMerged: Bool
    let sourceTitle: String
    var isDrawingEnabled: Bool
    var isHighlightAssistEnabled: Bool
    let colorScheme: ColorScheme
    let allDocuments: [AnnoteDocument]
    let modelContext: ModelContext
    var onSwipeLeft: (() -> Void)? = nil
    var onSwipeRight: (() -> Void)? = nil
    
    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = NonAutoScrollingScrollView()
        scrollView.minimumZoomScale = 1.0
        scrollView.maximumZoomScale = 5.0
        scrollView.delegate = context.coordinator
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .clear
        
        let container = UIView()
        scrollView.addSubview(container)
        context.coordinator.container = container
        
        let docView = UIView()
        container.addSubview(docView)
        context.coordinator.docView = docView
        
        // Add overlay container view
        let overlayView = PassthroughOverlayView()
        overlayView.backgroundColor = .clear
        container.addSubview(overlayView)
        context.coordinator.overlayView = overlayView
        
        let canvas = PageAnnotationCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = context.coordinator
        canvas.documentView = docView
        canvas.overlayControlsView = overlayView
        canvas.isScrollEnabled = false
        canvas.minimumZoomScale = 1.0
        canvas.maximumZoomScale = 1.0
        canvas.zoomScale = 1.0
        
        // Setup initial Apple Pencil policy
        canvas.drawingPolicy = UIPencilInteraction.prefersPencilOnlyDrawing ? .pencilOnly : .anyInput
        
        container.addSubview(canvas)
        context.coordinator.canvas = canvas
        container.bringSubviewToFront(overlayView)
        
        context.coordinator.setupToolPicker(for: canvas)
        context.coordinator.setupPencilInteraction(for: canvas)
        
        // Add horizontal swipe gesture recognizers for page navigation (finger touches only)
        let swipeLeft = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(context.coordinator.handleSwipeLeft))
        swipeLeft.direction = .left
        swipeLeft.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        swipeLeft.delegate = context.coordinator
        scrollView.addGestureRecognizer(swipeLeft)
        
        let swipeRight = UISwipeGestureRecognizer(target: context.coordinator, action: #selector(context.coordinator.handleSwipeRight))
        swipeRight.direction = .right
        swipeRight.allowedTouchTypes = [UITouch.TouchType.direct.rawValue as NSNumber]
        swipeRight.delegate = context.coordinator
        scrollView.addGestureRecognizer(swipeRight)
        // Add pause gesture to canvas to preview line straightening while drawing
        let coordinator = context.coordinator
        let holdGesture = PauseGestureRecognizer()
        holdGesture.delegate = coordinator
        holdGesture.onPauseBegan = { [weak coordinator] start, current in
            coordinator?.handlePauseBegan(start: start, current: current)
        }
        holdGesture.onPauseChanged = { [weak coordinator] current in
            coordinator?.handlePauseChanged(current: current)
        }
        holdGesture.onPauseEnded = { [weak coordinator] in
            coordinator?.handlePauseEnded()
        }
        canvas.addGestureRecognizer(holdGesture)
        
        // Load initial drawing directly
        let initialDrawing = coordinator.loadDrawing()
        canvas.drawing = initialDrawing
        
        // Disable back swipe pop gesture to prevent conflict with PDF document swipe actions
        DispatchQueue.main.async {
            if let nav = coordinator.findNavigationController(from: scrollView) {
                coordinator.navigationController = nav
                nav.interactivePopGestureRecognizer?.isEnabled = false
            }
        }
        
        return scrollView
    }
    
    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(
            documentData: documentData,
            fileType: fileType,
            pageIndex: pageIndex,
            isDrawingEnabled: isDrawingEnabled,
            isHighlightAssistEnabled: isHighlightAssistEnabled,
            colorScheme: colorScheme
        )
        
        if let nav = context.coordinator.navigationController {
            nav.interactivePopGestureRecognizer?.isEnabled = (pageIndex == 0)
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, UIScrollViewDelegate, PKCanvasViewDelegate, PKToolPickerObserver, UITextViewDelegate, UIPencilInteractionDelegate, UIGestureRecognizerDelegate {
        var parent: ZoomablePageView
        var container: UIView?
        var docView: UIView?
        var overlayView: UIView?
        var canvas: PageAnnotationCanvasView?
        let toolPicker = PKToolPicker()
        weak var navigationController: UINavigationController?
        
        // Rebuild cache keys
        var lastLoadedDocumentId: UUID?
        var lastLoadedPageIndex: Int?
        var lastLoadedColorScheme: ColorScheme?
        var lastLoadedRenderMode: String?
        var lastLoadedOverlayIds: Set<UUID> = []
        var lastViewportSize: CGSize?
        var currentPageFrameInCanvas: CGRect = .zero
        var lastDrawingEnabled: Bool?
        var lastHighlightAssistEnabled: Bool?
        var lastOriginalWidth: CGFloat = 612
        var lastOriginalHeight: CGFloat = 792
        var lastDrawing: PKDrawing?
        var lastUiImageForOCR: UIImage?
        private let imageAnalyzer = ImageAnalyzer()
        private var imageAnalysisInteractions: [ImageAnalysisInteraction] = []
        
        // pnytail: stricter straighten — long hold 0.65s, tight 8pt drift, must be roughly linear
        // Also straighten unconditionally if the preview was shown (user held and saw the preview)
        private func shouldStraighten(_ stroke: PKStroke) -> Bool {
            // If the hold preview was shown, always straighten
            if didShowStraighteningPreview {
                didShowStraighteningPreview = false
                guard stroke.path.count > 1 else { return false }
                return true
            }
            
            guard stroke.path.count > 10,
                  let firstPoint = stroke.path.first,
                  let lastPoint = stroke.path.last else {
                return false
            }
            
            // Check end-hold: user must pause at end
            var holdDuration: TimeInterval = 0
            var idx = stroke.path.count - 1
            while idx >= 0 {
                let pt = stroke.path[idx]
                let dx = pt.location.x - lastPoint.location.x
                let dy = pt.location.y - lastPoint.location.y
                let dist = sqrt(dx*dx + dy*dy)
                if dist > 8 { break }
                holdDuration = lastPoint.timeOffset - pt.timeOffset
                idx -= 1
            }
            guard holdDuration >= 0.65 else { return false }
            
            // Check linearity: verify maximum perpendicular distance of points is very small
            let p1 = firstPoint.location
            let p2 = lastPoint.location
            let dx = p2.x - p1.x
            let dy = p2.y - p1.y
            let length = sqrt(dx*dx + dy*dy)
            
            // Too short = not a line
            guard length > 25 else { return false }
            
            var maxDistance: CGFloat = 0
            for pt in stroke.path {
                let p = pt.location
                let distance = abs(dx * (p1.y - p.y) - (p1.x - p.x) * dy) / length
                if distance > maxDistance {
                    maxDistance = distance
                }
            }
            
            // Ensure no point deviates by more than 15 points (stricter check to prevent curves/letters from straightening)
            return maxDistance < 15.0
        }
        
        private func straightenStroke(_ stroke: PKStroke) -> PKStroke {
            guard stroke.path.count > 1,
                  let firstPoint = stroke.path.first,
                  let lastPoint = stroke.path.last else {
                return stroke
            }
            
            let p1 = PKStrokePoint(location: firstPoint.location, timeOffset: 0, size: firstPoint.size, opacity: firstPoint.opacity, force: firstPoint.force, azimuth: firstPoint.azimuth, altitude: firstPoint.altitude)
            let p2 = PKStrokePoint(location: lastPoint.location, timeOffset: 0.1, size: lastPoint.size, opacity: lastPoint.opacity, force: lastPoint.force, azimuth: lastPoint.azimuth, altitude: lastPoint.altitude)
            
            let path = PKStrokePath(controlPoints: [p1, p2], creationDate: stroke.path.creationDate)
            return PKStroke(ink: stroke.ink, path: path, transform: stroke.transform, mask: stroke.mask)
        }
        
        private func createSelectableTextView(attributedText: NSAttributedString) -> UITextView {
            let tv = UITextView()
            tv.isEditable = false
            tv.isSelectable = !parent.isDrawingEnabled
            tv.isUserInteractionEnabled = !parent.isDrawingEnabled
            tv.isScrollEnabled = false
            tv.backgroundColor = .clear
            tv.textContainerInset = .zero
            tv.textContainer.lineFragmentPadding = 0
            tv.attributedText = attributedText
            return tv
        }
        
        private func parseSimpleHTML(_ html: String, font: UIFont, textColor: UIColor) -> NSAttributedString {
            var md = html
            md = md.replacingOccurrences(of: "<strong>", with: "**")
            md = md.replacingOccurrences(of: "</strong>", with: "**")
            md = md.replacingOccurrences(of: "<b>", with: "**")
            md = md.replacingOccurrences(of: "</b>", with: "**")
            md = md.replacingOccurrences(of: "<em>", with: "*")
            md = md.replacingOccurrences(of: "</em>", with: "*")
            md = md.replacingOccurrences(of: "<i>", with: "*")
            md = md.replacingOccurrences(of: "</i>", with: "*")
            
            // Strip remaining HTML tags
            md = md.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            
            // Unescape HTML entities
            md = md.replacingOccurrences(of: "&amp;", with: "&")
            md = md.replacingOccurrences(of: "&lt;", with: "<")
            md = md.replacingOccurrences(of: "&gt;", with: ">")
            md = md.replacingOccurrences(of: "&quot;", with: "\"")
            md = md.replacingOccurrences(of: "&#x27;", with: "'")
            md = md.replacingOccurrences(of: "&#x39;", with: "`")
            
            if let attrStr = try? NSAttributedString(markdown: md, options: .init(interpretedSyntax: .inlineOnly)) {
                let mutable = NSMutableAttributedString(attributedString: attrStr)
                let fullRange = NSRange(location: 0, length: mutable.length)
                mutable.addAttribute(.foregroundColor, value: textColor, range: fullRange)
                
                // Merge the font while preserving traits like bold/italic from markdown
                mutable.enumerateAttribute(.font, in: fullRange, options: []) { value, range, _ in
                    if let customFont = value as? UIFont {
                        var traits = customFont.fontDescriptor.symbolicTraits
                        if customFont.fontName.contains("Bold") {
                            traits.insert(.traitBold)
                        }
                        if customFont.fontName.contains("Italic") {
                            traits.insert(.traitItalic)
                        }
                        
                        let descriptor = font.fontDescriptor.withSymbolicTraits(traits) ?? font.fontDescriptor
                        let finalFont = UIFont(descriptor: descriptor, size: font.pointSize)
                        mutable.addAttribute(.font, value: finalFont, range: range)
                    } else {
                        mutable.addAttribute(.font, value: font, range: range)
                    }
                }
                return mutable
            }
            
            return NSAttributedString(string: md, attributes: [.font: font, .foregroundColor: textColor])
        }
        
        private func createSelectableTextView(text: String, font: UIFont, textColor: UIColor) -> UITextView {
            let tv = UITextView()
            tv.isEditable = false
            tv.isSelectable = !parent.isDrawingEnabled
            tv.isUserInteractionEnabled = !parent.isDrawingEnabled
            tv.isScrollEnabled = false
            tv.backgroundColor = .clear
            tv.textContainerInset = .zero
            tv.textContainer.lineFragmentPadding = 0
            tv.font = font
            tv.textColor = textColor
            tv.text = text
            return tv
        }
        
        private func setupImageAnalysis(for imageView: UIImageView) {
            guard ImageAnalyzer.isSupported else { return }
            let interaction = ImageAnalysisInteraction()
            interaction.preferredInteractionTypes = parent.isDrawingEnabled ? [] : .textSelection
            imageView.addInteraction(interaction)
            self.imageAnalysisInteractions.append(interaction)
            
            Task { [weak self, weak interaction] in
                guard let self = self, let interaction = interaction, let image = imageView.image else { return }
                let configuration = ImageAnalyzer.Configuration([.text])
                do {
                    let analysis = try await self.imageAnalyzer.analyze(image, configuration: configuration)
                    await MainActor.run {
                        interaction.analysis = analysis
                    }
                } catch {
                    print("Image analysis failed: \(error)")
                }
            }
        }
        
        var isSettingDrawing = false
        var pendingDrawingSave: DispatchWorkItem?
        var pendingDrawing: PKDrawing?
        var lastHighlightOCRKey: String?
        
        // Highlights Assist & OCR
        struct OCRWord: Equatable {
            let text: String
            let rect: CGRect
            
            static func == (lhs: OCRWord, rhs: OCRWord) -> Bool {
                return lhs.text == rhs.text && lhs.rect == rhs.rect
            }
        }
        var cachedWords: [OCRWord] = []
        var selectionStartWord: OCRWord?
        var selectionEndWord: OCRWord?
        var tempHighlightViews: [UIView] = []
        
        // Preview variables for holds
        var drawingStartPoint: CGPoint?
        var previewLayer: CAShapeLayer?
        var didShowStraighteningPreview = false
        var ocrInProgress = false
        
        init(_ parent: ZoomablePageView) {
            self.parent = parent
        }

        deinit {
            pendingDrawingSave?.cancel()
            if let pendingDrawing {
                saveDrawingImmediately(pendingDrawing)
            }
            // Clear undoManager actions to prevent freezes when detaching/deallocating PKCanvasView
            canvas?.undoManager?.removeAllActions()
            
            // Re-enable back gesture
            if let nav = navigationController {
                DispatchQueue.main.async {
                    nav.interactivePopGestureRecognizer?.isEnabled = true
                }
            }
        }
        
        func findNavigationController(from view: UIView) -> UINavigationController? {
            var nextResponder = view.next
            while nextResponder != nil {
                if let viewController = nextResponder as? UIViewController {
                    if let navController = viewController.navigationController {
                        return navController
                    }
                }
                nextResponder = nextResponder?.next
            }
            return nil
        }
        
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            return container
        }
        
        func setupToolPicker(for canvas: PKCanvasView) {
            toolPicker.addObserver(canvas)
            toolPicker.addObserver(self)
        }
        
        func setupPencilInteraction(for canvas: PKCanvasView) {
            let pencilInteraction = UIPencilInteraction(delegate: self)
            canvas.addInteraction(pencilInteraction)
        }
        
        @objc func handleSwipeLeft() {
            guard let scrollView = container?.superview as? UIScrollView, scrollView.zoomScale == 1.0 else { return }
            parent.onSwipeLeft?()
        }
        
        @objc func handleSwipeRight() {
            guard let scrollView = container?.superview as? UIScrollView, scrollView.zoomScale == 1.0 else { return }
            parent.onSwipeRight?()
        }
        
        func handlePauseBegan(start: CGPoint, current: CGPoint) {
            guard parent.isDrawingEnabled, let canvas = canvas, let overlayView = overlayView else { return }
            
            // Map coordinate space from canvas to overlayView
            let startInOverlay = canvas.convert(start, to: overlayView)
            let currentInOverlay = canvas.convert(current, to: overlayView)
            
            drawingStartPoint = startInOverlay
            
            // Trigger subtle haptic feedback
            let feedback = UIImpactFeedbackGenerator(style: .light)
            feedback.impactOccurred()
            didShowStraighteningPreview = true
            
            // Use active tool color and width for preview
            let activeTool = toolPicker.selectedTool
            var strokeColor = UIColor.label
            var strokeWidth: CGFloat = 4
            if let inkTool = activeTool as? PKInkingTool {
                strokeColor = inkTool.color
                strokeWidth = inkTool.width
            }
            
            // Create preview line layer matching active tool appearance
            let layer = CAShapeLayer()
            layer.strokeColor = strokeColor.withAlphaComponent(0.4).cgColor
            layer.lineWidth = strokeWidth
            layer.lineCap = .round
            layer.fillColor = nil
            
            let path = UIBezierPath()
            path.move(to: startInOverlay)
            path.addLine(to: currentInOverlay)
            layer.path = path.cgPath
            overlayView.layer.addSublayer(layer)
            previewLayer = layer
        }
        
        func handlePauseChanged(current: CGPoint) {
            guard let start = drawingStartPoint, let layer = previewLayer, let canvas = canvas, let overlayView = overlayView else { return }
            let currentInOverlay = canvas.convert(current, to: overlayView)
            
            let path = UIBezierPath()
            path.move(to: start)
            path.addLine(to: currentInOverlay)
            layer.path = path.cgPath
        }
        
        func handlePauseEnded() {
            previewLayer?.removeFromSuperlayer()
            previewLayer = nil
            drawingStartPoint = nil
        }
        
        // MARK: - PKCanvasViewDelegate
        
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            if isSettingDrawing { return }
            let newDrawing = canvasView.drawing
            
            let newStrokes = newDrawing.strokes
            let oldStrokes = lastDrawing?.strokes ?? []
            
            if newStrokes.count > oldStrokes.count {
                let addedStrokes = newStrokes.suffix(newStrokes.count - oldStrokes.count)
                var modifiedStrokes = Array(newStrokes.prefix(oldStrokes.count))
                var didModify = false
                
                for stroke in addedStrokes {
                    var finalStroke = stroke
                    
                    // 1. Check hold-to-straighten
                    if shouldStraighten(stroke) {
                        finalStroke = straightenStroke(stroke)
                        didModify = true
                    }
                    
                    // 2. Highlight Assist marker snapping
                    // ponytail: use path envelope not renderBounds (renderBounds inflated by stroke width → catches too many words)
                    if parent.isHighlightAssistEnabled && finalStroke.ink.inkType == .marker && !cachedWords.isEmpty {
                        var intersectedWords: [OCRWord] = []
                        for word in cachedWords {
                            let wordCanvasRect = word.rect.offsetBy(dx: currentPageFrameInCanvas.minX, dy: currentPageFrameInCanvas.minY)
                            // Robust segment check: does any line segment of the stroke cross the word horizontally and vertically?
                            var intersected = false
                            let pathCount = finalStroke.path.count
                            if pathCount > 1 {
                                for i in 1..<pathCount {
                                    let pA = finalStroke.path[i-1].location.applying(finalStroke.transform)
                                    let pB = finalStroke.path[i].location.applying(finalStroke.transform)
                                    let minSegX = min(pA.x, pB.x)
                                    let maxSegX = max(pA.x, pB.x)
                                    
                                    let overlapStart = max(minSegX, wordCanvasRect.minX)
                                    let overlapEnd = min(maxSegX, wordCanvasRect.maxX)
                                    let overlapWidth = overlapEnd - overlapStart
                                    
                                    if overlapWidth >= min(6.0, wordCanvasRect.width * 0.2) {
                                        let segMidY = (pA.y + pB.y) / 2.0
                                        if abs(segMidY - wordCanvasRect.midY) <= wordCanvasRect.height * 0.5 {
                                            intersected = true
                                            break
                                        }
                                    }
                                }
                            } else if let pt = finalStroke.path.first {
                                let loc = pt.location.applying(finalStroke.transform)
                                if wordCanvasRect.contains(loc) {
                                    intersected = true
                                }
                            }
                            if intersected {
                                intersectedWords.append(word)
                            }
                        }
                        
                        if !intersectedWords.isEmpty {
                            let groupedLines = groupWordsIntoLines(intersectedWords)
                            for lineWords in groupedLines {
                                var unionRect = CGRect.null
                                for w in lineWords {
                                    let wRect = w.rect.offsetBy(dx: currentPageFrameInCanvas.minX, dy: currentPageFrameInCanvas.minY)
                                    unionRect = unionRect.union(wRect)
                                }
                                
                                if !unionRect.isNull {
                                    let snappedStroke = createHighlighterStroke(rect: unionRect, color: finalStroke.ink.color)
                                    modifiedStrokes.append(snappedStroke)
                                    didModify = true
                                }
                            }
                        } else {
                            modifiedStrokes.append(finalStroke)
                        }
                    } else {
                        modifiedStrokes.append(finalStroke)
                    }
                }
                
                if didModify {
                    let updatedDrawing = PKDrawing(strokes: modifiedStrokes)
                    
                    // Register undo action for the programmatic snap/straightening
                    let oldDrawing = newDrawing
                    canvasView.undoManager?.registerUndo(withTarget: canvasView) { [weak self] targetCanvas in
                        guard let self = self else { return }
                        self.isSettingDrawing = true
                        targetCanvas.drawing = oldDrawing
                        self.isSettingDrawing = false
                        self.lastDrawing = oldDrawing
                        self.scheduleDrawingSave(oldDrawing)
                    }
                    
                    isSettingDrawing = true
                    canvasView.drawing = updatedDrawing
                    isSettingDrawing = false
                    lastDrawing = updatedDrawing
                    scheduleDrawingSave(updatedDrawing)
                    return
                }
            }
            
            lastDrawing = newDrawing
            scheduleDrawingSave(newDrawing)
        }
        
        private func groupWordsIntoLines(_ words: [OCRWord]) -> [[OCRWord]] {
            let sorted = words.sorted { $0.rect.minY < $1.rect.minY }
            var lines: [[OCRWord]] = []
            
            for word in sorted {
                if var lastLine = lines.last, let firstInLine = lastLine.first {
                    let verticalOverlap = min(word.rect.maxY, firstInLine.rect.maxY) - max(word.rect.minY, firstInLine.rect.minY)
                    let minHeight = min(word.rect.height, firstInLine.rect.height)
                    if verticalOverlap > minHeight * 0.4 {
                        lastLine.append(word)
                        lines[lines.count - 1] = lastLine.sorted { $0.rect.minX < $1.rect.minX }
                    } else {
                        lines.append([word])
                    }
                } else {
                    lines.append([word])
                }
            }
            return lines
        }
        
        // MARK: - UIPencilInteractionDelegate
        
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            if let canvas = canvas {
                if canvas.drawingPolicy != .pencilOnly {
                    canvas.drawingPolicy = .pencilOnly
                }
            }
        }
        
        func textViewDidEndEditing(_ textView: UITextView) {
            if let doc = parent.allDocuments.first(where: { $0.id == parent.documentId }) {
                doc.extractedOCRText = textView.text
                try? doc.modelContext?.save()
            }
        }
        
        // MARK: - UIGestureRecognizerDelegate
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
            if isOverlayGesture(gestureRecognizer) || isOverlayGesture(otherGestureRecognizer) {
                return false
            }
            return true
        }
        
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            return true
        }
        
        private func isOverlayGesture(_ gesture: UIGestureRecognizer) -> Bool {
            guard let view = gesture.view else { return false }
            if let overlayView = overlayView {
                return view.isDescendant(of: overlayView)
            }
            return false
        }
        
        // MARK: - Update and Render Loop
        
        func update(documentData: Data, fileType: String, pageIndex: Int, isDrawingEnabled: Bool, isHighlightAssistEnabled: Bool, colorScheme: ColorScheme) {
            guard let container = container,
                  let docView = docView,
                  let overlayView = overlayView,
                  let canvas = canvas else { return }
            
            // Handle drawing enablement changes
            if lastDrawingEnabled != isDrawingEnabled {
                canvas.isDrawingActive = isDrawingEnabled
                canvas.drawingPolicy = UIPencilInteraction.prefersPencilOnlyDrawing ? .pencilOnly : .anyInput
                if isDrawingEnabled {
                    toolPicker.setVisible(true, forFirstResponder: canvas)
                    canvas.becomeFirstResponder()
                } else {
                    toolPicker.setVisible(false, forFirstResponder: canvas)
                    // Don't resignFirstResponder — just hide tool picker and let hitTest passthrough handle it.
                    // Resigning then re-becoming first responder breaks PencilKit's internal gesture state.
                }
                lastDrawingEnabled = isDrawingEnabled
                
                // Update image analysis interactions preferredInteractionTypes
                for interaction in imageAnalysisInteractions {
                    interaction.preferredInteractionTypes = isDrawingEnabled ? [] : .textSelection
                }
                
                // ponytail: disable selectable text views during drawing to prevent touch conflicts (fixes article stroke flicker)
                setTextViewsSelectable(!isDrawingEnabled, in: docView)
            }

            let highlightAssistChanged = lastHighlightAssistEnabled != isHighlightAssistEnabled
            if highlightAssistChanged {
                lastHighlightAssistEnabled = isHighlightAssistEnabled
            }
            
            let doc = parent.allDocuments.first(where: { $0.id == parent.documentId })
            let renderMode = doc?.pdfRenderMode ?? (colorScheme == .dark ? "dark" : "paper")
            let overlayIds = Set(doc?.overlays.filter { $0.parentPageIndex == pageIndex }.map { $0.id } ?? [])
            
            let scrollView = container.superview as? UIScrollView
            let viewportSize = scrollView?.bounds.size ?? .zero
            let viewportSizeChanged = lastViewportSize != viewportSize
            
            let needsRebuild = lastLoadedDocumentId != parent.documentId ||
                               lastLoadedPageIndex != pageIndex ||
                               lastLoadedColorScheme != colorScheme ||
                               lastLoadedRenderMode != renderMode ||
                               lastLoadedOverlayIds != overlayIds ||
                               container.frame.size == .zero
            
            let pageChanged = lastLoadedDocumentId != parent.documentId || lastLoadedPageIndex != pageIndex
            
            if needsRebuild {
                // Clean interactions
                imageAnalysisInteractions.removeAll()
                
                // Clean subviews
                docView.subviews.forEach { $0.removeFromSuperview() }
                
                var originalWidth: CGFloat = 612
                var originalHeight: CGFloat = 792
                
                var uiImageForOCR: UIImage?
                
                let isMerged = parent.isMerged
                let sourceTitle = parent.sourceTitle
                
                if fileType == "pdf", let pdfDoc = PDFDocument(data: documentData), pageIndex < pdfDoc.pageCount, let page = pdfDoc.page(at: pageIndex) {
                    let pageRect = page.bounds(for: .mediaBox)
                    originalWidth = pageRect.width
                    originalHeight = pageRect.height
                    
                    let pageRenderer = UIGraphicsImageRenderer(size: pageRect.size)
                    let rawPageImage = pageRenderer.image { context in
                        let cgContext = context.cgContext
                        cgContext.translateBy(x: 0, y: pageRect.size.height)
                        cgContext.scaleBy(x: 1.0, y: -1.0)
                        page.draw(with: .mediaBox, to: cgContext)
                    }
                    
                    var pdfImg = rawPageImage
                    if let ciImage = CIImage(image: rawPageImage) {
                        var filteredCI: CIImage?
                        if renderMode == "dark" {
                            filteredCI = applyDarkModeInversion(to: ciImage)
                        } else {
                            filteredCI = applyPaperTint(to: ciImage, isDarkMode: colorScheme == .dark)
                        }
                        
                        if let outCI = filteredCI,
                           let cgImage = CIContext().createCGImage(outCI, from: outCI.extent) {
                            pdfImg = UIImage(cgImage: cgImage)
                        }
                    }
                    uiImageForOCR = rawPageImage
                    self.lastUiImageForOCR = rawPageImage
                    
                    let imageView = UIImageView(image: pdfImg)
                    imageView.frame = CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight)
                    self.setupImageAnalysis(for: imageView)
                    
                    let pageContainer = UIView(frame: CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight))
                    pageContainer.addSubview(imageView)
                    
                    if isMerged {
                        let label = UILabel(frame: CGRect(x: 20, y: 15, width: originalWidth - 40, height: 25))
                        label.font = UIFont.systemFont(ofSize: 12, weight: .bold)
                        label.textColor = UIColor.gray.withAlphaComponent(0.6)
                        label.text = "Merged from: \(sourceTitle)"
                        pageContainer.addSubview(label)
                    }
                    
                    docView.addSubview(pageContainer)
                    
                } else if fileType == "blank" {
                    originalWidth = 612
                    originalHeight = 792
                    let blankView = UIView(frame: CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight))
                    blankView.backgroundColor = Theme.backgroundColorUIColor(for: colorScheme)
                    
                    if isMerged {
                        let label = UILabel(frame: CGRect(x: 20, y: 15, width: originalWidth - 40, height: 25))
                        label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
                        label.textColor = Theme.textColorUIColor(for: colorScheme).withAlphaComponent(0.4)
                        label.text = "Merged from: \(sourceTitle)"
                        blankView.addSubview(label)
                    }
                    docView.addSubview(blankView)
                    
                } else if fileType == "txt" || fileType == "md" {
                    let textWidth: CGFloat = 650
                    let padding: CGFloat = 40
                    let attrStr: NSMutableAttributedString
                    
                    if fileType == "md" {
                        let mdText = String(data: documentData, encoding: .utf8) ?? ""
                        let htmlText = parseMarkdownToHTML(mdText)
                        let htmlData = Data(htmlText.utf8)
                        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
                            .documentType: NSAttributedString.DocumentType.html,
                            .characterEncoding: String.Encoding.utf8.rawValue
                        ]
                        attrStr = NSMutableAttributedString(attributedString: (try? NSAttributedString(data: htmlData, options: options, documentAttributes: nil)) ?? NSAttributedString(string: mdText))
                    } else {
                        let text = String(data: documentData, encoding: .utf8) ?? ""
                        attrStr = NSMutableAttributedString(string: text)
                    }
                    
                    let fullRange = NSRange(location: 0, length: attrStr.length)
                    attrStr.addAttribute(.foregroundColor, value: Theme.textColorUIColor(for: colorScheme), range: fullRange)
                    attrStr.addAttribute(.font, value: UIFont.serifFont(size: 18), range: fullRange)
                    
                    let textView = self.createSelectableTextView(attributedText: attrStr)
                    
                    let size = textView.sizeThatFits(CGSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude))
                    let contentHeight = size.height + padding * 2 + (isMerged ? 40 : 0)
                    
                    originalWidth = textWidth + padding * 2
                    originalHeight = contentHeight
                    
                    let textContainer = UIView(frame: CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight))
                    textContainer.backgroundColor = Theme.backgroundColorUIColor(for: colorScheme)
                    textView.frame = CGRect(x: padding, y: padding + (isMerged ? 40 : 0), width: textWidth, height: size.height)
                    textContainer.addSubview(textView)
                    
                    if isMerged {
                        let mergeLabel = UILabel(frame: CGRect(x: padding, y: 15, width: textWidth, height: 25))
                        mergeLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
                        mergeLabel.textColor = Theme.textColorUIColor(for: colorScheme).withAlphaComponent(0.4)
                        mergeLabel.text = "Merged from: \(sourceTitle)"
                        textContainer.addSubview(mergeLabel)
                    }
                    docView.addSubview(textContainer)
                    
                } else if fileType == "docx" || fileType == "epub" {
                    originalWidth = 700
                    originalHeight = 900
                    
                    let webContainer = UIView(frame: CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight))
                    webContainer.backgroundColor = Theme.backgroundColorUIColor(for: colorScheme)
                    
                    let htmlString: String
                    if fileType == "docx" {
                        htmlString = DocxEpubParser.parseDocx(data: documentData, isDarkMode: colorScheme == .dark)
                    } else {
                        htmlString = DocxEpubParser.parseEpub(data: documentData, isDarkMode: colorScheme == .dark)
                    }
                    
                    let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight))
                    webView.backgroundColor = .clear
                    webView.isOpaque = false
                    webView.loadHTMLString(htmlString, baseURL: nil)
                    webContainer.addSubview(webView)
                    
                    if isMerged {
                        let label = UILabel(frame: CGRect(x: 20, y: 15, width: originalWidth - 40, height: 25))
                        label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
                        label.textColor = Theme.textColorUIColor(for: colorScheme).withAlphaComponent(0.4)
                        label.text = "Merged from: \(sourceTitle)"
                        webContainer.addSubview(label)
                    }
                    docView.addSubview(webContainer)
                    
                } else if fileType == "image" {
                    originalWidth = 612
                    originalHeight = 792
                    guard let uiImage = UIImage(data: documentData) else { return }
                    uiImageForOCR = uiImage
                    
                    let imgContainer = UIView(frame: CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight))
                    imgContainer.backgroundColor = Theme.backgroundColorUIColor(for: colorScheme)
                    
                    let imageHeight = originalHeight * 0.45
                    let textHeight = originalHeight * 0.43
                    
                    let isColored = doc?.sourceURL == "colored"
                    var renderedImg = uiImage
                    if !isColored, let ci = CIImage(image: uiImage) {
                        if let filter = CIFilter(name: "CIPhotoEffectMono") {
                            filter.setValue(ci, forKey: kCIInputImageKey)
                            if let out = filter.outputImage,
                               let cg = CIContext().createCGImage(out, from: out.extent) {
                                renderedImg = UIImage(cgImage: cg)
                            }
                        }
                    }
                    
                    let imageView = UIImageView(image: renderedImg)
                    imageView.contentMode = .scaleAspectFit
                    imageView.frame = CGRect(x: 20, y: isMerged ? 50 : 20, width: originalWidth - 40, height: imageHeight)
                    self.setupImageAnalysis(for: imageView)
                    imgContainer.addSubview(imageView)
                    
                    // Color toggle button with direct UIKit update
                    let toggleBtn = UIButton(type: .system)
                    toggleBtn.frame = CGRect(x: originalWidth - 50, y: (isMerged ? 50 : 20) + 10, width: 34, height: 34)
                    let iconName = isColored ? "circle.lefthalf.filled" : "camera.filters"
                    toggleBtn.setImage(UIImage(systemName: iconName), for: .normal)
                    toggleBtn.backgroundColor = Theme.textColorUIColor(for: colorScheme).withAlphaComponent(0.08)
                    toggleBtn.tintColor = Theme.textColorUIColor(for: colorScheme)
                    toggleBtn.layer.cornerRadius = 17
                    toggleBtn.addAction(UIAction { [weak self] _ in
                        guard let self = self else { return }
                        if let doc = self.parent.allDocuments.first(where: { $0.id == self.parent.documentId }) {
                            let currColored = doc.sourceURL == "colored"
                            let nextColored = !currColored
                            doc.sourceURL = nextColored ? "colored" : nil
                            try? doc.modelContext?.save()
                            
                            // In-place UI changes
                            let nextIcon = nextColored ? "circle.lefthalf.filled" : "camera.filters"
                            toggleBtn.setImage(UIImage(systemName: nextIcon), for: .normal)
                            
                            var newRendered = uiImage
                            if !nextColored, let ci = CIImage(image: uiImage) {
                                if let filter = CIFilter(name: "CIPhotoEffectMono") {
                                    filter.setValue(ci, forKey: kCIInputImageKey)
                                    if let out = filter.outputImage,
                                       let cg = CIContext().createCGImage(out, from: out.extent) {
                                        newRendered = UIImage(cgImage: cg)
                                    }
                                }
                            }
                            imageView.image = newRendered
                        }
                    }, for: .touchUpInside)
                    imgContainer.addSubview(toggleBtn)
                    
                    let textHeader = UILabel(frame: CGRect(x: 20, y: imageHeight + 40, width: originalWidth - 40, height: 20))
                    textHeader.font = UIFont.systemFont(ofSize: 11, weight: .bold)
                    textHeader.textColor = Theme.textColorUIColor(for: colorScheme).withAlphaComponent(0.5)
                    textHeader.text = "EXTRACTED OCR TEXT (EDITABLE)"
                    imgContainer.addSubview(textHeader)
                    
                    let textView = UITextView(frame: CGRect(x: 20, y: imageHeight + 65, width: originalWidth - 40, height: textHeight))
                    textView.font = UIFont.serifFont(size: 15)
                    textView.textColor = Theme.textColorUIColor(for: colorScheme)
                    textView.backgroundColor = Theme.textColorUIColor(for: colorScheme).withAlphaComponent(0.03)
                    textView.layer.cornerRadius = 8
                    textView.text = doc?.extractedOCRText ?? ""
                    textView.delegate = self
                    imgContainer.addSubview(textView)
                    
                    if isMerged {
                        let label = UILabel(frame: CGRect(x: 20, y: 15, width: originalWidth - 40, height: 25))
                        label.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
                        label.textColor = Theme.textColorUIColor(for: colorScheme).withAlphaComponent(0.4)
                        label.text = "Merged from: \(sourceTitle)"
                        imgContainer.addSubview(label)
                    }
                    docView.addSubview(imgContainer)
                    
                } else if fileType == "article" {
                    let textWidth: CGFloat = 650
                    let padding: CGFloat = 40
                    guard let article = try? JSONDecoder().decode(RichArticle.self, from: documentData) else { return }
                    
                    let stack = UIStackView()
                    stack.axis = .vertical
                    stack.spacing = 20
                    stack.alignment = .fill
                    
                    let titleLabel = self.createSelectableTextView(text: article.title, font: UIFont.serifFont(size: 28), textColor: Theme.textColorUIColor(for: colorScheme))
                    stack.addArrangedSubview(titleLabel)
                    
                    var bylineComponents: [String] = []
                    if let auth = doc?.author { bylineComponents.append("By \(auth)") }
                    if let pub = doc?.publication { bylineComponents.append(pub) }
                    
                    if !bylineComponents.isEmpty {
                        let bylineLabel = self.createSelectableTextView(text: bylineComponents.joined(separator: " • "), font: UIFont.systemFont(ofSize: 13, weight: .semibold), textColor: Theme.textColorUIColor(for: colorScheme).withAlphaComponent(0.5))
                        stack.addArrangedSubview(bylineLabel)
                    }
                    
                    for block in article.blocks {
                        switch block.type {
                        case "h1", "h2", "h3", "p":
                            let fontSize: CGFloat = block.type == "h1" ? 24 : (block.type == "h2" ? 20 : (block.type == "h3" ? 18 : 16))
                            let font = block.type.hasPrefix("h") ? UIFont.boldSystemFont(ofSize: fontSize) : UIFont.serifFont(size: fontSize)
                            let attrStr = self.parseSimpleHTML(block.text, font: font, textColor: Theme.textColorUIColor(for: colorScheme))
                            
                            let label = self.createSelectableTextView(attributedText: attrStr)
                            stack.addArrangedSubview(label)
                            
                        case "code":
                            let codeLabel = self.createSelectableTextView(text: block.text, font: UIFont.monospacedSystemFont(ofSize: 13, weight: .regular), textColor: Theme.textColorUIColor(for: colorScheme))
                            
                            let codeContainer = UIView()
                            codeContainer.backgroundColor = Theme.textColorUIColor(for: colorScheme).withAlphaComponent(0.05)
                            codeContainer.layer.cornerRadius = 6
                            codeContainer.addSubview(codeLabel)
                            
                            codeLabel.translatesAutoresizingMaskIntoConstraints = false
                            NSLayoutConstraint.activate([
                                codeLabel.topAnchor.constraint(equalTo: codeContainer.topAnchor, constant: 12),
                                codeLabel.bottomAnchor.constraint(equalTo: codeContainer.bottomAnchor, constant: -12),
                                codeLabel.leadingAnchor.constraint(equalTo: codeContainer.leadingAnchor, constant: 12),
                                codeLabel.trailingAnchor.constraint(equalTo: codeContainer.trailingAnchor, constant: -12)
                            ])
                            stack.addArrangedSubview(codeContainer)
                            
                        case "image":
                            if let docImage = doc?.images.first(where: { $0.urlString == block.imageUrl }),
                               let uiImg = UIImage(data: docImage.rawData) {
                                let containerImgView = UIView()
                                containerImgView.backgroundColor = .clear
                                
                                var rendered = uiImg
                                if !docImage.isColored, let ci = CIImage(image: uiImg) {
                                    if let filter = CIFilter(name: "CIPhotoEffectMono") {
                                        filter.setValue(ci, forKey: kCIInputImageKey)
                                        if let out = filter.outputImage,
                                           let cg = CIContext().createCGImage(out, from: out.extent) {
                                            rendered = UIImage(cgImage: cg)
                                        }
                                    }
                                }
                                
                                let imgView = UIImageView(image: rendered)
                                imgView.contentMode = .scaleAspectFit
                                imgView.layer.cornerRadius = 8
                                imgView.clipsToBounds = true
                                containerImgView.addSubview(imgView)
                                
                                let aspect = uiImg.size.height / uiImg.size.width
                                imgView.translatesAutoresizingMaskIntoConstraints = false
                                NSLayoutConstraint.activate([
                                    imgView.topAnchor.constraint(equalTo: containerImgView.topAnchor),
                                    imgView.bottomAnchor.constraint(equalTo: containerImgView.bottomAnchor),
                                    imgView.leadingAnchor.constraint(equalTo: containerImgView.leadingAnchor),
                                    imgView.trailingAnchor.constraint(equalTo: containerImgView.trailingAnchor),
                                    imgView.heightAnchor.constraint(equalTo: imgView.widthAnchor, multiplier: aspect)
                                ])
                                
                                // Direct UIKit update color toggle
                                let toggleBtn = UIButton(type: .system)
                                let iconName = docImage.isColored ? "circle.lefthalf.filled" : "camera.filters"
                                toggleBtn.setImage(UIImage(systemName: iconName), for: .normal)
                                toggleBtn.backgroundColor = Theme.textColorUIColor(for: colorScheme).withAlphaComponent(0.08)
                                toggleBtn.tintColor = Theme.textColorUIColor(for: colorScheme)
                                toggleBtn.layer.cornerRadius = 15
                                toggleBtn.addAction(UIAction { _ in
                                    docImage.isColored.toggle()
                                    try? docImage.modelContext?.save()
                                    
                                    let nextColored = docImage.isColored
                                    let nextIcon = nextColored ? "circle.lefthalf.filled" : "camera.filters"
                                    toggleBtn.setImage(UIImage(systemName: nextIcon), for: .normal)
                                    
                                    var nextRendered = uiImg
                                    if !nextColored, let ci = CIImage(image: uiImg) {
                                        if let filter = CIFilter(name: "CIPhotoEffectMono") {
                                            filter.setValue(ci, forKey: kCIInputImageKey)
                                            if let out = filter.outputImage,
                                               let cg = CIContext().createCGImage(out, from: out.extent) {
                                                nextRendered = UIImage(cgImage: cg)
                                            }
                                        }
                                    }
                                    imgView.image = nextRendered
                                }, for: .touchUpInside)
                                
                                containerImgView.addSubview(toggleBtn)
                                toggleBtn.translatesAutoresizingMaskIntoConstraints = false
                                NSLayoutConstraint.activate([
                                    toggleBtn.topAnchor.constraint(equalTo: containerImgView.topAnchor, constant: 10),
                                    toggleBtn.trailingAnchor.constraint(equalTo: containerImgView.trailingAnchor, constant: -10),
                                    toggleBtn.widthAnchor.constraint(equalToConstant: 30),
                                    toggleBtn.heightAnchor.constraint(equalToConstant: 30)
                                ])
                                
                                stack.addArrangedSubview(containerImgView)
                            }
                        default:
                            break
                        }
                    }
                    
                    let targetSize = CGSize(width: textWidth, height: UIView.layoutFittingCompressedSize.height)
                    let autoSize = stack.systemLayoutSizeFitting(targetSize, withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
                    
                    stack.frame = CGRect(x: padding, y: padding + (isMerged ? 40 : 0), width: textWidth, height: autoSize.height)
                    let contentHeight = autoSize.height + padding * 2 + (isMerged ? 40 : 0)
                    
                    originalWidth = textWidth + padding * 2
                    originalHeight = contentHeight
                    
                    let textContainer = UIView(frame: CGRect(x: 0, y: 0, width: originalWidth, height: originalHeight))
                    textContainer.backgroundColor = Theme.backgroundColorUIColor(for: colorScheme)
                    textContainer.addSubview(stack)
                    
                    if isMerged {
                        let mergeLabel = UILabel(frame: CGRect(x: padding, y: 15, width: textWidth, height: 25))
                        mergeLabel.font = UIFont.systemFont(ofSize: 12, weight: .semibold)
                        mergeLabel.textColor = Theme.textColorUIColor(for: colorScheme).withAlphaComponent(0.4)
                        mergeLabel.text = "Merged from: \(sourceTitle)"
                        textContainer.addSubview(mergeLabel)
                    }
                    docView.addSubview(textContainer)
                    
                    // ponytail: snapshot article for OCR so annotation doesn't re-render
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                        guard let self = self else { return }
                        let renderer = UIGraphicsImageRenderer(bounds: textContainer.bounds)
                        let snapshot = renderer.image { ctx in
                            textContainer.layer.render(in: ctx.cgContext)
                        }
                        self.lastUiImageForOCR = snapshot
                    }
                }
                
                // Cache the sizes and image
                lastOriginalWidth = originalWidth
                lastOriginalHeight = originalHeight
                lastUiImageForOCR = uiImageForOCR
                
                // Trigger OCR if page changed
                if pageChanged {
                    cachedWords.removeAll()
                    if isHighlightAssistEnabled, let imgOcr = uiImageForOCR {
                        runOCR(image: imgOcr)
                    } else if isHighlightAssistEnabled && (fileType == "txt" || fileType == "md" || fileType == "article") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                            guard let self = self, let dv = self.docView else { return }
                            let renderer = UIGraphicsImageRenderer(bounds: dv.bounds)
                            let docImage = renderer.image { ctx in
                                dv.layer.render(in: ctx.cgContext)
                            }
                            self.lastUiImageForOCR = docImage
                            self.runOCR(image: docImage)
                        }
                    }
                }
            }
            
            // Layout and center container if anything changed (including viewport resizing)
            if pageChanged {
                scrollView?.zoomScale = 1.0
            }
            
            let isZoomed = (scrollView?.zoomScale ?? 1.0) > 1.0
            if (needsRebuild || viewportSizeChanged) && !isZoomed {
                let originalWidth = lastOriginalWidth
                let originalHeight = lastOriginalHeight
                
                let minimumCanvasWidth = originalWidth + ZoomablePageView.pageHorizontalMargin * 2
                let containerSize = CGSize(
                    width: max(minimumCanvasWidth, viewportSize.width),
                    height: max(originalHeight, viewportSize.height)
                )
                let pageX = ZoomablePageView.pageHorizontalMargin
                let pageY: CGFloat = 0
                currentPageFrameInCanvas = CGRect(x: pageX, y: pageY, width: originalWidth, height: originalHeight)
                
                container.frame = CGRect(origin: .zero, size: containerSize)
                docView.frame = currentPageFrameInCanvas
                overlayView.frame = currentPageFrameInCanvas
                canvas.frame = CGRect(origin: .zero, size: containerSize)
                canvas.contentSize = containerSize
                
                if let scrollView {
                    scrollView.contentSize = containerSize
                    centerContainer(scrollView: scrollView, container: container)
                }
                
                lastViewportSize = viewportSize
            }
            
            // Load or sync drawing
            if pageChanged {
                canvas.undoManager?.removeAllActions()
                flushPendingDrawingSave()
                let drawing = loadDrawing()
                isSettingDrawing = true
                canvas.drawing = drawing
                isSettingDrawing = false
                lastDrawing = drawing
            }
            
            // Render overlays
            if needsRebuild || viewportSizeChanged {
                let originalWidth = lastOriginalWidth
                let originalHeight = lastOriginalHeight
                renderOverlays(for: doc, onPage: pageIndex, parentSize: CGSize(width: originalWidth, height: originalHeight))
            }
            
            // ponytail: run OCR lazily without touching layout/zoom state
            if isHighlightAssistEnabled && cachedWords.isEmpty && !needsRebuild && !ocrInProgress {
                if let imgOcr = lastUiImageForOCR {
                    runOCR(image: imgOcr)
                } else if fileType == "txt" || fileType == "md" || fileType == "article" {
                    // Use cached snapshot if available, otherwise render one off-main
                    DispatchQueue.main.async { [weak self] in
                        guard let self = self, let dv = self.docView else { return }
                        let renderer = UIGraphicsImageRenderer(bounds: dv.bounds)
                        let docImage = renderer.image { ctx in
                            dv.layer.render(in: ctx.cgContext)
                        }
                        self.lastUiImageForOCR = docImage
                        self.runOCR(image: docImage)
                    }
                }
            }
            
            // ponytail: always sync selectable text views state to match current drawing mode after layout/rebuild
            setTextViewsSelectable(!isDrawingEnabled, in: docView)
            
            lastLoadedDocumentId = parent.documentId
            lastLoadedPageIndex = pageIndex
            lastLoadedColorScheme = colorScheme
            lastLoadedRenderMode = renderMode
            lastLoadedOverlayIds = overlayIds
            
        }
        
        // MARK: - Overlays Layout, Drag & Resize
        
        private func renderOverlays(for doc: AnnoteDocument?, onPage pageIndex: Int, parentSize: CGSize) {
            guard let overlayContainer = overlayView else { return }
            overlayContainer.subviews.forEach { $0.removeFromSuperview() }
            
            guard let overlays = doc?.overlays.filter({ $0.parentPageIndex == pageIndex }) else { return }
            
            for overlay in overlays {
                let overlayWidth = overlay.width * parentSize.width
                let overlayHeight = overlay.height * parentSize.height
                let overlayFrame = CGRect(
                    x: overlay.x * parentSize.width,
                    y: overlay.y * parentSize.height,
                    width: overlayWidth,
                    height: overlayHeight
                )
                
                let itemContainer = UIView(frame: overlayFrame)
                itemContainer.backgroundColor = Theme.backgroundColorUIColor(for: parent.colorScheme)
                itemContainer.layer.cornerRadius = 8
                itemContainer.layer.shadowColor = UIColor.black.cgColor
                itemContainer.layer.shadowOpacity = 0.15
                itemContainer.layer.shadowOffset = CGSize(width: 0, height: 2)
                itemContainer.layer.shadowRadius = 4
                itemContainer.clipsToBounds = false
                
                // Add content
                let contentFrame = CGRect(x: 0, y: 0, width: overlayWidth, height: overlayHeight)
                if let imgData = overlay.imageData, let img = UIImage(data: imgData) {
                    var renderedImg = img
                    if !overlay.isColored, let ci = CIImage(image: img) {
                        if let filter = CIFilter(name: "CIPhotoEffectMono") {
                            filter.setValue(ci, forKey: kCIInputImageKey)
                            if let out = filter.outputImage,
                               let cg = CIContext().createCGImage(out, from: out.extent) {
                                renderedImg = UIImage(cgImage: cg)
                            }
                        }
                    }
                    let iv = UIImageView(image: renderedImg)
                    iv.frame = contentFrame
                    iv.contentMode = .scaleAspectFill
                    iv.clipsToBounds = true
                    iv.layer.cornerRadius = 8
                    itemContainer.addSubview(iv)
                    
                    // Direct UIKit update color toggle for image overlay
                    let toggleBtn = UIButton(type: .system)
                    let iconName = overlay.isColored ? "circle.lefthalf.filled" : "camera.filters"
                    toggleBtn.setImage(UIImage(systemName: iconName), for: .normal)
                    toggleBtn.backgroundColor = Theme.textColorUIColor(for: parent.colorScheme).withAlphaComponent(0.08)
                    toggleBtn.tintColor = Theme.textColorUIColor(for: parent.colorScheme)
                    toggleBtn.layer.cornerRadius = 12
                    toggleBtn.frame = CGRect(x: overlayWidth - 36, y: 10, width: 26, height: 26)
                    
                    toggleBtn.addAction(UIAction { [weak self] _ in
                        overlay.isColored.toggle()
                        try? overlay.modelContext?.save()
                        
                        let nextColored = overlay.isColored
                        let nextIcon = nextColored ? "circle.lefthalf.filled" : "camera.filters"
                        toggleBtn.setImage(UIImage(systemName: nextIcon), for: .normal)
                        
                        var nextRendered = img
                        if !nextColored, let ci = CIImage(image: img) {
                            if let filter = CIFilter(name: "CIPhotoEffectMono") {
                                filter.setValue(ci, forKey: kCIInputImageKey)
                                if let out = filter.outputImage,
                                   let cg = CIContext().createCGImage(out, from: out.extent) {
                                    nextRendered = UIImage(cgImage: cg)
                                }
                            }
                        }
                        iv.image = nextRendered
                    }, for: .touchUpInside)
                    itemContainer.addSubview(toggleBtn)
                } else if let sourceDocId = overlay.sourceDocumentId,
                          let sourceDoc = parent.allDocuments.first(where: { $0.id == sourceDocId }) {
                    // Page preview overlay - render actual page preview!
                    let pageIdx = overlay.sourcePageIndex ?? 0
                    if let previewImg = renderPagePreview(document: sourceDoc, pageIndex: pageIdx) {
                        let iv = UIImageView(image: previewImg)
                        iv.frame = contentFrame
                        iv.contentMode = .scaleAspectFill
                        iv.clipsToBounds = true
                        iv.layer.cornerRadius = 8
                        itemContainer.addSubview(iv)
                    } else {
                        // Fallback text card
                        let label = UILabel(frame: contentFrame)
                        label.text = "📄 \(sourceDoc.title)\nPage \(pageIdx + 1)"
                        label.numberOfLines = 0
                        label.textAlignment = .center
                        label.font = UIFont.systemFont(ofSize: 11, weight: .medium)
                        label.textColor = Theme.textColorUIColor(for: parent.colorScheme).withAlphaComponent(0.7)
                        label.backgroundColor = Theme.textColorUIColor(for: parent.colorScheme).withAlphaComponent(0.04)
                        label.layer.cornerRadius = 8
                        label.clipsToBounds = true
                        itemContainer.addSubview(label)
                    }
                }
                
                // Add drag gestures
                let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handleOverlayPan(_:)))
                panGesture.delegate = self
                itemContainer.addGestureRecognizer(panGesture)
                itemContainer.isUserInteractionEnabled = true
                
                // Add long press menu to delete
                let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleOverlayLongPress(_:)))
                longPress.delegate = self
                itemContainer.addGestureRecognizer(longPress)
                
                // Add resize handle (bottom-right corner)
                let resizeHandle = UIView(frame: CGRect(x: overlayWidth - 20, y: overlayHeight - 20, width: 20, height: 20))
                resizeHandle.backgroundColor = .clear
                
                let line1 = UIView(frame: CGRect(x: 8, y: 14, width: 8, height: 2))
                line1.backgroundColor = Theme.textColorUIColor(for: parent.colorScheme).withAlphaComponent(0.4)
                let line2 = UIView(frame: CGRect(x: 14, y: 8, width: 2, height: 8))
                line2.backgroundColor = Theme.textColorUIColor(for: parent.colorScheme).withAlphaComponent(0.4)
                resizeHandle.addSubview(line1)
                resizeHandle.addSubview(line2)
                
                itemContainer.addSubview(resizeHandle)
                
                let resizeGesture = UIPanGestureRecognizer(target: self, action: #selector(handleOverlayResize(_:)))
                resizeGesture.delegate = self
                resizeHandle.addGestureRecognizer(resizeGesture)
                resizeHandle.isUserInteractionEnabled = true
                panGesture.require(toFail: resizeGesture)
                
                itemContainer.accessibilityLabel = overlay.id.uuidString
                overlayContainer.addSubview(itemContainer)
            }
        }
        
        @objc private func handleOverlayPan(_ gesture: UIPanGestureRecognizer) {
            // Overlays are locked during annotation mode
            guard !parent.isDrawingEnabled else { gesture.isEnabled = false; gesture.isEnabled = true; return }
            guard let view = gesture.view,
                  let parentSize = docView?.frame.size,
                  let overlayIdStr = view.accessibilityLabel,
                  let overlayId = UUID(uuidString: overlayIdStr),
                  let doc = parent.allDocuments.first(where: { $0.id == parent.documentId }),
                  let overlay = doc.overlays.first(where: { $0.id == overlayId }) else { return }
            
            let translation = gesture.translation(in: docView)
            gesture.setTranslation(.zero, in: docView)
            
            var newFrame = view.frame
            newFrame.origin.x += translation.x
            newFrame.origin.y += translation.y
            
            // Constrain within bounds
            newFrame.origin.x = max(0, min(newFrame.origin.x, parentSize.width - newFrame.width))
            newFrame.origin.y = max(0, min(newFrame.origin.y, parentSize.height - newFrame.height))
            view.frame = newFrame
            
            if gesture.state == .ended || gesture.state == .cancelled {
                overlay.x = Double(newFrame.origin.x / parentSize.width)
                overlay.y = Double(newFrame.origin.y / parentSize.height)
                try? overlay.modelContext?.save()
            }
        }
        
        @objc private func handleOverlayResize(_ gesture: UIPanGestureRecognizer) {
            // Overlays are locked during annotation mode
            guard !parent.isDrawingEnabled else { gesture.isEnabled = false; gesture.isEnabled = true; return }
            guard let handle = gesture.view,
                  let view = handle.superview,
                  let parentSize = docView?.frame.size,
                  let overlayIdStr = view.accessibilityLabel,
                  let overlayId = UUID(uuidString: overlayIdStr),
                  let doc = parent.allDocuments.first(where: { $0.id == parent.documentId }),
                  let overlay = doc.overlays.first(where: { $0.id == overlayId }) else { return }
            
            let translation = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)
            
            var newFrame = view.frame
            newFrame.size.width = max(80, min(newFrame.size.width + translation.x, parentSize.width - newFrame.origin.x))
            newFrame.size.height = max(60, min(newFrame.size.height + translation.y, parentSize.height - newFrame.origin.y))
            view.frame = newFrame
            
            let contentFrame = CGRect(x: 0, y: 0, width: newFrame.width, height: newFrame.height)
            for subview in view.subviews where subview !== handle {
                if subview is UIImageView || subview is UILabel {
                    subview.frame = contentFrame
                }
            }
            
            handle.frame = CGRect(x: newFrame.width - 20, y: newFrame.height - 20, width: 20, height: 20)
            
            if gesture.state == .ended || gesture.state == .cancelled {
                overlay.width = Double(newFrame.width / parentSize.width)
                overlay.height = Double(newFrame.height / parentSize.height)
                try? overlay.modelContext?.save()
            }
        }
        
        @objc private func handleOverlayLongPress(_ gesture: UILongPressGestureRecognizer) {
            // Overlays are locked during annotation mode
            guard !parent.isDrawingEnabled else { return }
            guard gesture.state == .began,
                  let view = gesture.view,
                  let overlayIdStr = view.accessibilityLabel,
                  let overlayId = UUID(uuidString: overlayIdStr),
                  let doc = parent.allDocuments.first(where: { $0.id == parent.documentId }),
                  let overlay = doc.overlays.first(where: { $0.id == overlayId }) else { return }
            
            let alert = UIAlertController(title: "Delete Overlay", message: "Are you sure you want to remove this overlay?", preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
            alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in
                overlay.modelContext?.delete(overlay)
                try? doc.modelContext?.save()
                
                UIView.animate(withDuration: 0.2, animations: {
                    view.alpha = 0
                }) { _ in
                    view.removeFromSuperview()
                }
            })
            
            if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
               let rootVC = windowScene.windows.first?.rootViewController {
                rootVC.present(alert, animated: true)
            }
        }
        
        // MARK: - Direct Drawing SwiftData Load & Save
        
        func loadDrawing() -> PKDrawing {
            let docId = parent.documentId
            let pIdx = parent.pageIndex
            if let doc = parent.allDocuments.first(where: { $0.id == docId }) {
                if let annotation = doc.annotations.first(where: { $0.pageIndex == pIdx }) {
                    return (try? PKDrawing(data: annotation.drawingData)) ?? PKDrawing()
                }
            }
            return PKDrawing()
        }
        
        func saveDrawing(_ drawing: PKDrawing) {
            scheduleDrawingSave(drawing)
        }

        func scheduleDrawingSave(_ drawing: PKDrawing) {
            pendingDrawing = drawing
            pendingDrawingSave?.cancel()

            let workItem = DispatchWorkItem { [weak self] in
                guard let self = self, let drawing = self.pendingDrawing else { return }
                self.pendingDrawing = nil
                self.saveDrawingImmediately(drawing)
            }
            pendingDrawingSave = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: workItem)
        }

        func flushPendingDrawingSave() {
            pendingDrawingSave?.cancel()
            pendingDrawingSave = nil
            guard let drawing = pendingDrawing else { return }
            pendingDrawing = nil
            saveDrawingImmediately(drawing)
        }

        func saveDrawingImmediately(_ drawing: PKDrawing) {
            let docId = parent.documentId
            let pIdx = parent.pageIndex
            let modelContext = parent.modelContext
            
            if let doc = parent.allDocuments.first(where: { $0.id == docId }) {
                let drawingData = drawing.dataRepresentation()
                if let existing = doc.annotations.first(where: { $0.pageIndex == pIdx }) {
                    if existing.drawingData != drawingData {
                        existing.drawingData = drawingData
                        try? modelContext.save()
                    }
                } else {
                    let newAnnotation = PageAnnotation(pageIndex: pIdx, drawingData: drawingData)
                    doc.annotations.append(newAnnotation)
                    modelContext.insert(newAnnotation)
                    try? modelContext.save()
                }
            }
        }
        
        // MARK: - Text Selection Bounding Boxes & Gesture
        
        func runOCR(image: UIImage) {
            guard let cgImage = image.cgImage else { return }
            ocrInProgress = true
            let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            let request = VNRecognizeTextRequest { [weak self] request, error in
                guard let self = self,
                      let observations = request.results as? [VNRecognizedTextObservation] else {
                    DispatchQueue.main.async { self?.ocrInProgress = false }
                    return
                }
                
                let originalWidth = self.docView?.bounds.width ?? image.size.width
                let originalHeight = self.docView?.bounds.height ?? image.size.height
                
                var words: [OCRWord] = []
                for observation in observations {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let string = candidate.string
                    
                    var searchIndex = string.startIndex
                    while searchIndex < string.endIndex {
                        if let nextSpaceRange = string[searchIndex...].rangeOfCharacter(from: .whitespacesAndNewlines) {
                            let wordRange = searchIndex..<nextSpaceRange.lowerBound
                            if !wordRange.isEmpty {
                                let wordText = String(string[wordRange])
                                if let box = try? candidate.boundingBox(for: wordRange) {
                                    let x = box.boundingBox.origin.x * originalWidth
                                    let y = (1.0 - box.boundingBox.origin.y - box.boundingBox.height) * originalHeight
                                    let w = box.boundingBox.width * originalWidth
                                    let h = box.boundingBox.height * originalHeight
                                    words.append(OCRWord(text: wordText, rect: CGRect(x: x, y: y, width: w, height: h)))
                                }
                            }
                            searchIndex = nextSpaceRange.upperBound
                        } else {
                            let wordRange = searchIndex..<string.endIndex
                            if !wordRange.isEmpty {
                                let wordText = String(string[wordRange])
                                if let box = try? candidate.boundingBox(for: wordRange) {
                                    let x = box.boundingBox.origin.x * originalWidth
                                    let y = (1.0 - box.boundingBox.origin.y - box.boundingBox.height) * originalHeight
                                    let w = box.boundingBox.width * originalWidth
                                    let h = box.boundingBox.height * originalHeight
                                    words.append(OCRWord(text: wordText, rect: CGRect(x: x, y: y, width: w, height: h)))
                                }
                            }
                            break
                        }
                    }
                }
                
                words.sort { w1, w2 in
                    if abs(w1.rect.midY - w2.rect.midY) < 15 {
                        return w1.rect.minX < w2.rect.minX
                    }
                    return w1.rect.minY < w2.rect.minY
                }
                
                DispatchQueue.main.async {
                    self.cachedWords = words
                    self.ocrInProgress = false
                }
            }
            request.recognitionLevel = VNRequestTextRecognitionLevel.accurate
            DispatchQueue.global(qos: .userInitiated).async {
                try? requestHandler.perform([request])
            }
        }
        

        
        // ponytail: full rect.height for a natural human-drawn highlight feel
        private func createHighlighterStroke(rect: CGRect, color: UIColor = UIColor.systemYellow.withAlphaComponent(0.5)) -> PKStroke {
            let ink = PKInk(.marker, color: color)
            let centerY = rect.midY
            let startPoint = CGPoint(x: rect.minX, y: centerY)
            let endPoint = CGPoint(x: rect.maxX, y: centerY)
            
            let strokeWidth = rect.height * 1.3
            let size = CGSize(width: strokeWidth, height: strokeWidth)
            
            let p1 = PKStrokePoint(location: startPoint, timeOffset: 0, size: size, opacity: 1.0, force: 1.0, azimuth: 0, altitude: 0)
            let p2 = PKStrokePoint(location: endPoint, timeOffset: 0.1, size: size, opacity: 1.0, force: 1.0, azimuth: 0, altitude: 0)
            
            let strokePath = PKStrokePath(controlPoints: [p1, p2], creationDate: Date())
            return PKStroke(ink: ink, path: strokePath, transform: .identity, mask: nil)
        }
        
        private func renderPagePreview(document: AnnoteDocument, pageIndex: Int) -> UIImage? {
            if document.fileType == "pdf" {
                guard let pdfDoc = PDFDocument(data: document.fileData),
                      pageIndex < pdfDoc.pageCount,
                      let page = pdfDoc.page(at: pageIndex) else { return nil }
                let pageRect = page.bounds(for: .mediaBox)
                let renderer = UIGraphicsImageRenderer(size: pageRect.size)
                return renderer.image { context in
                    let cgContext = context.cgContext
                    cgContext.translateBy(x: 0, y: pageRect.size.height)
                    cgContext.scaleBy(x: 1.0, y: -1.0)
                    page.draw(with: .mediaBox, to: cgContext)
                }
            } else if document.fileType == "blank" {
                let size = CGSize(width: 300, height: 400)
                let renderer = UIGraphicsImageRenderer(size: size)
                return renderer.image { context in
                    UIColor.systemBackground.setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                }
            } else if document.fileType == "image" {
                return UIImage(data: document.fileData)
            } else if document.fileType == "txt" || document.fileType == "md" {
                let text = String(data: document.fileData, encoding: .utf8) ?? ""
                let size = CGSize(width: 300, height: 400)
                let renderer = UIGraphicsImageRenderer(size: size)
                return renderer.image { context in
                    UIColor.systemBackground.setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                    let font = UIFont.systemFont(ofSize: 10)
                    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: UIColor.label]
                    (text as NSString).draw(in: CGRect(x: 10, y: 10, width: 280, height: 380), withAttributes: attrs)
                }
            } else if document.fileType == "article" {
                let size = CGSize(width: 300, height: 400)
                let renderer = UIGraphicsImageRenderer(size: size)
                return renderer.image { context in
                    // Background
                    UIColor.systemBackground.setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                    
                    // Top accent bar
                    UIColor.systemBlue.withAlphaComponent(0.15).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: size.width, height: 6))
                    
                    var yOffset: CGFloat = 18
                    
                    // Article title
                    if let article = try? JSONDecoder().decode(RichArticle.self, from: document.fileData) {
                        let titleAttrs: [NSAttributedString.Key: Any] = [
                            .font: UIFont.boldSystemFont(ofSize: 13),
                            .foregroundColor: UIColor.label
                        ]
                        let titleRect = CGRect(x: 12, y: yOffset, width: 276, height: 60)
                        article.title.draw(in: titleRect, withAttributes: titleAttrs)
                        yOffset += 68
                        
                        // Byline separator
                        UIColor.separator.setFill()
                        context.fill(CGRect(x: 12, y: yOffset, width: 276, height: 1))
                        yOffset += 8
                        
                        // First few text blocks
                        let bodyAttrs: [NSAttributedString.Key: Any] = [
                            .font: UIFont.systemFont(ofSize: 9),
                            .foregroundColor: UIColor.secondaryLabel
                        ]
                        for block in article.blocks.prefix(6) where block.type == "p" || block.type.hasPrefix("h") {
                            if yOffset > 360 { break }
                            let blockRect = CGRect(x: 12, y: yOffset, width: 276, height: 30)
                            let displayText = block.text.count > 80 ? String(block.text.prefix(80)) + "…" : block.text
                            displayText.draw(in: blockRect, withAttributes: bodyAttrs)
                            yOffset += 22
                        }
                    } else {
                        // Fallback plain title
                        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 12), .foregroundColor: UIColor.label]
                        document.title.draw(in: CGRect(x: 12, y: yOffset, width: 276, height: 40), withAttributes: attrs)
                    }
                }
            } else if document.fileType == "docx" || document.fileType == "epub" {
                let size = CGSize(width: 300, height: 400)
                let renderer = UIGraphicsImageRenderer(size: size)
                return renderer.image { context in
                    UIColor.systemBackground.setFill()
                    context.fill(CGRect(origin: .zero, size: size))
                    
                    UIColor.systemOrange.withAlphaComponent(0.15).setFill()
                    context.fill(CGRect(x: 0, y: 0, width: size.width, height: 6))
                    
                    let attrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.boldSystemFont(ofSize: 13),
                        .foregroundColor: UIColor.label
                    ]
                    let typeLabel = document.fileType.uppercased()
                    let typeAttrs: [NSAttributedString.Key: Any] = [
                        .font: UIFont.systemFont(ofSize: 9, weight: .semibold),
                        .foregroundColor: UIColor.secondaryLabel
                    ]
                    typeLabel.draw(in: CGRect(x: 12, y: 16, width: 276, height: 16), withAttributes: typeAttrs)
                    document.title.draw(in: CGRect(x: 12, y: 36, width: 276, height: 60), withAttributes: attrs)
                }
            } else {
                return nil
            }
        }
        
        // MARK: - Core Image Helpers
        
        private func applyPaperTint(to ciImage: CIImage, isDarkMode: Bool) -> CIImage? {
            guard let monoFilter = CIFilter(name: "CIPhotoEffectMono") else { return nil }
            monoFilter.setValue(ciImage, forKey: kCIInputImageKey)
            guard let monoImage = monoFilter.outputImage else { return nil }
            
            guard let matrixFilter = CIFilter(name: "CIColorMatrix") else { return nil }
            
            let bgR: CGFloat = isDarkMode ? 0.12 : 0.96
            let bgG: CGFloat = isDarkMode ? 0.12 : 0.94
            let bgB: CGFloat = isDarkMode ? 0.12 : 0.91
            
            let txtR: CGFloat = isDarkMode ? 0.91 : 0.11
            let txtG: CGFloat = isDarkMode ? 0.91 : 0.11
            let txtB: CGFloat = isDarkMode ? 0.91 : 0.11
            
            matrixFilter.setValue(monoImage, forKey: kCIInputImageKey)
            matrixFilter.setValue(CIVector(x: bgR - txtR, y: 0, z: 0, w: 0), forKey: "inputRVector")
            matrixFilter.setValue(CIVector(x: 0, y: bgG - txtG, z: 0, w: 0), forKey: "inputGVector")
            matrixFilter.setValue(CIVector(x: 0, y: 0, z: bgB - txtB, w: 0), forKey: "inputBVector")
            matrixFilter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            matrixFilter.setValue(CIVector(x: txtR, y: txtG, z: txtB, w: 0), forKey: "inputBiasVector")
            
            return matrixFilter.outputImage
        }
        
        private func applyDarkModeInversion(to ciImage: CIImage) -> CIImage? {
            guard let invertFilter = CIFilter(name: "CIColorInvert") else { return nil }
            invertFilter.setValue(ciImage, forKey: kCIInputImageKey)
            return invertFilter.outputImage
        }
        
        private func centerContainer(scrollView: UIScrollView, container: UIView) {
            // ponytail: let UIScrollView handle layout completely when zoomed in to prevent view shifting
            if scrollView.zoomScale > 1.0 {
                return
            }
            
            let boundsSize = scrollView.bounds.size
            var contentsFrame = container.frame
            
            if contentsFrame.size.width < boundsSize.width {
                contentsFrame.origin.x = (boundsSize.width - contentsFrame.size.width) / 2.0
            } else {
                contentsFrame.origin.x = 0.0
            }
            
            if contentsFrame.size.height < boundsSize.height {
                contentsFrame.origin.y = (boundsSize.height - contentsFrame.size.height) / 2.0
            } else {
                contentsFrame.origin.y = 0.0
            }
            
            if container.frame != contentsFrame {
                container.frame = contentsFrame
            }
        }
        
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let container = container else { return }
            // ponytail: skip centering during active drawing to prevent view shift
            if let canvas = canvas, canvas.isFirstResponder, scrollView.isZooming { return }
            centerContainer(scrollView: scrollView, container: container)
        }
        
        // ponytail: toggle UITextView selectability and WKWebView interaction recursively
        private func setTextViewsSelectable(_ selectable: Bool, in view: UIView) {
            for sub in view.subviews {
                if let tv = sub as? UITextView {
                    tv.isSelectable = selectable
                    tv.isUserInteractionEnabled = selectable
                } else if let web = sub as? WKWebView {
                    web.isUserInteractionEnabled = selectable
                }
                setTextViewsSelectable(selectable, in: sub)
            }
        }
    }
}

// =========================================================================
// MARK: - Custom ZIP Decompressor and DOCX / EPUB Parser
// =========================================================================

struct DocxEpubParser {
    
    // Decodes ZIP archives using high-performance ZIPFoundation framework
    static func unzip(data: Data) -> [String: Data] {
        var entries: [String: Data] = [:]
        guard let archive = Archive(data: data, accessMode: .read) else {
            return [:]
        }
        
        for entry in archive {
            var entryData = Data()
            do {
                _ = try archive.extract(entry, consumer: { chunk in
                    entryData.append(chunk)
                })
                entries[entry.path] = entryData
            } catch {
                print("Failed to extract ZIP entry \(entry.path): \(error.localizedDescription)")
            }
        }
        
        return entries
    }
    
    // Parses DOCX file into fully styled HTML with inline images
    static func parseDocx(data: Data, isDarkMode: Bool) -> String {
        let entries = unzip(data: data)
        
        guard let docXmlData = entries["word/document.xml"] else {
            return "<html><body><p>Invalid DOCX file: word/document.xml missing.</p></body></html>"
        }
        
        // Parse relations
        var relations: [String: String] = [:]
        if let relsData = entries["word/_rels/document.xml.rels"] {
            let relsParser = XMLParser(data: relsData)
            let relsDelegate = DocxRelsDelegate()
            relsParser.delegate = relsDelegate
            relsParser.parse()
            relations = relsDelegate.relations
        }
        
        let docParser = XMLParser(data: docXmlData)
        let docDelegate = DocxXMLDelegate(relations: relations, zipEntries: entries)
        docParser.delegate = docDelegate
        docParser.parse()
        
        return wrapInHtmlTemplate(bodyHtml: docDelegate.htmlContent, isDarkMode: isDarkMode)
    }
    
    // Parses EPUB file into aggregated styled HTML with inline images
    static func parseEpub(data: Data, isDarkMode: Bool) -> String {
        let entries = unzip(data: data)
        
        // 1. Get container XML
        guard let containerData = entries["META-INF/container.xml"] else {
            return "<html><body><p>Invalid EPUB file: container.xml missing.</p></body></html>"
        }
        
        let containerParser = XMLParser(data: containerData)
        let containerDelegate = EpubContainerDelegate()
        containerParser.delegate = containerDelegate
        containerParser.parse()
        
        let opfPath = containerDelegate.opfPath
        guard !opfPath.isEmpty, let opfData = entries[opfPath] else {
            return "<html><body><p>Invalid EPUB file: OPF document missing.</p></body></html>"
        }
        
        // Find OPF base directory
        let opfDir: String
        if let lastSlashIndex = opfPath.lastIndex(of: "/") {
            opfDir = String(opfPath[..<lastSlashIndex]) + "/"
        } else {
            opfDir = ""
        }
        
        // 2. Parse OPF file manifest and spine
        let opfParser = XMLParser(data: opfData)
        let opfDelegate = EpubOpfDelegate()
        opfParser.delegate = opfDelegate
        opfParser.parse()
        
        var combinedHtml = ""
        
        // 3. Extract, resolve images, and combine spine files
        for spineId in opfDelegate.spine {
            guard let href = opfDelegate.manifest[spineId] else { continue }
            let fullXhtmlPath = opfDir + href
            
            guard let xhtmlData = entries[fullXhtmlPath],
                  let xhtmlStr = String(data: xhtmlData, encoding: .utf8) else { continue }
            
            // Resolve base path directory of the current xhtml page
            let xhtmlDir: String
            if let slashIndex = fullXhtmlPath.lastIndex(of: "/") {
                xhtmlDir = String(fullXhtmlPath[..<slashIndex]) + "/"
            } else {
                xhtmlDir = ""
            }
            
            if let parsedDoc = try? SwiftSoup.parse(xhtmlStr) {
                // Inline images using SwiftSoup selector
                if let imgs = try? parsedDoc.select("img") {
                    for img in imgs {
                        if let src = try? img.attr("src") {
                            let resolvedPath = resolveRelativePath(src, relativeTo: xhtmlDir)
                            if let imgData = entries[resolvedPath] {
                                let base64 = imgData.base64EncodedString()
                                let mime = resolvedPath.lowercased().hasSuffix("png") ? "image/png" : "image/jpeg"
                                try? img.attr("src", "data:\(mime);base64,\(base64)")
                            }
                        }
                    }
                }
                
                if let body = parsedDoc.body() {
                    combinedHtml += (try? body.html()) ?? ""
                }
            }
        }
        
        return wrapInHtmlTemplate(bodyHtml: combinedHtml, isDarkMode: isDarkMode)
    }
    
    private static func resolveRelativePath(_ relativePath: String, relativeTo basePath: String) -> String {
        var baseParts = basePath.split(separator: "/").map(String.init)
        let relParts = relativePath.split(separator: "/")
        
        for part in relParts {
            if part == "." {
                continue
            } else if part == ".." {
                if !baseParts.isEmpty {
                    baseParts.removeLast()
                }
            } else {
                baseParts.append(String(part))
            }
        }
        return baseParts.joined(separator: "/")
    }
    
    private static func wrapInHtmlTemplate(bodyHtml: String, isDarkMode: Bool) -> String {
        let bgHex = isDarkMode ? "#141414" : "#F5F0E8"
        let textHex = isDarkMode ? "#E8E8E8" : "#1C1C1C"
        
        return """
        <html>
        <head>
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <style>
          body {
            background-color: \(bgHex);
            color: \(textHex);
            font-family: Georgia, -apple-system, serif;
            font-size: 18px;
            line-height: 1.6;
            padding: 40px 24px;
            max-width: 650px;
            margin: 0 auto;
            word-wrap: break-word;
          }
          h1, h2, h3, h4, h5, h6 {
            font-family: -apple-system, sans-serif;
            font-weight: bold;
            margin-top: 1.5em;
            margin-bottom: 0.5em;
            color: \(textHex);
          }
          h1 { font-size: 1.6em; }
          h2 { font-size: 1.3em; }
          h3 { font-size: 1.1em; }
          p { margin-bottom: 1.2em; text-align: justify; }
          img {
            max-width: 100%;
            height: auto;
            border-radius: 8px;
            filter: grayscale(100%);
            transition: filter 0.3s ease;
            cursor: pointer;
            display: block;
            margin: 20px auto;
            box-shadow: 0 4px 10px rgba(0,0,0,0.1);
          }
          img.colorized {
            filter: grayscale(0%) !important;
          }
          pre, code {
            font-family: Menlo, monospace;
            font-size: 0.85em;
            background-color: rgba(0,0,0,0.04);
            padding: 2px 4px;
            border-radius: 4px;
          }
          pre {
            padding: 12px;
            overflow-x: auto;
            display: block;
            margin-bottom: 1.2em;
          }
        </style>
        <script>
          document.addEventListener('DOMContentLoaded', function() {
            document.addEventListener('click', function(e) {
              if (e.target.tagName === 'IMG') {
                e.target.classList.toggle('colorized');
              }
            });
          });
        </script>
        </head>
        <body>
          \(bodyHtml)
        </body>
        </html>
        """
    }
}

// MARK: - XML Parsing Delegates

class DocxRelsDelegate: NSObject, XMLParserDelegate {
    var relations: [String: String] = [:]
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "Relationship" {
            if let id = attributeDict["Id"], let target = attributeDict["Target"] {
                relations[id] = target
            }
        }
    }
}

class DocxXMLDelegate: NSObject, XMLParserDelegate {
    var htmlContent = ""
    var currentElement = ""
    var currentParagraphStyle = ""
    var currentRunIsBold = false
    var currentRunIsItalic = false
    var currentRunText = ""
    var paragraphText = ""
    
    let relations: [String: String]
    let zipEntries: [String: Data]
    
    init(relations: [String: String], zipEntries: [String: Data]) {
        self.relations = relations
        self.zipEntries = zipEntries
    }
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        
        if elementName == "w:p" {
            paragraphText = ""
            currentParagraphStyle = ""
        } else if elementName == "w:pStyle" {
            if let val = attributeDict["w:val"] {
                currentParagraphStyle = val
            }
        } else if elementName == "w:r" {
            currentRunIsBold = false
            currentRunIsItalic = false
            currentRunText = ""
        } else if elementName == "w:b" {
            currentRunIsBold = true
        } else if elementName == "w:i" {
            currentRunIsItalic = true
        } else if elementName == "a:blip" {
            if let embedId = attributeDict["r:embed"] ?? attributeDict["r:id"],
               let targetPath = relations[embedId] {
                let fullPath = targetPath.hasPrefix("word/") ? targetPath : "word/\(targetPath)"
                if let imgData = zipEntries[fullPath] ?? zipEntries[targetPath] {
                    let base64 = imgData.base64EncodedString()
                    let mime = targetPath.lowercased().hasSuffix("png") ? "image/png" : "image/jpeg"
                    paragraphText += "<img src=\"data:\(mime);base64,\(base64)\" />"
                }
            }
        }
    }
    
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "w:t" {
            currentRunText += string
        }
    }
    
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "w:t" {
            var formattedRun = currentRunText
            if currentRunIsBold { formattedRun = "<b>\(formattedRun)</b>" }
            if currentRunIsItalic { formattedRun = "<i>\(formattedRun)</i>" }
            paragraphText += formattedRun
        } else if elementName == "w:p" {
            if !paragraphText.isEmpty {
                let tag: String
                if currentParagraphStyle.contains("Heading1") { tag = "h1" }
                else if currentParagraphStyle.contains("Heading2") { tag = "h2" }
                else if currentParagraphStyle.contains("Heading3") { tag = "h3" }
                else { tag = "p" }
                
                htmlContent += "<\(tag)>\(paragraphText)</\(tag)>\n"
            }
        }
    }
}

class EpubContainerDelegate: NSObject, XMLParserDelegate {
    var opfPath = ""
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "rootfile" {
            if let path = attributeDict["full-path"] {
                opfPath = path
            }
        }
    }
}

class EpubOpfDelegate: NSObject, XMLParserDelegate {
    var manifest: [String: String] = [:]
    var spine: [String] = []
    
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "item" {
            if let id = attributeDict["id"], let href = attributeDict["href"] {
                manifest[id] = href
            }
        } else if elementName == "itemref" {
            if let idref = attributeDict["idref"] {
                spine.append(idref)
            }
        }
    }
}
import WebKit
import UIKit.UIGestureRecognizerSubclass

class PauseGestureRecognizer: UIGestureRecognizer {
    var lastLocation: CGPoint = .zero
    var startLocation: CGPoint = .zero
    var onPauseBegan: ((CGPoint, CGPoint) -> Void)? // (start, current)
    var onPauseChanged: ((CGPoint) -> Void)?
    var onPauseEnded: (() -> Void)?
    
    private var timer: Timer?
    private var isPaused = false
    
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesBegan(touches, with: event)
        guard let touch = touches.first else { return }
        startLocation = touch.location(in: view)
        lastLocation = startLocation
        isPaused = false
        resetTimer()
    }
    
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesMoved(touches, with: event)
        guard let touch = touches.first else { return }
        let loc = touch.location(in: view)
        
        let dist = distance(loc, lastLocation)
        if dist > 8 {
            lastLocation = loc
            if isPaused {
                onPauseChanged?(loc)
            } else {
                resetTimer()
            }
        }
    }
    
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesEnded(touches, with: event)
        invalidateTimer()
        if isPaused {
            onPauseEnded?()
        }
        state = .failed
    }
    
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        super.touchesCancelled(touches, with: event)
        invalidateTimer()
        if isPaused {
            onPauseEnded?()
        }
        state = .failed
    }
    
    private func resetTimer() {
        invalidateTimer()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.isPaused = true
            self.onPauseBegan?(self.startLocation, self.lastLocation)
        }
    }
    
    private func invalidateTimer() {
        timer?.invalidate()
        timer = nil
    }
    
    private func distance(_ p1: CGPoint, _ p2: CGPoint) -> CGFloat {
        let dx = p1.x - p2.x
        let dy = p1.y - p2.y
        return sqrt(dx*dx + dy*dy)
    }
}
