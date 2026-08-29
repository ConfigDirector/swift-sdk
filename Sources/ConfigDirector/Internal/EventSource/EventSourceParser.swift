import Foundation

/// Turns a byte stream into server-sent events.
///
/// Bytes are fed in one at a time rather than in chunks so that a multi-byte character split across
/// two network reads cannot be mis-decoded: line terminators are ASCII, and UTF-8 is
/// self-synchronizing, so a line is only decoded once it is known to be complete.
struct EventSourceParser {
    enum Output: Sendable, Equatable {
        case message(EventSourceMessage)
        case comment(String)
        case retry(TimeInterval)
    }

    private enum ByteOrderMarkState: Equatable {
        case scanning(matched: Int)
        case done
    }

    private static let byteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]
    private static let lineFeed: UInt8 = 0x0A
    private static let carriageReturn: UInt8 = 0x0D
    private static let space: UInt8 = 0x20

    private var byteOrderMarkState = ByteOrderMarkState.scanning(matched: 0)
    private var line: [UInt8] = []
    private var sawCarriageReturn = false
    private var currentEvent: String?
    private var currentData = ""

    private(set) var lastEventID: String?

    mutating func consume(_ byte: UInt8) -> Output? {
        if case let .scanning(matched) = byteOrderMarkState {
            if byte == Self.byteOrderMark[matched] {
                let next = matched + 1
                byteOrderMarkState = next == Self.byteOrderMark.count ? .done : .scanning(matched: next)
                return nil
            }
            // Not a byte order mark after all, so the bytes held back are ordinary content.
            line.append(contentsOf: Self.byteOrderMark.prefix(matched))
            byteOrderMarkState = .done
        }

        switch byte {
        case Self.lineFeed:
            // The line feed of a CRLF pair was already handled by the carriage return.
            guard !sawCarriageReturn else {
                sawCarriageReturn = false
                return nil
            }
            return dispatchLine()
        case Self.carriageReturn:
            sawCarriageReturn = true
            return dispatchLine()
        default:
            sawCarriageReturn = false
            line.append(byte)
            return nil
        }
    }

    /// Discards whatever is buffered. An event needs a terminating blank line to be dispatched, so
    /// anything left when the stream ends is incomplete by definition.
    mutating func finish() {
        line.removeAll(keepingCapacity: false)
        currentEvent = nil
        currentData = ""
    }

    private mutating func dispatchLine() -> Output? {
        let text = String(decoding: line, as: UTF8.self)
        line.removeAll(keepingCapacity: true)

        if text.isEmpty {
            return emitEvent()
        }

        if text.hasPrefix(":") {
            return .comment(value(of: text, from: text.index(after: text.startIndex)))
        }

        return applyField(text)
    }

    private mutating func applyField(_ text: String) -> Output? {
        let field: Substring
        let value: String
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = self.value(of: text, from: text.index(after: colon))
        } else {
            field = text[...]
            value = ""
        }

        switch field {
        case "event":
            currentEvent = value
        case "data":
            currentData += value + "\n"
        case "id":
            // The spec singles out null characters as the one id value to ignore.
            if !value.contains("\0") {
                lastEventID = value
            }
        case "retry":
            if let milliseconds = retryMilliseconds(value) {
                return .retry(TimeInterval(milliseconds) / 1000)
            }
        default:
            break
        }

        return nil
    }

    private mutating func emitEvent() -> Output? {
        var data = currentData
        if data.hasSuffix("\n") {
            data.removeLast()
        }

        let event = currentEvent
        currentEvent = nil
        currentData = ""

        guard !data.isEmpty else { return nil }

        return .message(EventSourceMessage(id: lastEventID, event: event, data: data))
    }

    /// A single space after the colon is part of the syntax rather than the value.
    private func value(of text: String, from start: String.Index) -> String {
        guard start < text.endIndex, text.utf8[start] == Self.space else {
            return String(text[start...])
        }
        return String(text[text.index(after: start)...])
    }

    private func retryMilliseconds(_ value: String) -> Int? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(value)
    }
}
