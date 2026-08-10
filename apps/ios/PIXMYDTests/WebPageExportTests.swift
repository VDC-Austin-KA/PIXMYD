import Foundation
import XCTest
@testable import PIXMYD

/// The web page is the format handed to people who will not install anything,
/// so the failure that matters is a page that opens and shows nothing. These
/// check the two ways that happens: a payload that does not decode, and a
/// resource the browser cannot fetch.
final class WebPageExportTests: XCTestCase {

    private var directory = URL(fileURLWithPath: NSTemporaryDirectory())

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pixmyd-webpage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Not a real GLB — these tests are about the wrapper, and a byte pattern
    /// makes a truncation or an off-by-one in the encoding obvious.
    private func payload(_ count: Int = 4096) -> Data {
        Data((0..<count).map { UInt8($0 & 0xff) })
    }

    private func write(
        glb: Data,
        name: String = "Bay 4",
        capturedAt: Date? = nil,
        facts: [WebPageExport.Fact] = []
    ) throws -> String {
        let url = directory.appendingPathComponent("page.html")
        try WebPageExport.write(
            glb: glb, name: name, capturedAt: capturedAt, facts: facts, to: url
        )
        return try String(contentsOf: url, encoding: .utf8)
    }

    func testTheModelSurvivesTheRoundTrip() throws {
        let glb = payload()
        let html = try write(glb: glb)

        let pattern = try NSRegularExpression(pattern: "base64,([A-Za-z0-9+/=]+)\"")
        let range = NSRange(html.startIndex..., in: html)
        let match = try XCTUnwrap(pattern.firstMatch(in: html, range: range))
        let encoded = String(html[Range(match.range(at: 1), in: html)!])

        // A viewer decodes exactly these bytes. If the encoding is wrong the
        // page renders an empty scene and reports nothing.
        XCTAssertEqual(Data(base64Encoded: encoded), glb)
    }

    func testNothingIsFetchedFromTheNetworkButTheViewer() throws {
        let html = try write(glb: payload())

        // Anything the page *fetches* is a way for it to fail on someone
        // else's machine. A link the reader clicks is not in that category, so
        // this looks at src= and <link> only.
        let pattern = try NSRegularExpression(
            pattern: "(?:\\bsrc=\"|<link\\b[^>]*\\bhref=\")(https?://[^\"]+)"
        )
        let range = NSRange(html.startIndex..., in: html)
        let matches = pattern.matches(in: html, range: range).map {
            String(html[Range($0.range(at: 1), in: html)!])
        }

        XCTAssertEqual(matches.count, 1, "unexpected external loads: \(matches)")
        XCTAssertTrue(matches[0].contains("model-viewer"))
    }

    func testTheScanNameIsEscapedRatherThanInjected() throws {
        // Project names are typed on a phone and go straight into markup. A
        // name with a quote in it must not close an attribute and start
        // writing tags.
        let html = try write(
            glb: payload(64),
            name: "\"><script>alert(1)</script>",
            facts: [.init(label: "<b>x</b>", value: "\"y\"")]
        )

        XCTAssertFalse(html.contains("<script>alert(1)</script>"), "name injected as markup")
        XCTAssertTrue(html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("&lt;b&gt;x&lt;/b&gt;"))
        XCTAssertTrue(html.contains("&quot;y&quot;"))
    }

    func testFactsAppearAndAreOmittedWhenEmpty() throws {
        let withFacts = try write(
            glb: payload(64),
            capturedAt: Date(timeIntervalSince1970: 1_775_000_000),
            facts: [
                .init(label: "Triangles", value: "48210"),
                .init(label: "Resolution", value: "25 mm"),
            ]
        )
        XCTAssertTrue(withFacts.contains("Triangles"))
        XCTAssertTrue(withFacts.contains("48210"))
        XCTAssertTrue(withFacts.contains("25 mm"))
        XCTAssertTrue(withFacts.contains("Captured"))

        let without = try write(glb: payload(64))
        XCTAssertFalse(without.contains("<dl>"), "an empty fact list still rendered a container")
        XCTAssertFalse(without.contains("Captured"))
    }

    func testTheDocumentIsWellFormedEnoughToParse() throws {
        let html = try write(glb: payload(64), facts: [.init(label: "A", value: "1")])

        XCTAssertTrue(html.hasPrefix("<!doctype html>"))
        XCTAssertTrue(html.contains("</html>"))
        // Balanced enough that a browser will not guess: every tag opened in
        // the template is closed.
        for tag in ["html", "head", "body", "header", "footer", "model-viewer", "style"] {
            XCTAssertEqual(
                html.components(separatedBy: "</\(tag)>").count - 1, 1,
                "\(tag) is not closed exactly once"
            )
        }
    }

    func testAModelOfRealisticSizeIsHandled() throws {
        // 8 MB, roughly a decimated room. Base64 of that is 11 MB of string,
        // and the point is that nothing here chunks or truncates.
        let glb = payload(8 * 1024 * 1024)
        let url = directory.appendingPathComponent("big.html")
        try WebPageExport.write(
            glb: glb, name: "Big", capturedAt: nil, facts: [], to: url
        )

        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        // Base64 is 4 bytes out of every 3, so the page must be at least a
        // third larger than the model. A much smaller file means truncation.
        XCTAssertGreaterThan(try XCTUnwrap(size), glb.count * 4 / 3)
    }
}
