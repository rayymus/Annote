//
//  AnnoteApp.swift
//  Annote
//
//  Created by Raymus Lim on 30/5/24.
//

import SwiftUI
import SwiftData

@main
struct AnnoteApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(for: [AnnoteDocument.self, PageAnnotation.self, DocumentImage.self, DocumentMerge.self, PageImageOverlay.self, AnnoteFolder.self])
    }
}
