// Portions of this file are ported from etekcity_esf551_ble (src/etekcity_esf551_ble/esf24/),
// under the following license:
//
// MIT License
//
// Copyright (c) 2024 Ron Ben Yosef
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Foundation

/// The wire protocol of the Etekcity ESF-24 smart scale, and nothing else.
///
/// Ported from the MIT-licensed `etekcity_esf551_ble` Python package (Ron Ben Yosef,
/// <https://pypi.org/project/etekcity-esf551-ble/>), whose ESF-24 support was reverse-engineered
/// from packet captures. That package calls its ESF-24 support experimental, and so is this.
/// The ESF-17/18 speak the same protocol, so this should cover them too, untested.
///
/// Kept free of CoreBluetooth on purpose: everything here is bytes in, bytes out, so the whole
/// conversation can be driven from a unit test on any platform. The app's `ScaleMonitor` owns
/// the radio and does nothing but carry bytes between the scale and ``ESF24Session``.
///
/// ## The conversation
///
/// Every frame, in both directions, is `opcode, length, vendor byte, …, checksum`, where the
/// checksum is the low byte of the sum of everything before it. Once notifications are on:
///
/// 1. The scale sends a **unit request** (`0x12`) about every 200 ms until it is answered. Its
///    byte 2 is the per-scale *vendor byte* every reply has to echo (`0x15` on most units,
///    `0xff` on some).
/// 2. We answer with the **display unit** command, which also sets what the scale shows.
/// 3. The scale sends a **measurement-init request** (`0x14`); we answer with the clock.
/// 4. The scale acks the clock (`0x21`), then streams **measurement frames** (`0x10`) while the
///    reading settles. Only the frame whose status byte is `0x01` carries the final weight.
/// 5. We send **end measurement** (`0x1f`). Without it the scale repeats the final frame about
///    twice a second.
///
/// The scale can also hold readings taken while nothing was connected, and hands them over in
/// response to a `0x22` query — deleting each one from its memory as it does. Tally never sends
/// that query, so those readings stay on the scale for the VeSync app to collect.
public enum ESF24Protocol {
    /// The service holding both characteristics below.
    public static let serviceUUID = "FFF0"
    /// The scale notifies every frame on this characteristic.
    public static let notifyCharacteristicUUID = "FFF1"
    /// Commands are written to this one.
    public static let writeCharacteristicUUID = "FFF2"

    /// What every ESF-24 seen before the `0xff` units used. Replaced by whatever the scale's
    /// unit request says, so this only matters for a frame that arrives before that one does.
    public static let defaultVendorByte: UInt8 = 0x15

    /// The scale's clock counts seconds from this Unix time.
    ///
    /// Not quite 2000-01-01 UTC (that is 946684800): it is midnight on that day in UTC+8, the
    /// vendor's time zone. Kept exactly as the captures show it rather than "corrected".
    public static let epochOffset: TimeInterval = 946_656_000

    // MARK: Commands

    /// Sets the unit the scale displays. The weight it reports is always kilograms regardless.
    public static func displayUnitCommand(_ unit: MassUnit, vendorByte: UInt8) -> [UInt8] {
        let unitFlag: UInt8 = switch unit {
        case .kilograms: 0x01
        case .pounds: 0x02
        }
        return withChecksum([0x13, 0x09, vendorByte, unitFlag, 0x10, 0x28, 0x37, 0x00])
    }

    /// Answers the measurement-init request with the current time.
    public static func setTimeCommand(at date: Date, vendorByte: UInt8) -> [UInt8] {
        let seconds = UInt32(clamping: Int64((date.timeIntervalSince1970 - epochOffset).rounded(.down)))
        return withChecksum([
            0x20, 0x08, vendorByte,
            UInt8(truncatingIfNeeded: seconds),
            UInt8(truncatingIfNeeded: seconds >> 8),
            UInt8(truncatingIfNeeded: seconds >> 16),
            UInt8(truncatingIfNeeded: seconds >> 24),
        ])
    }

