import Foundation
import os

/// Signposts only: no per-frame console output or document content.
enum StabilityTrace {
    private static let log = OSLog(subsystem: "saumyapatel.Plume", category: "Stability")

    static func begin(_ name: StaticString, revision: Int = 0, reason: String = "") -> OSSignpostID {
        #if DEBUG
        let id = OSSignpostID(log: log)
        os_signpost(.begin, log: log, name: name, signpostID: id,
                    "revision=%ld reason=%{public}@", revision, reason as NSString)
        return id
        #else
        return .invalid
        #endif
    }

    static func end(_ name: StaticString, _ id: OSSignpostID) {
        #if DEBUG
        os_signpost(.end, log: log, name: name, signpostID: id)
        #endif
    }

    static func identity(_ name: StaticString, _ object: AnyObject) {
        #if DEBUG
        os_signpost(.event, log: log, name: name, "object=%{public}@", String(describing: ObjectIdentifier(object)) as NSString)
        #endif
    }
}
