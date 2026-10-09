import Foundation
import Network
import XCTest
@testable import ViewTheWordCore

final class AltViewConfidenceTests: XCTestCase {
    func testThisMacDiscoveryUsesActualPortStableAccountAndRemoteFallback() throws {
        let id = UUID(), marker = "boot"
        let discovery = AltViewReceiverDiscovery { _, _ in }
        let endpoint = NWEndpoint.service(name: "AltView", type: AltViewProtocol.serviceType, domain: "local.", interface: nil)
        func destination(_ port: String, marker advertised: String = "boot") throws -> AltViewDestination {
            let found = try XCTUnwrap(discovery.receiver(endpoint: endpoint, metadata: .bonjour(NWTXTRecord(["receiverID": id.uuidString, "localMarker": advertised, "port": port])), localMarker: marker))
            return try XCTUnwrap(AltViewDestination(found))
        }
        let first = try destination("54321"), second = try destination("54322")
        XCTAssertEqual(first.localReceiverID, id); XCTAssertEqual(first.host, "127.0.0.1")
        XCTAssertEqual(first.account, second.account)
        XCTAssertEqual(second.endpoint, .hostPort(host: "127.0.0.1", port: .init(rawValue: 54322)!))
        XCTAssertTrue(first.isValid)
        XCTAssertNil(try destination("54321", marker: "another-boot").localReceiverID)
        XCTAssertNil(try destination("0").localReceiverID)
        XCTAssertFalse(AltViewDestination(name: "Manual", host: "127.0.0.1").isValid, "Manual connections require the receiver’s actual port")
    }
    func testSecondaryConfidenceRoundTripsAndSingleTranslationHasNoSecondary() throws {
        let content = AltViewDisplayContent(body: "Audience primary", confidence: .init(title: "John 3:16", body: "Primary",
            footer: "NIV", secondary: .init(body: "Secondary", footer: "NLT")))
        var decoder = AltViewFrameDecoder()
        XCTAssertEqual(try decoder.append(AltViewFrameCodec.encode(.init(kind: .state, content: content))).first?.content, content)
        let single = AltViewConfidenceText(title: "John 3:16", body: "Primary", footer: "NIV")
        XCTAssertNil(try JSONDecoder().decode(AltViewConfidenceText.self, from: JSONEncoder().encode(single)).secondary)
        var oversized = content
        oversized.confidence?.secondary?.body = String(repeating: "é", count: 12_001)
        XCTAssertFalse(oversized.isValid)
        oversized.confidence?.secondary = .init(body: "Secondary", footer: String(repeating: "é", count: 513))
        XCTAssertFalse(oversized.isValid)
    }
    func testConfidenceTextExtensionRoundTripsAndDoesNotChangeAudienceVisibility() throws {
        let content = AltViewDisplayContent(title: "John 3:16", body: "Primary verse", footer: "Primary name", visible: false,
            confidence: .init(title: "John 3:16", body: "Primary verse", footer: "Primary name"))
        var decoder = AltViewFrameDecoder()
        let message = AltViewWireMessage(kind: .state, content: content)
        XCTAssertEqual(try decoder.append(AltViewFrameCodec.encode(message)).first?.content, content)
        XCTAssertFalse(content.visible)
        XCTAssertEqual(content.confidence?.body, "Primary verse")
        XCTAssertTrue(content.isValid)
    }
}
