//
//  AppSettings.swift
//  ViewTheWord
//
//  Centralized settings management
//

import Foundation
import SwiftUI

/// Centralized settings manager for the application
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Bible Settings
    @AppStorage("PrimaryBibleName") var primaryBibleName: String = bundledPrimaryBibleUrl?.absoluteString ?? ""
    @AppStorage("SecondaryBibleName") var secondaryBibleName: String = bundledSecondaryBibleUrl?.absoluteString ?? ""
    @AppStorage("showOnlyPrimary") var showOnlyPrimary: Bool = false

    // MARK: - Display Settings
    @AppStorage("fontSizeVerse") var fontSizeVerse: Double = 100.0
    @AppStorage("fontSizeVerseRef") var fontSizeVerseRef: Double = 20.0
    @AppStorage("vStackPadding") var vStackPadding: Double = 20.0
    @AppStorage("transparentBackground") var transparentBackground: Bool = false

    // MARK: - UI Settings
    @AppStorage("scrollTo") var scrollTo: Bool = true

    // MARK: - History
    @AppStorage("history") var history: [String] = ["John 3: 16"]

    // MARK: - API Settings
    @AppStorage("apiUrlToPost") var apiUrlToPost: URL?

    private init() {}

    /// Clears all history
    func clearHistory() {
        history.removeAll()
        logger.info("History cleared")
    }

    /// Validates API URL
    func isValidApiUrl() -> Bool {
        guard let url = apiUrlToPost,
              url.host != nil,
              url.scheme == "http" || url.scheme == "https" else {
            return false
        }
        return true
    }
}
