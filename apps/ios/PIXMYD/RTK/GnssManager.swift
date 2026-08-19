import Combine
import CoreLocation
import ExternalAccessory
import Foundation
import Network

/// Position, from whichever source is best available.
///
/// Three sources, in descending order of accuracy:
///
/// 1. **External RTK receiver** over MFi serial, Bluetooth LE or Wi-Fi — Emlid
///    Reach RX, viDoc, Bad Elf, Trimble DA2. Centimetre, when it has a fixed
///    solution. The link is found by `ReceiverScanner` and handed here as a
///    `ReceiverTransport`; this class does not care which of the three it is.
/// 2. **NTRIP-corrected** position, where the receiver takes corrections this
///    app fetches from a caster.
/// 3. **The internal GNSS**, via CoreLocation. Metre-level at best.
///
/// The manager never silently substitutes one for another. The capture screen
/// shows which is in use and what it is worth, because a scan georeferenced
/// from the internal GNSS and one from an RTK fix look identical afterwards and
/// differ by two orders of magnitude.
@MainActor
final class GnssManager: NSObject, ObservableObject {

    enum ConnectionState: Equatable {
        case disconnected
        case searching
        case connected
    }

    enum Source: String {
        case internalGnss = "Internal GNSS"
        case external = "External receiver"
    }

    @Published private(set) var currentFix: GnssFix?
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var source: Source = .internalGnss
    @Published private(set) var receiverName: String?
    @Published private(set) var ntripState: NtripClient.State = .idle
    @Published private(set) var lastMessage: String?

    /// The receiver this session is attached to, if any.
    @Published private(set) var connectedReceiver: DiscoveredReceiver?
    @Published private(set) var linkState: ReceiverTransportState = .idle
    /// Bytes read off the receiver link since it opened.
    @Published private(set) var receiverBytes = 0
    /// What those bytes turned out to be.
    ///
    /// A link that opens and then delivers something unreadable is the failure
    /// this exists for: without it, a receiver in binary-only mode looks
    /// exactly like a receiver with no sky view, and neither the app nor the
    /// user can tell them apart.
    @Published private(set) var streamKind: ReceiverStreamKind = .silent

    /// Antenna phase centre to camera centre, device body axes, metres.
    ///
    /// A pole-mounted rover sits a fixed offset above and behind the phone.
    /// Ignoring it is a systematic error of exactly that size in every frame —
    /// it does not average out, and it is invisible in the residuals because it
    /// shifts every point identically.
    @Published var leverArm: SIMD3<Double> = .zero

