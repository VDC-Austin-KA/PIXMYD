import XCTest
@testable import PIXMYD

/// What a scan is allowed to write into a profile, and what it must not touch.
final class RtkProfileBindingTests: XCTestCase {

    private func receiver(
        _ identifier: String,
        name: String = "Reach RX",
        link: ReceiverLink = .bluetooth
    ) -> SavedReceiver {
        SavedReceiver(link: link, identifier: identifier, name: name)
    }

    func testFirstConnectionCreatesAProfileNamedAfterTheDevice() {
        var profiles: [RtkProfile] = []
        var active: UUID?

        let profile = RtkProfileBinding.remember(receiver("A"), in: &profiles, active: &active)

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profile.name, "Reach RX")
        XCTAssertEqual(profile.receiver?.identifier, "A")
        XCTAssertEqual(active, profile.id)
    }

    func testReconnectingTheSameDeviceDoesNotPileUpProfiles() {
        // A profile per session would turn the profiles screen into a log.
        var profiles: [RtkProfile] = []
        var active: UUID?

        let first = RtkProfileBinding.remember(receiver("A"), in: &profiles, active: &active)
        let second = RtkProfileBinding.remember(receiver("A"), in: &profiles, active: &active)

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(first.id, second.id)
    }

    func testAnActiveProfileWithNoReceiverAdoptsTheOneJustConnected() {
        // The common setup order: caster details typed first, receiver scanned
        // second. Creating a second profile here would split one setup across
        // two entries, neither of them complete.
        var typed = RtkProfile()
        typed.name = "Site network"
        typed.host = "rtk.example.com"
        typed.mountPoint = "VRS32"
        typed.username = "surveyor"
        typed.password = "secret"
        var profiles = [typed]
        var active: UUID? = typed.id

        let bound = RtkProfileBinding.remember(receiver("A"), in: &profiles, active: &active)

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(bound.id, typed.id)
        XCTAssertEqual(bound.receiver?.identifier, "A")
        // Nothing typed may be disturbed.
        XCTAssertEqual(bound.name, "Site network")
        XCTAssertEqual(bound.host, "rtk.example.com")
        XCTAssertEqual(bound.mountPoint, "VRS32")
        XCTAssertEqual(bound.password, "secret")
    }

    func testAnUnnamedActiveProfileTakesTheDeviceName() {
        let blank = RtkProfile()
        var profiles = [blank]
        var active: UUID? = blank.id

        let bound = RtkProfileBinding.remember(receiver("A"), in: &profiles, active: &active)

        XCTAssertEqual(bound.name, "Reach RX")
    }

    func testASecondDeviceGetsItsOwnProfileRatherThanStealingTheFirst() {
        var profiles: [RtkProfile] = []
        var active: UUID?
        RtkProfileBinding.remember(receiver("A", name: "Reach RX"), in: &profiles, active: &active)
        RtkProfileBinding.remember(receiver("B", name: "Bad Elf Flex"), in: &profiles, active: &active)

        XCTAssertEqual(profiles.count, 2)
        XCTAssertEqual(profiles[0].receiver?.identifier, "A")
        XCTAssertEqual(profiles[1].receiver?.identifier, "B")
        XCTAssertEqual(active, profiles[1].id)
    }

    func testMfiAccessoriesAreMatchedByNameBecauseTheirIdChangesEveryTime() {
        // iOS hands out a fresh connection ID each time an accessory is
        // attached, so matching on it would create a profile per plug-in.
        var profiles: [RtkProfile] = []
        var active: UUID?
        RtkProfileBinding.remember(
            receiver("11", name: "Bad Elf GNSS Surveyor", link: .mfi),
            in: &profiles, active: &active
        )
        RtkProfileBinding.remember(
            receiver("47", name: "Bad Elf GNSS Surveyor", link: .mfi),
            in: &profiles, active: &active
        )

        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].receiver?.identifier, "47")
    }

    func testTheSameIdentifierOnADifferentLinkIsADifferentDevice() {
        var profiles: [RtkProfile] = []
        var active: UUID?
        RtkProfileBinding.remember(receiver("A", link: .bluetooth), in: &profiles, active: &active)
        RtkProfileBinding.remember(receiver("A", link: .wifi), in: &profiles, active: &active)

        XCTAssertEqual(profiles.count, 2)
    }

    func testAWiFiReceiverKeepsItsAddressSoItCanBeReopenedWithoutAScan() {
        let found = DiscoveredReceiver(link: .wifi, identifier: "192.168.42.1:9000", name: "rover")
        let saved = SavedReceiver(found)

        XCTAssertEqual(saved.host, "192.168.42.1")
        XCTAssertEqual(saved.port, 9000)
        XCTAssertEqual(saved.addressLabel, "192.168.42.1:9000")
    }

    func testABluetoothReceiverIsNotGivenAnInventedAddress() {
        let found = DiscoveredReceiver(link: .bluetooth, identifier: "6C6F-…", name: "Reach RX")
        XCTAssertNil(SavedReceiver(found).host)
        XCTAssertNil(SavedReceiver(found).addressLabel)
    }

    func testASavedReceiverSurvivesARoundTripThroughDisk() throws {
        // Profiles are persisted as JSON in UserDefaults; a receiver that
        // cannot be decoded again is a profile that silently forgets its
        // device on the next launch.
        var profile = RtkProfile()
        profile.receiver = SavedReceiver(
            DiscoveredReceiver(link: .wifi, identifier: "10.0.0.5:9001", name: "Reach RS3")
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(RtkProfile.self, from: data)

        XCTAssertEqual(decoded.receiver, profile.receiver)
        XCTAssertEqual(decoded.receiver?.port, 9001)
    }

    func testAProfileSavedBeforeReceiversExistedStillDecodes() throws {
        // Every profile already on someone's phone was written without a
        // receiver field. Failing to decode those would wipe their casters.
        let legacy = """
        {"id":"\(UUID().uuidString)","name":"Old profile","host":"rtk.example.com","port":2101,
         "mountPoint":"VRS32","username":"u","password":"p","sendPositionToCaster":true,
         "leverArmX":0,"leverArmY":0,"leverArmZ":0,"antennaHeight":0}
        """
        let decoded = try JSONDecoder().decode(RtkProfile.self, from: Data(legacy.utf8))

        XCTAssertNil(decoded.receiver)
        XCTAssertEqual(decoded.mountPoint, "VRS32")
    }
}

