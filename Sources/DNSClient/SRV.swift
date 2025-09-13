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
/// Implements RFC 2782 Section 3 (Selection of SRV RR):
/// - Partition records by `priority` and process priorities in ascending order.
/// - For a given priority group, repeat until the group is empty:
///   - Let S be the sum of all `weight` values (weights ≤ 0 are treated as 0).
///   - If S == 0, select one record uniformly at random from the remaining set.
///   - Else, choose a random number R in [0, S-1] and walk the set subtracting
///     each record's weight from R until R < 0; select that record.
///   - Remove the selected record from the group and continue.
/// 
/// The resulting concatenation of all groups is the recommended connection
/// attempt order for the client.
///
/// - Parameters:
///   - records: The SRV resource records to order.
///   - rng: The random number generator used for the weighted selection within
///          a priority group.
/// - Returns: The input records ordered according to RFC 2782 selection rules.
/// - Complexity: O(n²) per priority group, suitable for typical SRV set sizes.
internal func rfc2782Order<RNG: RandomNumberGenerator>(_ records: [ResourceRecord<SRVRecord>], rng: inout RNG) -> [ResourceRecord<SRVRecord>] {
    // Group by priority (lowest first)
    let byPriority = Dictionary(grouping: records, by: { Int($0.resource.priority) }).sorted { $0.key < $1.key }

    var result: [ResourceRecord<SRVRecord>] = []
    for (_, group) in byPriority {
        // Work on a mutable copy of this priority group.
        var pool = group
        // Repeatedly select one target by weight until the group is exhausted.
        while !pool.isEmpty {
            // Recompute S (sum of weights) after each removal, per RFC.
            let totalWeight = pool.reduce(0) { $0 + max(0, Int($1.resource.weight)) }
            let chosenIndex: Int
            if totalWeight == 0 {
                // All weights are zero: uniform random choice among remaining records.
                chosenIndex = randomBelow(pool.count, using: &rng)
            } else {
                // Draw R in [0, S-1] and walk the list until cumulative weight exceeds R.
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

/// Convenience overload using `SystemRandomNumberGenerator`.
///
/// - Parameter records: The SRV resource records to order.
/// - Returns: The input records ordered according to RFC 2782 selection rules.
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
    /// Returns a new array ordered per RFC 2782.
    ///
    /// The result is grouped by ascending `priority`; within a priority group,
    /// elements are ordered using weighted random selection. This overload uses
    /// `SystemRandomNumberGenerator` for the weighted selection.
    /// - Returns: A new array ordered according to RFC 2782 selection rules.
    internal func rfc2782Ordered() -> [Element] {
        rfc2782Order(self)
    }

    /// Returns a new array ordered per RFC 2782 using the provided RNG.
    ///
    /// The result is grouped by ascending `priority`; within a priority group,
    /// elements are ordered using weighted random selection.
    /// - Parameter rng: The random number generator used for weighted selection.
    ///                  The generator's state will be advanced.
    /// - Returns: A new array ordered according to RFC 2782 selection rules.
    internal func rfc2782Ordered<RNG: RandomNumberGenerator>(rng: inout RNG) -> [Element] {
        rfc2782Order(self, rng: &rng)
    }

    /// Orders this array in place per RFC 2782.
    ///
    /// The elements are grouped by ascending `priority`; within a priority group,
    /// elements are ordered using weighted random selection. This overload uses
    /// `SystemRandomNumberGenerator` for the weighted selection.
    internal mutating func rfc2782OrderInPlace() {
        self = rfc2782Order(self)
    }

    /// Orders this array in place per RFC 2782 using the provided RNG.
    ///
    /// The elements are grouped by ascending `priority`; within a priority group,
    /// elements are ordered using weighted random selection.
    /// - Parameter rng: The random number generator used for weighted selection.
    ///                  The generator's state will be advanced.
    internal mutating func rfc2782OrderInPlace<RNG: RandomNumberGenerator>(rng: inout RNG) {
        self = rfc2782Order(self, rng: &rng)
    }
}

// MARK: - EventLoopFuture convenience

extension EventLoopFuture where Value == [ResourceRecord<SRVRecord>] {
    /// Maps this future to RFC 2782–ordered results.
    ///
    /// The mapped value is grouped by ascending `priority`; within a priority group,
    /// elements are ordered using weighted random selection. This overload uses
    /// `SystemRandomNumberGenerator` for the weighted selection.
    internal func rfc2782Ordered() -> EventLoopFuture<Value> {
        self.map { records in rfc2782Order(records) }
    }

    /// Maps this future to RFC 2782–ordered results using the provided RNG.
    ///
    /// The mapping groups by ascending `priority` and applies weighted selection within
    /// each priority group. The `rng` is copied into the closure that performs the mapping;
    /// its external state will not be updated.
    /// - Parameter rng: The random number generator used for weighted selection. It is
    ///                  copied for use inside the closure.
    /// - Returns: A future that succeeds with RFC 2782–ordered records.
    internal func rfc2782Ordered<RNG: RandomNumberGenerator>(rng: inout RNG) -> EventLoopFuture<Value> {
        var rngCopy = rng
        return self.map { records in
            var localRng = rngCopy
            return rfc2782Order(records, rng: &localRng)
        }
    }
}
