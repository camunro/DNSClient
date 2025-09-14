# RFC 2782 — SRV Compliance Plan

Reference: RFC 2782 “A DNS RR for specifying the location of services (DNS SRV)”
https://datatracker.ietf.org/doc/html/rfc2782

## Objectives

- Enforce RFC 2782 selection semantics end-to-end.
- Handle “Target is .” (service not available) correctly.
- Consume Additional Data (A/AAAA) from SRV responses when present.
- Perform A/AAAA lookups for missing addresses.
- Provide a higher-level resolution API (and optional connect helper).

## Current State

- Selection/ordering implemented (priority grouping + weighted choice) via `rfc2782Order`.
- `getSRVRecords(from:)` returns SRV records ordered by RFC 2782 by default.

## Gaps

1) Target “.” (root) semantics
- If there is exactly one SRV RR and its Target is “.”, abort (service unavailable).
- If multiple SRV RRs exist and some Targets are “.”, ignore those entries.

2) Additional Data consumption
- Use A/AAAA records in the Additional section whose owner name equals the SRV Target.
- Avoid re-querying addresses already supplied in Additional.

3) Address lookup for missing targets
- For any SRV Target lacking addresses, look up A and AAAA and merge results.

4) Higher-level helper
- Resolution helper that returns ordered targets + their resolved addresses.
- Optional connector helper that attempts connections in RFC order.

## Proposed API

### Model

```swift
internal struct SRVResolved: Sendable {
    let record: ResourceRecord<SRVRecord>    // original SRV RR
    let addresses: [SocketAddress]          // A/AAAA for record.resource.domainName
    let fromAdditional: Bool                // true if fully satisfied from Additional section
}
```

### Resolution

```swift
public func resolveSRV(from host: String) -> EventLoopFuture<[SRVResolved]>
```

- Queries SRV.
- Enforces “single SRV with Target = .” ⇒ fail with `serviceUnavailable`.
- Drops any SRV with Target = . when others exist.
- Applies RFC ordering (existing `rfc2782Order`).
- Consumes Additional Data (A/AAAA) for each Target.
- Looks up missing A/AAAA in parallel; merges results.
- Returns ordered, address-resolved targets.

### Optional connect helper

```swift
public enum SRVError: Error {
    case serviceUnavailable
    case noRecords
    case connectFailed(lastError: Error)
}

public func srvConnect<T>(
    from host: String,
    connector: @escaping (SocketAddress) -> EventLoopFuture<T>
) -> EventLoopFuture<T>
```

- Uses `resolveSRV(from:)` and attempts addresses in order until one succeeds.
- Keeps transport pluggable (caller injects connector: POSIX, NIOTS, etc.).

## Implementation Notes

- `isRootTarget(_ labels: [DNSLabel]) -> Bool` helper (true for a single root label target).
- Additional Data map: `targetName -> [SocketAddress]` built from `.a` and `.aaaa` records where `rr.domainName.string == target`.
- Missing lookups: perform A and AAAA queries concurrently per target, merge results.
- Address order policy: preserve resolver/Additional order; let the connector implement any parallelization/HE.
- Ordering: always apply `rfc2782Order` on the SRV RR list before attaching addresses.

## Test Plan (XCTest)

1) Dot-target semantics
- `testSrvSingleDotTargetAborts`: exactly one SRV RR, target “.” ⇒ `resolveSRV` fails with `serviceUnavailable`.
- `testSrvIgnoresDotAmongOthers`: multiple SRV RRs, one target “.” ⇒ that entry is skipped; others remain.

2) Additional Data handling
- `testUsesAdditionalDataForAddresses`: SRV + Additional A/AAAA present ⇒ no extra lookups; addresses returned.
- `testQueriesMissingAddresses`: SRV w/o Additional ⇒ performs A & AAAA lookups; merged addresses returned.

3) Ordering preserved through resolution
- `testResolutionPreservesRFCOrder`: priority groups + weights ⇒ resolved list order matches `rfc2782Order`.

4) Connect helper (optional)
- `testSrvConnectTriesInOrder`: stub connector fails first address(es), succeeds next ⇒ verify order and success.
- `testSrvConnectWithSingleDotAborts`: only “.” ⇒ fails early with `serviceUnavailable`.

## Open Questions / Future Work

- Fallback behavior if no SRV: app policy (e.g., A/AAAA on original host + default port) — out of scope initially.
- TTL and caching strategy: consider exposing effective TTL per target (e.g., min of SRV/Address TTLs).
- IPv6/IPv4 policy and Happy Eyeballs: likely in the connector, not resolver.

## Next Steps

- [ ] Add `isRootTarget` helper and “dot target” handling.
- [ ] Implement Additional Data extraction for A/AAAA.
- [ ] Implement parallel A/AAAA lookup for missing addresses.
- [ ] Add `resolveSRV(from:)` with ordering + address merging.
- [ ] Add synthetic tests for dot-target and Additional Data usage.
- [ ] (Optional) Add `srvConnect` with stubbed tests.

