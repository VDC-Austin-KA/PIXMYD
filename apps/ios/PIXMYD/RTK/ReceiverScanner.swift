import Combine
import CoreBluetooth
import ExternalAccessory
import Foundation
import Network

/// Scan mode: find receivers over the air.
///
/// Three searches run at once, because a receiver announces itself on exactly
/// one of them and the user should not have to know which:
///
/// 1. **Bluetooth LE** — a scan for peripherals advertising a serial service,
///    or naming a maker this app recognises.
/// 2. **Wi-Fi** — a Bonjour browse for the service types receivers advertise,
///    plus a typed `host:port` for the many that advertise nothing at all.
/// 3. **MFi accessories** — already attached, listed for completeness so the
///    screen answers "is my receiver connected" rather than only "what is in
///    the air".
///
/// The scanner finds and identifies. It does not connect: `GnssManager` owns
/// the live link, because the position source is a property of the session, not
/// of a screen that gets dismissed.
@MainActor
final class ReceiverScanner: NSObject, ObservableObject {

    /// Whether a link can be used, and if not, why not — the reason is the
    /// useful half. "No devices found" while Bluetooth is switched off is a
    /// screen that lies by omission.
    enum LinkAvailability: Equatable {
        case unknown
        case ready
        case poweredOff
        case denied
        case unsupported
        case failed(String)

        var isReady: Bool { self == .ready }

        var explanation: String? {
            switch self {
            case .unknown: "Starting up."
            case .ready: nil
            case .poweredOff: "Bluetooth is switched off. Turn it on in Settings or Control Centre."
            case .denied: "PIXMYD is not allowed to use Bluetooth. Settings → PIXMYD → Bluetooth."
            case .unsupported: "This device has no Bluetooth LE radio."
            case .failed(let reason): reason
            }
        }
    }

    @Published private(set) var receivers: [DiscoveredReceiver] = []
    @Published private(set) var hiddenCount = 0
    /// A note about something no row can show — an accessory this build cannot
    /// open, most often.
    @Published private(set) var message: String?
    @Published private(set) var isScanning = false
    @Published private(set) var bluetooth: LinkAvailability = .unknown
    @Published private(set) var network: LinkAvailability = .unknown
    /// Most Bluetooth devices near anyone are not receivers. Off by default,
    /// and the count of what is hidden is shown so the filter is never a
    /// silent one.
    @Published var includeUnknownDevices = false {
        didSet { publish() }
    }

    /// Bonjour types worth browsing.
    ///
    /// Every one of these must also be listed in `NSBonjourServices` in
    /// Info.plist: iOS does not merely refuse an unlisted type, it returns no
    /// results for it, which looks exactly like nothing being there.
    static let bonjourTypes = ["_ntrip._tcp", "_nmea._tcp", "_gnss._tcp", "_reach._tcp"]

    private var list = ReceiverList()
    private var lastPublish = Date.distantPast
    private var central: CBCentralManager?
    private var browsers: [NWBrowser] = []
    private var pruneTimer: Timer?

    /// Handles back to the things found, keyed by `DiscoveredReceiver.id`.
    /// These cannot live in the value type — it is `Codable`-shaped and crosses
    /// into SwiftUI — so the scanner keeps them.
    private var peripherals: [String: CBPeripheral] = [:]
    private var endpoints: [String: NWEndpoint] = [:]
    private var accessories: [String: (accessory: EAAccessory, protocolString: String)] = [:]
    /// What each Bonjour browse last reported, so a service that disappears can
    /// be removed without disturbing the entries owned by the other browsers.
    private var bonjourIds: [String: Set<String>] = [:]

    /// The BLE link currently being opened or held, so central-level callbacks
    /// can be forwarded to it. Weak: the transport is owned by `GnssManager`,
    /// and a scan screen being dismissed must not close a live link.
    private weak var bluetoothTransport: BluetoothTransport?

    // MARK: - Lifecycle