    private let location = CLLocationManager()
    private let parser = NmeaAssembler()
    private var ntrip: NtripClient?
    private var transport: ReceiverTransport?
    private var lineBuffer = NmeaLineBuffer()
    /// The first bytes off the link, kept only until the stream is identified.
    private var probeBuffer = Data()
    private var sessionStart = Date()

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        location.activityType = .otherNavigation
    }

    // MARK: - Lifecycle

    func start() {
        sessionStart = Date()
        switch location.authorizationStatus {
        case .notDetermined:
            location.requestWhenInUseAuthorization()
        case .denied, .restricted:
            lastMessage = "Location is denied. Captures will have no georeference "
                + "until it is enabled in Settings."
        default:
            break
        }
        location.startUpdatingLocation()
        connectionState = .searching
        connectExternalAccessoryIfPresent()
    }

    func stop() {
        location.stopUpdatingLocation()
        disconnectReceiver()
        ntrip?.stop()
        connectionState = .disconnected
    }

    // MARK: - External receiver

    /// Take over a link found by the scanner.
    ///
    /// Any previous link is closed first. Two receivers feeding one assembler
    /// would interleave two devices' sentences into one position stream, and
    /// the result would look entirely plausible.
    func connect(_ transport: ReceiverTransport) {
        disconnectReceiver()

        self.transport = transport
        connectedReceiver = transport.receiver
        receiverName = transport.receiver.displayName
        source = .external
        connectionState = .searching
        linkState = .connecting
        lineBuffer.reset()
        probeBuffer.removeAll()
        receiverBytes = 0
        streamKind = .silent

        // Both callbacks arrive on the main queue, in order — the delivery
        // contract on `ReceiverTransport`. `assumeIsolated` keeps that
        // ordering; a `Task` hop would preserve neither the order of two reads
        // nor their order relative to a disconnect.
        transport.onBytes = { [weak self] data in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.ingest(data)
            }
        }
        transport.onStateChange = { [weak self] state in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.linkChanged(state)
            }
        }
        transport.open()
    }

    /// Close the receiver link and fall back to the internal GNSS.
    func disconnectReceiver() {
        releaseTransport()
        // A link that failed leaves the receiver on screen with its reason and
        // no transport behind it, so the receiver — not the transport — is what
        // says whether there is anything to tear down.
        guard connectedReceiver != nil else { return }
        connectedReceiver = nil
        receiverName = nil
        source = .internalGnss
        linkState = .closed
        streamKind = .silent
        receiverBytes = 0
        lineBuffer.reset()
        probeBuffer.removeAll()
        // The last fix came from the receiver that just went away. Keeping it
        // on screen would show a centimetre position that nothing is
        // maintaining any more.
        currentFix = nil
        connectionState = .searching
    }

    private func linkChanged(_ state: ReceiverTransportState) {
        linkState = state
        switch state {
        case .connected:
            lastMessage = nil
        case .failed(let reason):
            lastMessage = reason
            connectionState = .searching
            source = .internalGnss
            // Nothing is maintaining the last fix any more. Leaving a
            // centimetre position on screen after the link that produced it has
            // gone is the one failure mode this whole class exists to prevent.
            currentFix = nil
            // The transport is finished and is released, but the receiver stays
            // on screen carrying the reason, so the row can offer to reconnect
            // to the same device.
            releaseTransport()
        case .closed:
            connectionState = .searching
        case .idle, .connecting:
            break
        }
    }

    /// Drop the link without touching what the screen is showing about it.
    private func releaseTransport() {
        guard let transport else { return }
        // Detached first: `close()` reports a state change, and routing that
        // back into `linkChanged` from inside `linkChanged` would recurse.
        transport.onBytes = nil
        transport.onStateChange = nil
        transport.close()
        self.transport = nil
    }

    /// Whether corrections can reach the receiver over the current link.
    var canForwardCorrections: Bool { transport?.canSendCorrections ?? false }

    /// Attach to an MFi GNSS receiver if one is already paired.
    ///
    /// External Accessory only sees receivers that declare a protocol this app
    /// lists in `UISupportedExternalAccessoryProtocols`. A receiver that is
    /// paired but not listed is invisible here, which is a configuration
    /// problem rather than a bug — the scan screen says so explicitly.
    ///
    /// Bluetooth and Wi-Fi receivers are deliberately *not* connected
    /// automatically: both require a scan, and a scan that starts itself at
    /// launch would ask for Bluetooth permission before the user has asked for
    /// anything.
    private func connectExternalAccessoryIfPresent() {
        let manager = EAAccessoryManager.shared()
        manager.registerForLocalNotifications()

        let known = Bundle.main.object(
            forInfoDictionaryKey: "UISupportedExternalAccessoryProtocols"
        ) as? [String] ?? []

        guard let accessory = manager.connectedAccessories.first(where: { accessory in
            accessory.protocolStrings.contains(where: known.contains)
        }),
            let protocolString = accessory.protocolStrings.first(where: known.contains)
        else { return }

        let receiver = DiscoveredReceiver(
            link: .mfi,
            identifier: String(accessory.connectionID),
            name: accessory.name,
            vendor: ReceiverVendor.identify(accessory.name),
            detail: accessory.manufacturer,
            advertisesSerialService: true,
            lastSeen: Date()
        )
        connect(AccessoryTransport(
            receiver: receiver,
            accessory: accessory,
            protocolString: protocolString
        ))
    }

    // MARK: - NTRIP

    func startNtrip(profile: RtkProfile) {
        if transport == nil {
            // The phone cannot apply corrections itself — only the receiver
            // can. Streaming them with nowhere to put them looks like RTK is
            // running when nothing has changed.
            lastMessage = "Corrections have nowhere to go until a receiver is connected. "
                + "Scan for one first."
        } else if canForwardCorrections == false {
            lastMessage = "This link is read-only, so corrections cannot reach the receiver. "
                + "Feed the receiver its corrections directly, or connect over a link that "
                + "accepts them."
        }

        let client = NtripClient(profile: profile)
        client.onCorrection = { [weak self] data in
            // Corrections go straight back out to the receiver, which is the
            // only thing that can apply them. The app is a pipe here.
            Task { @MainActor in self?.sendToReceiver(data) }
        }
        client.onStateChange = { [weak self] state in
            Task { @MainActor in self?.ntripState = state }
        }
        ntrip = client
        client.start()
    }

    func stopNtrip() {
        ntrip?.stop()
        ntrip = nil
        ntripState = .idle
    }

    private func sendToReceiver(_ data: Data) {
        transport?.send(data)
    }

    // MARK: - NMEA ingestion

    private func ingest(_ data: Data) {
        receiverBytes += data.count
        identifyStream(data)

        for line in lineBuffer.append(data) {
            // The caster needs the rover's own position to generate a
            // correction stream for it, and the GGA the receiver already emits
            // is exactly that sentence — it is passed straight back up rather
            // than reconstructed from the parsed fix, so what the caster sees
            // is what the receiver said.
            //
            // Only a sentence that passed its checksum: a corrupted GGA is a
            // plausible wrong position, and a VRS network handed one generates
            // corrections for somewhere the rover is not. Nothing downstream
            // could detect that.
            if let sentence = Nmea.parse(line), sentence.valid, sentence.type == "GGA" {
                ntrip?.latestGga = line
            }

            guard let fix = parser.push(line, since: sessionStart) else { continue }
            var located = fix
            if leverArm != .zero {
                located.leverArm = [leverArm.x, leverArm.y, leverArm.z]
            }
            currentFix = located
            connectionState = .connected
        }
    }

    /// Work out what the link is carrying, once, from the first bytes.
    ///
    /// A couple of hundred bytes is a second of output from a 1 Hz receiver and
    /// several sentences, which is plenty. Once NMEA has been seen the question
    /// is settled and the probe stops running.
    private func identifyStream(_ data: Data) {
        guard streamKind != .nmea else { return }
        probeBuffer.append(data)
        if probeBuffer.count > 512 { probeBuffer = probeBuffer.suffix(512) }
        let kind = ReceiverProbe.classify(probeBuffer)
        guard kind != streamKind else { return }
        streamKind = kind
        if let advice = kind.advice { lastMessage = advice }
    }
}

