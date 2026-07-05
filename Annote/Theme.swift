//
//  Theme.swift
//  Annote
//
//  Created by Raymus Lim on 30/5/24.
//

import SwiftUI
import UniformTypeIdentifiers

// =========================================================================
// MARK: - UTType Extensions
// =========================================================================

extension UTType {
    static var markdown: UTType {
        UTType(filenameExtension: "md") ?? .plainText
    }
    static var docx: UTType {
        UTType(filenameExtension: "docx") ?? .data
    }
    static var epub: UTType {
        UTType(filenameExtension: "epub") ?? .data
    }
}

// =========================================================================
// MARK: - Theme System
// =========================================================================

enum Theme {
    // Light appearance
    static let lightText = Color(hex: "1C1C1C")
    static let lightBackground = Color(hex: "F8F5EF")

    // Dark appearance
    static let darkText = Color(hex: "E8E8E8")
    static let darkBackground = Color(hex: "000000")

    // UIKit equivalents
    static let lightTextUIColor = UIColor(hex: "1C1C1C")
    static let lightBackgroundUIColor = UIColor(hex: "F8F5EF")
    static let darkTextUIColor = UIColor(hex: "E8E8E8")
    static let darkBackgroundUIColor = UIColor(hex: "000000")

    static func textColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkText : lightText
    }

    static func backgroundColor(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkBackground : lightBackground
    }

    static func textColorUIColor(for colorScheme: ColorScheme) -> UIColor {
        colorScheme == .dark ? darkTextUIColor : lightTextUIColor
    }

    static func backgroundColorUIColor(for colorScheme: ColorScheme) -> UIColor {
        colorScheme == .dark ? darkBackgroundUIColor : lightBackgroundUIColor
    }

    static func readingFont(size: CGFloat = 18) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }
}

extension Font {
    static func serifFont(size: CGFloat) -> Font {
        .system(size: size, weight: .regular, design: .serif)
    }
}

// =========================================================================
// MARK: - Color Extensions
// =========================================================================

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

extension UIColor {
    convenience init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            red: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}

// =========================================================================
// MARK: - Font Extensions
// =========================================================================

extension UIFont {
    static func serifFont(size: CGFloat) -> UIFont {
        if let descriptor = UIFont.systemFont(ofSize: size, weight: .regular)
            .fontDescriptor.withDesign(.serif) {
            return UIFont(descriptor: descriptor, size: size)
        }
        return UIFont.systemFont(ofSize: size)
    }
}

// =========================================================================
// MARK: - String Extensions
// =========================================================================

extension String {
    /// Returns self if non-empty after trimming, otherwise nil.
    var presence: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
