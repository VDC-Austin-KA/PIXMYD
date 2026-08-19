import XCTest
@testable import PIXMYD

/// Tests for the half of scan mode that can be wrong quietly.
///
/// The radios cannot be tested off a phone. What can — and what actually
/// decides whether a scan is usable — is the bookkeeping: which sighting wins
/// when two describe the same device, when a device counts as gone, what the
/// bytes coming off a link turn out to be, and whether a sentence split across
/// two packets survives being reassembled.
final class ReceiverVendorTests: XCTestCase {

    func testVendorIsIdentifiedRegardlessOfCase() {
        XCTAssertEqual(ReceiverVendor.identify("Reach RX"), .emlid)
        XCTAssertEqual(ReceiverVendor.identify("REACH RX 1234"), .emlid)
        XCTAssertEqual(ReceiverVendor.identify("Bad Elf GNSS Surveyor"), .badElf)
        XCTAssertEqual(ReceiverVendor.identify("simpleRTK2B"), .ardusimple)
        XCTAssertEqual(ReceiverVendor.identify("mosaic-X5"), .septentrio)
    }

    func testUnknownAndEmptyNamesAreNotForcedIntoAVendor() {
        // A wrong maker on a row is worse than none: it promotes a pair of
        // headphones to the top of the list, above the receiver.
        XCTAssertNil(ReceiverVendor.identify("Keith's AirPods"))
        XCTAssertNil(ReceiverVendor.identify(""))
        XCTAssertNil(ReceiverVendor.identify(nil))
    }
}

final class ReceiverListTests: XCTestCase {

    private func ble(
        _ identifier: String,
        name: String? = nil,
        rssi: Int? = -60,
        serial: Bool = false,
        seen: Date = Date()
    ) -> DiscoveredReceiver {
        DiscoveredReceiver(
            link: .bluetooth,
            identifier: identifier,
            name: name,
            vendor: ReceiverVendor.identify(name),
            rssi: rssi,
            detail: nil,
            advertisesSerialService: serial,
            lastSeen: seen
        )
    }

    func testRepeatedSightingsCollapseToOneEntry() {
        var list = ReceiverList()
        list.merge(ble("A", name: "Reach RX", rssi: -70))
        list.merge(ble("A", name: "Reach RX", rssi: -55))

        XCTAssertEqual(list.receivers.count, 1)
        XCTAssertEqual(list.receivers.first?.rssi, -55)
    }

    func testANamelessSightingDoesNotEraseAKnownName() {
        // BLE alternates between an advertisement and a scan response and only
        // one carries the local name. Overwriting on every packet makes every
        // row in the list blink between its name and "Unnamed device".
        var list = ReceiverList()
        list.merge(ble("A", name: "Reach RX"))
        list.merge(ble("A", name: nil))

        XCTAssertEqual(list.receivers.first?.name, "Reach RX")
        XCTAssertEqual(list.receivers.first?.vendor, .emlid)
    }

    func testSerialServiceIsRememberedAcrossPacketsThatOmitIt() {
        var list = ReceiverList()
        list.merge(ble("A", name: nil, serial: true))
        list.merge(ble("A", name: nil, serial: false))

        XCTAssertTrue(list.receivers.first?.advertisesSerialService == true)
    }

    func testLikelyReceiversSortAboveTheNoiseAndStrongestFirst() {
        var list = ReceiverList()
        list.merge(ble("noise", name: "Someone's Watch", rssi: -40))
        list.merge(ble("weak", name: "Reach RX", rssi: -85))
        list.merge(ble("strong", name: "Reach RX 2", rssi: -50))

        // The watch has the strongest signal by a distance and must still sort
        // last: proximity is not relevance.
        XCTAssertEqual(list.receivers.map(\.identifier), ["strong", "weak", "noise"])
    }

    func testUnknownDevicesAreHiddenButCounted() {
        var list = ReceiverList()
        list.merge(ble("noise", name: "Someone's Watch"))
        list.merge(ble("real", name: "Reach RX"))

        XCTAssertEqual(list.visible(includingUnknown: false).map(\.identifier), ["real"])
        XCTAssertEqual(list.visible(includingUnknown: true).count, 2)
        XCTAssertEqual(list.hiddenCount, 1)
    }

