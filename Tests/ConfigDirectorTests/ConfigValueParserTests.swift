@testable import ConfigDirector
import Foundation
import Testing

struct ConfigValueParserTests {
    @Test func servesABooleanFromABooleanConfig() {
        let result = ConfigValueParser.parse(
            .make(key: "dark-mode", type: .boolean, value: "true", valueID: "on"),
            default: false
        )

        #expect(result.value == true)
        #expect(result.usedDefault == false)
        #expect(result.reason == .foundMatch)
        #expect(result.valueID == "on")
    }

    @Test(arguments: ["TRUE", "True"]) func parsesBooleansCaseInsensitively(_ rawValue: String) {
        let result = ConfigValueParser.parse(
            .make(key: "dark-mode", type: .boolean, value: rawValue),
            default: false
        )

        #expect(result.value == true)
    }

    @Test func servesABooleanFromAStringConfig() {
        let result = ConfigValueParser.parse(
            .make(key: "dark-mode", type: .string, value: "false"),
            default: true
        )

        #expect(result.value == false)
        #expect(result.reason == .foundMatch)
    }

    @Test func rejectsABooleanFromANumericConfig() {
        let result = ConfigValueParser.parse(
            .make(key: "dark-mode", type: .integer, value: "1"),
            default: false
        )

        #expect(result.value == false)
        #expect(result.usedDefault)
        #expect(result.reason == .typeMismatch)
    }

    @Test func rejectsAValueThatIsNotABoolean() {
        let result = ConfigValueParser.parse(
            .make(key: "dark-mode", type: .boolean, value: "yes"),
            default: false
        )

        #expect(result.usedDefault)
        #expect(result.reason == .invalidBoolean)
    }

    @Test(arguments: [ConfigType.boolean, .integer, .float, .enumeration, .url, .custom])
    func servesAStringFromAnyConfigType(_ type: ConfigType) {
        let result = ConfigValueParser.parse(
            .make(key: "anything", type: type, value: "42"),
            default: ""
        )

        #expect(result.value == "42")
        #expect(result.reason == .foundMatch)
    }

    @Test func servesTheRawDocumentOfAJSONConfigAsAString() {
        let result = ConfigValueParser.parse(
            .make(key: "theme", type: .json, value: #"{"a":1}"#),
            default: ""
        )

        #expect(result.value == #"{"a":1}"#)
        #expect(result.reason == .foundMatch)
    }

    @Test func servesAnIntegerFromAnIntegerConfig() {
        let result = ConfigValueParser.parse(
            .make(key: "max-retries", type: .integer, value: "42"),
            default: 0
        )

        #expect(result.value == 42)
        #expect(result.reason == .foundMatch)
    }

    @Test func truncatesAFloatServedToAnIntegerDefault() {
        let result = ConfigValueParser.parse(
            .make(key: "max-retries", type: .float, value: "3.9"),
            default: 0
        )

        #expect(result.value == 3)
        #expect(result.reason == .foundMatch)
    }

    @Test func rejectsANumberTooLargeForAnInteger() {
        let result = ConfigValueParser.parse(
            .make(key: "max-retries", type: .float, value: "1e30"),
            default: 7
        )

        #expect(result.value == 7)
        #expect(result.reason == .invalidNumber)
    }

    @Test func servesADoubleFromAFloatConfig() {
        let result = ConfigValueParser.parse(
            .make(key: "discount-rate", type: .float, value: "0.15"),
            default: 0.0
        )

        #expect(result.value == 0.15)
        #expect(result.reason == .foundMatch)
    }

    @Test(arguments: ["abc", "inf", "nan"]) func rejectsValuesThatAreNotFiniteNumbers(_ rawValue: String) {
        let result = ConfigValueParser.parse(
            .make(key: "discount-rate", type: .float, value: rawValue),
            default: 1.5
        )

        #expect(result.value == 1.5)
        #expect(result.reason == .invalidNumber)
    }

    @Test func rejectsANumberFromABooleanConfig() {
        let result = ConfigValueParser.parse(
            .make(key: "dark-mode", type: .boolean, value: "true"),
            default: 0
        )

        #expect(result.reason == .typeMismatch)
    }

    @Test func rejectsANumberFromAJSONConfig() {
        let result = ConfigValueParser.parse(
            .make(key: "theme", type: .json, value: "42"),
            default: 0
        )

        #expect(result.reason == .typeMismatch)
    }

    @Test(arguments: [nil, ""]) func fallsBackWhenTheConfigHasNoValue(_ rawValue: String?) {
        let result = ConfigValueParser.parse(
            .make(key: "dark-mode", type: .boolean, value: rawValue),
            default: true
        )

        #expect(result.value == true)
        #expect(result.usedDefault)
        #expect(result.reason == .valueMissing)
    }

    @Test func decodesAJSONConfig() {
        let result = ConfigValueParser.parseJSON(
            .make(
                key: "theme",
                type: .json,
                value: #"{"primaryColor":"blue","cornerRadius":8}"#,
                valueID: "blue"
            ),
            as: Theme.self,
            default: Theme(primaryColor: "red", cornerRadius: 0)
        )

        #expect(result.value == Theme(primaryColor: "blue", cornerRadius: 8))
        #expect(result.valueID == "blue")
        #expect(result.reason == .foundMatch)
    }

    @Test func rejectsADocumentThatDoesNotDecode() {
        let fallback = Theme(primaryColor: "red", cornerRadius: 0)
        let result = ConfigValueParser.parseJSON(
            .make(key: "theme", type: .json, value: #"{"primaryColor":"blue"}"#),
            as: Theme.self,
            default: fallback
        )

        #expect(result.value == fallback)
        #expect(result.reason == .invalidJSON)
    }

    @Test func rejectsDecodingAConfigThatIsNotJSON() {
        let fallback = Theme(primaryColor: "red", cornerRadius: 0)
        let result = ConfigValueParser.parseJSON(
            .make(key: "theme", type: .string, value: #"{"primaryColor":"blue","cornerRadius":8}"#),
            as: Theme.self,
            default: fallback
        )

        #expect(result.value == fallback)
        #expect(result.reason == .typeMismatch)
    }
}