/// Reading a caster's source table, which is where the mount point stops being
/// something typed from memory.
final class NtripSourceTableTests: XCTestCase {

    private let table = """
    SOURCETABLE 200 OK\r
    Server: NTRIP Caster 2.0\r
    \r
    CAS;rtk.example.com;2101;EXAMPLE;Example;0;USA;30.27;-97.74;0.0.0.0;0;
    NET;EXAMPLE;Example Network;B;N;http://example.com;;support@example.com;none
    STR;AUSTIN_RTCM3;Austin;RTCM 3.2;1004(1),1005(5);2;GPS+GLO;EXAMPLE;USA;30.27;-97.74;0;0;SNIP;none;B;N;9600;
    STR;VRS32;Texas VRS;RTCM 3.2;1004(1);2;GPS+GLO+GAL;EXAMPLE;USA;31.00;-99.00;1;0;SNIP;none;B;N;9600;
    STR;HOUSTON;Houston;RTCM 3.1;1004(1);2;GPS;EXAMPLE;USA;29.76;-95.37;0;0;SNIP;none;N;N;9600;
    ENDSOURCETABLE\r
    """

    func testOnlyStreamRecordsBecomeMountPoints() {
        let points = NtripSourceTable.parse(table)
        XCTAssertEqual(points.map(\.mountPoint), ["AUSTIN_RTCM3", "VRS32", "HOUSTON"])
    }

