import Combine
import CoreLocation
import ExternalAccessory
import Foundation
import Network

/// Position, from whichever source is best available.
///
/// Three sources, in descending order of accuracy:
///
/// 1. **External RTK receiver** over MFi serial or Bluetooth — Emlid Reach RX,
///    viDoc, Bad Elf, Trimble DA2. Centimetre, when it has a fixed solution.
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
    private var accessorySession: EASession?
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
        disconnectExternal()
        ntrip?.stop()
        connectionState = .disconnected
    }

    // MARK: - External receiver

    /// Attach to an MFi GNSS receiver if one is paired.
    ///
    /// External Accessory only sees receivers that declare a protocol this app
    /// lists in `UISupportedExternalAccessoryProtocols`. A receiver that is
    /// paired but not listed is invisible here, which is a configuration
    /// problem rather than a bug — hence the explicit message.
    private func connectExternalAccessoryIfPresent() {
        let manager = EAAccessoryManager.shared()
        manager.registerForLocalNotifications()

        let known = Bundle.main.object(
            forInfoDictionaryKey: "UISupportedExternalAccessoryProtocols"
        ) as? [String] ?? []

        guard let accessory = manager.connectedAccessories.first(where: { accessory in
            accessory.protocolStrings.contains(where: known.contains)
        }) else { return }

        guard let protocolString = accessory.protocolStrings.first(where: known.contains),
              let session = EASession(accessory: accessory, forProtocol: protocolString) else {
            lastMessage = "\(accessory.name) is connected but did not open a data session."
            return
        }

        accessorySession = session
        receiverName = accessory.name
        source = .external
        session.inputStream?.delegate = self
        session.inputStream?.schedule(in: .main, forMode: .default)
        session.inputStream?.open()
        session.outputStream?.schedule(in: .main, forMode: .default)
        session.outputStream?.open()
    }

    private func disconnectExternal() {
        accessorySession?.inputStream?.close()
        accessorySession?.outputStream?.close()
        accessorySession = nil
        receiverName = nil
        source = .internalGnss
    }

    // MARK: - NTRIP

    func startNtrip(profile: RtkProfile) {
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
        guard let output = accessorySession?.outputStream, output.hasSpaceAvailable else { return }
        _ = data.withUnsafeBytes { buffer in
            output.write(
                buffer.bindMemory(to: UInt8.self).baseAddress!,
                maxLength: data.count
            )
        }
    }

    // MARK: - NMEA ingestion

    private var lineBuffer = ""

    private func ingest(_ text: String) {
        lineBuffer += text
        // NMEA arrives in arbitrary chunks over a serial link, so lines have to
        // be reassembled rather than assumed to align with reads.
        while let newline = lineBuffer.firstIndex(of: "\n") {
            let line = String(lineBuffer[..<newline])
            lineBuffer = String(lineBuffer[lineBuffer.index(after: newline)...])
            if let fix = parser.push(line, since: sessionStart) {
                var located = fix
                if leverArm != .zero {
                    located.leverArm = [leverArm.x, leverArm.y, leverArm.z]
                }
                currentFix = located
                connectionState = .connected
            }
        }
        // Guard against a receiver that never sends a newline.
        if lineBuffer.count > 4096 { lineBuffer.removeAll() }
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

// MARK: - Stream

extension GnssManager: StreamDelegate {
    nonisolated func stream(_ stream: Stream, handle event: Stream.Event) {
        guard event == .hasBytesAvailable, let input = stream as? InputStream else { return }
        var buffer = [UInt8](repeating: 0, count: 1024)
        let read = input.read(&buffer, maxLength: buffer.count)
        guard read > 0, let text = String(bytes: buffer[0..<read], encoding: .ascii) else { return }
        Task { @MainActor in self.ingest(text) }
    }
}
