import Foundation
import os

enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "app.plume"
    
    static let audio = Logger(subsystem: subsystem, category: "Audio")
    static let tts = Logger(subsystem: subsystem, category: "TTS")
    static let share = Logger(subsystem: subsystem, category: "Share")
    static let network = Logger(subsystem: subsystem, category: "Network")
    static let general = Logger(subsystem: subsystem, category: "General")
}
