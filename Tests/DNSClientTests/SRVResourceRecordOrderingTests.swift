import XCTest
@testable import DNSClient

final class SRVResourceRecordOrderingTests: XCTestCase {
    private func labels(_ parts: [String]) -> [DNSLabel] {
        parts.map { DNSLabel(stringLiteral: $0) }
    }

    func testRFC2782Ordering_MirrorsDigExample() {
        // Mirror: _xmpp-client._tcp.conversations.im SRV
        // 5 0 5222 xmpp.conversations.im.
        // 10 0 80  xmpps.conversations.im.

        let owner = labels(["_xmpp-client", "_tcp", "conversations", "im", ""]) // owner name

        let r1 = SRVRecord(priority: 5,
                           weight: 0,
                           port: 5222,
                           domainName: labels(["xmpp", "conversations", "im", ""]))
        let rr1 = ResourceRecord(domainName: owner,
                                 dataType: 33, // SRV
                                 dataClass: 1, // IN
                                 ttl: 3600,
                                 resource: r1)

        let r2 = SRVRecord(priority: 10,
                           weight: 0,
                           port: 80,
                           domainName: labels(["xmpps", "conversations", "im", ""]))
        let rr2 = ResourceRecord(domainName: owner,
                                 dataType: 33,
                                 dataClass: 1,
                                 ttl: 3600,
                                 resource: r2)

        let ordered = rfc2782Order([rr2, rr1]) // intentionally out of order

        XCTAssertEqual(ordered.count, 2)
        XCTAssertEqual(ordered[0].resource.priority, 5)
        XCTAssertEqual(ordered[0].resource.port, 5222)
        XCTAssertEqual(ordered[0].resource.domainName.string, "xmpp.conversations.im")

        XCTAssertEqual(ordered[1].resource.priority, 10)
        XCTAssertEqual(ordered[1].resource.port, 80)
        XCTAssertEqual(ordered[1].resource.domainName.string, "xmpps.conversations.im")
    }
}