    func start() {
        guard !isScanning else { return }
        isScanning = true

        // Creating the manager is what prompts for Bluetooth permission, so it
        // is deliberately not done at launch — the prompt arrives when the user
        // has asked to scan and the reason for it is on screen behind it.
        if central == nil {
            central = CBCentralManager(delegate: self, queue: nil)
        } else {
            startBluetoothScan()
        }

        startBonjourBrowsers()
        refreshAccessories()

        pruneTimer?.invalidate()
        pruneTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            // The run loop fires this on the main thread; see the note on
            // delegate isolation below.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.prune()
            }
        }
    }

    func stop() {
        isScanning = false
        central?.stopScan()
        browsers.forEach { $0.cancel() }
        browsers.removeAll()
        pruneTimer?.invalidate()
        pruneTimer = nil
    }

    func clear() {
        list.removeAll()
        peripherals.removeAll()
        endpoints.removeAll()
        accessories.removeAll()
        publish()
        refreshAccessories()
    }

    // MARK: - Bluetooth

    private func startBluetoothScan() {
        guard let central, central.state == .poweredOn else { return }
        // Scanning with no service filter and duplicates on: a filtered scan
        // would miss every receiver using a vendor-specific service, and
        // duplicates are what keeps the signal strength and the freshness
        // timestamps current. Both are only acceptable in the foreground, which
        // is the only place this screen exists.
        central.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    private func record(
        _ peripheral: CBPeripheral,
        advertisement: [String: Any],
        rssi: NSNumber
    ) {
        let advertisedName = advertisement[CBAdvertisementDataLocalNameKey] as? String
        let name = advertisedName ?? peripheral.name
        let services = advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
        let known = Set(BleSerialProfile.serviceUUIDs)
        let serial = services.first { known.contains($0) }

        // RSSI of 127 is CoreBluetooth's "not available", not a very strong
        // signal. Treating it as a number would sort unreadable devices to the
        // top of the list.
        let strength = rssi.intValue == 127 ? nil : rssi.intValue

        let found = DiscoveredReceiver(
            link: .bluetooth,
            identifier: peripheral.identifier.uuidString,
            name: name,
            vendor: ReceiverVendor.identify(name),
            rssi: strength,
            detail: serial.flatMap { BleSerialProfile.named($0)?.name },
            advertisesSerialService: serial != nil,
            lastSeen: Date()
        )
        // A busy room produces tens of advertisements a second, and republishing
        // on each one makes SwiftUI re-diff the list that often for a signal
        // reading that moved by a decibel. A device appearing is what the user
        // is waiting for and is never delayed; everything else is a refresh and
        // can wait half a second.
        let isNew = peripherals[found.id] == nil
        peripherals[found.id] = peripheral
        list.merge(found)
        if isNew || Date().timeIntervalSince(lastPublish) > 0.5 { publish() }
    }

    // MARK: - Wi-Fi

    private func startBonjourBrowsers() {
        browsers.forEach { $0.cancel() }
        browsers = Self.bonjourTypes.map { type in
            let parameters = NWParameters()
            parameters.includePeerToPeer = true
            let browser = NWBrowser(
                for: .bonjour(type: type, domain: nil),
                using: parameters
            )
            browser.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.handleBrowser(state)
                }
            }
            browser.browseResultsChangedHandler = { [weak self] results, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.handleBrowse(results, type: type)
                }
            }
            browser.start(queue: .main)
            return browser
        }
    }

    private func handleBrowser(_ state: NWBrowser.State) {
        switch state {
        case .ready:
            network = .ready
        case .waiting(let error), .failed(let error):
            // The usual cause on a phone is the local-network permission being
            // refused, which produces no results and no error dialog.
            network = .failed(
                "Cannot browse the local network: \(error.localizedDescription). "
                    + "Check Settings → PIXMYD → Local Network."
            )
        default:
            break
        }
    }

    private func handleBrowse(_ results: Set<NWBrowser.Result>, type: String) {
        // A browse result set is the whole truth for that type: anything absent
        // from it has gone away, so entries are removed rather than aged out.
        var seen: Set<String> = []

        for result in results {
            guard case let .service(name, serviceType, domain, _) = result.endpoint else { continue }
            let identifier = "\(name).\(serviceType)\(domain)"
            let found = DiscoveredReceiver(
                link: .wifi,
                identifier: identifier,
                name: name,
                vendor: ReceiverVendor.identify(name),
                rssi: nil,
                detail: "\(serviceType) on the local network",
                advertisesSerialService: true,
                lastSeen: Date()
            )
            seen.insert(found.id)
            endpoints[found.id] = result.endpoint
            list.merge(found)
        }

        for departed in bonjourIds[type, default: []].subtracting(seen) {
            list.remove(id: departed)
            endpoints[departed] = nil
        }
        bonjourIds[type] = seen

        publish()
    }

    /// Turn a typed address into something connectable.
    ///
    /// Nothing is discovered here — the user is asserting that a receiver is at
    /// this address — so the entry is added to the list as found, and whether
    /// it is really there is settled by trying to connect.
    func manualEndpoint(_ text: String) -> DiscoveredReceiver? {
        guard let (host, port) = ReceiverEndpoint.parse(text) else { return nil }
        let found = DiscoveredReceiver(
            link: .wifi,
            identifier: "\(host):\(port)",
            name: host,
            vendor: ReceiverVendor.identify(host),
            rssi: nil,
            detail: "Entered by hand — port \(port)",
            advertisesSerialService: true,
            lastSeen: Date()
        )
        guard let port16 = UInt16(exactly: port), let endpointPort = NWEndpoint.Port(rawValue: port16)
        else { return nil }
        endpoints[found.id] = .hostPort(host: NWEndpoint.Host(host), port: endpointPort)
        list.merge(found)
        publish()
        return found
    }

    // MARK: - MFi

    func refreshAccessories() {
        let manager = EAAccessoryManager.shared()
        manager.registerForLocalNotifications()

        let declared = Bundle.main.object(
            forInfoDictionaryKey: "UISupportedExternalAccessoryProtocols"
        ) as? [String] ?? []

        for accessory in manager.connectedAccessories {
            guard let protocolString = accessory.protocolStrings.first(where: declared.contains)
            else { continue }
            let found = DiscoveredReceiver(
                link: .mfi,
                identifier: String(accessory.connectionID),
                name: accessory.name,
                vendor: ReceiverVendor.identify(accessory.name)
                    ?? ReceiverVendor.identify(accessory.manufacturer),
                rssi: nil,
                detail: "\(accessory.manufacturer) — \(protocolString)",
                advertisesSerialService: true,
                lastSeen: Date()
            )
            accessories[found.id] = (accessory, protocolString)
            list.merge(found)
        }

        // An accessory that is plugged in but speaks no protocol this build
        // declares cannot be opened at all, and the reason is not discoverable
        // from the screen. Say it.
        let stranger = manager.connectedAccessories.first { accessory in
            !accessory.protocolStrings.contains(where: declared.contains)
        }
        message = stranger.map { accessory in
            "\(accessory.name) is attached but does not use a protocol this build supports, "
                + "so iOS will not open a session to it."
        }

        publish()
    }

    // MARK: - Connecting

    /// Build a link to something the scan found.
    ///
    /// Returns nil when the handle has gone — a peripheral that stopped
    /// advertising and was pruned, or an accessory that was unplugged between
    /// the tap and here.
    func transport(for receiver: DiscoveredReceiver) -> ReceiverTransport? {
        switch receiver.link {
        case .bluetooth:
            guard let central, let peripheral = peripherals[receiver.id] else { return nil }
            let transport = BluetoothTransport(
                receiver: receiver,
                peripheral: peripheral,
                central: central
            )
            bluetoothTransport = transport
            return transport

        case .wifi:
            guard let endpoint = endpoints[receiver.id] else { return nil }
            return TcpTransport(receiver: receiver, endpoint: endpoint)

        case .mfi:
            guard let entry = accessories[receiver.id] else { return nil }
            return AccessoryTransport(
                receiver: receiver,
                accessory: entry.accessory,
                protocolString: entry.protocolString
            )
        }
    }

    // MARK: - List

    private func prune() {
        let gone = list.expire()
        for id in gone { peripherals[id] = nil }
        // Unconditional: this is also what flushes a refresh that the coalescing
        // in `record` skipped, so a signal reading is never more than a tick old.
        publish()
    }

    private func publish() {
        lastPublish = Date()
        receivers = list.visible(includingUnknown: includeUnknownDevices)
        hiddenCount = list.hiddenCount
    }
}

