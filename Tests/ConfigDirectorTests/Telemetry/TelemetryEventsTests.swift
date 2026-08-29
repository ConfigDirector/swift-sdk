@testable import ConfigDirector
import Foundation
import Testing

struct TelemetryValueTests {
    private let long = String(repeating: "a", count: TelemetryValue.maxLength + 1)

    @Test func reportsASmallValueInline() {
        let compacted = TelemetryValue(value: "Hello", type: .string).compacted()

        #expect(compacted == TelemetryValue(value: "Hello"))
    }

    @Test func reportsASmallValueInlineEvenWhenTheServerSentAnID() {
        let compacted = TelemetryValue(value: "Hello", valueID: "v1", type: .string).compacted()

        #expect(compacted == TelemetryValue(value: "Hello"))
    }

    @Test func reportsALongValueByTheIDTheServerSent() {
        let compacted = TelemetryValue(value: long, valueID: "v1", type: .string).compacted()

        #expect(compacted == TelemetryValue(valueID: "v1"))
    }

    @Test func reportsALongValueByADerivedIDWhenTheServerSentNone() {
        let compacted = TelemetryValue(value: long, type: .string).compacted()

        #expect(compacted == TelemetryValue(valueID: ValueID.make(for: long)))
    }

    @Test func alwaysReportsAJSONDocumentByID() {
        let document = #"{"primaryColor":"blue"}"#

        #expect(
            TelemetryValue(value: document, valueID: "v1", type: .json).compacted()
                == TelemetryValue(valueID: "v1")
        )
        #expect(
            TelemetryValue(value: document, type: .json).compacted()
                == TelemetryValue(valueID: ValueID.make(for: document))
        )
    }

    @Test func reportsNothingWhenThereIsNoValueAndNoID() {
        #expect(TelemetryValue(type: .string).compacted() == TelemetryValue())
        #expect(TelemetryValue(value: "", type: .string).compacted() == TelemetryValue())
    }

    @Test func reportsTheIDWhenThereIsNoValue() {
        #expect(TelemetryValue(valueID: "v1", type: .string).compacted() == TelemetryValue(valueID: "v1"))
    }

    @Test func dropsTheTypeOnceCompacted() throws {
        let encoded = try JSONEncoder().encode(TelemetryValue(value: "Hello", type: .string).compacted())

        #expect(String(decoding: encoded, as: UTF8.self) == #"{"value":"Hello"}"#)
    }
}

struct EvaluatedConfigEventTests {
    private func makeEvent(key: String = "dark-mode", value: String = "true") -> EvaluatedConfigEvent {
        EvaluatedConfigEvent(
            contextID: "user-1",
            key: key,
            type: .boolean,
            defaultValue: TelemetryValue(value: "false", type: .boolean),
            requestedType: "Bool",
            evaluatedValue: TelemetryValue(value: value, valueID: "on", type: .boolean),
            evaluatedValueID: "on",
            usedDefault: false,
            evaluationReason: .foundMatch
        )
    }

    @Test func compactsBothOfItsValues() {
        let long = String(repeating: "a", count: TelemetryValue.maxLength + 1)
        let compacted = makeEvent(value: long).compacted()

        #expect(compacted.evaluatedValue == TelemetryValue(valueID: "on"))
        #expect(compacted.defaultValue == TelemetryValue(value: "false"))
        #expect(compacted.key == "dark-mode")
        #expect(compacted.evaluatedValueID == "on")
    }

    @Test func identicalEvaluationsCollapseTogether() {
        #expect(makeEvent() == makeEvent())
        #expect(makeEvent(key: "other") != makeEvent())
        #expect(Set([makeEvent(), makeEvent(), makeEvent(key: "other")]).count == 2)
    }

    @Test func encodesTheFieldsTheServerExpects() throws {
        let encoded = try JSONEncoder().encode(makeEvent().compacted())
        let payload = try JSONDecoder().decode(TelemetryReport.ReportedEvaluation.self, from: encoded)

        #expect(payload.contextId == "user-1")
        #expect(payload.key == "dark-mode")
        #expect(payload.type == "boolean")
        #expect(payload.requestedType == "Bool")
        #expect(payload.defaultValue.value == "false")
        #expect(payload.evaluatedValue.value == "true")
        #expect(payload.evaluatedValueId == "on")
        #expect(payload.usedDefault == false)
        #expect(payload.evaluationReason == "found-match")
    }
}
