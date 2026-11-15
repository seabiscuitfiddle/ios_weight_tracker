import Foundation
import Testing
@testable import TallyCore

/// Byte sequences here are either quoted from captures in the Python client this protocol was
/// ported from, or built from its documented layout — see `ESF24Protocol`.
@Suite("ESF-24 protocol")
struct ESF24ProtocolTests {
    /// A measurement frame: `10 0b <vendor> <kg×100 BE> <status> <r50k BE> <r500k BE> <sum>`.
    static func measurementFrame(
        centikilograms: UInt16, final: Bool, vendor: UInt8 = 0x15,
        r50: UInt16 = 0, r500: UInt16 = 0
    ) -> [UInt8] {
        ESF24Protocol.withChecksum([
            0x10, 0x0B, vendor,
            UInt8(centikilograms >> 8), UInt8(centikilograms & 0xFF),
            final ? 0x01 : 0x00,
            UInt8(r50 >> 8), UInt8(r50 & 0xFF),
            UInt8(r500 >> 8), UInt8(r500 & 0xFF),
        ])
    }

    static func unitRequest(vendor: UInt8 = 0x15) -> [UInt8] {
        ESF24Protocol.withChecksum([0x12, 0x0F, vendor] + Array(repeating: 0, count: 11))
    }

    static let measurementInitRequest: [UInt8] =
        ESF24Protocol.withChecksum([0x14, 0x0B, 0x15] + Array(repeating: 0, count: 7))

    // MARK: Commands