    func testTheTableSaysWhichStreamsNeedAPositionReport() {
        // The difference between a VRS that works and one that connects,
        // delivers for a minute and goes quiet.
        let points = NtripSourceTable.parse(table)
        XCTAssertEqual(points.first { $0.mountPoint == "VRS32" }?.requiresPosition, true)
        XCTAssertEqual(points.first { $0.mountPoint == "AUSTIN_RTCM3" }?.requiresPosition, false)
    }

    func testAuthenticationIsReadFromTheTableAndNoneMeansNone() {
        let points = NtripSourceTable.parse(table)
        XCTAssertEqual(points.first { $0.mountPoint == "AUSTIN_RTCM3" }?.requiresAuthentication, true)
        XCTAssertEqual(points.first { $0.mountPoint == "HOUSTON" }?.requiresAuthentication, false)
    }

    func testFormatAndConstellationsAreCarriedThrough() throws {
        let austin = try XCTUnwrap(NtripSourceTable.parse(table).first)
        XCTAssertEqual(austin.identifier, "Austin")
        XCTAssertEqual(austin.format, "RTCM 3.2")
        XCTAssertEqual(austin.navSystem, "GPS+GLO")
        XCTAssertEqual(austin.country, "USA")
    }

    func testAShortRecordStillYieldsAUsableMountPoint() {
        // Casters differ in how many trailing fields they send. Refusing to
        // parse a short record would be choosing no information over partial.
        let points = NtripSourceTable.parse("STR;BASE1;;;;;;;;;;\nSTR;BASE2")
        XCTAssertEqual(points.map(\.mountPoint), ["BASE1", "BASE2"])
        XCTAssertNil(points[0].latitude)
        XCTAssertFalse(points[1].requiresPosition)
    }

    func testNearestBaseComesFirst() {
        // Austin. The Houston and statewide VRS entries are hundreds of
        // kilometres away, and picking a base by scrolling is how someone ends
        // up on one 300 km from the site.
        let ordered = NtripSourceTable.ordered(
            NtripSourceTable.parse(table),
            near: (latitude: 30.2672, longitude: -97.7431)
        )
        // Austin, then the statewide VRS reference point ~150 km away, then
        // Houston at ~235 km.
        XCTAssertEqual(ordered.map(\.mountPoint), ["AUSTIN_RTCM3", "VRS32", "HOUSTON"])
    }

    func testMountPointsWithNoCoordinatesAreKeptAtTheEndRatherThanDropped() {
        // On a single-base caster the entry with no location is often the only
        // one there is.
        var points = NtripSourceTable.parse(table)
        points.append(NtripMountPoint(
            mountPoint: "NOWHERE", identifier: "", format: "", navSystem: "", country: "",
            latitude: nil, longitude: nil, requiresPosition: false, requiresAuthentication: false
        ))
        let ordered = NtripSourceTable.ordered(points, near: (latitude: 30.2672, longitude: -97.7431))

        XCTAssertEqual(ordered.count, 4)
        XCTAssertEqual(ordered.last?.mountPoint, "NOWHERE")
    }

    func testOrderIsUntouchedWhenTheRoverHasNoPosition() {
        let points = NtripSourceTable.parse(table)
        XCTAssertEqual(NtripSourceTable.ordered(points, near: nil).map(\.mountPoint),
                       points.map(\.mountPoint))
    }

    func testDistanceIsRightToWithinAKilometre() throws {
        // Austin to Houston is about 235 km.
        let houston = try XCTUnwrap(NtripSourceTable.parse(table).first { $0.mountPoint == "HOUSTON" })
        let metres = try XCTUnwrap(houston.distance(fromLatitude: 30.2672, longitude: -97.7431))
        XCTAssertEqual(metres / 1000, 235, accuracy: 5)
    }
}
