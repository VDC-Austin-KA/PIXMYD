import CoreBluetooth
import ExternalAccessory
import Foundation
import Network

/// A byte pipe to a receiver, whatever it is carried over.
///
/// Above this line the app deals in NMEA sentences and RTCM corrections and
/// does not care whether they cross a BLE characteristic, a TCP socket or the
/// connector on the bottom of the phone. Below it, the three links are entirely
/// different animals.
///
/// **Delivery contract.** Every callback is invoked on the main queue, in the
/// order the bytes arrived. Ordering is not a nicety: NMEA sentences straddle
/// packet boundaries, so two chunks delivered out of order produce a sentence
/// that fails its checksum and a position that is silently missing. Each
/// implementation gets this by running its own I/O on the main queue rather
/// than by hopping afterwards — a hop through `Task` would reorder.
protocol ReceiverTransport: AnyObject {
    /// What was connected to, for display and for reconnection.
    var receiver: DiscoveredReceiver { get }
    var onBytes: ((Data) -> Void)? { get set }
    var onStateChange: ((ReceiverTransportState) -> Void)? { get set }
    /// Whether corrections can travel back down this link. False means the app
    /// can read positions but cannot feed the receiver RTCM, so NTRIP through
    /// this link will not work — worth saying rather than failing quietly.
    var canSendCorrections: Bool { get }

    func open()
    func close()
    /// Send RTCM to the receiver. A no-op when `canSendCorrections` is false.
    func send(_ data: Data)
}

enum ReceiverTransportState: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case failed(String)
    case closed

    var label: String {
        switch self {
        case .idle: "Not connected"
        case .connecting: "Connecting"
        case .connected: "Connected"
        case .failed(let reason): reason
        case .closed: "Disconnected"
        }
    }

    var isConnected: Bool { self == .connected }
}

// MARK: - Bluetooth

/// The serial-over-BLE services this app can read.
///
/// There is no standard GNSS-over-BLE service — every receiver picks a generic
/// serial bridge, and these are the four that cover what is on the market.
/// A device using none of them is still connectable: `BluetoothTransport`
/// falls back to any characteristic that can notify, which is what a serial
/// bridge looks like whatever UUID someone gave it.
struct BleSerialProfile {
    let name: String
    let service: CBUUID
    let notify: CBUUID
    let write: CBUUID

    static let all: [BleSerialProfile] = [
        // Nordic UART. The most common bridge by a distance — ArduSimple,
        // SparkFun and most ESP32/nRF-based receivers use it.
        BleSerialProfile(
            name: "Nordic UART",
            service: CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"),
            notify: CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"),
            write: CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
        ),
        // Microchip/ISSC transparent UART, used by several MFi-era receivers
        // that also expose a BLE side.
        BleSerialProfile(
            name: "Transparent UART",
            service: CBUUID(string: "49535343-FE7D-4AE5-8FA9-9FAFD205E455"),
            notify: CBUUID(string: "49535343-1E4D-4BD9-BA61-23C647249616"),
            write: CBUUID(string: "49535343-8841-43F4-A8D4-ECBE34729BB3")
        ),
        // HM-10 and its clones: one characteristic, read and written.
        BleSerialProfile(
            name: "HM-10 serial",
            service: CBUUID(string: "FFE0"),
            notify: CBUUID(string: "FFE1"),
            write: CBUUID(string: "FFE1")
        ),
        BleSerialProfile(
            name: "Generic serial",
            service: CBUUID(string: "FFF0"),
            notify: CBUUID(string: "FFF1"),
            write: CBUUID(string: "FFF2")
        ),
    ]

    static let serviceUUIDs: [CBUUID] = all.map(\.service)

    static func named(_ service: CBUUID) -> BleSerialProfile? {
        all.first { $0.service == service }
    }
}

/// A BLE link to a receiver.
///
/// Owned by `ReceiverScanner`, which holds the one `CBCentralManager` in the
/// app and forwards the central-level callbacks — connect, fail, disconnect —
/// that CoreBluetooth sends to the manager's delegate rather than to us.
final class BluetoothTransport: NSObject, ReceiverTransport {

    let receiver: DiscoveredReceiver
    var onBytes: ((Data) -> Void)?
    var onStateChange: ((ReceiverTransportState) -> Void)?

    private(set) var canSendCorrections = false

    let peripheral: CBPeripheral
    private weak var central: CBCentralManager?
    private var notifyCharacteristic: CBCharacteristic?
    private var writeCharacteristic: CBCharacteristic?
    private var isClosing = false

