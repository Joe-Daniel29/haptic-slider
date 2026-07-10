//
//  DiagLog.swift
//  haptic-slider
//
//  Append-only JSONL diagnostics for debugging tick behavior across sliders.
//  One JSON object per line in ~/Library/Logs/haptic-slider-diag.jsonl —
//  readable mid-session from the CLI (the unified log is not; see memory of
//  d5aef52). Writes happen on a utility queue, so logging never blocks the
//  event monitors or haptic timing.
//

import Foundation

final class DiagLog {
    static let shared = DiagLog()

    let url: URL
    private let queue = DispatchQueue(label: "haptic.diag.log", qos: .utility)
    private var handle: FileHandle?

    private init() {
        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Logs", isDirectory: true)
        url = logs.appendingPathComponent("haptic-slider-diag.jsonl")
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    /// Append one event. Values must be JSON-encodable (String/Int/Double/Bool).
    func log(_ fields: [String: Any]) {
        var f = fields
        f["t"] = Date().timeIntervalSince1970
        queue.async { [handle] in
            guard let handle,
                  let data = try? JSONSerialization.data(withJSONObject: f, options: [.sortedKeys])
            else { return }
            try? handle.write(contentsOf: data)
            try? handle.write(contentsOf: Data([0x0A]))   // newline
        }
    }
}
