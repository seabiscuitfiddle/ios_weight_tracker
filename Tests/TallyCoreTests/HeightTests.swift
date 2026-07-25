import Foundation
import Testing
@testable import TallyCore

@Suite("Height conversion")
struct HeightConversionTests {
    @Test("converts feet and inches to centimetres")
    func toCentimeters() {
        #expect(abs(Height.centimeters(feet: 5, inches: 10) - 177.8) < 0.001)
        #expect(abs(Height.centimeters(feet: 6, inches: 0) - 182.88) < 0.001)
        #expect(Height.centimeters(feet: 0, inches: 0) == 0)
    }

    @Test("splits centimetres into whole feet and inches")
    func toFeetAndInches() {
        let split = Height.feetAndInches(fromCentimeters: 177.8)
        #expect(split.feet == 5)
        #expect(split.inches == 10)
    }

    /// The reason rounding happens on total inches: rounding the components separately would
    /// report 5′12″ here.
    @Test("rolls a rounded-up eleventh inch into the next foot")
    func rollsOverToNextFoot() {
        let split = Height.feetAndInches(fromCentimeters: 182.7)
        #expect(split.feet == 6)
        #expect(split.inches == 0)
    }

    @Test("a foot/inch round trip stays within half an inch")
    func roundTripStaysClose() {
        for centimeters in stride(from: 140.0, through: 210.0, by: 0.5) {
            let split = Height.feetAndInches(fromCentimeters: centimeters)
            let back = Height.centimeters(feet: split.feet, inches: split.inches)
            #expect(abs(back - centimeters) <= Height.centimetersPerInch / 2 + 0.001)
            #expect(split.inches < Height.inchesPerFoot)
        }
    }

    @Test("clamps a nonsensical negative height rather than reporting negative inches")
    func negativeHeight() {
        let split = Height.feetAndInches(fromCentimeters: -10)
        #expect(split.feet == 0)
        #expect(split.inches == 0)
    }
}

@Suite("Profile height unit")
struct ProfileHeightUnitTests {
    /// Profiles written before the unit was selectable have no `heightUnit` key. They must still
    /// decode — the settings row carries height and age for the goal engine.
    @Test("decodes a profile saved before height units existed as centimetres")
    func decodesLegacyProfile() throws {
        let json = """
            {"activityLevel":"light","biologicalSex":"male","heightCentimeters":178,\
            "massUnit":"pounds"}
            """
        let profile = try JSONDecoder().decode(UserProfile.self, from: Data(json.utf8))
        #expect(profile.heightUnit == .centimeters)
        #expect(profile.heightCentimeters == 178)
        #expect(profile.massUnit == .pounds)
    }

    @Test("round-trips the chosen unit")
    func roundTrips() throws {
        let profile = UserProfile(heightCentimeters: 177.8, heightUnit: .feetInches)
        let data = try JSONEncoder().encode(profile)
        #expect(try JSONDecoder().decode(UserProfile.self, from: data) == profile)
    }
}