    /// Tells the scale the final reading arrived, so it stops repeating it.
    public static func endMeasurementCommand(vendorByte: UInt8) -> [UInt8] {
        withChecksum([0x1F, 0x05, vendorByte, 0x10])
    }

    static func withChecksum(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [checksum(bytes)]
    }

    static func checksum<C: Collection>(_ bytes: C) -> UInt8 where C.Element == UInt8 {
        bytes.reduce(0) { $0 &+ $1 }
    }

    // MARK: Frames from the scale

    /// One frame received from the scale, classified.
    public enum Frame: Equatable, Sendable {
        /// "Which unit should I show?" Carries the vendor byte every reply must echo.
        case unitRequest(vendorByte: UInt8)
        /// "What time is it?" — answered with ``setTimeCommand(at:vendorByte:)``.
        case measurementInitRequest
        /// The scale accepted the time; a measurement follows.
        case setTimeAck
        /// The weight is still settling, or the impedance measurement is still running.
        case settling
        /// The finished reading.
        case finalMeasurement(ESF24Measurement)
        /// Anything else. Logged, never acted on.
        case unrecognized
    }

    /// Classifies a notification payload.
    ///
    /// Lengths are only bounded from below, as the Python client does and the vendor's own
    /// decoder does: firmware variants append a byte to some frames without moving any field.
    public static func parse(_ payload: [UInt8], vendorByte: UInt8) -> Frame {
        guard payload.count >= 3 else { return .unrecognized }

        // Matched before the vendor byte is checked, because this is the frame that *tells* us
        // the vendor byte.
        if payload[0] == 0x12, payload.count >= 10 {
            return .unitRequest(vendorByte: payload[2])
        }

        guard payload[2] == vendorByte else { return .unrecognized }

        switch (payload[0], payload[1]) {
        case (0x10, 0x0B) where payload.count >= 11:
            guard payload[5] == 0x01 else { return .settling }
            return .finalMeasurement(ESF24Measurement(
                kilograms: Double(be16(payload, 3)) / 100,
                impedance50kHz: nonZero(be16(payload, 6)),
                impedance500kHz: nonZero(be16(payload, 8))
            ))
        case (0x14, 0x0B) where payload.count >= 11:
            return .measurementInitRequest
        // Seen as `21 05 15 01 3c` and as `21 04 ff 01 25`: the length byte differs by firmware.
        case (0x21, 0x04), (0x21, 0x05):
            return payload.count == 5 ? .setTimeAck : .unrecognized
        default:
            return .unrecognized
        }
    }

    private static func be16(_ bytes: [UInt8], _ offset: Int) -> Int {
        Int(bytes[offset]) << 8 | Int(bytes[offset + 1])
    }

    /// The scale reports 0 for an impedance band it didn't measure (no bare feet, say).
    private static func nonZero(_ value: Int) -> Int? { value == 0 ? nil : value }
}

/// A finished weigh-in, as the scale reported it.
public struct ESF24Measurement: Equatable, Sendable {
    /// Always kilograms on the wire, at 0.01 kg resolution, whatever unit the scale displays.
    public var kilograms: Double
    /// Bioimpedance in ohms, when the scale measured it. Not used by Tally yet; carried so a
    /// body-composition feature has it without another trip through the protocol.
    public var impedance50kHz: Int?
    public var impedance500kHz: Int?

    public init(kilograms: Double, impedance50kHz: Int? = nil, impedance500kHz: Int? = nil) {
        self.kilograms = kilograms
        self.impedance50kHz = impedance50kHz
        self.impedance500kHz = impedance500kHz
    }

    public var pounds: Double { WeightSample.pounds(fromKilograms: kilograms) }

    /// Rejects anything that can't be a person standing on the scale. The ESF-24 is rated to
    /// 180 kg; the floor screens out a cat, a bag, or a frame read at the wrong offset.
    public var isPlausibleBodyWeight: Bool { (10...250).contains(kilograms) }
}