    @Test("the display-unit command matches the captured vendor command, per unit")
    func displayUnitCommand() {
        // The capture is `13 09 15 00 10 28 37 00 a0`; the unit lives in byte 3's low nibble.
        #expect(ESF24Protocol.displayUnitCommand(.kilograms, vendorByte: 0x15)
            == [0x13, 0x09, 0x15, 0x01, 0x10, 0x28, 0x37, 0x00, 0xA1])
        #expect(ESF24Protocol.displayUnitCommand(.pounds, vendorByte: 0x15)
            == [0x13, 0x09, 0x15, 0x02, 0x10, 0x28, 0x37, 0x00, 0xA2])
    }

    @Test("commands echo the scale's vendor byte")
    func echoesVendorByte() {
        #expect(ESF24Protocol.endMeasurementCommand(vendorByte: 0x15) == [0x1F, 0x05, 0x15, 0x10, 0x49])
        #expect(ESF24Protocol.endMeasurementCommand(vendorByte: 0xFF) == [0x1F, 0x05, 0xFF, 0x10, 0x33])
    }

    @Test("the clock is sent little-endian, in seconds from the vendor's epoch")
    func setTimeCommand() {
        let date = Date(timeIntervalSince1970: ESF24Protocol.epochOffset + 0x0102_0304)
        #expect(ESF24Protocol.setTimeCommand(at: date, vendorByte: 0x15)
            == [0x20, 0x08, 0x15, 0x04, 0x03, 0x02, 0x01, 0x47])
    }

    // MARK: Parsing

    @Test("reads a final frame's weight and impedance")
    func parsesFinalFrame() {
        let frame = Self.measurementFrame(centikilograms: 8_234, final: true, r50: 512, r500: 480)
        #expect(ESF24Protocol.parse(frame, vendorByte: 0x15) == .finalMeasurement(
            ESF24Measurement(kilograms: 82.34, impedance50kHz: 512, impedance500kHz: 480)
        ))
    }

    @Test("an impedance the scale didn't measure is absent, not zero")
    func zeroImpedanceIsAbsent() {
        let frame = Self.measurementFrame(centikilograms: 7_000, final: true)
        guard case .finalMeasurement(let m) = ESF24Protocol.parse(frame, vendorByte: 0x15) else {
            Issue.record("expected a final measurement")
            return
        }
        #expect(m.impedance50kHz == nil)
        #expect(m.impedance500kHz == nil)
    }

    @Test("a settling frame carries no reading")
    func settlingFrame() {
        let frame = Self.measurementFrame(centikilograms: 8_100, final: false)
        #expect(ESF24Protocol.parse(frame, vendorByte: 0x15) == .settling)
    }

    @Test("accepts the 12-byte firmware variant of the measurement frame")
    func longerMeasurementFrame() {
        var frame = Self.measurementFrame(centikilograms: 8_000, final: true)
        frame.insert(0x00, at: 10)
        #expect(ESF24Protocol.parse(frame, vendorByte: 0x15)
            == .finalMeasurement(ESF24Measurement(kilograms: 80)))
    }

    @Test("recognises both captured shapes of the set-time ack")
    func setTimeAck() {
        #expect(ESF24Protocol.parse([0x21, 0x05, 0x15, 0x01, 0x3C], vendorByte: 0x15) == .setTimeAck)
        #expect(ESF24Protocol.parse([0x21, 0x04, 0xFF, 0x01, 0x25], vendorByte: 0xFF) == .setTimeAck)
    }

    @Test("a frame with another scale's vendor byte is ignored")
    func wrongVendorByte() {
        let frame = Self.measurementFrame(centikilograms: 8_000, final: true, vendor: 0xFF)
        #expect(ESF24Protocol.parse(frame, vendorByte: 0x15) == .unrecognized)
    }

    @Test("short and empty payloads are unrecognised rather than a crash")
    func shortPayloads() {
        #expect(ESF24Protocol.parse([], vendorByte: 0x15) == .unrecognized)
        #expect(ESF24Protocol.parse([0x10, 0x0B, 0x15, 0x20], vendorByte: 0x15) == .unrecognized)
    }

    @Test("plausibility screens out things that aren't a person")
    func plausibility() {
        #expect(ESF24Measurement(kilograms: 82).isPlausibleBodyWeight)
        #expect(!ESF24Measurement(kilograms: 4.2).isPlausibleBodyWeight)
        #expect(!ESF24Measurement(kilograms: 655.35).isPlausibleBodyWeight)
    }

    // MARK: Session

    @Test("runs the whole handshake and reports one reading per weigh-in")
    func fullWeighIn() {
        var session = ESF24Session(displayUnit: .pounds)
        let now = Date(timeIntervalSince1970: ESF24Protocol.epochOffset + 1_000)

        #expect(session.receive(Self.unitRequest(), at: now)
            == [.write(ESF24Protocol.displayUnitCommand(.pounds, vendorByte: 0x15))])
        // The scale asks again before our answer lands; one answer is enough.
        #expect(session.receive(Self.unitRequest(), at: now).isEmpty)

        #expect(session.receive(Self.measurementInitRequest, at: now)
            == [.write(ESF24Protocol.setTimeCommand(at: now, vendorByte: 0x15))])
        #expect(session.receive([0x21, 0x05, 0x15, 0x01, 0x3C], at: now).isEmpty)

        #expect(session.receive(Self.measurementFrame(centikilograms: 8_000, final: false)) == [.weighing])
        #expect(session.receive(Self.measurementFrame(centikilograms: 8_100, final: false)).isEmpty)

        let final = Self.measurementFrame(centikilograms: 8_123, final: true)
        #expect(session.receive(final) == [
            .write(ESF24Protocol.endMeasurementCommand(vendorByte: 0x15)),
            .measured(ESF24Measurement(kilograms: 81.23)),
        ])
        // Repeated until the end command lands — must not be logged twice.
        #expect(session.receive(final).isEmpty)
        #expect(session.receive(final).isEmpty)
    }

    @Test("a second weigh-in on the same connection is reported too")
    func secondWeighIn() {
        var session = ESF24Session(displayUnit: .kilograms)
        _ = session.receive(Self.unitRequest())
        _ = session.receive(Self.measurementFrame(centikilograms: 8_000, final: false))
        _ = session.receive(Self.measurementFrame(centikilograms: 8_000, final: true))

        #expect(session.receive(Self.measurementFrame(centikilograms: 7_900, final: false)) == [.weighing])
        #expect(session.receive(Self.measurementFrame(centikilograms: 7_950, final: true)).contains(
            .measured(ESF24Measurement(kilograms: 79.5))
        ))
    }

    @Test("learns the vendor byte from the unit request and echoes it afterwards")
    func adoptsVendorByte() {
        var session = ESF24Session(displayUnit: .kilograms)
        #expect(session.receive(Self.unitRequest(vendor: 0xFF))
            == [.write(ESF24Protocol.displayUnitCommand(.kilograms, vendorByte: 0xFF))])
        #expect(session.vendorByte == 0xFF)

        let final = Self.measurementFrame(centikilograms: 9_000, final: true, vendor: 0xFF)
        #expect(session.receive(final).first == .write([0x1F, 0x05, 0xFF, 0x10, 0x33]))
    }

    // MARK: Advertisement

    @Test("recognises the scale by name")
    func matchesByName() {
        #expect(ESF24Advertisement.matches(localName: "QN-Scale1", manufacturerData: nil))
        #expect(!ESF24Advertisement.matches(localName: "Etekcity Fitness Scale", manufacturerData: nil))
    }

    @Test("recognises the scale by QN model code, with CoreBluetooth's company-ID prefix")
    func matchesByManufacturerData() {
        // FF FF company ID, then model 294 (0x0126) big-endian, then the rest of the frame.
        let esf24 = Data([0xFF, 0xFF, 0x01, 0x26, 0x01, 0x00, 0x00, 1, 2, 3, 4, 5, 6])
        #expect(ESF24Advertisement.matches(localName: nil, manufacturerData: esf24))

        let unknownModel = Data([0xFF, 0xFF, 0x00, 0xD3, 0x01, 0x00, 0x00])
        #expect(!ESF24Advertisement.matches(localName: nil, manufacturerData: unknownModel))

        let otherCompany = Data([0xD0, 0x06, 0x01, 0x26])
        #expect(!ESF24Advertisement.matches(localName: nil, manufacturerData: otherCompany))
    }
}