// MARK: - CoreBluetooth

// The delegate methods are `nonisolated` because the protocol declares them
// that way, and they use `assumeIsolated` rather than a `Task` hop. The manager
// was created with a nil queue, so every callback already arrives on the main
// thread; hopping through a task would move the work to the same actor a moment
// later and lose the ordering between a connect and the disconnect that follows
// it.
extension ReceiverScanner: CBCentralManagerDelegate {

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            switch central.state {
            case .poweredOn:
                self.bluetooth = .ready
                if self.isScanning { self.startBluetoothScan() }
            case .poweredOff:
                self.bluetooth = .poweredOff
            case .unauthorized:
                self.bluetooth = .denied
            case .unsupported:
                self.bluetooth = .unsupported
            default:
                self.bluetooth = .unknown
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        MainActor.assumeIsolated {
            self.record(peripheral, advertisement: advertisementData, rssi: RSSI)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard self.bluetoothTransport?.peripheral.identifier == peripheral.identifier else { return }
            self.bluetoothTransport?.handleConnected()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard self.bluetoothTransport?.peripheral.identifier == peripheral.identifier else { return }
            self.bluetoothTransport?.handleConnectFailure(error)
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        MainActor.assumeIsolated {
            guard self.bluetoothTransport?.peripheral.identifier == peripheral.identifier else { return }
            self.bluetoothTransport?.handleDisconnected(error)
        }
    }
}
