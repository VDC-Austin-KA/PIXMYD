import Foundation

/// A saved RTK setup: which receiver to talk to, and where its corrections
/// come from.
///
/// The two halves are filled in from different places on purpose, because only
/// one of them is discoverable:
///
/// - **The receiver** is written by the scan. Its name, link and address are
///   things the phone found out for itself, so asking a user to type them
///   would be asking them to transcribe something the app already knows.
/// - **The caster** cannot be discovered from the receiver. Corrections come
///   from a subscription — a network account with a host, a mount point and
///   credentials — and no amount of Bluetooth scanning reveals them. Those are
///   typed once, and the mount point is then filled in from the caster's own
///   source table rather than guessed at.
struct RtkProfile: Identifiable, Codable, Equatable, Hashable {
    var id = UUID()
    var name: String = "New profile"

    /// The receiver this profile connects to, written by scan mode. Nil until
    /// a receiver has been connected while this profile was active.
    var receiver: SavedReceiver?

    // NTRIP caster
    var host: String = ""
    var port: Int = 2101
    var mountPoint: String = ""
    var username: String = ""
    var password: String = ""
    /// Send the receiver's own position to the caster, which most VRS networks
    /// require in order to generate a correction stream for your location.
    ///
    /// Set from the caster's source table when the mount point is picked from
    /// it: the table states per mount point whether a GGA is required, so this
    /// stops being a guess the moment the table has been read.
    var sendPositionToCaster = true

    /// Antenna phase centre relative to the camera, device body axes, metres.
    /// Positive Y is up the pole.
    var leverArmX: Double = 0
    var leverArmY: Double = 0
    var leverArmZ: Double = 0

    /// Antenna height measured from the ground mark to the phase centre. Kept
    /// separate from the lever arm because a surveyor measures and records it
    /// separately, and conflating them is how the two get added twice.
    var antennaHeight: Double = 0

    /// Whether corrections can be fetched. A profile with a receiver and no
    /// caster is still useful — the receiver may have its own correction
    /// source, or be logging autonomous positions — so this is about NTRIP
    /// alone and is never used to gate connecting.
    var isComplete: Bool {
        !host.isEmpty && !mountPoint.isEmpty
    }
}

/// A receiver the app has connected to before, in the form that survives being
/// written to disk.
///
/// Deliberately not a `DiscoveredReceiver`: signal strength and last-seen time
/// describe a moment during a scan and mean nothing a week later, and storing
/// them would invite showing a stale −56 dBm next to a receiver that is not
/// even switched on.
struct SavedReceiver: Codable, Equatable, Hashable {
    var link: ReceiverLink
    /// The CoreBluetooth peripheral identifier, the Bonjour instance name, or
    /// `host:port` — whatever the link uses to find this device again.
    var identifier: String
    var name: String
    /// Where a Wi-Fi receiver was reached. Bluetooth and MFi have no address.
    var host: String?
    var port: Int?
    var lastConnected: Date?

    init(link: ReceiverLink, identifier: String, name: String,
         host: String? = nil, port: Int? = nil, lastConnected: Date? = nil) {
        self.link = link
        self.identifier = identifier
        self.name = name
        self.host = host
        self.port = port
        self.lastConnected = lastConnected
    }

    init(_ found: DiscoveredReceiver, host: String? = nil, port: Int? = nil) {
        self.link = found.link
        self.identifier = found.identifier
        self.name = found.displayName
        // A Wi-Fi receiver reached by a typed address carries that address in
        // its identifier, and pulling it back out is what lets the app reopen
        // the socket after a restart without another scan. A Bonjour service
        // has no address of its own — the name is resolved afresh each time —
        // so it stays nil rather than being invented.
        if let host {
            self.host = host
            self.port = port
        } else if found.link == .wifi, let parsed = ReceiverEndpoint.parse(found.identifier) {
            self.host = parsed.host
            self.port = parsed.port
        } else {
            self.host = nil
            self.port = port
        }
        self.lastConnected = Date()
    }

    /// The same device, in the form the scanner and the transports speak.
    var descriptor: DiscoveredReceiver {
        DiscoveredReceiver(
            link: link,
            identifier: identifier,
            name: name,
            vendor: ReceiverVendor.identify(name),
            detail: host.map { "\($0):\(port ?? ReceiverEndpoint.defaultPort)" },
            advertisesSerialService: true,
            lastSeen: lastConnected ?? .distantPast
        )
    }

    /// Whether two sightings are the same physical device.
    ///
    /// An MFi accessory is matched by name rather than by identifier: iOS hands
    /// out a fresh connection ID every time an accessory is attached, so the
    /// identifier that was saved last week refers to nothing today.
    func isSameDevice(as other: SavedReceiver) -> Bool {
        guard link == other.link else { return false }
        if link == .mfi { return name == other.name }
        return identifier == other.identifier
    }

    var addressLabel: String? {
        guard let host else { return nil }
        return "\(host):\(port ?? ReceiverEndpoint.defaultPort)"
    }
}

/// Where a connected receiver gets written down.
///
/// Connecting to a receiver in scan mode should leave the app knowing about it
/// afterwards — otherwise every session starts by hunting for the same device
/// again, and the profile screen stays a form somebody has to fill in by hand.
enum RtkProfileBinding {

    /// Record `receiver` against a profile, and return the profile it went to.
    ///
    /// The rules, in order:
    ///
    /// 1. A profile already bound to this device wins. Reconnecting the same
    ///    receiver must not accumulate a profile per session.
    /// 2. Otherwise the active profile, if it has no receiver of its own,
    ///    adopts it. This is the common setup order — caster details typed
    ///    first, receiver connected second — and creating a second profile
    ///    there would split one setup across two entries, neither complete.
    /// 3. Otherwise a new profile is created, named after the device.
    ///
    /// Nothing typed is ever overwritten: a caster, credentials and antenna
    /// offsets are the user's, and a scan has no business touching them.
    @discardableResult
    static func remember(
        _ receiver: SavedReceiver,
        in profiles: inout [RtkProfile],
        active: inout UUID?
    ) -> RtkProfile {
        if let index = profiles.firstIndex(where: { $0.receiver?.isSameDevice(as: receiver) == true }) {
            profiles[index].receiver = receiver
            active = profiles[index].id
            return profiles[index]
        }

        if let activeID = active,
           let index = profiles.firstIndex(where: { $0.id == activeID }),
           profiles[index].receiver == nil {
            profiles[index].receiver = receiver
            // A profile still carrying the default name takes the device's,
            // because "New profile" names nothing. One the user has named is
            // left alone.
            if profiles[index].name == RtkProfile().name {
                profiles[index].name = receiver.name
            }
            return profiles[index]
        }

        var profile = RtkProfile()
        profile.name = receiver.name
        profile.receiver = receiver
        profiles.append(profile)
        active = profile.id
        return profile
    }
}
