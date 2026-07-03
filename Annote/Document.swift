//
//  Document.swift
//  Annote
//
//  Created by Raymus Lim on 30/5/24.
//

import Foundation
import SwiftData

@Model
final class AnnoteDocument {
    @Attribute(.unique) var id: UUID
    var title: String
    var createdAt: Date
    var fileType: String // "pdf", "txt", "article", "blank", "md", "docx", "epub", "image"
    var sourceURL: String?
    var author: String?
    var publication: String?
    var extractedOCRText: String?
    
    // PDF dual rendering mode preference ("paper" or "dark")
    var pdfRenderMode: String?
    
    // JSON-encoded dictionary of custom page names [Int: String]
    var customPageNamesJSON: String?
    
    // Sort metadata
    var lastOpenedAt: Date?
    
    // Bookmarks JSON list [Int]
    var bookmarkedPagesJSON: String?
    
    // Page deletion keys ("\(documentId)-\(pageIndex)")
    var deletedPageKeysJSON: String?
    
    // JSON-encoded manual outline items
    var manualOutlineJSON: String?
    
    var folder: AnnoteFolder?
    
    // External storage attribute to prevent database bloat for large PDF binaries
    @Attribute(.externalStorage) var fileData: Data
    
    @Relationship(deleteRule: .cascade, inverse: \PageAnnotation.document)
    var annotations: [PageAnnotation] = []
    
    @Relationship(deleteRule: .cascade, inverse: \DocumentImage.document)
    var images: [DocumentImage] = []
    
    @Relationship(deleteRule: .cascade, inverse: \DocumentMerge.targetDocument)
    var merges: [DocumentMerge] = []
    
    @Relationship(deleteRule: .cascade, inverse: \PageImageOverlay.document)
    var overlays: [PageImageOverlay] = []
    
    init(id: UUID = UUID(), title: String, createdAt: Date = Date(), fileType: String, fileData: Data, sourceURL: String? = nil, author: String? = nil, publication: String? = nil, extractedOCRText: String? = nil, pdfRenderMode: String? = nil, customPageNamesJSON: String? = nil, lastOpenedAt: Date? = nil, bookmarkedPagesJSON: String? = nil, deletedPageKeysJSON: String? = nil, manualOutlineJSON: String? = nil, folder: AnnoteFolder? = nil) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.fileType = fileType
        self.fileData = fileData
        self.sourceURL = sourceURL
        self.author = author
        self.publication = publication
        self.extractedOCRText = extractedOCRText
        self.pdfRenderMode = pdfRenderMode
        self.customPageNamesJSON = customPageNamesJSON
        self.lastOpenedAt = lastOpenedAt ?? createdAt
        self.bookmarkedPagesJSON = bookmarkedPagesJSON
        self.deletedPageKeysJSON = deletedPageKeysJSON
        self.manualOutlineJSON = manualOutlineJSON
        self.folder = folder
    }
    
    // Computed property for page names helper
    var customPageNames: [Int: String] {
        get {
            guard let data = customPageNamesJSON?.data(using: .utf8),
                  let dict = try? JSONDecoder().decode([Int: String].self, from: data) else {
                return [:]
            }
            return dict
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let str = String(data: data, encoding: .utf8) {
                customPageNamesJSON = str
            }
        }
    }
    
    // Computed property for bookmarks helper
    var bookmarkedPages: Set<Int> {
        get {
            guard let data = bookmarkedPagesJSON?.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([Int].self, from: data) else {
                return []
            }
            return Set(arr)
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue)),
               let str = String(data: data, encoding: .utf8) {
                bookmarkedPagesJSON = str
            }
        }
    }

    // Computed property for deleted pages helper
    var deletedPageKeys: Set<String> {
        get {
            guard let data = deletedPageKeysJSON?.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([String].self, from: data) else {
                return []
            }
            return Set(arr)
        }
        set {
            if let data = try? JSONEncoder().encode(Array(newValue)),
               let str = String(data: data, encoding: .utf8) {
                deletedPageKeysJSON = str
            }
        }
    }

    // Computed property for manual outline items helper
    var manualOutline: [ManualOutlineItem] {
        get {
            guard let data = manualOutlineJSON?.data(using: .utf8),
                  let arr = try? JSONDecoder().decode([ManualOutlineItem].self, from: data) else {
                return []
            }
            return arr
        }
        set {
            if let data = try? JSONEncoder().encode(newValue),
               let str = String(data: data, encoding: .utf8) {
                manualOutlineJSON = str
            }
        }
    }
}

struct ManualOutlineItem: Codable, Identifiable {
    var id = UUID()
    var title: String
    var pageIndex: Int
    var indentLevel: Int = 0
}

@Model
final class AnnoteFolder {
    @Attribute(.unique) var id: UUID
    var name: String
    var createdAt: Date
    
    @Relationship(deleteRule: .nullify, inverse: \AnnoteDocument.folder)
    var documents: [AnnoteDocument] = []
    
    init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
    }
}

@Model
final class PageImageOverlay {
    @Attribute(.unique) var id: UUID
    var parentPageIndex: Int
    
    // Drag & scale properties
    var x: Double
    var y: Double
    var width: Double
    var height: Double
    
    // Either image overlay or page overlay
    @Attribute(.externalStorage) var imageData: Data?
    var sourceDocumentId: UUID?
    var sourcePageIndex: Int?
    
    var isColored: Bool = false
    
    var document: AnnoteDocument?
    
    init(id: UUID = UUID(), parentPageIndex: Int, x: Double, y: Double, width: Double, height: Double, imageData: Data? = nil, sourceDocumentId: UUID? = nil, sourcePageIndex: Int? = nil, isColored: Bool = false) {
        self.id = id
        self.parentPageIndex = parentPageIndex
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.imageData = imageData
        self.sourceDocumentId = sourceDocumentId
        self.sourcePageIndex = sourcePageIndex
        self.isColored = isColored
    }
}

@Model
final class PageAnnotation {
    @Attribute(.unique) var id: UUID
    var pageIndex: Int
    
    // External storage attribute to prevent database bloat for complex drawings
    @Attribute(.externalStorage) var drawingData: Data // PKDrawing.dataRepresentation()
    
    var document: AnnoteDocument?
    
    init(id: UUID = UUID(), pageIndex: Int, drawingData: Data) {
        self.id = id
        self.pageIndex = pageIndex
        self.drawingData = drawingData
    }
}

@Model
final class DocumentImage {
    @Attribute(.unique) var id: UUID
    var urlString: String
    @Attribute(.externalStorage) var rawData: Data
    var isColored: Bool = false
    var document: AnnoteDocument?
    
    init(id: UUID = UUID(), urlString: String, rawData: Data, isColored: Bool = false) {
        self.id = id
        self.urlString = urlString
        self.rawData = rawData
        self.isColored = isColored
    }
}

@Model
final class DocumentMerge {
    @Attribute(.unique) var id: UUID
    var sourceDocumentId: UUID
    var insertAfterPageIndex: Int
    var sourceTitle: String
    var targetDocument: AnnoteDocument?
    
    init(id: UUID = UUID(), sourceDocumentId: UUID, insertAfterPageIndex: Int, sourceTitle: String) {
        self.id = id
        self.sourceDocumentId = sourceDocumentId
        self.insertAfterPageIndex = insertAfterPageIndex
        self.sourceTitle = sourceTitle
    }
}
