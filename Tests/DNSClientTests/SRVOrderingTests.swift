import XCTest
@testable import DNSClient

// Deterministic RNG that always returns 0
private struct ZeroRNG: RandomNumberGenerator {
    mutating func next() -> UInt64 { 0 }
}

// Helper to build DNS labels from strings
private func labels(_ parts: [String]) -> [DNSLabel] {
    parts.map { DNSLabel(stringLiteral: $0) }
}

final class SRVEntryOrderingTests: XCTestCase {
    func testPriorityOrdering() {
        // Mixed priorities; lower priority (0) must come first regardless of weights.
        let entries: [SRVEntry] = [
            .init(priority: 10, weight: 1, port: 1, target: "hi1"),
            .init(priority: 0,  weight: 1, port: 1, target: "lo1"),
            .init(priority: 10, weight: 1, port: 1, target: "hi2"),
            .init(priority: 0,  weight: 1, port: 1, target: "lo2"),
        ]

        var rng = ZeroRNG()
        let ordered = rfc2782Order(entries, rng: &rng)
        let priorities = ordered.map { $0.priority }

        // Expect all 0s before any 10s.
        XCTAssertEqual(priorities.prefix(2), [0, 0])
        XCTAssertEqual(priorities.suffix(2), [10, 10])
    }

    func testWeightedSelectionPrefersHigherWeightFirst() {
        // Same priority, weights: 0, 5, 0. With ZeroRNG, the first choice should be the weight=5 entry.
        let entries: [SRVEntry] = [
            .init(priority: 0, weight: 0, port: 1, target: "a"),
            .init(priority: 0, weight: 5, port: 1, target: "b"),
            .init(priority: 0, weight: 0, port: 1, target: "c"),
        ]

        var rng = ZeroRNG()
        let ordered = rfc2782Order(entries, rng: &rng)
        XCTAssertEqual(ordered.first?.target, "b")
    }

    func testAllZeroWeightsProducesPermutation() {
        // All zero weights: selection is uniform random; with ZeroRNG it will pick index 0 repeatedly.
        let entries: [SRVEntry] = [
            .init(priority: 0, weight: 0, port: 1, target: "a"),
            .init(priority: 0, weight: 0, port: 1, target: "b"),
            .init(priority: 0, weight: 0, port: 1, target: "c"),
        ]

        var rng = ZeroRNG()
        let ordered = rfc2782Order(entries, rng: &rng)

        // Verify it's a permutation of inputs.
        XCTAssertEqual(Set(entries.map { $0.target }), Set(ordered.map { $0.target }))
        XCTAssertEqual(entries.count, ordered.count)
    }

    func testNegativeWeightsTreatedAsZero() {
        // Negative weight should be treated as zero by implementation (max(0, weight)).
        let entries: [SRVEntry] = [
            .init(priority: 0, weight: -5, port: 1, target: "neg"),
            .init(priority: 0, weight:  1, port: 1, target: "pos"),
        ]

        var rng = ZeroRNG()
        let ordered = rfc2782Order(entries, rng: &rng)
        XCTAssertEqual(ordered.first?.target, "pos")
    }
}

final class SRVResourceRecordOrderingTests: XCTestCase {
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
