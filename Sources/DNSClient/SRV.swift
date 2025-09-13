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

// MARK: - RFC 2782 ordering for DNSClient ResourceRecord<SRVRecord>

/// RFC 2782 ordering directly on DNSClient's SRV resource records.
///
/// - Processes records by ascending `priority` (lower first).
/// - Within the same priority, performs weighted-random selection until exhausted.
public func rfc2782Order<RNG: RandomNumberGenerator>(_ records: [ResourceRecord<SRVRecord>], rng: inout RNG) -> [ResourceRecord<SRVRecord>] {
    // Group by priority (lowest first)
    let byPriority = Dictionary(grouping: records, by: { Int($0.resource.priority) }).sorted { $0.key < $1.key }

    var result: [ResourceRecord<SRVRecord>] = []
    for (_, group) in byPriority {
        var pool = group
        while !pool.isEmpty {
            let totalWeight = pool.reduce(0) { $0 + max(0, Int($1.resource.weight)) }
            let chosenIndex: Int
            if totalWeight == 0 {
                chosenIndex = randomBelow(pool.count, using: &rng)
            } else {
                var r = randomBelow(totalWeight, using: &rng)
                var i = 0
                while i < pool.count {
                    r -= max(0, Int(pool[i].resource.weight))
                    if r < 0 { break }
                    i += 1
                }
                chosenIndex = min(i, pool.count - 1)
            }
            result.append(pool.remove(at: chosenIndex))
        }
    }
    return result
}

/// Convenience overload using SystemRandomNumberGenerator.
public func rfc2782Order(_ records: [ResourceRecord<SRVRecord>]) -> [ResourceRecord<SRVRecord>] {
    var rng = SystemRandomNumberGenerator()
    return rfc2782Order(records, rng: &rng)
}

@inline(__always)
private func randomBelow<RNG: RandomNumberGenerator>(_ upper: Int, using rng: inout RNG) -> Int {
    precondition(upper > 0)
    let u = UInt64(upper)
    let r = rng.next()
    // Use high 64-bits of 128-bit product for unbiased scaling without loops.
    let scaled = r.multipliedFullWidth(by: u).high
    return Int(truncatingIfNeeded: scaled)
}

//    // Example usage:
//    // let srvRRs: [ResourceRecord<SRVRecord>] = ...
//    // let ordered = rfc2782Order(srvRRs)
//    // for rr in ordered { ... attempt connect to rr.resource.domainName ... }


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
