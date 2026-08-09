import XCTest
@testable import PIXMYD

/// The sentences below are real receiver output shapes, not invented ones. The
/// checksums are computed by hand in `checksum(for:)` and appended, so a test
/// can never accidentally pass because both sides made the same mistake.
private func nmea(_ body: String) -> String {
    var sum: UInt8 = 0
    for byte in body.utf8 { sum ^= byte }
    return String(format: "$%@*%02X", body, sum)
}

final class NmeaParsingTests: XCTestCase {

    func testChecksumRejectsCorruptedSentence() {
        let good = nmea("GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,")
        XCTAssertEqual(Nmea.parse(good)?.valid, true)

        // Flip one digit of the latitude and leave the checksum alone. This is
        // exactly what a dropped byte on a Bluetooth serial link looks like,
        // and the resulting latitude is entirely plausible — 48.2 degrees north
        // instead of 48.1 — which is why the checksum is the only defence.
        let corrupted = good.replacingOccurrences(of: "4807.038", with: "4817.038")
        XCTAssertEqual(Nmea.parse(corrupted)?.valid, false)

        let assembler = NmeaAssembler()
        XCTAssertNil(assembler.push(corrupted, since: Date()))
    }

    func testCoordinateConversionAndHemisphere() throws {
        // 4807.038 is 48 degrees 07.038 minutes = 48.1173 degrees.
        let lat = try XCTUnwrap(Nmea.coordinate("4807.038", hemisphere: "N"))
        XCTAssertEqual(lat, 48 + 7.038 / 60, accuracy: 1e-12)

        // South and west are negative. Note the magnitude is unsigned in the
        // sentence — the sign lives entirely in the hemisphere field, so a
        // parser that ignores it puts the site in the wrong quadrant.
        let south = try XCTUnwrap(Nmea.coordinate("4807.038", hemisphere: "S"))
        XCTAssertEqual(south, -lat, accuracy: 1e-12)

        // Longitude is dddmm.mmmm — three degree digits, not two.
        let lon = try XCTUnwrap(Nmea.coordinate("09731.500", hemisphere: "W"))
        XCTAssertEqual(lon, -(97 + 31.5 / 60), accuracy: 1e-12)
    }

    func testUtcSecondsKeepsSubSecondPrecision() throws {
        let t = try XCTUnwrap(Nmea.utcSeconds("123519.25"))
        XCTAssertEqual(t, 12 * 3600 + 35 * 60 + 19.25, accuracy: 1e-9)
        XCTAssertNil(Nmea.utcSeconds("1235"))
    }

    func testGgaHeightIsConvertedToEllipsoidal() throws {
        // GGA field 9 is height above the geoid, field 11 is the geoid
        // separation. Ellipsoidal height is their sum. Treating the orthometric
        // height as ellipsoidal is a ~27 m error in central Texas.
        let sentence = nmea("GNGGA,181500.00,3016.500000,N,09745.000000,W,4,18,0.7,182.400,M,-26.300,M,1.0,0000")
        let assembler = NmeaAssembler()
        let fix = try XCTUnwrap(assembler.push(sentence, since: Date()) ?? assembler.flush())

        XCTAssertEqual(fix.orthometricHeight, 182.4)
        XCTAssertEqual(fix.geoidSeparation, -26.3)
        XCTAssertEqual(fix.height, 182.4 - 26.3, accuracy: 1e-9)
        XCTAssertEqual(fix.quality, .rtkFixed)
        XCTAssertTrue(fix.quality.isSurveyGrade)
    }

    func testFloatFixIsNotSurveyGrade() throws {
        // Quality 5 renders identically to 4 on most receivers' displays and is
        // decimetres out. The distinction has to survive parsing.
        let sentence = nmea("GNGGA,181500.00,3016.500000,N,09745.000000,W,5,18,0.7,182.400,M,-26.300,M,1.0,0000")
        let assembler = NmeaAssembler()
        _ = assembler.push(sentence, since: Date())
        let fix = try XCTUnwrap(assembler.flush())
        XCTAssertEqual(fix.quality, .rtkFloat)
        XCTAssertFalse(fix.quality.isSurveyGrade)
    }

