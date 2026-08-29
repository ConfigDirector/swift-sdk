@testable import ConfigDirector
import Foundation
import Testing

enum ConfigValueParserTests {
    /// Which configs each type can be read from. Between them, the two argument lists in each pair
    /// name every config type, so the matrix stays exhaustive as config types are added.
    struct ReadsFrom {
        @Test(arguments: [ConfigType.boolean, .string, .custom])
        func aBooleanIsReadFrom(_ type: ConfigType) {
            let result = ConfigValueParser.parse(.make(key: "k", type: type, value: "true"), default: false)

            #expect(result.value == true)
            #expect(result.reason == .foundMatch)
        }

        @Test(arguments: [ConfigType.integer, .float, .enumeration, .url, .json])
        func aBooleanIsNotReadFrom(_ type: ConfigType) {
            let result = ConfigValueParser.parse(.make(key: "k", type: type, value: "true"), default: false)

            #expect(result.value == false)
            #expect(result.usedDefault)
            #expect(result.reason == .typeMismatch)
        }

        /// Every config value is a string on the wire, including a JSON config's raw document.
        @Test(arguments: ConfigType.allCases)
        func aStringIsReadFromEveryConfigType(_ type: ConfigType) {
            let result = ConfigValueParser.parse(.make(key: "k", type: type, value: "42"), default: "")

            #expect(result.value == "42")
            #expect(result.reason == .foundMatch)
        }

        @Test(arguments: [ConfigType.integer, .float, .enumeration, .string, .custom])
        func anIntegerIsReadFrom(_ type: ConfigType) {
            let result = ConfigValueParser.parse(.make(key: "k", type: type, value: "42"), default: 0)

            #expect(result.value == 42)
            #expect(result.reason == .foundMatch)
        }

        @Test(arguments: [ConfigType.boolean, .url, .json])
        func anIntegerIsNotReadFrom(_ type: ConfigType) {
            let result = ConfigValueParser.parse(.make(key: "k", type: type, value: "42"), default: 7)

            #expect(result.value == 7)
            #expect(result.usedDefault)
            #expect(result.reason == .typeMismatch)
        }

        @Test(arguments: [ConfigType.integer, .float, .enumeration, .string, .custom])
        func aDoubleIsReadFrom(_ type: ConfigType) {
            let result = ConfigValueParser.parse(.make(key: "k", type: type, value: "1.5"), default: 0.0)

            #expect(result.value == 1.5)
            #expect(result.reason == .foundMatch)
        }

        @Test(arguments: [ConfigType.boolean, .url, .json])
        func aDoubleIsNotReadFrom(_ type: ConfigType) {
            let result = ConfigValueParser.parse(.make(key: "k", type: type, value: "1.5"), default: 2.5)

            #expect(result.value == 2.5)
            #expect(result.usedDefault)
            #expect(result.reason == .typeMismatch)
        }
    }

    struct Booleans {
        @Test(arguments: ["true", "TRUE", "True", "tRuE"])
        func areReadCaseInsensitively(_ rawValue: String) {
            #expect(ConfigValueParser.parse(.make(key: "k", type: .boolean, value: rawValue), default: false)
                .value == true)
        }

