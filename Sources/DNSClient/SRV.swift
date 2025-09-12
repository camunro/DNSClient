import NIO

/// A DNS SRV record. This is used to specify the location of a service.
public struct SRVRecord: DNSResource {
    /// The priority of this record. Lower values are preferred. This is used to balance load between multiple servers. If two records have the same priority, the weight is used to balance load.
    public let priority: UInt16

    /// The weight of this record. Higher values are preferred. This is used to balance load between multiple servers. If two records have the same priority, the weight is used to balance load.
    public let weight: UInt16

    /// The port of the service.
    public let port: UInt16

    /// The domain name of the service. This can be used to resolve the IP address of the service.
    public let domainName: [DNSLabel]

    public static func read(from buffer: inout ByteBuffer, length: Int) -> SRVRecord? {
        guard
            let priority = buffer.readInteger(endianness: .big, as: UInt16.self),
            let weight = buffer.readInteger(endianness: .big, as: UInt16.self),
            let port = buffer.readInteger(endianness: .big, as: UInt16.self),
            let domainName = buffer.readLabels()
        else {
            return nil
        }

        return SRVRecord(priority: priority, weight: weight, port: port, domainName: domainName)
    }

    public func write(into buffer: inout ByteBuffer, labelIndices: inout [String: UInt16]) -> Int {
        var length = buffer.writeInteger(priority)
        length += buffer.writeInteger(weight)
        length += buffer.writeInteger(port)
        return length + buffer.writeCompressedLabels(domainName, labelIndices: &labelIndices)
    }
}

import Foundation

/// Minimal DTO you can build from DNSClient’s `ResourceRecord<SRVRecord>`
public struct SRVEntry: Sendable {
    public let priority: Int
    public let weight: Int
    public let port: Int
    public let target: String
    
    public init(priority: Int, weight: Int, port: Int, target: String) {
        self.priority = priority
        self.weight = weight
        self.port = port
        self.target = target
    }
}

/// RFC 2782 ordering:
/// 1) Process records by ascending `priority`.
/// 2) Within each priority, perform weighted-random selection until the set is exhausted.
///
///  What RFC 2782 requires
///
/// - Priority first: choose the lowest numeric priority; only if no target from that group works do ///you move to the next.
/// - Weighted selection within a priority:
///    - If sum(weights) > 0: pick ///one target with probability ///weight/total.
///    - If sum(weights) == 0: pick ///uniformly at random among the ///remaining targets.
///    - Remove the chosen target and ///repeat until the set is ///exhausted.
///
/// - Parameters:
///   - entries: [SRVEntry]
///   - rng: Random number generator
/// - Returns: compliant to RFC2782 ordering requirements [SRVEntry]
/// - Complexity: O(n^2) per priority group is fine for typical SRV set sizes.

public func rfc2782Order<RNG: RandomNumberGenerator>(_ entries: [SRVEntry], rng: inout RNG) -> [SRVEntry] {
    // Group by priority (lowest first), RFC 2782 §3
    let byPriority = Dictionary(grouping: entries, by: { $0.priority }).sorted { $0.key < $1.key }

    var result: [SRVEntry] = []

    for (_, group) in byPriority {
        // Within a single priority, repeatedly select one target by weight
        // (RFC 2782 weighted selection) until the group is exhausted.
        var pool = group
        while !pool.isEmpty {
            let totalWeight = pool.reduce(0) { $0 + max(0, $1.weight) }

            let chosenIndex: Int
            if totalWeight == 0 {
                // RFC 2782: if all weights are zero, select uniformly at random.
                chosenIndex = randomBelow(pool.count, using: &rng)
            } else {
                // Pick a random number R in [0, totalWeight - 1] and select the first
                // record whose cumulative weight exceeds R.
                var r = randomBelow(totalWeight, using: &rng)
                var i = 0
                while i < pool.count {
                    r -= max(0, pool[i].weight)
                    if r < 0 { break }
                    i += 1
                }
                chosenIndex = min(i, pool.count - 1) // defensive clamp
            }

            result.append(pool.remove(at: chosenIndex))
        }
    }

    return result
}

// Convenience overload with system RNG
public func rfc2782Order(_ entries: [SRVEntry]) -> [SRVEntry] {
    var rng = SystemRandomNumberGenerator()
    return rfc2782Order(entries, rng: &rng)
}

//    // Suppose `srvRRs: [ResourceRecord<SRVRecord>]` from client.getSRVRecords(...).get()
//    let entries = srvRRs.map { rr in
//        SRVEntry(
//            priority: Int(rr.resource.priority),
//            weight:   Int(rr.resource.weight),
//            port:     Int(rr.resource.port),
//            target:   rr.resource.domainName.string  // or labels.string, per your model
//        )
//    }
//    let connectOrder = rfc2782Order(entries)
//    // Try in order until one succeeds; cache the good one for the session.


//    # Multiple SRV answers (client-to-server XMPP)
//    dig +short _xmpp-client._tcp.jabber.org SRV           # expect 2+ lines (targets may change)
//
//    # MongoDB Atlas (replace with your cluster)
//    nslookup -type=SRV _mongodb._tcp.<your-cluster>.mongodb.net
//
//    # SIP examples vary by provider; illustrative:
//    host -t SRV _sip._tls.<your-sip-domain>

//    nslookup -type=SRV _mongodb._tcp.cluster0-pl-0-k45tj.mongodb.net
//    _mongodb._tcp.cluster0-pl-0-k45tj.mongodb.net service = 0 0 1026 pl-0-us-east-1-k45tj.mongodb.net.
//    _mongodb._tcp.cluster0-pl-0-k45tj.mongodb.net service = 0 0 1024 pl-0-us-east-1-k45tj.mongodb.net.
//    _mongodb._tcp.cluster0-pl-0-k45tj.mongodb.net service = 0 0 1025 pl-0-us-east-1-k45tj.mongodb.net.
@inline(__always)
private func randomBelow<RNG: RandomNumberGenerator>(_ upper: Int, using rng: inout RNG) -> Int {
    precondition(upper > 0)
    let u = UInt64(upper)
    let r = rng.next()
    // Use high 64-bits of 128-bit product for unbiased scaling without loops.
    let scaled = r.multipliedFullWidth(by: u).high
    return Int(truncatingIfNeeded: scaled)
}