// MARK: - CoreLocation

extension GnssManager: CLLocationManagerDelegate {
    nonisolated func locationManager(
        _ manager: CLLocationManager,
        didUpdateLocations locations: [CLLocation]
    ) {
        guard let location = locations.last else { return }
        Task { @MainActor in
            // An external receiver always wins. CoreLocation on the same device
            // is metre-level and would quietly overwrite a centimetre fix.
            guard self.source == .internalGnss else { return }
            self.currentFix = GnssFix(
                t: location.timestamp.timeIntervalSince(self.sessionStart),
                lat: location.coordinate.latitude,
                lon: location.coordinate.longitude,
                // CoreLocation reports orthometric altitude; the ellipsoidal
                // height geodesy needs is not available without a geoid model,
                // so it is left equal and the discrepancy is recorded honestly.
                height: location.altitude,
                orthometricHeight: location.altitude,
                geoidSeparation: nil,
                quality: location.horizontalAccuracy < 0 ? .invalid : .singlePoint,
                satellites: nil,
                hdop: nil,
                hAccuracy: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil,
                vAccuracy: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil,
                leverArm: nil
            )
            self.connectionState = .connected
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.lastMessage = error.localizedDescription }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .denied, .restricted:
                self.lastMessage = "Location is denied. Captures will have no georeference."
                self.connectionState = .disconnected
            case .authorizedWhenInUse, .authorizedAlways:
                manager.startUpdatingLocation()
            default:
                break
            }
        }
    }
}