    init(receiver: DiscoveredReceiver, peripheral: CBPeripheral, central: CBCentralManager) {
        self.receiver = receiver
        self.peripheral = peripheral
        self.central = central
        super.init()
    }

    func open() {
        isClosing = false
        peripheral.delegate = self
        onStateChange?(.connecting)
        central?.connect(peripheral, options: nil)
    }

    func close() {
        isClosing = true
        if let notifyCharacteristic, peripheral.state == .connected {
            peripheral.setNotifyValue(false, for: notifyCharacteristic)
        }
        central?.cancelPeripheralConnection(peripheral)
        onStateChange?(.closed)
    }

    func send(_ data: Data) {
        guard let writeCharacteristic, peripheral.state == .connected else { return }
        // Corrections are far larger than one BLE packet, and CoreBluetooth
        // does not fragment for you — anything over the negotiated maximum is
        // silently truncated, which shows up as a rover that never gets a fix.
        let withResponse = writeCharacteristic.properties.contains(.writeWithoutResponse) == false
        let type: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse
        let limit = max(20, peripheral.maximumWriteValueLength(for: type))

        var offset = data.startIndex
        while offset < data.endIndex {
            let end = data.index(offset, offsetBy: limit, limitedBy: data.endIndex) ?? data.endIndex
            peripheral.writeValue(data[offset..<end], for: writeCharacteristic, type: type)
            offset = end
        }
    }

    // MARK: Central-level callbacks, forwarded by the scanner

    func handleConnected() {
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func handleConnectFailure(_ error: Error?) {
        onStateChange?(.failed(Self.describe(error) ?? "The receiver refused the connection."))
    }

    func handleDisconnected(_ error: Error?) {
        notifyCharacteristic = nil
        writeCharacteristic = nil
        canSendCorrections = false
        if isClosing {
            onStateChange?(.closed)
        } else {
            // An unasked-for disconnect is the common field failure: the rover
            // is on a pole, the operator walks away, the link drops. Say so
            // rather than leaving the screen showing a connection.
            onStateChange?(.failed(Self.describe(error) ?? "The receiver disconnected."))
        }
    }

    private static func describe(_ error: Error?) -> String? {
        guard let error else { return nil }
        return error.localizedDescription
    }
}

extension BluetoothTransport: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            onStateChange?(.failed(error.localizedDescription))
            return
        }
        guard let services = peripheral.services, !services.isEmpty else {
            onStateChange?(.failed("The receiver exposes no services to read."))
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil, let characteristics = service.characteristics else { return }

        let profile = BleSerialProfile.named(service.uuid)

        // A known profile is taken at its word. Otherwise anything that can
        // notify is treated as the read side, because that is what a serial
        // bridge is regardless of the UUID its maker chose.
        let notify = characteristics.first { $0.uuid == profile?.notify }
            ?? characteristics.first { $0.properties.contains(.notify) || $0.properties.contains(.indicate) }
        let write = characteristics.first { $0.uuid == profile?.write }
            ?? characteristics.first {
                $0.properties.contains(.write) || $0.properties.contains(.writeWithoutResponse)
            }

        // A profile match beats a guess, so a later generic service never
        // displaces a Nordic UART that was already found.
        if let notify, notifyCharacteristic == nil || profile != nil {
            notifyCharacteristic = notify
            peripheral.setNotifyValue(true, for: notify)
        }
        if let write, writeCharacteristic == nil || profile != nil {
            writeCharacteristic = write
            canSendCorrections = true
        }
        if notifyCharacteristic != nil {
            onStateChange?(.connected)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let value = characteristic.value, !value.isEmpty else { return }
        onBytes?(value)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            onStateChange?(.failed(error.localizedDescription))
        }
    }
}

// MARK: - Wi-Fi

/// A TCP link to a receiver on the network.
///
/// Runs on the main queue so that reads are delivered in order — see the
/// delivery contract on `ReceiverTransport`. The volume is a few kilobytes a
/// second at 10 Hz, which the main queue does not notice.
final class TcpTransport: ReceiverTransport {

    let receiver: DiscoveredReceiver
    var onBytes: ((Data) -> Void)?
    var onStateChange: ((ReceiverTransportState) -> Void)?
    /// A raw TCP output port is bidirectional, so corrections can go back the
    /// way positions came — provided the receiver is listening on that port,
    /// which the app cannot know until it tries.
    let canSendCorrections = true

