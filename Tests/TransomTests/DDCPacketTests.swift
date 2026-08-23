import Testing

@testable import Transom

/* The reference bytes here were captured live from a Dell P2725QE over
   IOAVService I2C — real wire traffic, not spec transcription. */

@Test func getVCPRequestMatchesWireFormat() {
    #expect(DDCPacket.getVCPRequest(0x10) == [0x82, 0x01, 0x10, 0xAC])
}

@Test func setVCPRequestMatchesWireFormat() {
    /* Set luminance to 100 (0x64). */
    #expect(DDCPacket.setVCPRequest(0x10, value: 100) == [0x84, 0x03, 0x10, 0x00, 0x64, 0xCC])
    /* A two-byte value lands in hi/lo order. */
    #expect(DDCPacket.setVCPRequest(0x10, value: 0x1234)[3...4] == [0x12, 0x34])
}

@Test func parsesAWellFormedReply() {
    /* Luminance reply: current 100, max 100. */
    let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4]
    let parsed = DDCPacket.parseVCPReply(reply, code: 0x10)
    #expect(parsed?.current == 100)
    #expect(parsed?.max == 100)
}

@Test func rejectsCorruptedOrMismatchedReplies() {
    let good: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4]

    /* Wrong feature code requested. */
    #expect(DDCPacket.parseVCPReply(good, code: 0x12) == nil)

    /* Bad checksum (flipped current-value byte without fixing it up). */
    var corrupted = good
    corrupted[9] = 0x63
    #expect(DDCPacket.parseVCPReply(corrupted, code: 0x10) == nil)

    /* Monitor signals "unsupported VCP code". */
    var unsupported = good
    unsupported[3] = 0x01
    unsupported[10] ^= 0x01
    #expect(DDCPacket.parseVCPReply(unsupported, code: 0x10) == nil)

    /* Truncated read. */
    #expect(DDCPacket.parseVCPReply(Array(good.prefix(8)), code: 0x10) == nil)

    /* All-zero buffer (nothing driving the bus). */
    #expect(DDCPacket.parseVCPReply([UInt8](repeating: 0, count: 11), code: 0x10) == nil)
}
