# Capture Fixtures

These `.pcap` and `.pcapng` samples are synthetic test fixtures, not real local
traffic captures. They contain one UDP payload packet and one DNS response packet
using private/example addresses so the parser tests can safely assert stable
packet data in an open source repo.

`wireshark-tls12-dsb.pcapng` is Wireshark's own test capture
(`test/captures/tls12-dsb.pcapng`, GPL-2.0-or-later): two synthetic TLS 1.2
`HEAD` requests to example.com whose throwaway session keys are embedded in a
PCAPNG Decryption Secrets Block, used to test TLS decryption.
