import Testing
import GlassActCore
import GlassActTransport
import GlassActWire
import GlassActTestSupport

/// HELLO_OK geoMode 4 (virtual display) goes only to a host that advertises
/// WireCaps.virtualDisplay (one without the virtual-display SPI can't make
/// one) and falls back to Client Resolution otherwise.
@Suite struct VirtualDisplayGeometryTests {
    private func requestedMode(hostCaps: UInt32) -> Int? {
        let link = InProcLink(faults: .none)
        let host = HostEngine(width: 320, height: 240, transport: link.a)
        host.extraHelloCaps = hostCaps
        let viewer = ViewerEngine(transport: link.b)
        viewer.requestedGeometry = (GeometryMode.virtualDisplay, 1470, 918, 2)
        var got: Int?
        host.onResizeRequested = { mode, _, _, _ in got = mode }
        link.a.onControl = { host.handleControl($0, nowUS: link.nowUS) }
        link.b.onControl = { viewer.handleControl($0, nowUS: link.nowUS) }
        host.start(nowUS: 0)
        var t: UInt64 = 0
        while t < 300_000 {
            t += 1_000
            link.advance(toUS: t)
            viewer.tick(nowUS: link.nowUS)
            host.tick(nowUS: link.nowUS)
        }
        return got
    }

    @Test func virtualDisplayOnlyFromAHostThatOffersIt() {
        #expect(requestedMode(hostCaps: WireCaps.virtualDisplay) == Int(GeometryMode.virtualDisplay))
        #expect(requestedMode(hostCaps: 0) == Int(GeometryMode.clientResolution))
    }
}
