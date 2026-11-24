import OSLog

/// Local-only structured logging. Never log screenshots, OCR text, prompts, AI replies,
/// API keys, or URL query strings.
package enum AppLog {
    private static let subsystem = AppPaths.bundleIdentifier

    package static let app = Logger(subsystem: subsystem, category: "App")
    package static let capture = Logger(subsystem: subsystem, category: "Capture")
    package static let scroll = Logger(subsystem: subsystem, category: "Scroll")
    package static let ocr = Logger(subsystem: subsystem, category: "OCR")
    package static let ai = Logger(subsystem: subsystem, category: "AI")
    package static let settings = Logger(subsystem: subsystem, category: "Settings")
    package static let security = Logger(subsystem: subsystem, category: "Security")
}
