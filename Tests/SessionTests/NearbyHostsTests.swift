// Copyright © 2026 Glass Act. All rights reserved.

@testable import GlassActSession
import Testing

@Suite struct NearbyHostsTests {
    private func host(_ name: String, _ address: String) -> NearbyHost {
        NearbyHost(name: name, host: address, port: 5900, isLaptop: false)
    }

    @Test func thisMacsOwnHostIsNotListed() {
        let found = [host("Studio", "Studio.local"), host("Mini", "Mac-mini.local"), host("Air", "Air.local")]
        let listed = NearbyHosts.listed(found, ownAddress: "Mac-mini.local")
        #expect(listed.map(\.name) == ["Air", "Studio"])
    }

    @Test func ownAddressComparesWithoutCaseOrTrailingDot() {
        let found = [host("Mini", "MAC-MINI.local."), host("Studio", "Studio.local")]
        #expect(NearbyHosts.listed(found, ownAddress: "mac-mini.local").map(\.name) == ["Studio"])
    }

    @Test func anotherMacWithTheSameComputerNameIsListed() {
        // Computer names needn't be unique; local host names are (mDNS renames a clash).
        let found = [host("Mac mini", "Mac-mini-2.local")]
        #expect(NearbyHosts.listed(found, ownAddress: "Mac-mini.local").map(\.name) == ["Mac mini"])
    }

    @Test func withoutAnOwnAddressEveryHostIsListedOncePerMac() {
        let found = [host("Studio", "Studio.local"), host("Studio", "Studio.local"), host("Air", "Air.local")]
        #expect(NearbyHosts.listed(found, ownAddress: nil).map(\.name) == ["Air", "Studio"])
    }
}