    func testSilentBluetoothDevicesExpireAndWiFiOnesDoNot() {
        var list = ReceiverList(staleAfter: 10)
        let now = Date()
        list.merge(ble("gone", name: "Reach RX", seen: now.addingTimeInterval(-30)))
        list.merge(ble("here", name: "Reach RX 2", seen: now))
        list.merge(DiscoveredReceiver(
            link: .wifi,
            identifier: "rover._nmea._tcplocal.",
            name: "rover",
            advertisesSerialService: true,
            // A Bonjour service that has not been re-announced is still there;
            // its browser sends an explicit removal when it goes. Ageing it out
            // on a clock would delete a receiver that is working.
            lastSeen: now.addingTimeInterval(-3600)
        ))

        let removed = list.expire(now: now)

        XCTAssertEqual(removed, ["bluetooth:gone"])
        XCTAssertEqual(Set(list.receivers.map(\.identifier)), ["here", "rover._nmea._tcplocal."])
    }

    func testSignalBarsAreNilWhenTheLinkCannotMeasureThem() {
        // Wi-Fi and MFi have no per-device strength. Showing four bars for them
        // would claim a measurement that was never made.
        let wifi = DiscoveredReceiver(link: .wifi, identifier: "x", name: "rover")
        XCTAssertNil(wifi.signalBars)
        XCTAssertEqual(ble("A", rssi: -50).signalBars, 4)
        XCTAssertEqual(ble("A", rssi: -95).signalBars, 0)
    }
}

final class ReceiverEndpointTests: XCTestCase {

    func testHostWithoutPortTakesTheDefault() throws {
        let parsed = try XCTUnwrap(ReceiverEndpoint.parse("192.168.42.1"))
        XCTAssertEqual(parsed.host, "192.168.42.1")
        XCTAssertEqual(parsed.port, ReceiverEndpoint.defaultPort)
    }

    func testHostAndPort() throws {
        let parsed = try XCTUnwrap(ReceiverEndpoint.parse(" reach.local:9001 "))
        XCTAssertEqual(parsed.host, "reach.local")
        XCTAssertEqual(parsed.port, 9001)
    }

    func testPastedUrlIsAccepted() throws {
        let parsed = try XCTUnwrap(ReceiverEndpoint.parse("tcp://10.0.0.5:2101/mount"))
        XCTAssertEqual(parsed.host, "10.0.0.5")
        XCTAssertEqual(parsed.port, 2101)
    }

    func testBracketedIpv6KeepsItsColons() throws {
        let parsed = try XCTUnwrap(ReceiverEndpoint.parse("[fe80::1]:9000"))
        XCTAssertEqual(parsed.host, "fe80::1")
        XCTAssertEqual(parsed.port, 9000)
    }

    func testNonsenseIsRejectedRatherThanGuessedAt() {
        XCTAssertNil(ReceiverEndpoint.parse(""))
        XCTAssertNil(ReceiverEndpoint.parse("   "))
        XCTAssertNil(ReceiverEndpoint.parse("host:0"))
        XCTAssertNil(ReceiverEndpoint.parse("host:70000"))
        XCTAssertNil(ReceiverEndpoint.parse("host:port"))
        XCTAssertNil(ReceiverEndpoint.parse(":9000"))
    }
}

final class ReceiverProbeTests: XCTestCase {

    func testNmeaIsRecognised() {
        let data = Data("$GNGGA,181500.00,3016.500000,N,09745.000000,W,4,18,0.7\r\n".utf8)
        XCTAssertEqual(ReceiverProbe.classify(data), .nmea)
    }

    func testNmeaIsRecognisedWhenItStartsMidChunk() {
        // The first read off a link almost never starts on a sentence boundary.
        var data = Data([0x30, 0x2C, 0x4D, 0x2A, 0x35, 0x0D, 0x0A])
        data.append(Data("$GPGSV,3,1,11,01,80,096,42".utf8))
        XCTAssertEqual(ReceiverProbe.classify(data), .nmea)
    }

    func testRtcmIsNotMistakenForPositions() {
        // 0xD3, six zero bits, a ten-bit length, then payload. A receiver
        // sending this at the phone is wired backwards, and the app has to say
        // so rather than wait forever for a position.
        let data = Data([0xD3, 0x00, 0x13, 0x3E, 0xD0, 0x00, 0x03, 0x8E, 0xD0])
        XCTAssertEqual(ReceiverProbe.classify(data), .rtcm)
    }

