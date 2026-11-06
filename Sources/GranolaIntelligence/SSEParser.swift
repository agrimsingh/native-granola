import Foundation

/// Incremental Server-Sent Events parser. Feed it raw body chunks split at arbitrary byte boundaries
/// (including mid-line or mid-UTF-8 sequence); it returns the `data` payload of each completed event.
public struct SSEParser: Sendable {
    private var buffer: [UInt8] = []
    private var dataLines: [String] = []

    public init() {}

    public mutating func feed(_ chunk: Data) -> [String] {
        buffer.append(contentsOf: chunk)
        var events: [String] = []
        var lineStart = 0
        var i = 0
        while i < buffer.count {
            if buffer[i] == 0x0A {
                var end = i
                if end > lineStart, buffer[end - 1] == 0x0D { end -= 1 }
                let line = String(decoding: buffer[lineStart..<end], as: UTF8.self)
                if let event = process(line: line) { events.append(event) }
                lineStart = i + 1
            }
            i += 1
        }
        if lineStart > 0 { buffer.removeFirst(lineStart) }
        return events
    }

    /// Flushes any trailing line/event when the stream ends without a final blank line.
    public mutating func finish() -> [String] {
        var events: [String] = []
        if !buffer.isEmpty {
            var bytes = buffer[...]
            if bytes.last == 0x0D { bytes = bytes.dropLast() }
            let line = String(decoding: bytes, as: UTF8.self)
            buffer.removeAll()
            if let event = process(line: line) { events.append(event) }
        }
        if let event = dispatch() { events.append(event) }
        return events
    }

    private mutating func process(line: String) -> String? {
        if line.isEmpty { return dispatch() }
        if line.hasPrefix(":") { return nil }
        let field: Substring
        var value: Substring
        if let colon = line.firstIndex(of: ":") {
            field = line[..<colon]
            value = line[line.index(after: colon)...]
            if value.hasPrefix(" ") { value = value.dropFirst() }
        } else {
            field = line[...]
            value = ""
        }
        if field == "data" { dataLines.append(String(value)) }
        return nil
    }

    private mutating func dispatch() -> String? {
        guard !dataLines.isEmpty else { return nil }
        defer { dataLines.removeAll() }
        return dataLines.joined(separator: "\n")
    }
}