        @Test(arguments: ["false", "FALSE", "False"])
        func areReadCaseInsensitivelyWhenFalse(_ rawValue: String) {
            #expect(ConfigValueParser.parse(.make(key: "k", type: .boolean, value: rawValue), default: true)
                .value == false)
        }

        @Test(arguments: ["yes", "no", "1", "0", " true", "true "])
        func areRejectedWhenTheValueDoesNotSpellOne(_ rawValue: String) {
            let result = ConfigValueParser.parse(
                .make(key: "k", type: .boolean, value: rawValue),
                default: true
            )

            #expect(result.value == true)
            #expect(result.usedDefault)
            #expect(result.reason == .invalidBoolean)
        }
    }

    struct Integers {
        @Test(arguments: [("42", 42), ("-42", -42), ("0", 0), ("1e3", 1000)])
        func areReadFromWholeNumbers(rawValue: String, expected: Int) {
            let result = ConfigValueParser.parse(.make(key: "k", type: .integer, value: rawValue), default: 7)

            #expect(result.value == expected)
            #expect(result.reason == .foundMatch)
        }

        /// Truncated towards zero rather than floored, so a negative value rounds up.
        @Test(arguments: [("3.9", 3), ("-3.9", -3), ("0.9", 0), ("-0.9", 0)])
        func truncateAFloatTowardsZero(rawValue: String, expected: Int) {
            let result = ConfigValueParser.parse(.make(key: "k", type: .float, value: rawValue), default: 7)

            #expect(result.value == expected)
            #expect(result.reason == .foundMatch)
        }

        @Test(arguments: ["abc", "1e30", "-1e30", "inf", "nan", "4,2"])
        func areRejectedWhenTheValueIsNotAWholeNumberInRange(_ rawValue: String) {
            let result = ConfigValueParser.parse(.make(key: "k", type: .float, value: rawValue), default: 7)

            #expect(result.value == 7)
            #expect(result.usedDefault)
            #expect(result.reason == .invalidNumber)
        }
    }

    struct Doubles {
        @Test(arguments: [("0.15", 0.15), ("-0.15", -0.15), ("42", 42.0), ("1e-3", 0.001)])
        func areReadFromNumbers(rawValue: String, expected: Double) {
            let result = ConfigValueParser.parse(.make(key: "k", type: .float, value: rawValue), default: 1.5)

            #expect(result.value == expected)
            #expect(result.reason == .foundMatch)
        }

        @Test(arguments: ["abc", "inf", "-inf", "nan", "1,5"])
        func areRejectedWhenTheValueIsNotAFiniteNumber(_ rawValue: String) {
            let result = ConfigValueParser.parse(.make(key: "k", type: .float, value: rawValue), default: 1.5)

            #expect(result.value == 1.5)
            #expect(result.usedDefault)
            #expect(result.reason == .invalidNumber)
        }
    }

    struct MissingValues {
        @Test(arguments: ConfigType.allCases)
        func fallBackWhateverTheConfigTypeIs(_ type: ConfigType) {
            let result = ConfigValueParser.parse(.make(key: "k", type: type, value: nil), default: "fallback")

            #expect(result.value == "fallback")
            #expect(result.usedDefault)
            #expect(result.reason == .valueMissing)
        }

        @Test(arguments: [nil, ""]) func fallBackWhetherUnsetOrEmpty(_ rawValue: String?) {
            let result = ConfigValueParser.parse(
                .make(key: "k", type: .boolean, value: rawValue, valueID: "on"),
                default: true
            )

            #expect(result.value == true)
            #expect(result.reason == .valueMissing)
            #expect(result.valueID == nil, "a default value is not attributed to a served value")
        }

        @Test(arguments: [nil, ""]) func fallBackWhenDecodingAJSONConfig(_ rawValue: String?) {
            let fallback = Theme(primaryColor: "red", cornerRadius: 0)
            let result = ConfigValueParser.parseJSON(
                .make(key: "theme", type: .json, value: rawValue),
                as: Theme.self,
                default: fallback
            )

            #expect(result.value == fallback)
            #expect(result.usedDefault)
            #expect(result.reason == .valueMissing)
        }
    }

    struct ServedValueIDs {
        @Test func areCarriedThroughEveryReadableType() {
            #expect(ConfigValueParser.parse(
                .make(key: "k", type: .boolean, value: "true", valueID: "a"),
                default: false
            ).valueID == "a")
            #expect(ConfigValueParser.parse(
                .make(key: "k", type: .string, value: "hi", valueID: "b"),
                default: ""
            ).valueID == "b")
            #expect(ConfigValueParser.parse(
                .make(key: "k", type: .integer, value: "1", valueID: "c"),
                default: 0
            ).valueID == "c")
            #expect(ConfigValueParser.parse(
                .make(key: "k", type: .float, value: "1.5", valueID: "d"),
                default: 0.0
            ).valueID == "d")
        }

        @Test func areDroppedWhenTheDefaultValueIsUsed() {
            let result = ConfigValueParser.parse(
                .make(key: "k", type: .boolean, value: "yes", valueID: "a"),
                default: false
            )

            #expect(result.usedDefault)
            #expect(result.valueID == nil)
        }
    }

    struct JSONDocuments {
        private let fallback = Theme(primaryColor: "red", cornerRadius: 0)

        @Test func areDecodedIntoTheRequestedType() {
            let result = ConfigValueParser.parseJSON(
                .make(
                    key: "theme",
                    type: .json,
                    value: #"{"primaryColor":"blue","cornerRadius":8}"#,
                    valueID: "blue"
                ),
                as: Theme.self,
                default: fallback
            )

            #expect(result.value == Theme(primaryColor: "blue", cornerRadius: 8))
            #expect(result.valueID == "blue")
            #expect(result.usedDefault == false)
            #expect(result.reason == .foundMatch)
        }

        @Test(arguments: [
            #"{"primaryColor":"blue"}"#,
            #"{"primaryColor":"blue","cornerRadius":"eight"}"#,
            "not json at all",
            "[1, 2, 3]",
            "null",
        ])
        func fallBackWhenTheDocumentDoesNotDecode(_ document: String) {
            let result = ConfigValueParser.parseJSON(
                .make(key: "theme", type: .json, value: document),
                as: Theme.self,
                default: fallback
            )

            #expect(result.value == fallback)
            #expect(result.usedDefault)
            #expect(result.reason == .invalidJSON)
        }

        @Test(arguments: ConfigType.allCases.filter { $0 != .json })
        func areOnlyDecodedFromJSONConfigs(_ type: ConfigType) {
            let result = ConfigValueParser.parseJSON(
                .make(key: "theme", type: type, value: #"{"primaryColor":"blue","cornerRadius":8}"#),
                as: Theme.self,
                default: fallback
            )

            #expect(result.value == fallback)
            #expect(result.usedDefault)
            #expect(result.reason == .typeMismatch)
        }
    }

    struct TypesConformedOutsideTheSDK {
        @Test func areReadFromTheConfigsTheirKindAllows() {
            let result = ConfigValueParser.parse(
                .make(key: "rollout", type: .float, value: "12.5"),
                default: Percentage(0)
            )

            #expect(result.value == Percentage(12.5))
            #expect(result.usedDefault == false)
            #expect(result.reason == .foundMatch)
        }

        @Test func fallBackWhenTheyRejectTheValue() {
            let result = ConfigValueParser.parse(
                .make(key: "rollout", type: .float, value: "150"),
                default: Percentage(0)
            )

            #expect(result.value == Percentage(0))
            #expect(result.usedDefault)
            #expect(result.reason == .invalidNumber)
        }

        @Test func fallBackWhenTheConfigIsNotOneTheirKindReadsFrom() {
            let result = ConfigValueParser.parse(
                .make(key: "rollout", type: .boolean, value: "true"),
                default: Percentage(0)
            )

            #expect(result.usedDefault)
            #expect(result.reason == .typeMismatch)
        }
    }
}

/// A type an application could conform, to check the protocol works from outside the SDK.
private struct Percentage: ConfigValue {
    static var configValueKind: ConfigValueKind {
        .number
    }

    var value: Double

    init(_ value: Double) {
        self.value = value
    }

    init?(configValue: String) {
        guard let parsed = Double(configValue: configValue), (0 ... 100).contains(parsed) else {
            return nil
        }
        self.init(parsed)
    }
}