    func testUbxBinaryIsNamedSoTheAdviceCanBeSpecific() {
        let data = Data([0xB5, 0x62, 0x01, 0x07, 0x5C, 0x00, 0x00, 0x00])
        XCTAssertEqual(ReceiverProbe.classify(data), .ubx)
        XCTAssertNotNil(ReceiverStreamKind.ubx.advice)
    }

    func testEmptyIsSilentAndNoiseIsUnrecognised() {
        XCTAssertEqual(ReceiverProbe.classify(Data()), .silent)
        XCTAssertEqual(ReceiverProbe.classify(Data([0x01, 0x02, 0x03, 0x04])), .unrecognised)
    }

    func testAStrayPreambleByteIsNotReadAsACorrectionStream() {
        // 0xD3 followed by bits that are not a legal RTCM header. Claiming a
        // correction stream here would send the user to check the wrong thing.
        XCTAssertEqual(ReceiverProbe.classify(Data([0xD3, 0xFF, 0x40, 0x11])), .unrecognised)
    }

    func testOnlyNmeaHasNoAdvice() {
        // Every other outcome must tell the user what to do about it.
        XCTAssertNil(ReceiverStreamKind.nmea.advice)
        for kind in [ReceiverStreamKind.rtcm, .ubx, .unrecognised, .silent] {
            XCTAssertNotNil(kind.advice, "\(kind) needs advice")
        }
    }
}

final class NmeaLineBufferTests: XCTestCase {

    func testSentenceSplitAcrossPacketsIsReassembled() {
        // A BLE notification is twenty bytes by default, so this is the normal
        // case rather than an edge one.
        var buffer = NmeaLineBuffer()
        XCTAssertTrue(buffer.append(Data("$GNGGA,181500.00,301".utf8)).isEmpty)
        XCTAssertTrue(buffer.append(Data("6.500000,N,097".utf8)).isEmpty)
        let lines = buffer.append(Data("45.000000,W*4F\r\n".utf8))

        XCTAssertEqual(lines, ["$GNGGA,181500.00,3016.500000,N,09745.000000,W*4F"])
    }

    func testSeveralSentencesInOneReadComeOutSeparately() {
        var buffer = NmeaLineBuffer()
        let lines = buffer.append(Data("$GPGGA,1\r\n$GPGST,2\r\n$GPRMC,3".utf8))

        XCTAssertEqual(lines, ["$GPGGA,1", "$GPGST,2"])
        // The third has no newline yet and must be held, not emitted early.
        XCTAssertEqual(buffer.append(Data("\r\n".utf8)), ["$GPRMC,3"])
    }

    func testBinaryBytesDoNotDiscardTheSentencesAroundThem() {
        // Decoding each chunk as ASCII on arrival threw away the whole read
        // when a receiver interleaved binary, taking any complete sentences in
        // it with them.
        var buffer = NmeaLineBuffer()
        var data = Data([0xD3, 0x00, 0x13, 0x80])
        data.append(Data("$GPGGA,1\r\n".utf8))
        let lines = buffer.append(data)

        XCTAssertEqual(lines, ["$GPGGA,1"])
    }

    func testBinaryWithNoNewlineIsBoundedRatherThanGrowingForever() {
        var buffer = NmeaLineBuffer(limit: 64)
        for _ in 0..<10 {
            XCTAssertTrue(buffer.append(Data(repeating: 0xB5, count: 32)).isEmpty)
        }
        // Once the ceiling drops the junk, real sentences still get through.
        XCTAssertEqual(buffer.append(Data("$GPGGA,1\r\n".utf8)), ["$GPGGA,1"])
    }

    func testAssemblerStillRejectsACorruptedReassembledSentence() {
        // The buffer must not repair anything. A sentence corrupted in transit
        // has to arrive corrupted so the checksum can throw it away.
        var buffer = NmeaLineBuffer()
        let assembler = NmeaAssembler()
        let lines = buffer.append(Data(
            "$GPGGA,123519,4817.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*47\r\n".utf8
        ))

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(Nmea.parse(lines[0])?.valid, false)
        XCTAssertNil(assembler.push(lines[0], since: Date()))
    }
}
