// import Foundation
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

// MARK: - RFC 2782 ordering for DNSClient ResourceRecord<SRVRecord>

/// RFC 2782 ordering directly on DNSClient's SRV resource records.
///
/// - Processes records by ascending `priority` (lower first).
/// - Within the same priority, performs weighted-random selection until exhausted.
internal func rfc2782Order<RNG: RandomNumberGenerator>(_ records: [ResourceRecord<SRVRecord>], rng: inout RNG) -> [ResourceRecord<SRVRecord>] {
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
                var threshold = randomBelow(totalWeight, using: &rng)
                var index = 0
                while index < pool.count {
                    threshold -= max(0, Int(pool[index].resource.weight))
                    if threshold < 0 { break }
                    index += 1
                }
                chosenIndex = min(index, pool.count - 1)
            }
            result.append(pool.remove(at: chosenIndex))
        }
    }
    return result
}

/// Convenience overload using SystemRandomNumberGenerator.
internal func rfc2782Order(_ records: [ResourceRecord<SRVRecord>]) -> [ResourceRecord<SRVRecord>] {
    var rng = SystemRandomNumberGenerator()
    return rfc2782Order(records, rng: &rng)
}

@inline(__always)
private func randomBelow<RNG: RandomNumberGenerator>(_ upper: Int, using rng: inout RNG) -> Int {
    precondition(upper > 0)
    let upperU64 = UInt64(upper)
    let randomValue = rng.next()
    // Use high 64-bits of 128-bit product for unbiased scaling without loops.
    let scaled = randomValue.multipliedFullWidth(by: upperU64).high
    return Int(truncatingIfNeeded: scaled)
}

// MARK: - Array conveniences for RFC 2782 ordering

extension Array where Element == ResourceRecord<SRVRecord> {
    /// Return a new array ordered per RFC 2782 (priority grouping + weighted selection).
    public func rfc2782Ordered() -> [Element] {
        rfc2782Order(self)
    }

    /// Return a new array ordered per RFC 2782 using the provided RNG.
    public func rfc2782Ordered<RNG: RandomNumberGenerator>(rng: inout RNG) -> [Element] {
        rfc2782Order(self, rng: &rng)
    }

    /// In-place RFC 2782 ordering (priority grouping + weighted selection).
    public mutating func rfc2782OrderInPlace() {
        self = rfc2782Order(self)
    }

    /// In-place RFC 2782 ordering using the provided RNG.
    public mutating func rfc2782OrderInPlace<RNG: RandomNumberGenerator>(rng: inout RNG) {
        self = rfc2782Order(self, rng: &rng)
    }
}

// MARK: - EventLoopFuture convenience

extension EventLoopFuture where Value == [ResourceRecord<SRVRecord>] {
    /// Map to RFC 2782–ordered results.
    public func rfc2782Ordered() -> EventLoopFuture<Value> {
        self.map { records in rfc2782Order(records) }
    }

    /// Map to RFC 2782–ordered results using the provided RNG.
    /// Note: The RNG is copied into the closure; its external state will not be updated.
    public func rfc2782Ordered<RNG: RandomNumberGenerator>(rng: inout RNG) -> EventLoopFuture<Value> {
        var rngCopy = rng
        return self.map { records in
            var localRng = rngCopy
            return rfc2782Order(records, rng: &localRng)
        }
    }
}
