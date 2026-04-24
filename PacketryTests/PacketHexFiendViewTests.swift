import PcapPlusPlusCore
import Testing
@testable import Packetry

@MainActor
struct PacketHexFiendViewTests {
    @Test func selectionRangeUsesValidByteRange() {
        let range = PacketHexFiendSelectionRange(
            byteRange: PacketByteRange(offset: 8, length: 4),
            dataLength: 32
        )

        #expect(range == PacketHexFiendSelectionRange(offset: 8, length: 4))
    }

    @Test func selectionRangeIgnoresMissingRange() {
        let range = PacketHexFiendSelectionRange(byteRange: nil, dataLength: 32)

        #expect(range == nil)
    }

    @Test func selectionRangeIgnoresZeroAndNegativeLengths() {
        let zeroLengthRange = PacketHexFiendSelectionRange(
            byteRange: PacketByteRange(offset: 4, length: 0),
            dataLength: 32
        )
        let negativeLengthRange = PacketHexFiendSelectionRange(
            byteRange: PacketByteRange(offset: 4, length: -2),
            dataLength: 32
        )

        #expect(zeroLengthRange == nil)
        #expect(negativeLengthRange == nil)
    }

    @Test func selectionRangeIgnoresRangeBeyondData() {
        let range = PacketHexFiendSelectionRange(
            byteRange: PacketByteRange(offset: 32, length: 4),
            dataLength: 16
        )

        #expect(range == nil)
    }

    @Test func selectionRangeClipsPartiallyVisibleRange() {
        let range = PacketHexFiendSelectionRange(
            byteRange: PacketByteRange(offset: 14, length: 8),
            dataLength: 16
        )

        #expect(range == PacketHexFiendSelectionRange(offset: 14, length: 2))
    }
}
