import Foundation

/* DDC/CI message framing, kept pure for unit tests.

   DDC/CI is a tiny request/reply protocol spoken over the monitor's I2C bus
   (VESA DDC/CI spec). Every message is checksummed with XOR over the I2C
   addressing bytes plus the payload. The I2C layer itself (IOAVService)
   lives in DDCBrightness; this file only builds and parses the byte
   packets. */
enum DDCPacket {
    /* VCP feature code for luminance (backlight brightness). */
    static let luminance: UInt8 = 0x10

    /* I2C addressing per the spec: the display listens at 7-bit address
       0x37 (8-bit write address 0x6E), the host identifies itself as 0x51.
       IOAVServiceWriteI2C takes these as chipAddress and dataAddress. */
    static let displayChipAddress: UInt32 = 0x37
    static let hostDataAddress: UInt32 = 0x51

    /* "Get VCP Feature" request: [length|0x80, opcode, vcp, checksum].
       The checksum XORs the 8-bit destination (0x6E) and source (0x51)
       addresses in, even though the transport sends those out of band. */
    static func getVCPRequest(_ code: UInt8) -> [UInt8] {
        var packet: [UInt8] = [0x82, 0x01, code, 0]
        packet[3] = checksum(seed: 0x6E ^ 0x51, over: packet.dropLast())
        return packet
    }

    /* "Set VCP Feature" request: [length|0x80, opcode, vcp, hi, lo, chk]. */
    static func setVCPRequest(_ code: UInt8, value: UInt16) -> [UInt8] {
        var packet: [UInt8] = [
            0x84, 0x03, code, UInt8(value >> 8), UInt8(value & 0xFF), 0,
        ]
        packet[5] = checksum(seed: 0x6E ^ 0x51, over: packet.dropLast())
        return packet
    }

    /* Parses a "Get VCP Feature" reply as read from the wire:
       [src 0x6E, length 0x88, opcode 0x02, result, vcp, type,
        maxHi, maxLo, curHi, curLo, checksum].
       The reply checksum is seeded with 0x50 (the host read address).
       Returns nil for a malformed, failed, or wrong-feature reply. */
    static func parseVCPReply(_ reply: [UInt8], code: UInt8) -> (current: UInt16, max: UInt16)? {
        guard
            reply.count >= 11,
            reply[2] == 0x02,  // "VCP Feature reply" opcode
            reply[3] == 0x00,  // result code: no error
            reply[4] == code,
            reply[10] == checksum(seed: 0x50, over: reply.prefix(10))
        else { return nil }
        let maxValue = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        return (current, maxValue)
    }

    private static func checksum(seed: UInt8, over bytes: some Sequence<UInt8>) -> UInt8 {
        bytes.reduce(seed, ^)
    }
}