/// One connection's worth of conversation with an ESF-24.
///
/// A value type driven by ``receive(_:at:)``, which says what to do next rather than doing it:
/// the caller writes the commands and records the reading. That split is what lets the whole
/// handshake be tested without a radio.
public struct ESF24Session: Sendable {
    /// What the caller should do in response to a frame, in order.
    public enum Action: Equatable, Sendable {
        /// Write these bytes to ``ESF24Protocol/writeCharacteristicUUID``.
        case write([UInt8])
        /// Someone is on the scale and it is still settling. Sent once per weigh-in.
        case weighing
        /// A finished reading. Sent exactly once per weigh-in.
        case measured(ESF24Measurement)
    }

    /// The unit the scale should display.
    public var displayUnit: MassUnit

    public private(set) var vendorByte = ESF24Protocol.defaultVendorByte
    private var hasSetUnit = false
    private var hasSetTime = false
    private var isWeighing = false
    /// Set once a weigh-in's final frame has been reported. The scale repeats that frame until
    /// our end command lands, and one weigh-in must be logged once. Cleared by the next
    /// settling frame, because one connection can outlive several weigh-ins.
    private var hasDeliveredFinal = false

    public init(displayUnit: MassUnit) {
        self.displayUnit = displayUnit
    }

    public mutating func receive(_ payload: [UInt8], at now: Date = Date()) -> [Action] {
        switch ESF24Protocol.parse(payload, vendorByte: vendorByte) {
        case .unitRequest(let vendor):
            vendorByte = vendor
            // The scale keeps asking every ~200 ms until the answer lands. Answering every time
            // would queue a burst of identical writes; once is what the Python client does.
            guard !hasSetUnit else { return [] }
            hasSetUnit = true
            return [.write(ESF24Protocol.displayUnitCommand(displayUnit, vendorByte: vendor))]

        case .measurementInitRequest:
            guard !hasSetTime else { return [] }
            hasSetTime = true
            return [.write(ESF24Protocol.setTimeCommand(at: now, vendorByte: vendorByte))]

        case .settling:
            hasDeliveredFinal = false
            guard !isWeighing else { return [] }
            isWeighing = true
            return [.weighing]

        case .finalMeasurement(let measurement):
            guard !hasDeliveredFinal else { return [] }
            hasDeliveredFinal = true
            isWeighing = false
            return [
                .write(ESF24Protocol.endMeasurementCommand(vendorByte: vendorByte)),
                .measured(measurement),
            ]

        case .setTimeAck, .unrecognized:
            return []
        }
    }
}

/// Recognising an ESF-24 from its advertisement.
public enum ESF24Advertisement {
    /// The QN platform's company identifier. 0xFFFF is the "reserved for testing" ID, used by
    /// a lot of unrelated hardware, so it is only trusted together with a known model code.
    public static let qnCompanyID: UInt16 = 0xFFFF

    /// QN model codes seen on ESF-24 units.
    public static let modelCodes: Set<UInt16> = [294, 946]

    /// The name the ESF-24 advertises.
    public static let localNamePrefix = "QN-Scale"

    /// True when an advertisement looks like an ESF-24.
    ///
    /// - Parameters:
    ///   - localName: the advertised or GAP name, if any.
    ///   - manufacturerData: CoreBluetooth's manufacturer data, which — unlike bleak's — still
    ///     starts with the two-byte little-endian company identifier.
    ///
    /// The Python client also checks that the advertisement echoes the device's MAC address,
    /// which is what makes a 0xFFFF frame trustworthy. iOS never reveals a peripheral's MAC, so
    /// that check isn't available here, and the name is accepted on its own instead.
    public static func matches(localName: String?, manufacturerData: Data?) -> Bool {
        if let localName, localName.hasPrefix(localNamePrefix) { return true }
        guard let data = manufacturerData.map(Array.init), data.count >= 4 else { return false }
        let company = UInt16(data[0]) | UInt16(data[1]) << 8
        let model = UInt16(data[2]) << 8 | UInt16(data[3])
        return company == qnCompanyID && modelCodes.contains(model)
    }
}