    private let endpoint: NWEndpoint
    private var connection: NWConnection?
    private var isClosing = false

    init(receiver: DiscoveredReceiver, endpoint: NWEndpoint) {
        self.receiver = receiver
        self.endpoint = endpoint
    }

    func open() {
        isClosing = false
        // No TLS: these are raw NMEA sockets on a link-local address, usually
        // the receiver's own access point. There is nothing to negotiate with.
        let parameters = NWParameters.tcp
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onStateChange?(.connected)
                self.receiveLoop()
            case .waiting(let error):
                // `waiting` is not a failure — the connection retries — but on
                // a phone it usually means the network is not the one the
                // receiver is on, and saying nothing looks like a hang.
                self.onStateChange?(.failed(Self.describe(error)))
            case .failed(let error):
                self.onStateChange?(.failed(Self.describe(error)))
            case .cancelled:
                self.onStateChange?(self.isClosing ? .closed : .failed("The connection closed."))
            default:
                break
            }
        }
        onStateChange?(.connecting)
        connection.start(queue: .main)
    }

    func close() {
        isClosing = true
        connection?.cancel()
        connection = nil
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .idempotent)
    }

    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty { self.onBytes?(data) }
            if let error {
                self.onStateChange?(.failed(Self.describe(error)))
                return
            }
            if isComplete {
                self.onStateChange?(self.isClosing ? .closed : .failed("The receiver closed the connection."))
                return
            }
            self.receiveLoop()
        }
    }

    private static func describe(_ error: NWError) -> String {
        switch error {
        case .posix(.ECONNREFUSED):
            return "Nothing is listening on that port. Check the receiver's output settings."
        case .posix(.EHOSTUNREACH), .posix(.ENETUNREACH), .posix(.ETIMEDOUT):
            return "The receiver is not reachable. Check the phone is on the same network — "
                + "usually the receiver's own Wi-Fi."
        default:
            return error.localizedDescription
        }
    }
}

// MARK: - MFi accessory

/// A link to an MFi accessory over the connector or classic Bluetooth.
///
/// External Accessory only sees accessories declaring a protocol this app lists
/// in `UISupportedExternalAccessoryProtocols`. That list is fixed at build
/// time, so a paired receiver whose protocol is missing from it is invisible to
/// iOS — a configuration limit rather than a bug, and one the scan screen says
/// out loud instead of leaving the user to wonder.
final class AccessoryTransport: NSObject, ReceiverTransport {

    let receiver: DiscoveredReceiver
    var onBytes: ((Data) -> Void)?
    var onStateChange: ((ReceiverTransportState) -> Void)?
    let canSendCorrections = true

    private let accessory: EAAccessory
    private let protocolString: String
    private var session: EASession?

    init(receiver: DiscoveredReceiver, accessory: EAAccessory, protocolString: String) {
        self.receiver = receiver
        self.accessory = accessory
        self.protocolString = protocolString
        super.init()
    }

    func open() {
        onStateChange?(.connecting)
        guard let session = EASession(accessory: accessory, forProtocol: protocolString) else {
            onStateChange?(.failed("\(accessory.name) is connected but did not open a data session."))
            return
        }
        self.session = session
        session.inputStream?.delegate = self
        session.inputStream?.schedule(in: .main, forMode: .default)
        session.inputStream?.open()
        session.outputStream?.schedule(in: .main, forMode: .default)
        session.outputStream?.open()
        onStateChange?(.connected)
    }

    func close() {
        session?.inputStream?.close()
        session?.inputStream?.remove(from: .main, forMode: .default)
        session?.outputStream?.close()
        session?.outputStream?.remove(from: .main, forMode: .default)
        session = nil
        onStateChange?(.closed)
    }

    func send(_ data: Data) {
        guard let output = session?.outputStream, output.hasSpaceAvailable else { return }
        _ = data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) -> Int in
            guard let base = buffer.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return output.write(base, maxLength: data.count)
        }
    }
}

extension AccessoryTransport: StreamDelegate {
    func stream(_ stream: Stream, handle event: Stream.Event) {
        switch event {
        case .hasBytesAvailable:
            guard let input = stream as? InputStream else { return }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let read = input.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { return }
            onBytes?(Data(buffer[0..<read]))
        case .errorOccurred:
            onStateChange?(.failed(stream.streamError?.localizedDescription
                                   ?? "The accessory link failed."))
        case .endEncountered:
            onStateChange?(.closed)
        default:
            break
        }
    }
}
