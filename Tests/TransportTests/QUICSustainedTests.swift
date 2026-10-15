import Foundation
import Testing
import GlassActCodec
import GlassActCore
import GlassActTransport
import GlassActWire
import GlassActTestSupport

/// Guards against a control path that dies after the handshake: the session
/// establishes and HELLO / HELLO_OK flow, but every subsequent control
/// message (viewer ACKs, host PINGs) vanishes until the stream times out. A
/// sustained session with a realistic cold-start datagram burst and multiple
/// control exchanges in both directions must keep converging.
@Suite(.serialized, .tags(.quic), .notInFastLane) struct QUICSustainedSessionTests {
    @Test func sustainedSessionKeepsConverging() throws {
        let (identity, fingerprint) = try QUICLoopbackTests.makeTestIdentity()
        let width = 2048, height = 2048 // 1024 tiles; noise → RAW → ~14k datagrams per full batch
        var host: HostEngine?
        var viewer: ViewerEngine?

        guard let session = try QUICLoopbackTests.makeSession(
            fingerprint: fingerprint, identity: identity,
            configureHost: { transport in
                let engine = HostEngine(width: width, height: height, transport: transport,
                                        clock: { MonotonicClock.nowUS })
                host = engine
                transport.onControl = { engine.handleControl($0, nowUS: MonotonicClock.nowUS) }
            },
            configureClient: { transport in
                let engine = ViewerEngine(transport: transport)
                viewer = engine
                transport.onControl = { engine.handleControl($0, nowUS: MonotonicClock.nowUS) }
                transport.onDatagram = { engine.handleDatagram($0, nowUS: MonotonicClock.nowUS) }
            }
        ) else {
            Issue.record("QUIC loopback session failed to become ready")
            return
        }
        defer {
            session.client.cancel()
            session.host.cancel()
            session.server.cancel()
        }
        guard let host, let viewer else {
            Issue.record("engines not created")
            return
        }

        var rngState: UInt64 = 4242
        func fill(_ frame: inout [UInt8]) {
            for i in 0..<frame.count {
                rngState = rngState &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                frame[i] = UInt8(truncatingIfNeeded: rngState >> 33)
            }
        }
        var frame = [UInt8](repeating: 0, count: width * height * 4)
        fill(&frame)

        session.serverQueue.sync { host.start(nowUS: MonotonicClock.nowUS) }

        func canvasMatches() -> Bool {
            session.clientQueue.sync {
                viewer.withCanvas { canvas in
                    frame.withUnsafeBytes { expected in
                        canvas.count == expected.count
                            && memcmp(canvas.baseAddress, expected.baseAddress, expected.count) == 0
                    }
                } ?? false
            }
        }

        // Multiple rounds: each mutates the frame, then drives real time until
        // the viewer's canvas is byte-identical. Round 1 exercises the
        // cold-start burst; later rounds only work if control (ACKs) keeps
        // flowing both ways.
        var completedRounds = 0
        for round in 0..<4 {
            if round > 0 {
                fill(&frame) // full-frame change: another ~900-datagram burst
            }
            // Generous: this test exists to catch the control path DYING
            // (which never converges, at any deadline), not to benchmark
            // convergence latency. 8 s is flaky when the full suite's heavy
            // CoreTests run in parallel and starve this real-time loop — the
            // deadline is not the assertion.
            let deadline = Date().addingTimeInterval(25)
            var matched = false
            while Date() < deadline && !matched {
                session.serverQueue.sync {
                    let now = MonotonicClock.nowUS
                    if host.state == .running {
                        frame.withUnsafeBytes { raw in
                            host.encodeTick(frame: raw, bytesPerRow: width * 4, dirtyRects: nil,
                                            captureTimestampUS: now, nowUS: now)
                        }
                    }
                    host.tick(nowUS: now)
                }
                session.clientQueue.sync { viewer.tick(nowUS: MonotonicClock.nowUS) }
                matched = canvasMatches()
                Thread.sleep(forTimeInterval: 0.016)
            }
            if matched {
                completedRounds += 1
            } else {
                break
            }
        }
        let ackCount = session.serverQueue.sync { host.stats.acksReceived }
        #expect(completedRounds == 4,
                "session stopped converging after round \(completedRounds) — control path died (acks received by host: \(ackCount))")
        #expect(ackCount >= 4, "host must keep receiving viewer ACKs (got \(ackCount))")
    }
}