    func testGgaWithoutGstCarriesNoAccuracy() throws {
        // HDOP is a geometry factor, not an accuracy. A fix with no GST must
        // report no accuracy rather than borrowing HDOP, which would be a
        // number the receiver never claimed.
        let assembler = NmeaAssembler()
        _ = assembler.push(
            nmea("GNGGA,181500.00,3016.500000,N,09745.000000,W,4,18,0.7,182.400,M,-26.300,M,1.0,0000"),
            since: Date()
        )
        let fix = try XCTUnwrap(assembler.flush())
        XCTAssertEqual(fix.hdop, 0.7)
        XCTAssertNil(fix.hAccuracy)
        XCTAssertNil(fix.vAccuracy)
    }

    func testGstPairsWithGgaAtTheSameEpoch() throws {
        let assembler = NmeaAssembler()
        let epoch = Date()

        XCTAssertNil(assembler.push(
            nmea("GNGGA,181500.00,3016.500000,N,09745.000000,W,4,18,0.7,182.400,M,-26.300,M,1.0,0000"),
            since: epoch
        ))

        // GST fields: utc, rms, semi-major, semi-minor, orientation, lat sigma,
        // lon sigma, height sigma.
        let fix = try XCTUnwrap(assembler.push(
            nmea("GNGST,181500.00,0.012,0.011,0.008,32.1,0.008,0.009,0.017"),
            since: epoch
        ))

        XCTAssertEqual(try XCTUnwrap(fix.hAccuracy), (0.008 * 0.008 + 0.009 * 0.009).squareRoot(), accuracy: 1e-12)
        XCTAssertEqual(fix.vAccuracy, 0.017)
    }

    func testGstFromADifferentEpochIsNotPaired() throws {
        let assembler = NmeaAssembler()
        let epoch = Date()

        _ = assembler.push(
            nmea("GNGGA,181500.00,3016.500000,N,09745.000000,W,4,18,0.7,182.400,M,-26.300,M,1.0,0000"),
            since: epoch
        )
        // One full second later: a different epoch entirely, so pairing it
        // would attach one position's accuracy to another position.
        XCTAssertNil(assembler.push(
            nmea("GNGST,181501.00,0.012,0.011,0.008,32.1,0.008,0.009,0.017"),
            since: epoch
        ))

        let fix = try XCTUnwrap(assembler.flush())
        XCTAssertNil(fix.hAccuracy)
    }

    func testFixTimesAreRelativeToTheFirstFix() throws {
        let assembler = NmeaAssembler()
        let epoch = Date()

        let first = assembler.push(
            nmea("GNGGA,181500.00,3016.500000,N,09745.000000,W,4,18,0.7,182.400,M,-26.300,M,1.0,0000"),
            since: epoch
        )
        // The second GGA flushes the first one out.
        let flushed = try XCTUnwrap(first ?? assembler.push(
            nmea("GNGGA,181502.50,3016.500100,N,09745.000000,W,4,18,0.7,182.400,M,-26.300,M,1.0,0000"),
            since: epoch
        ))
        XCTAssertEqual(flushed.t, 0, accuracy: 1e-9)

        let second = try XCTUnwrap(assembler.flush())
        XCTAssertEqual(second.t, 2.5, accuracy: 1e-9)
    }

    func testNonPositionSentencesAreIgnored() {
        let assembler = NmeaAssembler()
        XCTAssertNil(assembler.push(nmea("GPGSV,3,1,11,03,03,111,00"), since: Date()))
        XCTAssertNil(assembler.push("not a sentence", since: Date()))
        XCTAssertNil(assembler.flush())
    }
}
