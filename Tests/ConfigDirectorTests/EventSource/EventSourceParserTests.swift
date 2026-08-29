@testable import ConfigDirector
import Foundation
import Testing

struct EventSourceParserTests {
    private func parse(_ text: String) -> [EventSourceParser.Output] {
        var parser = EventSourceParser()
        return Array(text.utf8).compactMap { parser.consume($0) }
    }

    private func messages(_ text: String) -> [EventSourceMessage] {
        parse(text).compactMap { output in
            guard case let .message(message) = output else { return nil }
            return message
        }
    }

    @Test func dispatchesAnEventOnTheBlankLineThatEndsIt() {
        #expect(messages("data: hello\n\n") == [EventSourceMessage(data: "hello")])
    }

    @Test func doesNotDispatchWithoutATerminatingBlankLine() {
        #expect(messages("data: hello\n").isEmpty)
    }

    @Test func joinsMultipleDataLinesWithNewlines() {
        #expect(messages("data: one\ndata: two\n\n") == [EventSourceMessage(data: "one\ntwo")])
    }

    @Test func carriesTheEventType() {
        #expect(
            messages("event: put\ndata: hello\n\n")
                == [EventSourceMessage(event: "put", data: "hello")]
        )
    }

    @Test func resetsTheEventTypeBetweenEvents() {
        let dispatched = messages("event: put\ndata: one\n\ndata: two\n\n")

        #expect(dispatched == [
            EventSourceMessage(event: "put", data: "one"),
            EventSourceMessage(data: "two"),
        ])
    }

    @Test func carriesTheLastSeenIDForwardToLaterEvents() {
        let dispatched = messages("id: 1\ndata: one\n\ndata: two\n\n")

        #expect(dispatched == [
            EventSourceMessage(id: "1", data: "one"),
            EventSourceMessage(id: "1", data: "two"),
        ])
    }

    @Test func ignoresAnIDContainingANullCharacter() {
        #expect(messages("id: a\0b\ndata: hello\n\n") == [EventSourceMessage(data: "hello")])
    }

    @Test func doesNotDispatchAnEventWithNoData() {
        #expect(messages("event: ping\n\n").isEmpty)
    }

    @Test(arguments: ["\r\n", "\r", "\n"]) func acceptsEveryLineTerminator(_ terminator: String) {
        let text = "data: hello\(terminator)\(terminator)"

        #expect(messages(text) == [EventSourceMessage(data: "hello")])
    }

    @Test func treatsCRLFAsOneTerminatorRatherThanTwo() {
        // Two data lines belong to a single event. Were the CR and the LF each treated as a
        // terminator, the LF would look like the blank line that ends an event and split them.
        let dispatched = messages("data: one\r\ndata: two\r\n\r\n")

        #expect(dispatched == [EventSourceMessage(data: "one\ntwo")])
    }

    @Test func stripsOnlyOneSpaceAfterTheColon() {
        #expect(messages("data:  hello\n\n") == [EventSourceMessage(data: " hello")])
    }

    @Test func acceptsAFieldWithNoSpaceAfterTheColon() {
        #expect(messages("data:hello\n\n") == [EventSourceMessage(data: "hello")])
    }

    @Test func treatsALineWithNoColonAsAFieldWithAnEmptyValue() {
        #expect(messages("data\ndata: hello\n\n") == [EventSourceMessage(data: "\nhello")])
    }

    @Test func reportsComments() {
        #expect(parse(": keep-alive\n") == [.comment("keep-alive")])
    }

    @Test func reportsTheServerRetryInterval() {
        #expect(parse("retry: 2500\n") == [.retry(2.5)])
    }

    @Test(arguments: ["abc", "2.5", "", "-1"]) func ignoresARetryThatIsNotDigits(_ value: String) {
        #expect(parse("retry: \(value)\n").isEmpty)
    }

    @Test func stripsALeadingByteOrderMark() {
        #expect(messages("\u{FEFF}data: hello\n\n") == [EventSourceMessage(data: "hello")])
    }

    @Test func doesNotSwallowAFirstByteThatIsNotAByteOrderMark() {
        #expect(messages("data: hello\n\n") == [EventSourceMessage(data: "hello")])
    }

    @Test func recoversAfterAPartialByteOrderMarkCorruptsTheFirstLine() {
        var parser = EventSourceParser()
        // The first two bytes of a byte order mark, and then something that is not one. They are
        // put back rather than dropped, which corrupts that line's field name but nothing after it.
        let bytes: [UInt8] = [0xEF, 0xBB] + Array("data: one\n\ndata: two\n\n".utf8)

        let dispatched = bytes.compactMap { parser.consume($0) }

        #expect(dispatched == [.message(EventSourceMessage(data: "two"))])
    }

    @Test func decodesMultiByteCharactersSplitAcrossReads() {
        // Every byte is fed separately, so a character spanning several of them can only decode if
        // the parser waits for the whole line.
        #expect(messages("data: caffè ☕️\n\n") == [EventSourceMessage(data: "caffè ☕️")])
    }

    @Test func discardsAPartialEventWhenTheStreamEnds() {
        var parser = EventSourceParser()
        for byte in Array("data: hello\n".utf8) {
            _ = parser.consume(byte)
        }

        parser.finish()

        let afterFinish = Array("\n".utf8).compactMap { parser.consume($0) }
        #expect(afterFinish.isEmpty)
    }
}
