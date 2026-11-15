import CoreBluetooth
import Foundation
import Observation
import TallyCore

/// Finds an Etekcity ESF-24 over Bluetooth while the app is in the foreground, and reports each
/// finished weigh-in.
///
/// Owns the radio and nothing else. The protocol — what to answer, which frame is the final
/// one, when one weigh-in ends and the next begins — is ``ESF24Session``'s, in TallyCore, where
/// it is tested without a radio. This class only moves bytes between the scale and the session
/// and keeps the connection alive.
///
/// The lifecycle is deliberately simple, because the scale's is: it advertises only while it is
/// awake (from a step until a few seconds after the reading), so "scan, connect to the first
/// ESF-24 seen, and go back to scanning when it drops" is all the pairing there is. There is no
/// background mode — readings taken with Tally closed stay on the scale for the VeSync app.
///
/// Delegate callbacks arrive on the main queue (`queue: nil`), which is what makes the
/// `@preconcurrency` conformances below sound for a main-actor class.
@Observable
@MainActor
final class ScaleMonitor: NSObject {
    enum Status: Equatable {
        /// Not running: switched off in Settings, or the app isn't in the foreground.
        case idle
        case unauthorized
        case bluetoothOff
        case unsupported
        /// Bluetooth is up and nothing is connected; the scale is asleep or out of range.
        case searching
        case connecting
        /// Connected and waiting for someone to step on.
        case connected
        /// Someone is on the scale and the reading is settling.
        case weighing
    }

    private(set) var status: Status = .idle

    /// Called once per finished weigh-in.
    var onMeasurement: (@MainActor (ESF24Measurement) -> Void)?

    /// The unit the scale's own display should show, read fresh on every connection so a
    /// change in Settings reaches the scale the next time it wakes.
    var displayUnit: @MainActor () -> MassUnit = { .pounds }

    /// Created on first ``start()``, not before: creating a central is what raises the
    /// Bluetooth permission prompt, and that belongs to the moment the user asked for a scale.
    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var writeCharacteristic: CBCharacteristic?
    private var session: ESF24Session
    private var isRunning = false
    /// Pending reconnect or connect-timeout, cancelled by whatever supersedes it.
    private var pendingTask: Task<Void, Never>?

    /// How long to stop listening after a disconnect. The scale keeps advertising for a few
    /// seconds after it drops the link as it goes to sleep, and connecting straight back to it
    /// would only start a session it is about to abandon.
    static let cooldown: Duration = .seconds(5)
    /// A connect that hasn't completed by then is given up on: CoreBluetooth never times one
    /// out by itself, and a scale that fell asleep mid-connect would otherwise wedge us.
    static let connectTimeout: Duration = .seconds(10)

    private static let notifyUUID = CBUUID(string: ESF24Protocol.notifyCharacteristicUUID)
    private static let writeUUID = CBUUID(string: ESF24Protocol.writeCharacteristicUUID)

    override init() {
        self.session = ESF24Session(displayUnit: .pounds)
        super.init()
    }

    // MARK: Control

