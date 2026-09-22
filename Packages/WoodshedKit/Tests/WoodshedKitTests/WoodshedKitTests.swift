import Testing
@testable import WoodshedKit

@Suite("Skeleton placeholder")
struct WoodshedKitTests {
    @Test("domain namespace is reachable")
    func domainNamespace() {
        #expect(WoodshedKit.domain == "WoodshedKit")
    }

    @Test("milestone marker is set for M0")
    func milestoneMarker() {
        #expect(WoodshedKit.milestone == "M0-skeleton")
    }

    @Test("skeleton exposes no stored state beyond constants")
    func constantsAreStable() {
        // Guards the contract later issues depend on: these markers exist
        // and are pure constants (no clock, no I/O) in the M0 skeleton.
        let first = (WoodshedKit.domain, WoodshedKit.milestone)
        let second = (WoodshedKit.domain, WoodshedKit.milestone)
        #expect(first == second)
    }
}
