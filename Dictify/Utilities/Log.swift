import Foundation
import os

/// Centralised os.Logger / os_signpost instances.
///
/// Keep subsystem aligned with the bundle identifier so log collection tools
/// (Console.app, `log stream`) filter cleanly.
enum Log {
    static let subsystem = "com.dictify.app"

    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let media = Logger(subsystem: subsystem, category: "media")
    static let api = Logger(subsystem: subsystem, category: "api")
    static let permissions = Logger(subsystem: subsystem, category: "permissions")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let pipeline = Logger(subsystem: subsystem, category: "pipeline")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let ui = Logger(subsystem: subsystem, category: "ui")

    /// Signposts for the end-to-end pipeline. Intervals:
    ///   `record`, `upload`, `refine`, `insert`.
    static let pipelineSignpost = OSSignposter(subsystem: subsystem, category: "pipeline")
}
