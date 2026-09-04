@testable import ConfigDirector
import Foundation
import Testing

struct ConfigDirectorContextTests {
    @Test func encodesEveryTraitValueKind() throws {
        let context = ConfigDirectorContext(
            id: "user-1",
            name: "Ada",
            traits: [
                "plan": "pro",
                "seats": 12,
                "score": 0.5,
                "beta": true,
                "regions": ["us", "eu"],
                "address": ["city": "Lima"],
                "nickname": nil,
            ],
            isAnonymous: false
        )

        let encoded = try JSONEncoder().encode(context)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        #expect(json["id"] as? String == "user-1")
        #expect(json["name"] as? String == "Ada")
        #expect(json["anonymous"] as? Bool == false)
        let traits = try #require(json["traits"] as? [String: Any])
        #expect(traits["plan"] as? String == "pro")
        #expect(traits["seats"] as? Int == 12)
        #expect(traits["score"] as? Double == 0.5)
        #expect(traits["beta"] as? Bool == true)
        #expect(traits["regions"] as? [String] == ["us", "eu"])
        #expect(traits["address"] as? [String: String] == ["city": "Lima"])
        #expect(traits["nickname"] is NSNull)
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func encodesANonFiniteDoubleTraitAsNull(value: Double) throws {
        let context = ConfigDirectorContext(traits: ["score": .double(value), "nested": [.double(value)]])

        let encoded = try JSONEncoder().encode(context)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])

        let traits = try #require(json["traits"] as? [String: Any])
        #expect(traits["score"] is NSNull)
        #expect((traits["nested"] as? [Any])?.first is NSNull)
    }
}
