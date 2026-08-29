@testable import ConfigDirector
import Testing

struct ValueIDTests {
    /// The ids the other ConfigDirector SDKs derive for the same values.
    @Test(arguments: [
        ("", "6ve2WrOl3mnciB6WIL2fIa"),
        ("hello", "1MoOW7eqAPjhZeoELVwO9G"),
        (#"{"primaryColor":"blue","cornerRadius":8}"#, "0aJfn8fEPvzqgW7hj44nv0"),
        (String(repeating: "a", count: 600), "5fN8d72HXaUK6VkcOwuKTN"),
    ])
    func derivesTheSameIdEveryOtherSDKDerives(value: String, expected: String) {
        #expect(ValueID.make(for: value) == expected)
    }

    @Test func isAlwaysTwentyTwoBase62Digits() {
        let alphabet = Set("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")

        for value in (0 ..< 200).map({ "value-\($0)" }) {
            let id = ValueID.make(for: value)
            #expect(id.count == 22, "'\(value)' produced '\(id)'")
            #expect(id.allSatisfy(alphabet.contains), "'\(value)' produced '\(id)'")
        }
    }

    @Test func derivesDifferentIdsForDifferentValues() {
        #expect(ValueID.make(for: "one") != ValueID.make(for: "two"))
        #expect(ValueID.make(for: "one") == ValueID.make(for: "one"))
    }
}