    /// Starts looking for the scale. Safe to call repeatedly.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        if let central {
            updateForState(central.state)
        } else {
            // State arrives through centralManagerDidUpdateState, which starts the scan.
            central = CBCentralManager(delegate: self, queue: nil)
        }
    }

    /// Stops scanning and drops any connection. Called when the app leaves the foreground or
    /// the feature is switched off.
    func stop() {
        guard isRunning else { return }
        isRunning = false
        pendingTask?.cancel()
        pendingTask = nil
        if central?.isScanning == true { central?.stopScan() }
        dropPeripheral()
        status = .idle
    }

    // MARK: Internals

    private func updateForState(_ state: CBManagerState) {
        guard isRunning else { return }
        switch state {
        case .poweredOn:
            if peripheral == nil { scan() }
        case .unauthorized:
            status = .unauthorized
        case .unsupported:
            status = .unsupported
        case .poweredOff:
            // The system has already torn down every connection.
            dropPeripheral()
            status = .bluetoothOff
        case .resetting, .unknown:
            // Transient: another update follows.
            dropPeripheral()
        @unknown default:
            break
        }
    }

    private func scan() {
        guard isRunning, let central, central.state == .poweredOn, peripheral == nil else { return }
        status = .searching
        // No service filter: the ESF-24 isn't documented to advertise FFF0, and a filter that
        // turns out to be wrong fails silently. Scanning unfiltered is fine in the foreground,
        // which is the only place this runs.
        if !central.isScanning {
            central.scanForPeripherals(withServices: nil)
        }
    }

    private func connect(_ candidate: CBPeripheral) {
        guard let central else { return }
        central.stopScan()
        peripheral = candidate
        writeCharacteristic = nil
        candidate.delegate = self
        status = .connecting
        central.connect(candidate)

        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.connectTimeout)
            guard !Task.isCancelled, let self, self.status == .connecting else { return }
            self.connectionEnded()
        }
    }

    /// Forgets the current peripheral, cancelling its connection if there is one.
    private func dropPeripheral() {
        if let peripheral {
            peripheral.delegate = nil
            central?.cancelPeripheralConnection(peripheral)
        }
        peripheral = nil
        writeCharacteristic = nil
    }

    /// The link is gone, by design or not. Waits out the cooldown, then looks again.
    private func connectionEnded() {
        dropPeripheral()
        guard isRunning else { return }
        status = .searching
        pendingTask?.cancel()
        pendingTask = Task { [weak self] in
            try? await Task.sleep(for: Self.cooldown)
            guard !Task.isCancelled, let self else { return }
            self.scan()
        }
    }

    private func handle(_ actions: [ESF24Session.Action]) {
        for action in actions {
            switch action {
            case .write(let bytes):
                write(bytes)
            case .weighing:
                status = .weighing
            case .measured(let measurement):
                status = .connected
                onMeasurement?(measurement)
            }
        }
    }

    private func write(_ bytes: [UInt8]) {
        guard let peripheral, let writeCharacteristic else { return }
        // Write-with-response when the characteristic offers it, as bleak picks by default;
        // the scale's acks are frames on the notify side either way.
        let type: CBCharacteristicWriteType =
            writeCharacteristic.properties.contains(.write) ? .withResponse : .withoutResponse
        peripheral.writeValue(Data(bytes), for: writeCharacteristic, type: type)
    }
}

// MARK: - CBCentralManagerDelegate

extension ScaleMonitor: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        updateForState(central.state)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard isRunning, self.peripheral == nil else { return }
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data
        guard ESF24Advertisement.matches(localName: name, manufacturerData: manufacturerData) else {
            return
        }
        connect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard peripheral == self.peripheral else { return }
        pendingTask?.cancel()
        pendingTask = nil
        session = ESF24Session(displayUnit: displayUnit())
        status = .connected
        // All services rather than FFF0 alone, for the same reason the scan is unfiltered: the
        // Python client finds the characteristics by UUID wherever they are.
        peripheral.discoverServices(nil)
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        guard peripheral == self.peripheral else { return }
        connectionEnded()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: (any Error)?
    ) {
        guard peripheral == self.peripheral else { return }
        connectionEnded()
    }
}

// MARK: - CBPeripheralDelegate

extension ScaleMonitor: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: (any Error)?) {
        guard peripheral == self.peripheral else { return }
        guard error == nil, let services = peripheral.services, !services.isEmpty else {
            connectionEnded()
            return
        }
        for service in services {
            peripheral.discoverCharacteristics([Self.notifyUUID, Self.writeUUID], for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: (any Error)?
    ) {
        guard peripheral == self.peripheral, error == nil else { return }
        let characteristics = service.characteristics ?? []

        // The write side first: the scale starts asking for its unit the moment notifications
        // are on, and the answer needs somewhere to go.
        if let write = characteristics.first(where: { $0.uuid == Self.writeUUID }) {
            writeCharacteristic = write
        }
        if let notify = characteristics.first(where: { $0.uuid == Self.notifyUUID }) {
            peripheral.setNotifyValue(true, for: notify)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        // A scale that won't notify can never report a weight; drop it and try again on the
        // next wake rather than sitting on a dead connection.
        guard peripheral == self.peripheral, error != nil else { return }
        connectionEnded()
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: (any Error)?
    ) {
        guard peripheral == self.peripheral,
              characteristic.uuid == Self.notifyUUID,
              error == nil,
              let value = characteristic.value
        else { return }
        handle(session.receive(Array(value)))
    }
}
