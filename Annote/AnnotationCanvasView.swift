//
//  AnnotationCanvasView.swift
//  Annote
//
//  Created by Raymus Lim on 30/5/24.
//

import SwiftUI
import PencilKit

struct AnnotationCanvasView: UIViewRepresentable {
    @Binding var drawing: PKDrawing
    var isDrawingEnabled: Bool
    
    func makeUIView(context: Context) -> PKCanvasView {
        let canvas = PKCanvasView()
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.delegate = context.coordinator
        
        // Dynamically set drawing policy based on system settings for Apple Pencil
        canvas.drawingPolicy = UIPencilInteraction.prefersPencilOnlyDrawing ? .pencilOnly : .anyInput
        
        context.coordinator.setupToolPicker(for: canvas)
        context.coordinator.setupPencilInteraction(for: canvas)
        
        return canvas
    }
    
    func updateUIView(_ uiView: PKCanvasView, context: Context) {
        uiView.isUserInteractionEnabled = isDrawingEnabled
        
        if isDrawingEnabled {
            context.coordinator.toolPicker.setVisible(true, forFirstResponder: uiView)
            uiView.becomeFirstResponder()
        } else {
            context.coordinator.toolPicker.setVisible(false, forFirstResponder: uiView)
            uiView.resignFirstResponder()
        }
        
        // Only update drawing if it wasn't triggered by the user sketching on the canvas itself
        if !context.coordinator.isUpdatingFromCanvas {
            if uiView.drawing != drawing {
                uiView.drawing = drawing
            }
        } else {
            // Reset the flag since the update cycle has caught up
            context.coordinator.isUpdatingFromCanvas = false
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, PKCanvasViewDelegate, PKToolPickerObserver, UIPencilInteractionDelegate {
        var parent: AnnotationCanvasView
        let toolPicker = PKToolPicker()
        var isUpdatingFromCanvas = false
        
        init(_ parent: AnnotationCanvasView) {
            self.parent = parent
        }
        
        func setupToolPicker(for canvas: PKCanvasView) {
            toolPicker.addObserver(canvas)
            toolPicker.addObserver(self)
        }
        
        func setupPencilInteraction(for canvas: PKCanvasView) {
            let pencilInteraction = UIPencilInteraction(delegate: self)
            canvas.addInteraction(pencilInteraction)
        }
        
        // MARK: - PKCanvasViewDelegate
        
        func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
            let newDrawing = canvasView.drawing
            isUpdatingFromCanvas = true
            
            DispatchQueue.main.async {
                if self.parent.drawing != newDrawing {
                    self.parent.drawing = newDrawing
                }
            }
        }
        
        // MARK: - UIPencilInteractionDelegate
        
        func pencilInteractionDidTap(_ interaction: UIPencilInteraction) {
            // Toggle drawing policy to pencil only since we have active pencil presence
            if let canvas = interaction.view as? PKCanvasView {
                if canvas.drawingPolicy != .pencilOnly {
                    canvas.drawingPolicy = .pencilOnly
                }
            }
        }
    }
}
