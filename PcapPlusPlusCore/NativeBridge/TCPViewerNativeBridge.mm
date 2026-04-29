#import "TCPViewerNativeBridge.h"

#include <arpa/inet.h>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <deque>
#include <filesystem>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

#include <pcapplusplus/ArpLayer.h>
#include <pcapplusplus/BgpLayer.h>
#include <pcapplusplus/DnsLayer.h>
#include <pcapplusplus/EthLayer.h>
#include <pcapplusplus/HttpLayer.h>
#include <pcapplusplus/IcmpLayer.h>
#include <pcapplusplus/IcmpV6Layer.h>
#include <pcapplusplus/IPv4Layer.h>
#include <pcapplusplus/IPv6Layer.h>
#include <pcapplusplus/Layer.h>
#include <pcapplusplus/PcapFileDevice.h>
#include <pcapplusplus/PcapFilter.h>
#include <pcapplusplus/PcapLiveDevice.h>
#include <pcapplusplus/PcapLiveDeviceList.h>
#include <pcapplusplus/Packet.h>
#include <pcapplusplus/PacketUtils.h>
#include <pcapplusplus/PayloadLayer.h>
#include <pcapplusplus/ProtocolType.h>
#include <pcapplusplus/RawPacket.h>
#include <pcapplusplus/SSLCommon.h>
#include <pcapplusplus/SSLHandshake.h>
#include <pcapplusplus/SSLLayer.h>
#include <pcapplusplus/TcpReassembly.h>
#include <pcapplusplus/TcpLayer.h>
#include <pcapplusplus/UdpLayer.h>

#include "../Dissection/PacketDissectionEngine.hpp"

static NSString *const TCPViewerNativeErrorDomain = @"com.proxyman.tcpviewer.NativeBridge";
static NSString *const TCPViewerOpaquePayloadDecodeReason = @"The remaining payload is encrypted, unsupported, or needs stream reassembly.";

typedef NS_ENUM(NSInteger, TCPViewerNativeErrorCode) {
    TCPViewerNativeErrorCodeInterfaceDiscoveryFailed = 1000,
    TCPViewerNativeErrorCodeUnsupportedInterface = 1001,
    TCPViewerNativeErrorCodeOpenFailed = 1002,
    TCPViewerNativeErrorCodeCaptureStartFailed = 1003,
    TCPViewerNativeErrorCodeCapturePauseFailed = 1004,
    TCPViewerNativeErrorCodeCaptureResumeFailed = 1005,
    TCPViewerNativeErrorCodeCaptureStopFailed = 1006,
    TCPViewerNativeErrorCodeFileReadFailed = 1007,
    TCPViewerNativeErrorCodeFileWriteFailed = 1008,
    TCPViewerNativeErrorCodeInvalidOptions = 1009,
    TCPViewerNativeErrorCodeInvalidFilter = 1010,
    TCPViewerNativeErrorCodeOperationCancelled = 1011,
};

namespace {

NSString *MakeNSString(const std::string &value)
{
    if (value.empty()) {
        return @"";
    }

    return [[NSString alloc] initWithUTF8String:value.c_str()] ?: @"";
}

NSString *NullableNSString(const std::string &value)
{
    return value.empty() ? nil : MakeNSString(value);
}

std::string MakeStdString(NSString *value)
{
    return value == nil ? std::string() : std::string(value.UTF8String ?: "");
}

NSDate *MakeNSDate(const timespec &timestamp)
{
    NSTimeInterval interval = static_cast<NSTimeInterval>(timestamp.tv_sec);
    interval += static_cast<NSTimeInterval>(timestamp.tv_nsec) / 1'000'000'000.0;
    return [NSDate dateWithTimeIntervalSince1970:interval];
}

NSError *MakeError(TCPViewerNativeErrorCode code, NSString *description)
{
    return [NSError errorWithDomain:TCPViewerNativeErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey: description}];
}

PCPPNativeAddressFamily MapAddressFamily(const std::string &value)
{
    if (value.find(':') != std::string::npos) {
        return PCPPNativeAddressFamilyIPv6;
    }

    if (value.find('.') != std::string::npos) {
        return PCPPNativeAddressFamilyIPv4;
    }

    return PCPPNativeAddressFamilyUnknown;
}

PCPPNativeLinkType MapLinkType(pcpp::LinkLayerType linkType)
{
    switch (linkType) {
        case pcpp::LINKTYPE_ETHERNET:
            return PCPPNativeLinkTypeEthernet;
        case pcpp::LINKTYPE_NULL:
        case pcpp::LINKTYPE_LOOP:
            return PCPPNativeLinkTypeLoopback;
        case pcpp::LINKTYPE_RAW:
        case pcpp::LINKTYPE_DLT_RAW1:
        case pcpp::LINKTYPE_DLT_RAW2:
        case pcpp::LINKTYPE_IPV4:
        case pcpp::LINKTYPE_IPV6:
            return PCPPNativeLinkTypeRaw;
        default:
            return PCPPNativeLinkTypeUnknown;
    }
}

bool SupportsLinkType(pcpp::LinkLayerType linkType)
{
    return MapLinkType(linkType) != PCPPNativeLinkTypeUnknown;
}

bool IsHiddenInterface(const std::string &interfaceName)
{
    static const std::vector<std::string> prefixes = {
        "awdl",
        "llw",
        "utun",
        "anpi",
        "ipsec",
        "gif",
        "stf",
    };

    return std::any_of(prefixes.begin(), prefixes.end(), [&](const std::string &prefix) {
        return interfaceName.rfind(prefix, 0) == 0;
    });
}

NSArray<PCPPNativeAddressDescriptor *> *MapAddresses(const pcpp::PcapLiveDevice &device)
{
    NSMutableArray<PCPPNativeAddressDescriptor *> *addresses = [NSMutableArray array];

    for (const auto &address : device.getIPAddresses()) {
        [addresses addObject:[[PCPPNativeAddressDescriptor alloc] initWithFamily:address.isIPv4() ? PCPPNativeAddressFamilyIPv4 : PCPPNativeAddressFamilyIPv6
                                                                           value:MakeNSString(address.toString())]];
    }

    const auto macAddress = device.getMacAddress();
    if (macAddress != pcpp::MacAddress::Zero) {
        [addresses addObject:[[PCPPNativeAddressDescriptor alloc] initWithFamily:PCPPNativeAddressFamilyLinkLayer
                                                                           value:MakeNSString(macAddress.toString())]];
    }

    return addresses;
}

NSString *TLSVersionLabel(pcpp::SSLVersion version)
{
    switch (version.asEnum(true)) {
        case pcpp::SSLVersion::SSL3:
            return @"SSLv3.0";
        case pcpp::SSLVersion::TLS1_0:
            return @"TLSv1.0";
        case pcpp::SSLVersion::TLS1_1:
            return @"TLSv1.1";
        case pcpp::SSLVersion::TLS1_2:
            return @"TLSv1.2";
        case pcpp::SSLVersion::TLS1_3:
            return @"TLSv1.3";
        case pcpp::SSLVersion::Unknown:
        default:
            return @"TLS";
    }
}

pcpp::SSLVersion EffectiveTLSVersionForClientHello(pcpp::SSLClientHelloMessage *clientHelloMessage)
{
    if (auto *supportedVersions = clientHelloMessage->getExtensionOfType<pcpp::SSLSupportedVersionsExtension>()) {
        std::optional<uint16_t> highestKnownVersion;
        for (auto version : supportedVersions->getSupportedVersions()) {
            if (version.asEnum(true) == pcpp::SSLVersion::Unknown) {
                continue;
            }

            if (!highestKnownVersion.has_value() || version.asUInt() > highestKnownVersion.value()) {
                highestKnownVersion = version.asUInt();
            }
        }

        if (highestKnownVersion.has_value()) {
            return pcpp::SSLVersion(highestKnownVersion.value());
        }
    }

    return clientHelloMessage->getHandshakeVersion();
}

pcpp::SSLVersion EffectiveTLSVersion(pcpp::SSLLayer *sslLayer)
{
    if (auto *handshakeLayer = dynamic_cast<pcpp::SSLHandshakeLayer *>(sslLayer)) {
        for (int index = 0; index < static_cast<int>(handshakeLayer->getHandshakeMessagesCount()); index += 1) {
            auto *message = handshakeLayer->getHandshakeMessageAt(index);
            if (auto *clientHelloMessage = dynamic_cast<pcpp::SSLClientHelloMessage *>(message)) {
                return EffectiveTLSVersionForClientHello(clientHelloMessage);
            }

            if (auto *serverHelloMessage = dynamic_cast<pcpp::SSLServerHelloMessage *>(message)) {
                return serverHelloMessage->getHandshakeVersion();
            }
        }
    }

    return sslLayer->getRecordVersion();
}

NSString *TLSLayerName(pcpp::SSLLayer *sslLayer)
{
    return TLSVersionLabel(EffectiveTLSVersion(sslLayer));
}

NSString *TLSVersionFieldValue(pcpp::SSLVersion version)
{
    return [NSString stringWithFormat:@"%@ (0x%04x)", TLSVersionLabel(version), version.asUInt()];
}

NSString *TLSRecordTypeName(pcpp::SSLRecordType recordType)
{
    switch (recordType) {
        case pcpp::SSL_CHANGE_CIPHER_SPEC:
            return @"Change Cipher Spec";
        case pcpp::SSL_ALERT:
            return @"Alert";
        case pcpp::SSL_HANDSHAKE:
            return @"Handshake";
        case pcpp::SSL_APPLICATION_DATA:
            return @"Application Data";
        default:
            return @"Unknown";
    }
}

NSString *TLSRecordTypeFieldValue(pcpp::SSLRecordType recordType)
{
    return [NSString stringWithFormat:@"%@ (%u)", TLSRecordTypeName(recordType), static_cast<unsigned>(recordType)];
}

NSString *TLSHandshakeTypeName(pcpp::SSLHandshakeType handshakeType)
{
    switch (handshakeType) {
        case pcpp::SSL_HELLO_REQUEST:
            return @"Hello Request";
        case pcpp::SSL_CLIENT_HELLO:
            return @"Client Hello";
        case pcpp::SSL_SERVER_HELLO:
            return @"Server Hello";
        case pcpp::SSL_NEW_SESSION_TICKET:
            return @"New Session Ticket";
        case pcpp::SSL_END_OF_EARLY_DATE:
            return @"End Of Early Data";
        case pcpp::SSL_ENCRYPTED_EXTENSIONS:
            return @"Encrypted Extensions";
        case pcpp::SSL_CERTIFICATE:
            return @"Certificate";
        case pcpp::SSL_SERVER_KEY_EXCHANGE:
            return @"Server Key Exchange";
        case pcpp::SSL_CERTIFICATE_REQUEST:
            return @"Certificate Request";
        case pcpp::SSL_SERVER_DONE:
            return @"Server Hello Done";
        case pcpp::SSL_CERTIFICATE_VERIFY:
            return @"Certificate Verify";
        case pcpp::SSL_CLIENT_KEY_EXCHANGE:
            return @"Client Key Exchange";
        case pcpp::SSL_FINISHED:
            return @"Finished";
        case pcpp::SSL_KEY_UPDATE:
            return @"Key Update";
        case pcpp::SSL_HANDSHAKE_UNKNOWN:
        default:
            return @"Unknown";
    }
}

NSString *TLSHandshakeTypeFieldValue(pcpp::SSLHandshakeType handshakeType)
{
    return [NSString stringWithFormat:@"%@ (%u)", TLSHandshakeTypeName(handshakeType), static_cast<unsigned>(handshakeType)];
}

NSString *TLSSupportedVersionsSummary(pcpp::SSLSupportedVersionsExtension *supportedVersions)
{
    if (supportedVersions == nullptr) {
        return nil;
    }

    NSMutableArray<NSString *> *versions = [NSMutableArray array];
    for (auto version : supportedVersions->getSupportedVersions()) {
        [versions addObject:TLSVersionLabel(version)];
    }

    if (versions.count == 0) {
        return nil;
    }

    return [versions componentsJoinedByString:@", "];
}

NSString *TLSAlertLevelName(pcpp::SSLAlertLevel alertLevel)
{
    switch (alertLevel) {
        case pcpp::SSL_ALERT_LEVEL_WARNING:
            return @"Warning";
        case pcpp::SSL_ALERT_LEVEL_FATAL:
            return @"Fatal";
        case pcpp::SSL_ALERT_LEVEL_ENCRYPTED:
        default:
            return @"Encrypted";
    }
}

NSString *TLSAlertDescriptionName(pcpp::SSLAlertDescription alertDescription)
{
    switch (alertDescription) {
        case pcpp::SSL_ALERT_CLOSE_NOTIFY:
            return @"Close Notify";
        case pcpp::SSL_ALERT_UNEXPECTED_MESSAGE:
            return @"Unexpected Message";
        case pcpp::SSL_ALERT_BAD_RECORD_MAC:
            return @"Bad Record MAC";
        case pcpp::SSL_ALERT_DECRYPTION_FAILED:
            return @"Decryption Failed";
        case pcpp::SSL_ALERT_RECORD_OVERFLOW:
            return @"Record Overflow";
        case pcpp::SSL_ALERT_DECOMPRESSION_FAILURE:
            return @"Decompression Failure";
        case pcpp::SSL_ALERT_HANDSHAKE_FAILURE:
            return @"Handshake Failure";
        case pcpp::SSL_ALERT_NO_CERTIFICATE:
            return @"No Certificate";
        case pcpp::SSL_ALERT_BAD_CERTIFICATE:
            return @"Bad Certificate";
        case pcpp::SSL_ALERT_UNSUPPORTED_CERTIFICATE:
            return @"Unsupported Certificate";
        case pcpp::SSL_ALERT_CERTIFICATE_REVOKED:
            return @"Certificate Revoked";
        case pcpp::SSL_ALERT_CERTIFICATE_EXPIRED:
            return @"Certificate Expired";
        case pcpp::SSL_ALERT_CERTIFICATE_UNKNOWN:
            return @"Certificate Unknown";
        case pcpp::SSL_ALERT_ILLEGAL_PARAMETER:
            return @"Illegal Parameter";
        case pcpp::SSL_ALERT_UNKNOWN_CA:
            return @"Unknown CA";
        case pcpp::SSL_ALERT_ACCESS_DENIED:
            return @"Access Denied";
        case pcpp::SSL_ALERT_DECODE_ERROR:
            return @"Decode Error";
        case pcpp::SSL_ALERT_DECRYPT_ERROR:
            return @"Decrypt Error";
        case pcpp::SSL_ALERT_EXPORT_RESTRICTION:
            return @"Export Restriction";
        case pcpp::SSL_ALERT_PROTOCOL_VERSION:
            return @"Protocol Version";
        case pcpp::SSL_ALERT_INSUFFICIENT_SECURITY:
            return @"Insufficient Security";
        case pcpp::SSL_ALERT_INTERNAL_ERROR:
            return @"Internal Error";
        case pcpp::SSL_ALERT_USER_CANCELLED:
            return @"User Cancelled";
        case pcpp::SSL_ALERT_NO_RENEGOTIATION:
            return @"No Renegotiation";
        case pcpp::SSL_ALERT_UNSUPPORTED_EXTENSION:
            return @"Unsupported Extension";
        case pcpp::SSL_ALERT_ENCRYPTED:
        default:
            return @"Encrypted";
    }
}

bool LooksLikeWebSocketPacket(const pcpp::Packet &packet)
{
    auto *tcpLayer = packet.getLayerOfType<pcpp::TcpLayer>(true);
    auto *payloadLayer = packet.getLayerOfType<pcpp::PayloadLayer>(true);
    if (tcpLayer == nullptr || payloadLayer == nullptr) {
        return false;
    }

    if (!pcpp::HttpMessage::isHttpPort(tcpLayer->getSrcPort()) && !pcpp::HttpMessage::isHttpPort(tcpLayer->getDstPort())) {
        return false;
    }

    const uint8_t *payload = payloadLayer->getPayload();
    if (payload == nullptr || payloadLayer->getPayloadLen() < 2) {
        return false;
    }

    const uint8_t opcode = payload[0] & 0x0f;
    const bool reservedBitsAreClear = (payload[0] & 0x70) == 0;
    const bool opcodeIsKnown = opcode == 0x0 || opcode == 0x1 || opcode == 0x2 || opcode == 0x8 || opcode == 0x9 || opcode == 0x0a;
    return reservedBitsAreClear && opcodeIsKnown;
}

PCPPNativeTransportHint MapTransportHint(const pcpp::Packet &packet)
{
    if (packet.isPacketOfType(pcpp::HTTPRequest) || packet.isPacketOfType(pcpp::HTTPResponse)) {
        return PCPPNativeTransportHintHTTP1;
    }

    if (packet.isPacketOfType(pcpp::DNS)) {
        return PCPPNativeTransportHintDNS;
    }

    if (packet.isPacketOfType(pcpp::SSL)) {
        return PCPPNativeTransportHintTLS;
    }

    if (packet.isPacketOfType(pcpp::ICMP) || packet.isPacketOfType(pcpp::ICMPv6)) {
        return PCPPNativeTransportHintICMP;
    }

    if (LooksLikeWebSocketPacket(packet)) {
        return PCPPNativeTransportHintWebSocket;
    }

    if (packet.isPacketOfType(pcpp::TCP)) {
        return PCPPNativeTransportHintTCP;
    }

    if (packet.isPacketOfType(pcpp::UDP)) {
        return PCPPNativeTransportHintUDP;
    }

    if (packet.isPacketOfType(pcpp::ARP)) {
        return PCPPNativeTransportHintARP;
    }

    if (packet.isPacketOfType(pcpp::IPv6)) {
        return PCPPNativeTransportHintIPv6;
    }

    if (packet.isPacketOfType(pcpp::IPv4)) {
        return PCPPNativeTransportHintIPv4;
    }

    if (packet.isPacketOfType(pcpp::Ethernet)) {
        return PCPPNativeTransportHintEthernet;
    }

    return PCPPNativeTransportHintUnknown;
}

NSString *LayerName(pcpp::Layer &layer)
{
    switch (layer.getProtocol()) {
        case pcpp::Ethernet:
            return @"Ethernet";
        case pcpp::ARP:
            return @"ARP";
        case pcpp::IPv4:
            return @"IPv4";
        case pcpp::IPv6:
            return @"IPv6";
        case pcpp::ICMP:
            return @"ICMP";
        case pcpp::ICMPv6:
            return @"ICMPv6";
        case pcpp::TCP:
            return @"TCP";
        case pcpp::UDP:
            return @"UDP";
        case pcpp::DNS:
            return @"DNS";
        case pcpp::HTTPRequest:
            return @"HTTP Request";
        case pcpp::HTTPResponse:
            return @"HTTP Response";
        case pcpp::SSL:
            return TLSLayerName(static_cast<pcpp::SSLLayer *>(&layer));
        case pcpp::GenericPayload:
            return @"Payload";
        default:
            return MakeNSString(layer.toString());
    }
}

NSArray<PCPPNativePacketLayerDescriptor *> *MapLayers(const pcpp::Packet &packet)
{
    NSMutableArray<PCPPNativePacketLayerDescriptor *> *layers = [NSMutableArray array];
    const bool websocketPayload = LooksLikeWebSocketPacket(packet);
    for (pcpp::Layer *layer = packet.getFirstLayer(); layer != nullptr; layer = layer->getNextLayer()) {
        NSString *detailSummary = MakeNSString(layer->toString());
        NSString *layerName = websocketPayload && layer->getProtocol() == pcpp::GenericPayload ? @"WebSocket" : LayerName(*layer);
        [layers addObject:[[PCPPNativePacketLayerDescriptor alloc] initWithName:layerName
                                                                  detailSummary:detailSummary]];
    }
    return layers;
}

NSString *TCPFlagsSummaryForPacket(const pcpp::Packet &packet);
NSNumber *TCPPayloadLengthForPacket(const pcpp::Packet &packet);

PCPPNativePacketEndpointDescriptor *MapSourceEndpoint(const pcpp::Packet &packet)
{
    if (auto *ipv4Layer = packet.getLayerOfType<pcpp::IPv4Layer>()) {
        NSNumber *port = nil;
        if (auto *tcpLayer = packet.getLayerOfType<pcpp::TcpLayer>(true)) {
            port = @(tcpLayer->getSrcPort());
        } else if (auto *udpLayer = packet.getLayerOfType<pcpp::UdpLayer>(true)) {
            port = @(udpLayer->getSrcPort());
        }

        return [[PCPPNativePacketEndpointDescriptor alloc] initWithAddress:MakeNSString(ipv4Layer->getSrcIPv4Address().toString())
                                                                      port:port];
    }

    if (auto *ipv6Layer = packet.getLayerOfType<pcpp::IPv6Layer>()) {
        NSNumber *port = nil;
        if (auto *tcpLayer = packet.getLayerOfType<pcpp::TcpLayer>(true)) {
            port = @(tcpLayer->getSrcPort());
        } else if (auto *udpLayer = packet.getLayerOfType<pcpp::UdpLayer>(true)) {
            port = @(udpLayer->getSrcPort());
        }

        return [[PCPPNativePacketEndpointDescriptor alloc] initWithAddress:MakeNSString(ipv6Layer->getSrcIPv6Address().toString())
                                                                      port:port];
    }

    if (auto *arpLayer = packet.getLayerOfType<pcpp::ArpLayer>()) {
        return [[PCPPNativePacketEndpointDescriptor alloc] initWithAddress:MakeNSString(arpLayer->getSenderIpAddr().toString())
                                                                      port:nil];
    }

    return [[PCPPNativePacketEndpointDescriptor alloc] initWithAddress:nil port:nil];
}

PCPPNativePacketEndpointDescriptor *MapDestinationEndpoint(const pcpp::Packet &packet)
{
    if (auto *ipv4Layer = packet.getLayerOfType<pcpp::IPv4Layer>()) {
        NSNumber *port = nil;
        if (auto *tcpLayer = packet.getLayerOfType<pcpp::TcpLayer>(true)) {
            port = @(tcpLayer->getDstPort());
        } else if (auto *udpLayer = packet.getLayerOfType<pcpp::UdpLayer>(true)) {
            port = @(udpLayer->getDstPort());
        }

        return [[PCPPNativePacketEndpointDescriptor alloc] initWithAddress:MakeNSString(ipv4Layer->getDstIPv4Address().toString())
                                                                      port:port];
    }

    if (auto *ipv6Layer = packet.getLayerOfType<pcpp::IPv6Layer>()) {
        NSNumber *port = nil;
        if (auto *tcpLayer = packet.getLayerOfType<pcpp::TcpLayer>(true)) {
            port = @(tcpLayer->getDstPort());
        } else if (auto *udpLayer = packet.getLayerOfType<pcpp::UdpLayer>(true)) {
            port = @(udpLayer->getDstPort());
        }

        return [[PCPPNativePacketEndpointDescriptor alloc] initWithAddress:MakeNSString(ipv6Layer->getDstIPv6Address().toString())
                                                                      port:port];
    }

    if (auto *arpLayer = packet.getLayerOfType<pcpp::ArpLayer>()) {
        return [[PCPPNativePacketEndpointDescriptor alloc] initWithAddress:MakeNSString(arpLayer->getTargetIpAddr().toString())
                                                                      port:nil];
    }

    return [[PCPPNativePacketEndpointDescriptor alloc] initWithAddress:nil port:nil];
}

std::pair<PCPPNativeDecodeStatusKind, NSString *> DetermineDecodeStatus(const pcpp::Packet &packet,
                                                                        const pcpp::RawPacket &rawPacket)
{
    if (rawPacket.getRawDataLen() <= 0) {
        return {PCPPNativeDecodeStatusKindMalformed, @"Packet payload was empty."};
    }

    if (rawPacket.getRawDataLen() < rawPacket.getFrameLength()) {
        return {PCPPNativeDecodeStatusKindPartial, @"Packet capture was truncated before full decoding completed."};
    }

    const auto *lastLayer = packet.getLastLayer();
    if (lastLayer == nullptr) {
        return {PCPPNativeDecodeStatusKindUnsupported, @"Packet could not be decoded into protocol layers."};
    }

    if (lastLayer->getProtocol() == pcpp::GenericPayload) {
        return {PCPPNativeDecodeStatusKindPartial, TCPViewerOpaquePayloadDecodeReason};
    }

    return {PCPPNativeDecodeStatusKindComplete, nil};
}

NSString *InfoSummaryForPacket(const pcpp::Packet &packet, const pcpp::RawPacket &rawPacket)
{
    if (const auto *lastLayer = packet.getLastLayer()) {
        return MakeNSString(lastLayer->toString());
    }

    return [NSString stringWithFormat:@"Captured %d bytes", rawPacket.getRawDataLen()];
}

NSString * _Nullable SniDomainNameForPacket(const pcpp::Packet &packet)
{
    for (auto *handshakeLayer = packet.getLayerOfType<pcpp::SSLHandshakeLayer>();
         handshakeLayer != nullptr;
         handshakeLayer = packet.getNextLayerOfType<pcpp::SSLHandshakeLayer>(handshakeLayer)) {
        auto *clientHelloMessage = handshakeLayer->getHandshakeMessageOfType<pcpp::SSLClientHelloMessage>();
        if (clientHelloMessage == nullptr) {
            continue;
        }

        auto *sniExtension = clientHelloMessage->getExtensionOfType<pcpp::SSLServerNameIndicationExtension>();
        if (sniExtension == nullptr) {
            continue;
        }

        auto hostName = sniExtension->getHostName();
        if (!hostName.empty()) {
            return MakeNSString(hostName);
        }
    }

    return nil;
}

std::optional<std::string> SniDomainNameForTLSRecordBytes(const uint8_t *data, size_t dataLength)
{
    // Parses buffered TLS records until a complete ClientHello exposes SNI.
    static constexpr size_t kTLSRecordHeaderLength = 5;
    static constexpr size_t kMaxTLSRecordLength = 18 * 1024;

    size_t offset = 0;
    while (offset + kTLSRecordHeaderLength <= dataLength) {
        const uint8_t contentType = data[offset];
        const uint16_t recordVersion = (static_cast<uint16_t>(data[offset + 1]) << 8) | data[offset + 2];
        const uint16_t recordLength = (static_cast<uint16_t>(data[offset + 3]) << 8) | data[offset + 4];

        if ((recordVersion & 0xff00) != 0x0300 || recordLength == 0 || recordLength > kMaxTLSRecordLength) {
            return std::nullopt;
        }

        const size_t totalRecordLength = kTLSRecordHeaderLength + recordLength;
        if (offset + totalRecordLength > dataLength) {
            return std::nullopt;
        }

        if (contentType == 22) {
            auto record = std::make_unique<uint8_t[]>(totalRecordLength);
            std::memcpy(record.get(), data + offset, totalRecordLength);
            pcpp::SSLHandshakeLayer handshakeLayer(record.release(), totalRecordLength, nullptr, nullptr);
            auto *clientHelloMessage = handshakeLayer.getHandshakeMessageOfType<pcpp::SSLClientHelloMessage>();
            if (clientHelloMessage != nullptr) {
                auto *sniExtension = clientHelloMessage->getExtensionOfType<pcpp::SSLServerNameIndicationExtension>();
                if (sniExtension != nullptr) {
                    auto hostName = sniExtension->getHostName();
                    if (!hostName.empty()) {
                        return hostName;
                    }
                }
            }
        }

        offset += totalRecordLength;
    }

    return std::nullopt;
}

class SniReassemblyState {
public:
    SniReassemblyState()
        : tcpReassembly_(HandleTcpData,
                         this,
                         nullptr,
                         HandleConnectionEnd,
                         pcpp::TcpReassemblyConfiguration(true, 5, 30, 32)) {}

    std::optional<std::string> domainNameForPacket(const pcpp::RawPacket &rawPacket, uint32_t streamIdentifier)
    {
        // Reassembles the current TCP flow only until a bounded ClientHello SNI is found.
        if (streamIdentifier != 0) {
            if (auto domain = domainByStreamID_.find(streamIdentifier); domain != domainByStreamID_.end()) {
                return domain->second;
            }
        }

        lastDomainName_.reset();
        tcpReassembly_.reassemblePacket(const_cast<pcpp::RawPacket *>(&rawPacket));
        if (!lastDomainName_.has_value()) {
            return std::nullopt;
        }

        if (streamIdentifier != 0) {
            rememberDomain(streamIdentifier, *lastDomainName_);
        }
        return lastDomainName_;
    }

private:
    struct SideKey {
        uint32_t flowKey;
        int8_t side;

        bool operator==(const SideKey &other) const
        {
            return flowKey == other.flowKey && side == other.side;
        }
    };

    struct SideKeyHash {
        size_t operator()(const SideKey &key) const
        {
            return (static_cast<size_t>(key.flowKey) << 8) ^ static_cast<uint8_t>(key.side);
        }
    };

    static constexpr size_t kMaxBufferedClientHelloBytes = 64 * 1024;
    static constexpr size_t kMaxRememberedDomains = 100'000;

    pcpp::TcpReassembly tcpReassembly_;
    std::optional<std::string> lastDomainName_;
    std::unordered_map<SideKey, std::vector<uint8_t>, SideKeyHash> bufferedBytesBySide_;
    std::unordered_set<SideKey, SideKeyHash> rejectedSides_;
    std::unordered_set<uint32_t> completedFlowKeys_;
    std::unordered_map<uint32_t, std::string> domainByStreamID_;
    std::deque<uint32_t> domainStreamOrder_;

    static void HandleTcpData(int8_t side, const pcpp::TcpStreamData &tcpData, void *userCookie)
    {
        auto *state = static_cast<SniReassemblyState *>(userCookie);
        if (state != nullptr) {
            state->handleTcpData(side, tcpData);
        }
    }

    static void HandleConnectionEnd(const pcpp::ConnectionData &connectionData,
                                    pcpp::TcpReassembly::ConnectionEndReason,
                                    void *userCookie)
    {
        auto *state = static_cast<SniReassemblyState *>(userCookie);
        if (state != nullptr) {
            state->removeBuffers(connectionData.flowKey);
            state->completedFlowKeys_.erase(connectionData.flowKey);
        }
    }

    void handleTcpData(int8_t side, const pcpp::TcpStreamData &tcpData)
    {
        const uint32_t flowKey = tcpData.getConnectionData().flowKey;
        if (completedFlowKeys_.find(flowKey) != completedFlowKeys_.end() || tcpData.getDataLength() == 0 || tcpData.isBytesMissing()) {
            return;
        }

        SideKey key{flowKey, side};
        if (rejectedSides_.find(key) != rejectedSides_.end()) {
            return;
        }

        auto &buffer = bufferedBytesBySide_[key];
        if (buffer.empty() && tcpData.getData()[0] != 22) {
            rejectedSides_.insert(key);
            bufferedBytesBySide_.erase(key);
            return;
        }

        if (buffer.size() + tcpData.getDataLength() > kMaxBufferedClientHelloBytes) {
            rejectedSides_.insert(key);
            bufferedBytesBySide_.erase(key);
            return;
        }

        buffer.insert(buffer.end(), tcpData.getData(), tcpData.getData() + tcpData.getDataLength());
        if (auto domainName = SniDomainNameForTLSRecordBytes(buffer.data(), buffer.size())) {
            lastDomainName_ = *domainName;
            completedFlowKeys_.insert(flowKey);
            removeBuffers(flowKey);
        }
    }

    void rememberDomain(uint32_t streamIdentifier, const std::string &domainName)
    {
        if (domainByStreamID_.find(streamIdentifier) == domainByStreamID_.end()) {
            domainStreamOrder_.push_back(streamIdentifier);
            if (domainStreamOrder_.size() > kMaxRememberedDomains) {
                uint32_t removedStreamID = domainStreamOrder_.front();
                domainStreamOrder_.pop_front();
                domainByStreamID_.erase(removedStreamID);
            }
        }

        domainByStreamID_[streamIdentifier] = domainName;
    }

    void removeBuffers(uint32_t flowKey)
    {
        for (int8_t side = 0; side < 2; side++) {
            SideKey key{flowKey, side};
            bufferedBytesBySide_.erase(key);
            rejectedSides_.erase(key);
        }
    }
};

PCPPNativePacketSummaryDescriptor *MakePacketSummary(const pcpp::RawPacket &rawPacket,
                                                     unsigned long long identifier,
                                                     NSString * _Nullable interfaceIdentifier,
                                                     NSString * _Nullable interfaceName,
                                                     NSString * _Nullable packetComment,
                                                     SniReassemblyState *sniReassembly = nullptr)
{
    try {
        pcpp::Packet packet(const_cast<pcpp::RawPacket *>(&rawPacket), false);
        auto decodeStatus = DetermineDecodeStatus(packet, rawPacket);
        NSNumber *streamIdentifier = nil;
        uint32_t streamHash = pcpp::hash5Tuple(&packet, false);
        if (streamHash != 0) {
            streamIdentifier = @(streamHash);
        }

        auto *captureMetadata = [[PCPPNativePacketCaptureMetadataDescriptor alloc] initWithLinkType:MapLinkType(rawPacket.getLinkLayerType())
                                                                                           truncated:rawPacket.getRawDataLen() < rawPacket.getFrameLength()
                                                                                       packetComment:packetComment
                                                                                       interfaceName:interfaceName];

        auto *decodeDescriptor = [[PCPPNativeDecodeStatusDescriptor alloc] initWithKind:decodeStatus.first
                                                                                  reason:decodeStatus.second];
        NSString *sniDomainName = SniDomainNameForPacket(packet);
        if (sniDomainName == nil && sniReassembly != nullptr && packet.isPacketOfType(pcpp::TCP)) {
            if (auto reassembledDomainName = sniReassembly->domainNameForPacket(rawPacket, streamHash)) {
                sniDomainName = MakeNSString(*reassembledDomainName);
            }
        }

        return [[PCPPNativePacketSummaryDescriptor alloc] initWithIdentifier:identifier
                                                                 packetNumber:identifier
                                                                    timestamp:MakeNSDate(rawPacket.getPacketTimeStamp())
                                                          interfaceIdentifier:interfaceIdentifier
                                                                transportHint:MapTransportHint(packet)
                                                               sourceEndpoint:MapSourceEndpoint(packet)
                                                          destinationEndpoint:MapDestinationEndpoint(packet)
                                                               originalLength:rawPacket.getFrameLength()
                                                               capturedLength:rawPacket.getRawDataLen()
                                                             streamIdentifier:streamIdentifier
                                                                      tcpFlags:TCPFlagsSummaryForPacket(packet)
                                                               tcpPayloadLength:TCPPayloadLengthForPacket(packet)
                                                                  infoSummary:InfoSummaryForPacket(packet, rawPacket)
                                                                      layers:MapLayers(packet)
                                                                 decodeStatus:decodeDescriptor
                                                              captureMetadata:captureMetadata
                                                                sniDomainName:sniDomainName];
    } catch (const std::exception &exception) {
        auto *captureMetadata = [[PCPPNativePacketCaptureMetadataDescriptor alloc] initWithLinkType:MapLinkType(rawPacket.getLinkLayerType())
                                                                                           truncated:rawPacket.getRawDataLen() < rawPacket.getFrameLength()
                                                                                       packetComment:packetComment
                                                                                       interfaceName:interfaceName];
        auto *decodeDescriptor = [[PCPPNativeDecodeStatusDescriptor alloc] initWithKind:PCPPNativeDecodeStatusKindMalformed
                                                                                  reason:MakeNSString(exception.what())];
        return [[PCPPNativePacketSummaryDescriptor alloc] initWithIdentifier:identifier
                                                                 packetNumber:identifier
                                                                    timestamp:MakeNSDate(rawPacket.getPacketTimeStamp())
                                                          interfaceIdentifier:interfaceIdentifier
                                                                transportHint:PCPPNativeTransportHintUnknown
                                                               sourceEndpoint:[[PCPPNativePacketEndpointDescriptor alloc] initWithAddress:nil port:nil]
                                                          destinationEndpoint:[[PCPPNativePacketEndpointDescriptor alloc] initWithAddress:nil port:nil]
                                                               originalLength:rawPacket.getFrameLength()
                                                               capturedLength:rawPacket.getRawDataLen()
                                                             streamIdentifier:nil
                                                                      tcpFlags:nil
                                                               tcpPayloadLength:nil
                                                                  infoSummary:@"Packet decoding failed."
                                                                       layers:@[]
                                                                 decodeStatus:decodeDescriptor
                                                              captureMetadata:captureMetadata
                                                                sniDomainName:nil];
    }
}

PCPPNativePacketByteRangeDescriptor *MakeByteRange(NSUInteger offset, NSUInteger length)
{
    return [[PCPPNativePacketByteRangeDescriptor alloc] initWithOffset:(NSInteger)offset length:(NSInteger)length];
}

PCPPNativePacketByteRangeDescriptor *MakeBitRange(const tcpviewer::dissection::ByteRange &range)
{
    return [[PCPPNativePacketByteRangeDescriptor alloc] initWithOffset:(NSInteger)range.offset
                                                                length:(NSInteger)range.length
                                                             bitOffset:(NSInteger)range.bitOffset
                                                             bitLength:(NSInteger)range.bitLength
                                                           hasBitRange:range.hasBitRange];
}

PCPPNativePacketDetailNodeDescriptor *MakeDetailNode(NSString *identifier,
                                                     NSString *name,
                                                     NSString * _Nullable value,
                                                     NSString *kind,
                                                     PCPPNativePacketByteRangeDescriptor * _Nullable byteRange,
                                                     NSNumber * _Nullable jumpTargetPacketIdentifier,
                                                     NSArray<PCPPNativePacketDetailNodeDescriptor *> *children)
{
    return [[PCPPNativePacketDetailNodeDescriptor alloc] initWithIdentifier:identifier
                                                                       name:name
                                                                  fieldName:identifier
                                                                      value:value
                                                                   rawValue:nil
                                                                       kind:kind
                                                                   severity:[kind isEqualToString:@"warning"] ? @"warning" : @"normal"
                                                                  byteRange:byteRange
                                                   jumpTargetPacketIdentifier:jumpTargetPacketIdentifier
                                                                    children:children];
}

NSString *DetailNodeKindValue(tcpviewer::dissection::NodeKind kind)
{
    switch (kind) {
        case tcpviewer::dissection::NodeKind::Layer:
            return @"layer";
        case tcpviewer::dissection::NodeKind::Warning:
            return @"warning";
        case tcpviewer::dissection::NodeKind::Field:
        default:
            return @"field";
    }
}

NSString *DetailNodeSeverityValue(tcpviewer::dissection::NodeSeverity severity)
{
    switch (severity) {
        case tcpviewer::dissection::NodeSeverity::Info:
            return @"info";
        case tcpviewer::dissection::NodeSeverity::Warning:
            return @"warning";
        case tcpviewer::dissection::NodeSeverity::Error:
            return @"error";
        case tcpviewer::dissection::NodeSeverity::Normal:
        default:
            return @"normal";
    }
}

PCPPNativePacketDetailNodeDescriptor *MakeDetailNode(const tcpviewer::dissection::DetailNode &node)
{
    NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *children = [NSMutableArray arrayWithCapacity:node.children.size()];
    for (const auto &child : node.children) {
        [children addObject:MakeDetailNode(child)];
    }

    PCPPNativePacketByteRangeDescriptor *byteRange = nil;
    if (node.range.has_value()) {
        byteRange = MakeBitRange(node.range.value());
    }

    return [[PCPPNativePacketDetailNodeDescriptor alloc] initWithIdentifier:MakeNSString(node.id)
                                                                       name:MakeNSString(node.title)
                                                                  fieldName:MakeNSString(node.fieldName)
                                                                      value:NullableNSString(node.displayValue)
                                                                   rawValue:NullableNSString(node.rawValue)
                                                                       kind:DetailNodeKindValue(node.kind)
                                                                   severity:DetailNodeSeverityValue(node.severity)
                                                                  byteRange:byteRange
                                                   jumpTargetPacketIdentifier:nil
                                                                   children:children];
}

PCPPNativePacketDetailNodeDescriptor *MakeFieldNode(NSString *identifier,
                                                    NSString *name,
                                                    NSString * _Nullable value,
                                                    NSUInteger baseOffset,
                                                    NSUInteger relativeOffset,
                                                    NSUInteger length)
{
    return MakeDetailNode(identifier,
                          name,
                          value,
                          @"field",
                          MakeByteRange(baseOffset + relativeOffset, length),
                          nil,
                          @[]);
}

PCPPNativePacketDetailNodeDescriptor *MakeSyntheticFieldNode(NSString *identifier,
                                                             NSString *name,
                                                             NSString * _Nullable value)
{
    return MakeDetailNode(identifier, name, value, @"field", nil, nil, @[]);
}

PCPPNativePacketDetailNodeDescriptor *MakeLayerNode(NSString *identifier,
                                                    NSString *name,
                                                    NSString * _Nullable value,
                                                    NSUInteger offset,
                                                    NSUInteger length,
                                                    NSArray<PCPPNativePacketDetailNodeDescriptor *> *children)
{
    return MakeDetailNode(identifier,
                          name,
                          value,
                          @"layer",
                          MakeByteRange(offset, length),
                          nil,
                          children);
}

PCPPNativePacketDetailNodeDescriptor *MakeWarningNode(NSString *identifier, NSString *message)
{
    return MakeDetailNode(identifier, @"Decode Warning", message, @"warning", nil, nil, @[]);
}

PCPPNativePacketDetailNodeDescriptor *MakeDecodeStatusNode(NSString *identifier,
                                                           PCPPNativeDecodeStatusKind kind,
                                                           NSString *message)
{
    if (kind == PCPPNativeDecodeStatusKindPartial && [message isEqualToString:TCPViewerOpaquePayloadDecodeReason]) {
        return [[PCPPNativePacketDetailNodeDescriptor alloc] initWithIdentifier:identifier
                                                                           name:@"Payload Not Decoded"
                                                                      fieldName:@"tcpviewer.payload_not_decoded"
                                                                          value:message
                                                                       rawValue:nil
                                                                           kind:@"field"
                                                                       severity:@"info"
                                                                      byteRange:nil
                                                       jumpTargetPacketIdentifier:nil
                                                                       children:@[]];
    }

    return MakeWarningNode(identifier, message);
}

NSUInteger LayerOffset(const pcpp::Layer &layer, const pcpp::RawPacket &rawPacket)
{
    return static_cast<NSUInteger>(layer.getData() - rawPacket.getRawData());
}

NSString *FormatHex16(uint16_t value)
{
    return [NSString stringWithFormat:@"0x%04x", value];
}

NSString *FormatHex32(uint32_t value)
{
    return [NSString stringWithFormat:@"0x%08x", value];
}

NSString *PayloadPreview(const uint8_t *bytes, size_t length, NSUInteger limit = 16)
{
    if (bytes == nullptr || length == 0) {
        return @"Empty";
    }

    NSMutableArray<NSString *> *segments = [NSMutableArray array];
    NSUInteger visibleLength = std::min<NSUInteger>(length, limit);
    for (NSUInteger index = 0; index < visibleLength; index += 1) {
        [segments addObject:[NSString stringWithFormat:@"%02x", bytes[index]]];
    }

    NSString *joined = [segments componentsJoinedByString:@" "];
    if (length > visibleLength) {
        return [joined stringByAppendingString:@" …"];
    }

    return joined;
}

size_t TLSHandshakeDeclaredPayloadLength(const uint8_t *messageData, size_t messageLength)
{
    if (messageData == nullptr || messageLength < sizeof(pcpp::ssl_tls_handshake_layer)) {
        return 0;
    }

    return (static_cast<size_t>(messageData[1]) << 16) |
           (static_cast<size_t>(messageData[2]) << 8) |
           static_cast<size_t>(messageData[3]);
}

NSString *TLSCipherSuiteFieldValue(uint16_t cipherSuiteID, pcpp::SSLCipherSuite *cipherSuite)
{
    if (cipherSuite == nullptr) {
        return FormatHex16(cipherSuiteID);
    }

    return [NSString stringWithFormat:@"%@ (%@)", MakeNSString(cipherSuite->asString()), FormatHex16(cipherSuiteID)];
}

NSString *TCPFlagsSummary(const pcpp::tcphdr *header)
{
    NSMutableArray<NSString *> *flags = [NSMutableArray array];
    if (header->finFlag) {
        [flags addObject:@"FIN"];
    }
    if (header->synFlag) {
        [flags addObject:@"SYN"];
    }
    if (header->rstFlag) {
        [flags addObject:@"RST"];
    }
    if (header->pshFlag) {
        [flags addObject:@"PSH"];
    }
    if (header->ackFlag) {
        [flags addObject:@"ACK"];
    }
    if (header->urgFlag) {
        [flags addObject:@"URG"];
    }
    if (header->eceFlag) {
        [flags addObject:@"ECE"];
    }
    if (header->cwrFlag) {
        [flags addObject:@"CWR"];
    }

    if (flags.count == 0) {
        return @"None";
    }

    return [flags componentsJoinedByString:@", "];
}

NSString *TCPFlagsSummaryForPacket(const pcpp::Packet &packet)
{
    if (auto *tcpLayer = packet.getLayerOfType<pcpp::TcpLayer>(true)) {
        return TCPFlagsSummary(tcpLayer->getTcpHeader());
    }

    return nil;
}

NSNumber *TCPPayloadLengthForPacket(const pcpp::Packet &packet)
{
    if (auto *tcpLayer = packet.getLayerOfType<pcpp::TcpLayer>(true)) {
        return @(tcpLayer->getLayerPayloadSize());
    }

    return nil;
}

uint16_t TCPFlagsValue(const pcpp::tcphdr *header)
{
    uint16_t value = 0;
    value |= header->cwrFlag ? 0x80 : 0;
    value |= header->eceFlag ? 0x40 : 0;
    value |= header->urgFlag ? 0x20 : 0;
    value |= header->ackFlag ? 0x10 : 0;
    value |= header->pshFlag ? 0x08 : 0;
    value |= header->rstFlag ? 0x04 : 0;
    value |= header->synFlag ? 0x02 : 0;
    value |= header->finFlag ? 0x01 : 0;
    return value;
}

NSString *SetStatus(bool isSet)
{
    return isSet ? @"Set" : @"Not set";
}

NSString *TCPOptionName(pcpp::TcpOptionEnumType type)
{
    switch (type) {
        case pcpp::TcpOptionEnumType::Mss:
            return @"TCP Option - Maximum segment size";
        case pcpp::TcpOptionEnumType::Nop:
            return @"TCP Option - No-Operation";
        case pcpp::TcpOptionEnumType::Window:
            return @"TCP Option - Window scale";
        case pcpp::TcpOptionEnumType::Timestamp:
            return @"TCP Option - Timestamps";
        case pcpp::TcpOptionEnumType::SackPerm:
            return @"TCP Option - SACK permitted";
        case pcpp::TcpOptionEnumType::Sack:
            return @"TCP Option - SACK";
        case pcpp::TcpOptionEnumType::Eol:
            return @"TCP Option - End of Option List";
        default:
            return @"TCP Option - Unknown";
    }
}

NSString *TCPOptionValue(pcpp::TcpOption &option)
{
    switch (option.getTcpOptionEnumType()) {
        case pcpp::TcpOptionEnumType::Mss:
            if (option.getDataSize() >= 2) {
                return [NSString stringWithFormat:@"%u bytes", ntohs(option.getValueAs<uint16_t>())];
            }
            break;
        case pcpp::TcpOptionEnumType::Window:
            if (option.getDataSize() >= 1) {
                uint8_t shift = option.getValueAs<uint8_t>();
                uint32_t multiplier = shift < 31 ? (1u << shift) : 0;
                return multiplier > 0
                    ? [NSString stringWithFormat:@"%u (multiply by %u)", shift, multiplier]
                    : [NSString stringWithFormat:@"%u", shift];
            }
            break;
        case pcpp::TcpOptionEnumType::Timestamp:
            if (option.getDataSize() >= 8) {
                uint32_t tsValue = ntohl(option.getValueAs<uint32_t>(0));
                uint32_t tsEcho = ntohl(option.getValueAs<uint32_t>(4));
                return [NSString stringWithFormat:@"TSval %u, TSecr %u", tsValue, tsEcho];
            }
            break;
        case pcpp::TcpOptionEnumType::SackPerm:
            return @"Permitted";
        case pcpp::TcpOptionEnumType::Nop:
        case pcpp::TcpOptionEnumType::Eol:
            return nil;
        default:
            break;
    }

    return [NSString stringWithFormat:@"Kind %u, %zu bytes", option.getType(), option.getTotalSize()];
}

NSString *UDPChecksumStatus(pcpp::UdpLayer *udpLayer)
{
    const uint16_t checksum = ntohs(udpLayer->getUdpHeader()->headerChecksum);
    if (checksum == 0) {
        auto *previousLayer = udpLayer->getPrevLayer();
        if (previousLayer != nullptr && previousLayer->getProtocol() == pcpp::IPv6) {
            return @"Illegal zero checksum";
        }
        return @"Not present";
    }

    return @"Present (unverified)";
}

NSUInteger DNSHeaderOffset(pcpp::DnsLayer *dnsLayer, NSUInteger layerOffset)
{
    return dynamic_cast<pcpp::DnsOverTcpLayer *>(dnsLayer) != nullptr
        ? layerOffset + sizeof(uint16_t)
        : layerOffset;
}

NSString *DNSRecordTypeName(pcpp::DnsType type)
{
    switch (type) {
        case pcpp::DNS_TYPE_A:
            return @"A";
        case pcpp::DNS_TYPE_NS:
            return @"NS";
        case pcpp::DNS_TYPE_CNAME:
            return @"CNAME";
        case pcpp::DNS_TYPE_SOA:
            return @"SOA";
        case pcpp::DNS_TYPE_PTR:
            return @"PTR";
        case pcpp::DNS_TYPE_MX:
            return @"MX";
        case pcpp::DNS_TYPE_TXT:
            return @"TXT";
        case pcpp::DNS_TYPE_AAAA:
            return @"AAAA";
        case pcpp::DNS_TYPE_SRV:
            return @"SRV";
        case pcpp::DNS_TYPE_OPT:
            return @"OPT";
        case pcpp::DNS_TYPE_DS:
            return @"DS";
        case pcpp::DNS_TYPE_RRSIG:
            return @"RRSIG";
        case pcpp::DNS_TYPE_NSEC:
            return @"NSEC";
        case pcpp::DNS_TYPE_DNSKEY:
            return @"DNSKEY";
        case pcpp::DNS_TYPE_ALL:
            return @"ANY";
        default:
            return @"Unknown";
    }
}

NSString *DNSRecordTypeValue(pcpp::DnsType type)
{
    return [NSString stringWithFormat:@"%@ (%u)", DNSRecordTypeName(type), static_cast<unsigned>(type)];
}

NSString *DNSClassName(pcpp::DnsClass dnsClass)
{
    switch (dnsClass) {
        case pcpp::DNS_CLASS_IN:
            return @"IN";
        case pcpp::DNS_CLASS_IN_QU:
            return @"IN QU";
        case pcpp::DNS_CLASS_CH:
            return @"CH";
        case pcpp::DNS_CLASS_HS:
            return @"HS";
        case pcpp::DNS_CLASS_ANY:
            return @"ANY";
        default:
            return @"Unknown";
    }
}

NSString *DNSClassValue(pcpp::DnsClass dnsClass)
{
    return [NSString stringWithFormat:@"%@ (%u)", DNSClassName(dnsClass), static_cast<unsigned>(dnsClass)];
}

NSString *DNSOpcodeName(uint16_t opcode)
{
    switch (opcode) {
        case 0:
            return @"Standard query";
        case 1:
            return @"Inverse query";
        case 2:
            return @"Status";
        case 4:
            return @"Notify";
        case 5:
            return @"Update";
        default:
            return @"Unknown";
    }
}

NSString *DNSResponseCodeName(uint16_t responseCode)
{
    switch (responseCode) {
        case 0:
            return @"No error";
        case 1:
            return @"Format error";
        case 2:
            return @"Server failure";
        case 3:
            return @"Non-existent domain";
        case 4:
            return @"Not implemented";
        case 5:
            return @"Refused";
        default:
            return @"Unknown";
    }
}

NSString *DNSQueryResponseValue(bool isResponse)
{
    return isResponse ? @"Response" : @"Query";
}

NSString *DNSResourceDataValue(pcpp::DnsResource *resource)
{
    auto data = resource->getData();
    if (data.get() == nullptr) {
        return nil;
    }

    return MakeNSString(data->toString());
}

class PacketDetailTreeBuilder {
public:
    PacketDetailTreeBuilder(const pcpp::Packet &packet,
                            const pcpp::RawPacket &rawPacket,
                            unsigned long long packetIdentifier,
                            NSString * _Nullable interfaceName,
                            NSString * _Nullable packetComment)
        : packet_(packet),
          rawPacket_(rawPacket),
          packetIdentifier_(packetIdentifier),
          interfaceName_(interfaceName),
          packetComment_(packetComment) {}

    NSArray<PCPPNativePacketDetailNodeDescriptor *> *build()
    {
        NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *nodes = [NSMutableArray array];
        appendFrame(nodes);
        for (pcpp::Layer *layer = packet_.getFirstLayer(); layer != nullptr; layer = layer->getNextLayer()) {
            appendLayer(layer, nodes);
        }

        auto decodeStatus = DetermineDecodeStatus(packet_, rawPacket_);
        if (decodeStatus.first != PCPPNativeDecodeStatusKindComplete && decodeStatus.second != nil) {
            [nodes addObject:MakeDecodeStatusNode(@"warning.decode", decodeStatus.first, decodeStatus.second)];
        }

        return nodes;
    }

private:
    const pcpp::Packet &packet_;
    const pcpp::RawPacket &rawPacket_;
    unsigned long long packetIdentifier_;
    NSString * _Nullable interfaceName_;
    NSString * _Nullable packetComment_;
    tcpviewer::dissection::PacketDissectionEngine engine_;

    tcpviewer::dissection::PacketDissectionContext dissectionContext() const
    {
        tcpviewer::dissection::PacketDissectionContext context{
            packet_,
            rawPacket_,
            packetIdentifier_,
            std::nullopt,
            std::nullopt,
        };
        if (interfaceName_ != nil) {
            context.interfaceName = MakeStdString(interfaceName_);
        }
        if (packetComment_ != nil) {
            context.packetComment = MakeStdString(packetComment_);
        }
        return context;
    }

    uint32_t streamIdentifier()
    {
        return pcpp::hash5Tuple(const_cast<pcpp::Packet *>(&packet_), false);
    }

    void appendFrame(NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *nodes)
    {
        [nodes addObject:MakeDetailNode(engine_.dissectFrame(dissectionContext()))];
    }

    void appendLayer(pcpp::Layer *layer, NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *nodes)
    {
        auto context = dissectionContext();
        if (auto node = engine_.dissectLayer(context, *layer)) {
            [nodes addObject:MakeDetailNode(node.value())];
            return;
        }

        NSUInteger offset = LayerOffset(*layer, rawPacket_);
        switch (layer->getProtocol()) {
            case pcpp::DNS:
                appendDNS(static_cast<pcpp::DnsLayer *>(layer), offset, nodes);
                break;
            case pcpp::SSL:
                appendTLS(static_cast<pcpp::SSLLayer *>(layer), offset, nodes);
                break;
            case pcpp::GenericPayload:
                appendPayload(static_cast<pcpp::PayloadLayer *>(layer), offset, nodes);
                break;
            default:
                appendUnsupported(layer, offset, nodes);
                break;
        }
    }

    void appendEthernet(pcpp::EthLayer *ethLayer, NSUInteger offset, NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *nodes)
    {
        auto *header = ethLayer->getEthHeader();
        NSArray *children = @[
            MakeFieldNode(@"eth.dst", @"Destination", MakeNSString(ethLayer->getDestMac().toString()), offset, 0, 6),
            MakeFieldNode(@"eth.src", @"Source", MakeNSString(ethLayer->getSourceMac().toString()), offset, 6, 6),
            MakeFieldNode(@"eth.type", @"Type", FormatHex16(ntohs(header->etherType)), offset, 12, 2),
        ];
        [nodes addObject:MakeLayerNode(@"eth",
                                       @"Ethernet",
                                       [NSString stringWithFormat:@"Src: %@, Dst: %@",
                                                                  MakeNSString(ethLayer->getSourceMac().toString()),
                                                                  MakeNSString(ethLayer->getDestMac().toString())],
                                       offset,
                                       ethLayer->getHeaderLen(),
                                       children)];
    }

    void appendARP(pcpp::ArpLayer *arpLayer, NSUInteger offset, NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *nodes)
    {
        auto *header = arpLayer->getArpHeader();
        NSArray *children = @[
            MakeFieldNode(@"arp.hardware", @"Hardware Type", [NSString stringWithFormat:@"%u", ntohs(header->hardwareType)], offset, 0, 2),
            MakeFieldNode(@"arp.protocol", @"Protocol Type", FormatHex16(ntohs(header->protocolType)), offset, 2, 2),
            MakeFieldNode(@"arp.hardwareSize", @"Hardware Size", [NSString stringWithFormat:@"%u", header->hardwareSize], offset, 4, 1),
            MakeFieldNode(@"arp.protocolSize", @"Protocol Size", [NSString stringWithFormat:@"%u", header->protocolSize], offset, 5, 1),
            MakeFieldNode(@"arp.opcode", @"Opcode", [NSString stringWithFormat:@"%u", ntohs(header->opcode)], offset, 6, 2),
            MakeFieldNode(@"arp.senderMac", @"Sender MAC", MakeNSString(arpLayer->getSenderMacAddress().toString()), offset, 8, 6),
            MakeFieldNode(@"arp.senderIP", @"Sender IP", MakeNSString(arpLayer->getSenderIpAddr().toString()), offset, 14, 4),
            MakeFieldNode(@"arp.targetMac", @"Target MAC", MakeNSString(arpLayer->getTargetMacAddress().toString()), offset, 18, 6),
            MakeFieldNode(@"arp.targetIP", @"Target IP", MakeNSString(arpLayer->getTargetIpAddr().toString()), offset, 24, 4),
        ];
        [nodes addObject:MakeLayerNode(@"arp",
                                       @"ARP",
                                       MakeNSString(arpLayer->toString()),
                                       offset,
                                       arpLayer->getHeaderLen(),
                                       children)];
    }

    void appendIPv4(pcpp::IPv4Layer *ipv4Layer, NSUInteger offset, NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *nodes)
    {
        auto *header = ipv4Layer->getIPv4Header();
        NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *children = [NSMutableArray arrayWithArray:@[
            MakeFieldNode(@"ipv4.version", @"Version", [NSString stringWithFormat:@"%u", header->ipVersion], offset, 0, 1),
            MakeFieldNode(@"ipv4.ihl", @"Header Length", [NSString stringWithFormat:@"%zu bytes", ipv4Layer->getHeaderLen()], offset, 0, 1),
            MakeFieldNode(@"ipv4.dscp", @"Differentiated Services", FormatHex16(header->typeOfService), offset, 1, 1),
            MakeFieldNode(@"ipv4.totalLength", @"Total Length", [NSString stringWithFormat:@"%u", ntohs(header->totalLength)], offset, 2, 2),
            MakeFieldNode(@"ipv4.identification", @"Identification", FormatHex16(ntohs(header->ipId)), offset, 4, 2),
            MakeFieldNode(@"ipv4.flagsOffset", @"Flags / Fragment Offset", FormatHex16(ntohs(header->fragmentOffset)), offset, 6, 2),
            MakeFieldNode(@"ipv4.ttl", @"Time To Live", [NSString stringWithFormat:@"%u", header->timeToLive], offset, 8, 1),
            MakeFieldNode(@"ipv4.protocol", @"Protocol", [NSString stringWithFormat:@"%u", header->protocol], offset, 9, 1),
            MakeFieldNode(@"ipv4.checksum", @"Header Checksum", FormatHex16(ntohs(header->headerChecksum)), offset, 10, 2),
            MakeFieldNode(@"ipv4.src", @"Source", MakeNSString(ipv4Layer->getSrcIPv4Address().toString()), offset, 12, 4),
            MakeFieldNode(@"ipv4.dst", @"Destination", MakeNSString(ipv4Layer->getDstIPv4Address().toString()), offset, 16, 4),
        ]];
        if (ipv4Layer->getHeaderLen() > sizeof(pcpp::iphdr)) {
            [children addObject:MakeFieldNode(@"ipv4.options",
                                              @"Options",
                                              [NSString stringWithFormat:@"%zu bytes", ipv4Layer->getHeaderLen() - sizeof(pcpp::iphdr)],
                                              offset,
                                              sizeof(pcpp::iphdr),
                                              ipv4Layer->getHeaderLen() - sizeof(pcpp::iphdr))];
        }
        [nodes addObject:MakeLayerNode(@"ipv4",
                                       @"IPv4",
                                       [NSString stringWithFormat:@"Src: %@, Dst: %@",
                                                                  MakeNSString(ipv4Layer->getSrcIPv4Address().toString()),
                                                                  MakeNSString(ipv4Layer->getDstIPv4Address().toString())],
                                       offset,
                                       ipv4Layer->getHeaderLen(),
                                       children)];
    }

    void appendIPv6(pcpp::IPv6Layer *ipv6Layer, NSUInteger offset, NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *nodes)
    {
        auto *header = ipv6Layer->getIPv6Header();
        uint32_t versionTrafficFlow = 0;
        std::memcpy(&versionTrafficFlow, header, sizeof(versionTrafficFlow));
        NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *children = [NSMutableArray arrayWithArray:@[
            MakeFieldNode(@"ipv6.versionTraffic", @"Version / Traffic Class / Flow Label", FormatHex32(ntohl(versionTrafficFlow)), offset, 0, 4),
            MakeFieldNode(@"ipv6.payloadLength", @"Payload Length", [NSString stringWithFormat:@"%u", ntohs(header->payloadLength)], offset, 4, 2),
            MakeFieldNode(@"ipv6.nextHeader", @"Next Header", [NSString stringWithFormat:@"%u", header->nextHeader], offset, 6, 1),
            MakeFieldNode(@"ipv6.hopLimit", @"Hop Limit", [NSString stringWithFormat:@"%u", header->hopLimit], offset, 7, 1),
            MakeFieldNode(@"ipv6.src", @"Source", MakeNSString(ipv6Layer->getSrcIPv6Address().toString()), offset, 8, 16),
            MakeFieldNode(@"ipv6.dst", @"Destination", MakeNSString(ipv6Layer->getDstIPv6Address().toString()), offset, 24, 16),
        ]];
        if (ipv6Layer->getHeaderLen() > sizeof(pcpp::ip6_hdr)) {
            [children addObject:MakeFieldNode(@"ipv6.extensions",
                                              @"Extension Headers",
                                              [NSString stringWithFormat:@"%zu bytes", ipv6Layer->getHeaderLen() - sizeof(pcpp::ip6_hdr)],
                                              offset,
                                              sizeof(pcpp::ip6_hdr),
                                              ipv6Layer->getHeaderLen() - sizeof(pcpp::ip6_hdr))];
        }
        [nodes addObject:MakeLayerNode(@"ipv6",
                                       @"IPv6",
                                       [NSString stringWithFormat:@"Src: %@, Dst: %@",
                                                                  MakeNSString(ipv6Layer->getSrcIPv6Address().toString()),
                                                                  MakeNSString(ipv6Layer->getDstIPv6Address().toString())],
                                       offset,
                                       ipv6Layer->getHeaderLen(),
                                       children)];
    }

    void appendTCP(pcpp::TcpLayer *tcpLayer, NSUInteger offset, NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *nodes)
    {
        auto *header = tcpLayer->getTcpHeader();
        NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *children = [NSMutableArray array];
        uint32_t streamID = streamIdentifier();
        if (streamID != 0) {
            [children addObject:MakeSyntheticFieldNode(@"tcp.streamID", @"Stream ID", [NSString stringWithFormat:@"%u", streamID])];
        }
        [children addObject:MakeSyntheticFieldNode(@"tcp.segmentLength", @"TCP Segment Len", [NSString stringWithFormat:@"%zu", tcpLayer->getLayerPayloadSize()])];
        [children addObject:MakeFieldNode(@"tcp.srcPort", @"Source Port", [NSString stringWithFormat:@"%u", tcpLayer->getSrcPort()], offset, 0, 2)];
        [children addObject:MakeFieldNode(@"tcp.dstPort", @"Destination Port", [NSString stringWithFormat:@"%u", tcpLayer->getDstPort()], offset, 2, 2)];
        [children addObject:MakeFieldNode(@"tcp.sequence.raw", @"Sequence Number (raw)", [NSString stringWithFormat:@"%u", ntohl(header->sequenceNumber)], offset, 4, 4)];
        [children addObject:MakeFieldNode(@"tcp.ack.raw", @"Acknowledgment Number (raw)", [NSString stringWithFormat:@"%u", ntohl(header->ackNumber)], offset, 8, 4)];
        [children addObject:MakeFieldNode(@"tcp.dataOffset", @"Header Length", [NSString stringWithFormat:@"%zu bytes (%u)", tcpLayer->getHeaderLen(), header->dataOffset], offset, 12, 1)];
        [children addObject:tcpFlagsNode(header, offset)];
        [children addObject:MakeFieldNode(@"tcp.window", @"Window", [NSString stringWithFormat:@"%u", ntohs(header->windowSize)], offset, 14, 2)];
        [children addObject:MakeFieldNode(@"tcp.checksum", @"Checksum", FormatHex16(ntohs(header->headerChecksum)), offset, 16, 2)];
        [children addObject:MakeFieldNode(@"tcp.urgentPointer", @"Urgent Pointer", [NSString stringWithFormat:@"%u", ntohs(header->urgentPointer)], offset, 18, 2)];

        if (tcpLayer->getHeaderLen() > sizeof(pcpp::tcphdr)) {
            [children addObject:MakeDetailNode(@"tcp.options",
                                              @"Options",
                                              [NSString stringWithFormat:@"%zu bytes", tcpLayer->getHeaderLen() - sizeof(pcpp::tcphdr)],
                                              @"field",
                                              MakeByteRange(offset + sizeof(pcpp::tcphdr), tcpLayer->getHeaderLen() - sizeof(pcpp::tcphdr)),
                                              nil,
                                              tcpOptionNodes(tcpLayer, offset))];
        }

        [nodes addObject:MakeLayerNode(@"tcp",
                                       @"TCP",
                                       [NSString stringWithFormat:@"%u → %u (%@)",
                                                                  tcpLayer->getSrcPort(),
                                                                  tcpLayer->getDstPort(),
                                                                  TCPFlagsSummary(header)],
                                       offset,
                                       tcpLayer->getHeaderLen(),
                                       children)];
    }

    PCPPNativePacketDetailNodeDescriptor *tcpFlagsNode(const pcpp::tcphdr *header, NSUInteger offset)
    {
        NSArray *flagChildren = @[
            MakeFieldNode(@"tcp.flags.cwr", @"Congestion Window Reduced", SetStatus(header->cwrFlag), offset, 12, 2),
            MakeFieldNode(@"tcp.flags.ece", @"ECN-Echo", SetStatus(header->eceFlag), offset, 12, 2),
            MakeFieldNode(@"tcp.flags.urg", @"Urgent", SetStatus(header->urgFlag), offset, 12, 2),
            MakeFieldNode(@"tcp.flags.ack", @"Acknowledgment", SetStatus(header->ackFlag), offset, 12, 2),
            MakeFieldNode(@"tcp.flags.psh", @"Push", SetStatus(header->pshFlag), offset, 12, 2),
            MakeFieldNode(@"tcp.flags.rst", @"Reset", SetStatus(header->rstFlag), offset, 12, 2),
            MakeFieldNode(@"tcp.flags.syn", @"Syn", SetStatus(header->synFlag), offset, 12, 2),
            MakeFieldNode(@"tcp.flags.fin", @"Fin", SetStatus(header->finFlag), offset, 12, 2),
        ];
        return MakeDetailNode(@"tcp.flags",
                              @"Flags",
                              [NSString stringWithFormat:@"0x%03x (%@)", TCPFlagsValue(header), TCPFlagsSummary(header)],
                              @"field",
                              MakeByteRange(offset + 12, 2),
                              nil,
                              flagChildren);
    }

    NSArray<PCPPNativePacketDetailNodeDescriptor *> *tcpOptionNodes(pcpp::TcpLayer *tcpLayer, NSUInteger layerOffset)
    {
        NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *nodes = [NSMutableArray array];
        pcpp::TcpOption option = tcpLayer->getFirstTcpOption();
        NSUInteger index = 0;
        while (option.isNotNull() && index < 64) {
            ptrdiff_t relativeOffset = option.getRecordBasePtr() - tcpLayer->getData();
            if (relativeOffset >= 0) {
                [nodes addObject:MakeDetailNode([NSString stringWithFormat:@"tcp.option.%lu", (unsigned long)index],
                                                TCPOptionName(option.getTcpOptionEnumType()),
                                                TCPOptionValue(option),
                                                @"field",
                                                MakeByteRange(layerOffset + static_cast<NSUInteger>(relativeOffset), option.getTotalSize()),
                                                nil,
                                                @[
                                                    MakeSyntheticFieldNode([NSString stringWithFormat:@"tcp.option.%lu.kind", (unsigned long)index],
                                                                           @"Kind",
                                                                           [NSString stringWithFormat:@"%u", option.getType()]),
                                                    MakeSyntheticFieldNode([NSString stringWithFormat:@"tcp.option.%lu.length", (unsigned long)index],
                                                                           @"Length",
                                                                           [NSString stringWithFormat:@"%zu", option.getTotalSize()]),
                                                ])];
            }

            option = tcpLayer->getNextTcpOption(option);
            index += 1;
        }
        return nodes;
    }

    void appendUDP(pcpp::UdpLayer *udpLayer, NSUInteger offset, NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *nodes)
    {
        auto *header = udpLayer->getUdpHeader();
        uint16_t udpLength = ntohs(header->length);
        uint16_t payloadLength = udpLength >= sizeof(pcpp::udphdr) ? udpLength - sizeof(pcpp::udphdr) : 0;
        uint16_t calculatedChecksum = udpLayer->calculateChecksum(false);
        NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *children = [NSMutableArray array];
        uint32_t streamID = streamIdentifier();
        if (streamID != 0) {
            [children addObject:MakeSyntheticFieldNode(@"udp.streamID", @"Stream ID", [NSString stringWithFormat:@"%u", streamID])];
        }
        [children addObject:MakeFieldNode(@"udp.srcPort", @"Source Port", [NSString stringWithFormat:@"%u", udpLayer->getSrcPort()], offset, 0, 2)];
        [children addObject:MakeFieldNode(@"udp.dstPort", @"Destination Port", [NSString stringWithFormat:@"%u", udpLayer->getDstPort()], offset, 2, 2)];
        [children addObject:MakeFieldNode(@"udp.length", @"Length", [NSString stringWithFormat:@"%u", udpLength], offset, 4, 2)];
        [children addObject:MakeFieldNode(@"udp.payloadLength", @"Payload Length", [NSString stringWithFormat:@"%u bytes", payloadLength], offset, 4, 2)];
        [children addObject:MakeFieldNode(@"udp.checksum", @"Checksum", FormatHex16(ntohs(header->headerChecksum)), offset, 6, 2)];
        [children addObject:MakeSyntheticFieldNode(@"udp.checksum.status", @"Checksum Status", UDPChecksumStatus(udpLayer))];
        [children addObject:MakeSyntheticFieldNode(@"udp.checksum.calculated", @"Calculated Checksum", FormatHex16(calculatedChecksum))];

        [nodes addObject:MakeLayerNode(@"udp",
                                       @"UDP",
                                       [NSString stringWithFormat:@"%u → %u", udpLayer->getSrcPort(), udpLayer->getDstPort()],
                                       offset,
                                       udpLayer->getHeaderLen(),
                                       children)];
    }

    void appendDNS(pcpp::DnsLayer *dnsLayer, NSUInteger offset, NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *nodes)
    {
        // Decode the DNS header, flags, and record sections exposed by PcapPlusPlus.
        auto *header = dnsLayer->getDnsHeader();
        NSUInteger headerOffset = DNSHeaderOffset(dnsLayer, offset);
        uint16_t flags = 0;
        std::memcpy(&flags, dnsLayer->getData() + (headerOffset - offset) + 2, sizeof(flags));
        flags = ntohs(flags);

        NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *children = [NSMutableArray arrayWithArray:@[
            MakeFieldNode(@"dns.id", @"Transaction ID", FormatHex16(ntohs(header->transactionID)), headerOffset, 0, 2),
            dnsFlagsNode(header, flags, headerOffset),
            MakeFieldNode(@"dns.count.queries", @"Questions", [NSString stringWithFormat:@"%u", ntohs(header->numberOfQuestions)], headerOffset, 4, 2),
            MakeFieldNode(@"dns.count.answers", @"Answer RRs", [NSString stringWithFormat:@"%u", ntohs(header->numberOfAnswers)], headerOffset, 6, 2),
            MakeFieldNode(@"dns.count.authorities", @"Authority RRs", [NSString stringWithFormat:@"%u", ntohs(header->numberOfAuthority)], headerOffset, 8, 2),
            MakeFieldNode(@"dns.count.additional", @"Additional RRs", [NSString stringWithFormat:@"%u", ntohs(header->numberOfAdditional)], headerOffset, 10, 2),
        ]];

        appendDNSQueries(dnsLayer, offset, children);
        appendDNSResources(dnsLayer, pcpp::DnsAnswerType, @"dns.answers", @"Answers", offset, children);
        appendDNSResources(dnsLayer, pcpp::DnsAuthorityType, @"dns.authorities", @"Authoritative nameservers", offset, children);
        appendDNSResources(dnsLayer, pcpp::DnsAdditionalType, @"dns.additional", @"Additional records", offset, children);

        [nodes addObject:MakeLayerNode(@"dns",
                                       @"Domain Name System",
                                       MakeNSString(dnsLayer->toString()),
                                       offset,
                                       dnsLayer->getHeaderLen(),
                                       children)];
    }

    PCPPNativePacketDetailNodeDescriptor *dnsFlagsNode(const pcpp::dnshdr *header, uint16_t flags, NSUInteger headerOffset)
    {
        NSArray *flagChildren = @[
            MakeFieldNode(@"dns.flags.response", @"Query/Response", DNSQueryResponseValue(header->queryOrResponse), headerOffset, 2, 2),
            MakeFieldNode(@"dns.flags.opcode", @"Opcode", [NSString stringWithFormat:@"%@ (%u)", DNSOpcodeName(header->opcode), header->opcode], headerOffset, 2, 2),
            MakeFieldNode(@"dns.flags.authoritative", @"Authoritative", SetStatus(header->authoritativeAnswer), headerOffset, 2, 2),
            MakeFieldNode(@"dns.flags.truncated", @"Truncated", SetStatus(header->truncation), headerOffset, 2, 2),
            MakeFieldNode(@"dns.flags.recursionDesired", @"Recursion Desired", SetStatus(header->recursionDesired), headerOffset, 2, 2),
            MakeFieldNode(@"dns.flags.recursionAvailable", @"Recursion Available", SetStatus(header->recursionAvailable), headerOffset, 2, 2),
            MakeFieldNode(@"dns.flags.authenticData", @"Authentic Data", SetStatus(header->authenticData), headerOffset, 2, 2),
            MakeFieldNode(@"dns.flags.checkingDisabled", @"Checking Disabled", SetStatus(header->checkingDisabled), headerOffset, 2, 2),
            MakeFieldNode(@"dns.flags.rcode", @"Response Code", [NSString stringWithFormat:@"%@ (%u)", DNSResponseCodeName(header->responseCode), header->responseCode], headerOffset, 2, 2),
        ];
        return MakeDetailNode(@"dns.flags",
                              @"Flags",
                              FormatHex16(flags),
                              @"field",
                              MakeByteRange(headerOffset + 2, 2),
                              nil,
                              flagChildren);
    }

    void appendDNSQueries(pcpp::DnsLayer *dnsLayer,
                          NSUInteger layerOffset,
                          NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *children)
    {
        NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *queryNodes = [NSMutableArray array];
        pcpp::DnsQuery *query = dnsLayer->getFirstQuery();
        NSUInteger index = 0;
        while (query != nullptr && index < 256) {
            [queryNodes addObject:dnsQueryNode(query, layerOffset, index)];
            query = dnsLayer->getNextQuery(query);
            index += 1;
        }

        if (queryNodes.count == 0) {
            return;
        }

        [children addObject:MakeDetailNode(@"dns.queries",
                                           @"Queries",
                                           [NSString stringWithFormat:@"%lu", static_cast<unsigned long>(queryNodes.count)],
                                           @"field",
                                           nil,
                                           nil,
                                           queryNodes)];
    }

    PCPPNativePacketDetailNodeDescriptor *dnsQueryNode(pcpp::DnsQuery *query, NSUInteger layerOffset, NSUInteger index)
    {
        NSUInteger recordOffset = static_cast<NSUInteger>(query->getNameOffset());
        NSUInteger recordLength = static_cast<NSUInteger>(query->getSize());
        NSUInteger nameLength = recordLength >= 4 ? recordLength - 4 : 0;
        NSString *identifier = [NSString stringWithFormat:@"dns.query.%lu", static_cast<unsigned long>(index)];
        NSArray *children = @[
            MakeFieldNode([identifier stringByAppendingString:@".name"],
                          @"Name",
                          MakeNSString(query->getName()),
                          layerOffset,
                          recordOffset,
                          nameLength),
            MakeFieldNode([identifier stringByAppendingString:@".type"],
                          @"Type",
                          DNSRecordTypeValue(query->getDnsType()),
                          layerOffset,
                          recordOffset + nameLength,
                          2),
            MakeFieldNode([identifier stringByAppendingString:@".class"],
                          @"Class",
                          DNSClassValue(query->getDnsClass()),
                          layerOffset,
                          recordOffset + nameLength + 2,
                          2),
        ];
        return MakeDetailNode(identifier,
                              [NSString stringWithFormat:@"Query: %@", MakeNSString(query->getName())],
                              DNSRecordTypeValue(query->getDnsType()),
                              @"field",
                              MakeByteRange(layerOffset + recordOffset, recordLength),
                              nil,
                              children);
    }

    void appendDNSResources(pcpp::DnsLayer *dnsLayer,
                            pcpp::DnsResourceType resourceType,
                            NSString *identifier,
                            NSString *name,
                            NSUInteger layerOffset,
                            NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *children)
    {
        NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *resourceNodes = [NSMutableArray array];
        pcpp::DnsResource *resource = firstDNSResource(dnsLayer, resourceType);
        NSUInteger index = 0;
        while (resource != nullptr && index < 512) {
            [resourceNodes addObject:dnsResourceNode(resource, resourceType, layerOffset, index)];
            resource = nextDNSResource(dnsLayer, resource, resourceType);
            index += 1;
        }

        if (resourceNodes.count == 0) {
            return;
        }

        [children addObject:MakeDetailNode(identifier,
                                           name,
                                           [NSString stringWithFormat:@"%lu", static_cast<unsigned long>(resourceNodes.count)],
                                           @"field",
                                           nil,
                                           nil,
                                           resourceNodes)];
    }

    pcpp::DnsResource *firstDNSResource(pcpp::DnsLayer *dnsLayer, pcpp::DnsResourceType resourceType)
    {
        switch (resourceType) {
            case pcpp::DnsAnswerType:
                return dnsLayer->getFirstAnswer();
            case pcpp::DnsAuthorityType:
                return dnsLayer->getFirstAuthority();
            case pcpp::DnsAdditionalType:
                return dnsLayer->getFirstAdditionalRecord();
            case pcpp::DnsQueryType:
                return nullptr;
        }
    }

    pcpp::DnsResource *nextDNSResource(pcpp::DnsLayer *dnsLayer,
                                       pcpp::DnsResource *resource,
                                       pcpp::DnsResourceType resourceType)
    {
        switch (resourceType) {
            case pcpp::DnsAnswerType:
                return dnsLayer->getNextAnswer(resource);
            case pcpp::DnsAuthorityType:
                return dnsLayer->getNextAuthority(resource);
            case pcpp::DnsAdditionalType:
                return dnsLayer->getNextAdditionalRecord(resource);
            case pcpp::DnsQueryType:
                return nullptr;
        }
    }

    PCPPNativePacketDetailNodeDescriptor *dnsResourceNode(pcpp::DnsResource *resource,
                                                         pcpp::DnsResourceType resourceType,
                                                         NSUInteger layerOffset,
                                                         NSUInteger index)
    {
        NSUInteger recordOffset = static_cast<NSUInteger>(resource->getNameOffset());
        NSUInteger recordLength = static_cast<NSUInteger>(resource->getSize());
        NSUInteger dataOffset = static_cast<NSUInteger>(resource->getDataOffset());
        NSUInteger dataLength = static_cast<NSUInteger>(resource->getDataLength());
        NSUInteger fixedFieldsLength = 10;
        NSUInteger nameLength = dataOffset >= recordOffset + fixedFieldsLength
            ? dataOffset - recordOffset - fixedFieldsLength
            : 0;
        NSString *identifier = [NSString stringWithFormat:@"dns.%@.%lu", DNSResourceSectionIdentifier(resourceType), static_cast<unsigned long>(index)];
        NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *children = [NSMutableArray arrayWithArray:@[
            MakeFieldNode([identifier stringByAppendingString:@".name"],
                          @"Name",
                          MakeNSString(resource->getName()),
                          layerOffset,
                          recordOffset,
                          nameLength),
            MakeFieldNode([identifier stringByAppendingString:@".type"],
                          @"Type",
                          DNSRecordTypeValue(resource->getDnsType()),
                          layerOffset,
                          recordOffset + nameLength,
                          2),
            MakeFieldNode([identifier stringByAppendingString:@".class"],
                          @"Class",
                          DNSClassValue(resource->getDnsClass()),
                          layerOffset,
                          recordOffset + nameLength + 2,
                          2),
            MakeFieldNode([identifier stringByAppendingString:@".ttl"],
                          @"Time to Live",
                          [NSString stringWithFormat:@"%u", resource->getTTL()],
                          layerOffset,
                          recordOffset + nameLength + 4,
                          4),
            MakeFieldNode([identifier stringByAppendingString:@".dataLength"],
                          @"Data Length",
                          [NSString stringWithFormat:@"%zu", resource->getDataLength()],
                          layerOffset,
                          recordOffset + nameLength + 8,
                          2),
        ]];

        NSString *dataValue = DNSResourceDataValue(resource);
        if (dataValue != nil) {
            [children addObject:MakeFieldNode([identifier stringByAppendingString:@".data"],
                                              @"Data",
                                              dataValue,
                                              layerOffset,
                                              dataOffset,
                                              dataLength)];
        }

        return MakeDetailNode(identifier,
                              [NSString stringWithFormat:@"%@: %@", DNSResourceRecordName(resourceType), MakeNSString(resource->getName())],
                              dataValue ?: DNSRecordTypeValue(resource->getDnsType()),
                              @"field",
                              MakeByteRange(layerOffset + recordOffset, recordLength),
                              nil,
                              children);
    }

    NSString *DNSResourceSectionIdentifier(pcpp::DnsResourceType resourceType)
    {
        switch (resourceType) {
            case pcpp::DnsAnswerType:
                return @"answer";
            case pcpp::DnsAuthorityType:
                return @"authority";
            case pcpp::DnsAdditionalType:
                return @"additional";
            case pcpp::DnsQueryType:
                return @"query";
        }
    }

    NSString *DNSResourceRecordName(pcpp::DnsResourceType resourceType)
    {
        switch (resourceType) {
            case pcpp::DnsAnswerType:
                return @"Answer";
            case pcpp::DnsAuthorityType:
                return @"Authority";
            case pcpp::DnsAdditionalType:
                return @"Additional";
            case pcpp::DnsQueryType:
                return @"Query";
        }
    }

    void appendTLS(pcpp::SSLLayer *sslLayer, NSUInteger offset, NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *nodes)
    {
        NSString *identifier = [NSString stringWithFormat:@"tls.%lu", static_cast<unsigned long>(offset)];
        pcpp::SSLRecordType recordType = sslLayer->getRecordType();
        uint16_t recordLength = ntohs(sslLayer->getRecordLayer()->length);
        NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *children = [NSMutableArray arrayWithArray:@[
            MakeFieldNode([NSString stringWithFormat:@"%@.contentType", identifier],
                          @"Content Type",
                          TLSRecordTypeFieldValue(recordType),
                          offset,
                          0,
                          1),
            MakeFieldNode([NSString stringWithFormat:@"%@.version", identifier],
                          @"Version",
                          TLSVersionFieldValue(sslLayer->getRecordVersion()),
                          offset,
                          1,
                          2),
            MakeFieldNode([NSString stringWithFormat:@"%@.length", identifier],
                          @"Length",
                          [NSString stringWithFormat:@"%u bytes", recordLength],
                          offset,
                          3,
                          2),
        ]];

        if (auto *handshakeLayer = dynamic_cast<pcpp::SSLHandshakeLayer *>(sslLayer)) {
            appendTLSHandshake(handshakeLayer, offset, identifier, children);
        } else if (auto *applicationDataLayer = dynamic_cast<pcpp::SSLApplicationDataLayer *>(sslLayer)) {
            appendTLSApplicationData(applicationDataLayer, offset, identifier, children);
        } else if (auto *alertLayer = dynamic_cast<pcpp::SSLAlertLayer *>(sslLayer)) {
            appendTLSAlert(alertLayer, offset, identifier, children);
        } else if (auto *changeCipherSpecLayer = dynamic_cast<pcpp::SSLChangeCipherSpecLayer *>(sslLayer)) {
            appendTLSChangeCipherSpec(changeCipherSpecLayer, offset, identifier, children);
        }

        [nodes addObject:MakeLayerNode(identifier,
                                       @"Transport Layer Security",
                                       [NSString stringWithFormat:@"%@, %@", TLSLayerName(sslLayer), TLSRecordTypeName(recordType)],
                                       offset,
                                       sslLayer->getHeaderLen(),
                                       children)];
    }

    void appendTLSHandshake(pcpp::SSLHandshakeLayer *handshakeLayer,
                            NSUInteger offset,
                            NSString *identifier,
                            NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *children)
    {
        // Decode the handshake records PcapPlusPlus exposes without attempting TLS decryption.
        [children addObject:MakeSyntheticFieldNode([NSString stringWithFormat:@"%@.handshake.count", identifier],
                                                   @"Handshake Message Count",
                                                   [NSString stringWithFormat:@"%zu", handshakeLayer->getHandshakeMessagesCount()])];

        size_t messageRelativeOffset = sizeof(pcpp::ssl_tls_record_layer);
        size_t layerLength = handshakeLayer->getHeaderLen();
        for (int index = 0; index < static_cast<int>(handshakeLayer->getHandshakeMessagesCount()); index += 1) {
            auto *message = handshakeLayer->getHandshakeMessageAt(index);
            if (message == nullptr || messageRelativeOffset >= layerLength) {
                break;
            }

            size_t messageLength = std::min(message->getMessageLength(), layerLength - messageRelativeOffset);
            if (messageLength == 0) {
                break;
            }

            NSUInteger messageOffset = offset + messageRelativeOffset;
            const uint8_t *messageData = handshakeLayer->getData() + messageRelativeOffset;
            NSString *messageIdentifier = [NSString stringWithFormat:@"%@.handshake.%d", identifier, index];
            pcpp::SSLHandshakeType handshakeType = message->getHandshakeType();
            NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *messageChildren = [NSMutableArray arrayWithArray:@[
                MakeFieldNode([NSString stringWithFormat:@"%@.type", messageIdentifier],
                              @"Handshake Type",
                              TLSHandshakeTypeFieldValue(handshakeType),
                              messageOffset,
                              0,
                              1),
                MakeFieldNode([NSString stringWithFormat:@"%@.length", messageIdentifier],
                              @"Length",
                              [NSString stringWithFormat:@"%zu bytes", TLSHandshakeDeclaredPayloadLength(messageData, messageLength)],
                              messageOffset,
                              1,
                              3),
                MakeSyntheticFieldNode([NSString stringWithFormat:@"%@.complete", messageIdentifier],
                                       @"Complete",
                                       message->isMessageComplete() ? @"Yes" : @"No"),
            ]];

            appendTLSHandshakeMessageMetadata(message, messageOffset, messageLength, messageIdentifier, messageChildren);
            [children addObject:MakeDetailNode(messageIdentifier,
                                               [NSString stringWithFormat:@"Handshake Protocol: %@", TLSHandshakeTypeName(handshakeType)],
                                               MakeNSString(message->toString()),
                                               @"field",
                                               MakeByteRange(messageOffset, messageLength),
                                               nil,
                                               messageChildren)];
            messageRelativeOffset += messageLength;
        }
    }

    void appendTLSHandshakeMessageMetadata(pcpp::SSLHandshakeMessage *message,
                                           NSUInteger messageOffset,
                                           size_t messageLength,
                                           NSString *messageIdentifier,
                                           NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *children)
    {
        if (auto *clientHelloMessage = dynamic_cast<pcpp::SSLClientHelloMessage *>(message)) {
            if (messageLength >= sizeof(pcpp::ssl_tls_client_server_hello)) {
                [children addObject:MakeFieldNode([NSString stringWithFormat:@"%@.handshakeVersion", messageIdentifier],
                                                  @"Handshake Version",
                                                  TLSVersionFieldValue(clientHelloMessage->getHandshakeVersion()),
                                                  messageOffset,
                                                  4,
                                                  2)];
            }
            if (auto *sniExtension = clientHelloMessage->getExtensionOfType<pcpp::SSLServerNameIndicationExtension>()) {
                NSString *hostName = NullableNSString(sniExtension->getHostName());
                if (hostName != nil) {
                    [children addObject:MakeSyntheticFieldNode([NSString stringWithFormat:@"%@.sni", messageIdentifier],
                                                               @"Server Name Indication",
                                                               hostName)];
                }
            }
            [children addObject:MakeSyntheticFieldNode([NSString stringWithFormat:@"%@.cipherSuiteCount", messageIdentifier],
                                                       @"Cipher Suites",
                                                       [NSString stringWithFormat:@"%d", clientHelloMessage->getCipherSuiteCount()])];
            [children addObject:MakeSyntheticFieldNode([NSString stringWithFormat:@"%@.extensionCount", messageIdentifier],
                                                       @"Extensions",
                                                       [NSString stringWithFormat:@"%d", clientHelloMessage->getExtensionCount()])];
            NSString *supportedVersions = TLSSupportedVersionsSummary(clientHelloMessage->getExtensionOfType<pcpp::SSLSupportedVersionsExtension>());
            if (supportedVersions != nil) {
                [children addObject:MakeSyntheticFieldNode([NSString stringWithFormat:@"%@.supportedVersions", messageIdentifier],
                                                           @"Supported Versions",
                                                           supportedVersions)];
            }
            return;
        }

        if (auto *serverHelloMessage = dynamic_cast<pcpp::SSLServerHelloMessage *>(message)) {
            if (messageLength >= sizeof(pcpp::ssl_tls_client_server_hello)) {
                [children addObject:MakeFieldNode([NSString stringWithFormat:@"%@.handshakeVersion", messageIdentifier],
                                                  @"Handshake Version",
                                                  TLSVersionFieldValue(serverHelloMessage->getHandshakeVersion()),
                                                  messageOffset,
                                                  4,
                                                  2)];
            }

            bool isValid = false;
            uint16_t cipherSuiteID = serverHelloMessage->getCipherSuiteID(isValid);
            if (isValid) {
                [children addObject:MakeSyntheticFieldNode([NSString stringWithFormat:@"%@.cipherSuite", messageIdentifier],
                                                           @"Cipher Suite",
                                                           TLSCipherSuiteFieldValue(cipherSuiteID, serverHelloMessage->getCipherSuite()))];
            }
            [children addObject:MakeSyntheticFieldNode([NSString stringWithFormat:@"%@.extensionCount", messageIdentifier],
                                                       @"Extensions",
                                                       [NSString stringWithFormat:@"%d", serverHelloMessage->getExtensionCount()])];
            NSString *supportedVersions = TLSSupportedVersionsSummary(serverHelloMessage->getExtensionOfType<pcpp::SSLSupportedVersionsExtension>());
            if (supportedVersions != nil) {
                [children addObject:MakeSyntheticFieldNode([NSString stringWithFormat:@"%@.supportedVersions", messageIdentifier],
                                                           @"Supported Versions",
                                                           supportedVersions)];
            }
            return;
        }

        if (auto *certificateMessage = dynamic_cast<pcpp::SSLCertificateMessage *>(message)) {
            [children addObject:MakeSyntheticFieldNode([NSString stringWithFormat:@"%@.certificateCount", messageIdentifier],
                                                       @"Certificates",
                                                       [NSString stringWithFormat:@"%d", certificateMessage->getNumOfCertificates()])];
        }
    }

    void appendTLSApplicationData(pcpp::SSLApplicationDataLayer *applicationDataLayer,
                                  NSUInteger offset,
                                  NSString *identifier,
                                  NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *children)
    {
        size_t encryptedDataLength = applicationDataLayer->getEncryptedDataLen();
        NSUInteger encryptedDataOffset = offset + sizeof(pcpp::ssl_tls_record_layer);
        [children addObject:MakeFieldNode([NSString stringWithFormat:@"%@.encryptedData", identifier],
                                          @"Encrypted Application Data",
                                          [NSString stringWithFormat:@"%zu bytes", encryptedDataLength],
                                          encryptedDataOffset,
                                          0,
                                          encryptedDataLength)];
        [children addObject:MakeFieldNode([NSString stringWithFormat:@"%@.encryptedDataPreview", identifier],
                                          @"Encrypted Data Preview",
                                          PayloadPreview(applicationDataLayer->getEncryptedData(), encryptedDataLength),
                                          encryptedDataOffset,
                                          0,
                                          encryptedDataLength)];
    }

    void appendTLSAlert(pcpp::SSLAlertLayer *alertLayer,
                        NSUInteger offset,
                        NSString *identifier,
                        NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *children)
    {
        if (alertLayer->getHeaderLen() > sizeof(pcpp::ssl_tls_record_layer)) {
            pcpp::SSLAlertLevel alertLevel = alertLayer->getAlertLevel();
            [children addObject:MakeFieldNode([NSString stringWithFormat:@"%@.alert.level", identifier],
                                              @"Alert Level",
                                              [NSString stringWithFormat:@"%@ (%u)", TLSAlertLevelName(alertLevel), static_cast<unsigned>(alertLevel)],
                                              offset,
                                              sizeof(pcpp::ssl_tls_record_layer),
                                              1)];
        }

        if (alertLayer->getHeaderLen() > sizeof(pcpp::ssl_tls_record_layer) + 1) {
            pcpp::SSLAlertDescription alertDescription = alertLayer->getAlertDescription();
            [children addObject:MakeFieldNode([NSString stringWithFormat:@"%@.alert.description", identifier],
                                              @"Alert Description",
                                              [NSString stringWithFormat:@"%@ (%u)", TLSAlertDescriptionName(alertDescription), static_cast<unsigned>(alertDescription)],
                                              offset,
                                              sizeof(pcpp::ssl_tls_record_layer) + 1,
                                              1)];
        }
    }

    void appendTLSChangeCipherSpec(pcpp::SSLChangeCipherSpecLayer *changeCipherSpecLayer,
                                   NSUInteger offset,
                                   NSString *identifier,
                                   NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *children)
    {
        if (changeCipherSpecLayer->getHeaderLen() <= sizeof(pcpp::ssl_tls_record_layer)) {
            return;
        }

        [children addObject:MakeFieldNode([NSString stringWithFormat:@"%@.changeCipherSpec", identifier],
                                          @"Change Cipher Spec",
                                          [NSString stringWithFormat:@"%u", changeCipherSpecLayer->getData()[sizeof(pcpp::ssl_tls_record_layer)]],
                                          offset,
                                          sizeof(pcpp::ssl_tls_record_layer),
                                          1)];
    }

    void appendPayload(pcpp::PayloadLayer *payloadLayer, NSUInteger offset, NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *nodes)
    {
        NSArray *children = @[
            MakeFieldNode(@"payload.length",
                          @"Length",
                          [NSString stringWithFormat:@"%zu bytes", payloadLayer->getPayloadLen()],
                          offset,
                          0,
                          payloadLayer->getPayloadLen()),
            MakeFieldNode(@"payload.preview",
                          @"Preview",
                          PayloadPreview(payloadLayer->getPayload(), payloadLayer->getPayloadLen()),
                          offset,
                          0,
                          payloadLayer->getPayloadLen()),
        ];
        [nodes addObject:MakeLayerNode(@"payload",
                                       @"Payload",
                                       [NSString stringWithFormat:@"%zu bytes", payloadLayer->getPayloadLen()],
                                       offset,
                                       payloadLayer->getPayloadLen(),
                                       children)];
    }

    void appendUnsupported(pcpp::Layer *layer, NSUInteger offset, NSMutableArray<PCPPNativePacketDetailNodeDescriptor *> *nodes)
    {
        [nodes addObject:MakeLayerNode([NSString stringWithFormat:@"layer-%lu", (unsigned long)offset],
                                       LayerName(*layer),
                                       [NSString stringWithFormat:@"Detailed field decoding is not available yet for %@.",
                                                                  LayerName(*layer)],
                                       offset,
                                       layer->getHeaderLen(),
                                       @[
                                           MakeFieldNode([NSString stringWithFormat:@"layer-%lu.bytes", (unsigned long)offset],
                                                         @"Bytes",
                                                         [NSString stringWithFormat:@"%zu bytes", layer->getHeaderLen()],
                                                         offset,
                                                         0,
                                                         layer->getHeaderLen()),
                                       ])];
    }
};

NSArray<PCPPNativePacketDetailNodeDescriptor *> *BuildPacketDetailNodes(const pcpp::Packet &packet,
                                                                        const pcpp::RawPacket &rawPacket,
                                                                        unsigned long long packetIdentifier,
                                                                        NSString * _Nullable interfaceName,
                                                                        NSString * _Nullable packetComment)
{
    return PacketDetailTreeBuilder(packet, rawPacket, packetIdentifier, interfaceName, packetComment).build();
}

PCPPNativePacketInspectionDescriptor *MakePacketInspection(const pcpp::RawPacket &rawPacket,
                                                           unsigned long long identifier,
                                                           NSString * _Nullable interfaceName,
                                                           NSString * _Nullable packetComment)
{
    NSData *rawBytes = [NSData dataWithBytes:rawPacket.getRawData() length:static_cast<NSUInteger>(rawPacket.getRawDataLen())];

    try {
        pcpp::Packet packet(const_cast<pcpp::RawPacket *>(&rawPacket), false);
        auto decodeStatus = DetermineDecodeStatus(packet, rawPacket);
        auto *decodeDescriptor = [[PCPPNativeDecodeStatusDescriptor alloc] initWithKind:decodeStatus.first
                                                                                  reason:decodeStatus.second];
        return [[PCPPNativePacketInspectionDescriptor alloc] initWithPacketIdentifier:identifier
                                                                         packetNumber:identifier
                                                                             rawBytes:rawBytes
                                                                          detailNodes:BuildPacketDetailNodes(packet, rawPacket, identifier, interfaceName, packetComment)
                                                                         decodeStatus:decodeDescriptor];
    } catch (const std::exception &exception) {
        auto *decodeDescriptor = [[PCPPNativeDecodeStatusDescriptor alloc] initWithKind:PCPPNativeDecodeStatusKindMalformed
                                                                                  reason:MakeNSString(exception.what())];
        return [[PCPPNativePacketInspectionDescriptor alloc] initWithPacketIdentifier:identifier
                                                                         packetNumber:identifier
                                                                             rawBytes:rawBytes
                                                                          detailNodes:@[
                                                                              MakeLayerNode(@"frame",
                                                                                            @"Frame",
                                                                                            [NSString stringWithFormat:@"Packet %llu: %d bytes on wire (%d captured)",
                                                                                                                       identifier,
                                                                                                                       rawPacket.getFrameLength(),
                                                                                                                       rawPacket.getRawDataLen()],
                                                                                            0,
                                                                                            rawPacket.getRawDataLen(),
                                                                                            @[]),
                                                                              MakeWarningNode(@"warning.decode", MakeNSString(exception.what())),
                                                                          ]
                                                                         decodeStatus:decodeDescriptor];
    }
}

struct StoredPacket {
    std::unique_ptr<pcpp::RawPacket> rawPacket;
    std::string packetComment;
};

struct OfflineDocumentSaveSnapshot {
    NSURL *currentURL = nil;
    std::vector<StoredPacket> packets;
    std::string format;
    std::string operatingSystem;
    std::string hardware;
    std::string captureApplication;
    std::string fileComment;
};

struct LivePacketDiskRecord {
    unsigned long long identifier = 0;
    uint64_t offset = 0;
    int capturedLength = 0;
    int originalLength = 0;
    timespec timestamp{};
    pcpp::LinkLayerType linkLayerType = pcpp::LINKTYPE_ETHERNET;
};

NSError *MakeFileError(TCPViewerNativeErrorCode code, const std::string &message)
{
    return MakeError(code, MakeNSString(message));
}

pcpp::LinkLayerType LinkLayerTypeFromInteger(NSInteger linkLayerType)
{
    if (pcpp::RawPacket::isLinkTypeValid(static_cast<int>(linkLayerType))) {
        return static_cast<pcpp::LinkLayerType>(linkLayerType);
    }

    return pcpp::LINKTYPE_ETHERNET;
}

class LivePacketDiskStore {
public:
    LivePacketDiskStore()
        : filePath_(makeTemporaryFilePath()) {}

    ~LivePacketDiskStore()
    {
        clear();
    }

    void append(const pcpp::RawPacket &packet, unsigned long long identifier)
    {
        ensureFileOpen();

        const auto offset = currentOffset();
        const int capturedLength = packet.getRawDataLen();
        if (capturedLength > 0) {
            const auto bytesWritten = ::fwrite(packet.getRawData(), 1, static_cast<size_t>(capturedLength), file_);
            if (bytesWritten != static_cast<size_t>(capturedLength)) {
                throw std::runtime_error("Failed to write packet bytes into the live capture backing store.");
            }
        }

        index_.push_back({
            identifier,
            offset,
            capturedLength,
            packet.getFrameLength(),
            packet.getPacketTimeStamp(),
            packet.getLinkLayerType(),
        });
    }

    std::unique_ptr<pcpp::RawPacket> packet(unsigned long long identifier)
    {
        const auto *record = recordForIdentifier(identifier);
        if (record == nullptr) {
            throw std::out_of_range("TCP Viewer could not find that packet in the live capture backing store.");
        }

        flushPendingWrites();
        if (::fseeko(file_, static_cast<off_t>(record->offset), SEEK_SET) != 0) {
            throw std::runtime_error("Failed to seek to packet bytes in the live capture backing store.");
        }

        auto bytes = std::make_unique<uint8_t[]>(static_cast<size_t>(record->capturedLength));
        if (record->capturedLength > 0) {
            const auto bytesRead = ::fread(bytes.get(), 1, static_cast<size_t>(record->capturedLength), file_);
            if (bytesRead != static_cast<size_t>(record->capturedLength)) {
                throw std::runtime_error("Failed to read packet bytes from the live capture backing store.");
            }
        }

        auto packet = std::make_unique<pcpp::RawPacket>();
        if (!packet->setRawData(bytes.get(),
                                record->capturedLength,
                                record->timestamp,
                                record->linkLayerType,
                                record->originalLength)) {
            throw std::runtime_error("Failed to rebuild a packet from the live capture backing store.");
        }

        bytes.release();
        return packet;
    }

    uint64_t offset(unsigned long long identifier) const
    {
        const auto *record = recordForIdentifier(identifier);
        if (record == nullptr) {
            throw std::out_of_range("TCP Viewer could not find that packet in the live capture backing store.");
        }

        return record->offset;
    }

    size_t count() const
    {
        return index_.size();
    }

    uint64_t fileSize()
    {
        flushPendingWrites();
        if (!std::filesystem::exists(filePath_)) {
            return 0;
        }

        return static_cast<uint64_t>(std::filesystem::file_size(filePath_));
    }

    const std::filesystem::path &filePath() const
    {
        return filePath_;
    }

    bool fileExists() const
    {
        return std::filesystem::exists(filePath_);
    }

    void clear()
    {
        if (file_ != nullptr) {
            ::fclose(file_);
            file_ = nullptr;
        }

        std::error_code error;
        std::filesystem::remove(filePath_, error);
        index_.clear();
    }

private:
    static std::filesystem::path makeTemporaryFilePath()
    {
        NSString *fileName = [NSString stringWithFormat:@"TCPViewerLiveCapture-%@.pktstore", NSUUID.UUID.UUIDString];
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:fileName];
        return std::filesystem::path(MakeStdString(path));
    }

    void ensureFileOpen()
    {
        if (file_ != nullptr) {
            return;
        }

        file_ = ::fopen(filePath_.string().c_str(), "w+b");
        if (file_ == nullptr) {
            throw std::runtime_error("Failed to open the live capture backing store.");
        }

        NSLog(@"[TCPViewer] 🗂️ Live capture temp packet store created: %@", MakeNSString(filePath_.string()));
    }

    uint64_t currentOffset()
    {
        const off_t offset = ::ftello(file_);
        if (offset < 0) {
            throw std::runtime_error("Failed to determine the live capture backing store offset.");
        }

        return static_cast<uint64_t>(offset);
    }

    void flushPendingWrites()
    {
        if (file_ != nullptr && ::fflush(file_) != 0) {
            throw std::runtime_error("Failed to flush the live capture backing store.");
        }
    }

    const LivePacketDiskRecord *recordForIdentifier(unsigned long long identifier) const
    {
        if (identifier == 0 || identifier > index_.size()) {
            return nullptr;
        }

        const auto &record = index_[static_cast<size_t>(identifier - 1)];
        return record.identifier == identifier ? &record : nullptr;
    }

    std::filesystem::path filePath_;
    FILE *file_ = nullptr;
    std::vector<LivePacketDiskRecord> index_;
};

bool AppendLivePacket(OfflineDocumentSaveSnapshot &snapshot, LivePacketDiskStore &packetStore, unsigned long long identifier, NSError **error);
bool SavePacketsToURL(const OfflineDocumentSaveSnapshot &state,
                      NSURL *targetURL,
                      const std::string &format,
                      PCPPNativePacketExportProgressHandler progressHandler,
                      PCPPNativeCancellationHandler cancellationCheck,
                      NSError **error);
bool IsExportCancelled(PCPPNativeCancellationHandler cancellationCheck, NSError **error);

class CaptureFileWriter {
public:
    CaptureFileWriter(const std::string &mode,
                      const std::filesystem::path &directory,
                      const std::string &fileNameStem,
                      const std::string &fileFormat,
                      uint64_t maxFileSizeBytes,
                      NSUInteger ringFileCount)
        : mode_(mode),
          directory_(directory),
          fileNameStem_(fileNameStem),
          fileFormat_(fileFormat),
          maxFileSizeBytes_(maxFileSizeBytes),
          ringFileCount_(ringFileCount) {}

    void writePacket(const pcpp::RawPacket &packet, NSString *packetComment)
    {
        if (mode_ == "disabled") {
            return;
        }

        std::filesystem::create_directories(directory_);
        rotateIfNeeded(packet.getRawDataLen());
        ensureWriterOpen(packet.getLinkLayerType());

        if (fileFormat_ == "pcapng") {
            auto *writer = dynamic_cast<pcpp::PcapNgFileWriterDevice *>(writer_.get());
            if (writer == nullptr) {
                throw std::runtime_error("Packet writer is not configured for pcapng output.");
            }

            if (!writer->writePacket(packet, MakeStdString(packetComment))) {
                throw std::runtime_error("Failed to write packet into pcapng capture output.");
            }
        } else {
            if (!writer_->writePacket(packet)) {
                throw std::runtime_error("Failed to write packet into pcap capture output.");
            }
        }

        bytesWrittenToCurrentFile_ += static_cast<uint64_t>(packet.getRawDataLen());
    }

    void finish()
    {
        if (writer_ != nullptr) {
            writer_->close();
            writer_.reset();
        }
    }

private:
    void rotateIfNeeded(int incomingPacketSize)
    {
        if (mode_ == "single" || maxFileSizeBytes_ == 0) {
            return;
        }

        if (writer_ == nullptr) {
            return;
        }

        if (bytesWrittenToCurrentFile_ + static_cast<uint64_t>(incomingPacketSize) <= maxFileSizeBytes_) {
            return;
        }

        writer_->close();
        writer_.reset();
        bytesWrittenToCurrentFile_ = 0;

        if (mode_ == "rotating") {
            ++currentFileIndex_;
        } else if (mode_ == "ring") {
            currentFileIndex_ = (currentFileIndex_ + 1) % std::max<NSUInteger>(ringFileCount_, 1);
        }
    }

    void ensureWriterOpen(pcpp::LinkLayerType linkType)
    {
        if (writer_ != nullptr) {
            return;
        }

        const auto path = filePathForIndex(currentFileIndex_);
        if (fileFormat_ == "pcapng") {
            auto writer = std::make_unique<pcpp::PcapNgFileWriterDevice>(path.string());
            if (!writer->open("macOS", "", "TCP Viewer", "TCP Viewer live capture")) {
                throw std::runtime_error("Failed to open a pcapng writer for live capture output.");
            }
            writer_ = std::move(writer);
        } else {
            auto writer = std::make_unique<pcpp::PcapFileWriterDevice>(path.string(), linkType);
            if (!writer->open()) {
                throw std::runtime_error("Failed to open a pcap writer for live capture output.");
            }
            writer_ = std::move(writer);
        }
    }

    std::filesystem::path filePathForIndex(NSUInteger index) const
    {
        if (mode_ == "single") {
            return directory_ / (fileNameStem_ + "." + fileFormat_);
        }

        char suffix[16] = {0};
        std::snprintf(suffix, sizeof(suffix), "-%06u", static_cast<unsigned int>(index));
        return directory_ / (fileNameStem_ + suffix + "." + fileFormat_);
    }

    std::string mode_;
    std::filesystem::path directory_;
    std::string fileNameStem_;
    std::string fileFormat_;
    uint64_t maxFileSizeBytes_;
    NSUInteger ringFileCount_;
    NSUInteger currentFileIndex_ = 0;
    uint64_t bytesWrittenToCurrentFile_ = 0;
    std::unique_ptr<pcpp::IFileWriterDevice> writer_;
};

class LiveCaptureState {
public:
    explicit LiveCaptureState(NSString *interfaceIdentifier, PCPPNativeCaptureOptionsDescriptor *options)
        : interfaceIdentifier_(interfaceIdentifier),
          options_(options),
          writer_(MakeStdString(options.fileWritingMode),
                  std::filesystem::path(MakeStdString(options.captureDirectoryURL.path ?: @"")),
                  MakeStdString(options.fileNameStem ?: @"capture"),
                  MakeStdString(options.fileFormat ?: @"pcapng"),
                  options.maxFileSizeBytes,
                  options.ringFileCount) {}

    pcpp::PcapLiveDevice *device = nullptr;
    NSString *interfaceIdentifier_ = nil;
    PCPPNativeCaptureOptionsDescriptor *options_ = nil;
    std::mutex mutex;
    unsigned long long nextPacketIdentifier = 1;
    unsigned long long packetsObserved = 0;
    unsigned long long packetsReceived = 0;
    unsigned long long packetsDropped = 0;
    unsigned long long packetsDroppedByInterface = 0;
    LivePacketDiskStore packetStore;
    NSString *statusMessage = @"Live capture is ready.";
    PCPPNativeLiveSessionPhase phase = PCPPNativeLiveSessionPhaseReady;
    CaptureFileWriter writer_;
    std::unique_ptr<SniReassemblyState> sniReassembly = std::make_unique<SniReassemblyState>();
};

void UpdateStats(LiveCaptureState &state)
{
    pcpp::IPcapDevice::PcapStats stats{};
    if (state.device != nullptr && state.device->isOpened()) {
        state.device->getStatistics(stats);
        state.packetsReceived = stats.packetsRecv;
        state.packetsDropped = stats.packetsDrop;
        state.packetsDroppedByInterface = stats.packetsDropByInterface;
    }
}

PCPPNativeCaptureHealthDescriptor *MakeHealthDescriptor(const LiveCaptureState &state)
{
    return [[PCPPNativeCaptureHealthDescriptor alloc] initWithPacketsReceived:state.packetsReceived
                                                               packetsDropped:state.packetsDropped
                                                    packetsDroppedByInterface:state.packetsDroppedByInterface
                                                              packetsObserved:state.packetsObserved
                                                                  lastUpdated:[NSDate date]
                                                                statusMessage:state.statusMessage];
}

}  // namespace

@implementation PCPPNativeAddressDescriptor

- (instancetype)initWithFamily:(PCPPNativeAddressFamily)family value:(NSString *)value
{
    self = [super init];
    if (self) {
        _family = family;
        _value = [value copy];
    }
    return self;
}

@end

@implementation PCPPNativeActivityPreviewDescriptor

- (instancetype)initWithPacketsPerSecond:(NSNumber *)packetsPerSecond observedAt:(NSDate *)observedAt
{
    self = [super init];
    if (self) {
        _packetsPerSecond = packetsPerSecond;
        _observedAt = observedAt;
    }
    return self;
}

@end

@implementation PCPPNativeInterfaceDescriptor

- (instancetype)initWithIdentifier:(NSString *)identifier
                     technicalName:(NSString *)technicalName
                       displayName:(NSString *)displayName
                      friendlyName:(NSString *)friendlyName
              interfaceDescription:(NSString *)interfaceDescription
                           loopback:(BOOL)loopback
                       availability:(PCPPNativeInterfaceAvailability)availability
                 availabilityReason:(NSString *)availabilityReason
                           linkType:(PCPPNativeLinkType)linkType
                          addresses:(NSArray<PCPPNativeAddressDescriptor *> *)addresses
                    activityPreview:(PCPPNativeActivityPreviewDescriptor *)activityPreview
                         canCapture:(BOOL)canCapture
             supportsPromiscuousMode:(BOOL)supportsPromiscuousMode
          requiresBPFPermissionSetup:(BOOL)requiresBPFPermissionSetup
                 providesMacOSMetadata:(BOOL)providesMacOSMetadata
{
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _technicalName = [technicalName copy];
        _displayName = [displayName copy];
        _friendlyName = [friendlyName copy];
        _interfaceDescription = [interfaceDescription copy];
        _availabilityReason = [availabilityReason copy];
        _loopback = loopback;
        _availability = availability;
        _linkType = linkType;
        _addresses = [addresses copy];
        _activityPreview = activityPreview;
        _canCapture = canCapture;
        _supportsPromiscuousMode = supportsPromiscuousMode;
        _requiresBPFPermissionSetup = requiresBPFPermissionSetup;
        _providesMacOSMetadata = providesMacOSMetadata;
    }
    return self;
}

@end

@implementation PCPPNativePacketEndpointDescriptor

- (instancetype)initWithAddress:(NSString *)address port:(NSNumber *)port
{
    self = [super init];
    if (self) {
        _address = [address copy];
        _port = port;
    }
    return self;
}

@end

@implementation PCPPNativePacketLayerDescriptor

- (instancetype)initWithName:(NSString *)name detailSummary:(NSString *)detailSummary
{
    self = [super init];
    if (self) {
        _name = [name copy];
        _detailSummary = [detailSummary copy];
    }
    return self;
}

@end

@implementation PCPPNativePacketCaptureMetadataDescriptor

- (instancetype)initWithLinkType:(PCPPNativeLinkType)linkType
                       truncated:(BOOL)truncated
                   packetComment:(NSString *)packetComment
                   interfaceName:(NSString *)interfaceName
{
    self = [super init];
    if (self) {
        _linkType = linkType;
        _truncated = truncated;
        _packetComment = [packetComment copy];
        _interfaceName = [interfaceName copy];
    }
    return self;
}

@end

@implementation PCPPNativeDecodeStatusDescriptor

- (instancetype)initWithKind:(PCPPNativeDecodeStatusKind)kind reason:(NSString *)reason
{
    self = [super init];
    if (self) {
        _kind = kind;
        _reason = [reason copy];
    }
    return self;
}

@end

@implementation PCPPNativePacketSummaryDescriptor

- (instancetype)initWithIdentifier:(unsigned long long)identifier
                       packetNumber:(unsigned long long)packetNumber
                          timestamp:(NSDate *)timestamp
                interfaceIdentifier:(NSString *)interfaceIdentifier
                      transportHint:(PCPPNativeTransportHint)transportHint
                     sourceEndpoint:(PCPPNativePacketEndpointDescriptor *)sourceEndpoint
                destinationEndpoint:(PCPPNativePacketEndpointDescriptor *)destinationEndpoint
                     originalLength:(NSInteger)originalLength
                     capturedLength:(NSInteger)capturedLength
                   streamIdentifier:(NSNumber *)streamIdentifier
                           tcpFlags:(NSString *)tcpFlags
                    tcpPayloadLength:(NSNumber *)tcpPayloadLength
                        infoSummary:(NSString *)infoSummary
                             layers:(NSArray<PCPPNativePacketLayerDescriptor *> *)layers
                       decodeStatus:(PCPPNativeDecodeStatusDescriptor *)decodeStatus
                    captureMetadata:(PCPPNativePacketCaptureMetadataDescriptor *)captureMetadata
                       sniDomainName:(NSString *)sniDomainName
{
    self = [super init];
    if (self) {
        _identifier = identifier;
        _packetNumber = packetNumber;
        _timestamp = timestamp;
        _interfaceIdentifier = [interfaceIdentifier copy];
        _transportHint = transportHint;
        _sourceEndpoint = sourceEndpoint;
        _destinationEndpoint = destinationEndpoint;
        _originalLength = originalLength;
        _capturedLength = capturedLength;
        _streamIdentifier = streamIdentifier;
        _tcpFlags = [tcpFlags copy];
        _tcpPayloadLength = tcpPayloadLength;
        _infoSummary = [infoSummary copy];
        _layers = [layers copy];
        _decodeStatus = decodeStatus;
        _captureMetadata = captureMetadata;
        _sniDomainName = [sniDomainName copy];
    }
    return self;
}

@end

@implementation PCPPNativeCaptureHealthDescriptor

- (instancetype)initWithPacketsReceived:(unsigned long long)packetsReceived
                         packetsDropped:(unsigned long long)packetsDropped
              packetsDroppedByInterface:(unsigned long long)packetsDroppedByInterface
                        packetsObserved:(unsigned long long)packetsObserved
                            lastUpdated:(NSDate *)lastUpdated
                          statusMessage:(NSString *)statusMessage
{
    self = [super init];
    if (self) {
        _packetsReceived = packetsReceived;
        _packetsDropped = packetsDropped;
        _packetsDroppedByInterface = packetsDroppedByInterface;
        _packetsObserved = packetsObserved;
        _lastUpdated = lastUpdated;
        _statusMessage = [statusMessage copy];
    }
    return self;
}

@end

@implementation PCPPNativeCaptureDocumentMetadataDescriptor

- (instancetype)initWithFormat:(NSString *)format
                operatingSystem:(NSString *)operatingSystem
                       hardware:(NSString *)hardware
             captureApplication:(NSString *)captureApplication
                    fileComment:(NSString *)fileComment
{
    self = [super init];
    if (self) {
        _format = [format copy];
        _operatingSystem = [operatingSystem copy];
        _hardware = [hardware copy];
        _captureApplication = [captureApplication copy];
        _fileComment = [fileComment copy];
    }
    return self;
}

@end

@implementation PCPPNativeFilterValidationDescriptor

- (instancetype)initWithDisposition:(NSString *)disposition
               normalizedExpression:(NSString *)normalizedExpression
                            message:(NSString *)message
{
    self = [super init];
    if (self) {
        _disposition = [disposition copy];
        _normalizedExpression = [normalizedExpression copy];
        _message = [message copy];
    }
    return self;
}

@end

@implementation PCPPNativeCaptureOptionsDescriptor

- (instancetype)initWithPromiscuousMode:(BOOL)promiscuousMode
                         snapshotLength:(NSInteger)snapshotLength
                  kernelBufferSizeBytes:(NSInteger)kernelBufferSizeBytes
                readTimeoutMilliseconds:(NSInteger)readTimeoutMilliseconds
                captureFilterExpression:(NSString *)captureFilterExpression
                               stopMode:(NSString *)stopMode
                              stopValue:(unsigned long long)stopValue
                        fileWritingMode:(NSString *)fileWritingMode
                    captureDirectoryURL:(NSURL *)captureDirectoryURL
                           fileNameStem:(NSString *)fileNameStem
                             fileFormat:(NSString *)fileFormat
                       maxFileSizeBytes:(unsigned long long)maxFileSizeBytes
                          ringFileCount:(NSUInteger)ringFileCount
{
    self = [super init];
    if (self) {
        _promiscuousMode = promiscuousMode;
        _snapshotLength = snapshotLength;
        _kernelBufferSizeBytes = kernelBufferSizeBytes;
        _readTimeoutMilliseconds = readTimeoutMilliseconds;
        _captureFilterExpression = [captureFilterExpression copy];
        _stopMode = [stopMode copy];
        _stopValue = stopValue;
        _fileWritingMode = [fileWritingMode copy];
        _captureDirectoryURL = captureDirectoryURL;
        _fileNameStem = [fileNameStem copy];
        _fileFormat = [fileFormat copy];
        _maxFileSizeBytes = maxFileSizeBytes;
        _ringFileCount = ringFileCount;
    }
    return self;
}

@end

@implementation PCPPNativePacketByteRangeDescriptor

- (instancetype)initWithOffset:(NSInteger)offset length:(NSInteger)length
{
    return [self initWithOffset:offset
                         length:length
                      bitOffset:0
                      bitLength:0
                    hasBitRange:NO];
}

- (instancetype)initWithOffset:(NSInteger)offset
                        length:(NSInteger)length
                     bitOffset:(NSInteger)bitOffset
                     bitLength:(NSInteger)bitLength
                   hasBitRange:(BOOL)hasBitRange
{
    self = [super init];
    if (self) {
        _offset = offset;
        _length = length;
        _bitOffset = bitOffset;
        _bitLength = bitLength;
        _hasBitRange = hasBitRange;
    }
    return self;
}

@end

@implementation PCPPNativePacketDetailNodeDescriptor

- (instancetype)initWithIdentifier:(NSString *)identifier
                              name:(NSString *)name
                         fieldName:(NSString *)fieldName
                             value:(NSString *)value
                          rawValue:(NSString *)rawValue
                              kind:(NSString *)kind
                          severity:(NSString *)severity
                         byteRange:(PCPPNativePacketByteRangeDescriptor *)byteRange
          jumpTargetPacketIdentifier:(NSNumber *)jumpTargetPacketIdentifier
                           children:(NSArray<PCPPNativePacketDetailNodeDescriptor *> *)children
{
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _name = [name copy];
        _fieldName = [fieldName copy];
        _value = [value copy];
        _rawValue = [rawValue copy];
        _kind = [kind copy];
        _severity = [severity copy];
        _byteRange = byteRange;
        _jumpTargetPacketIdentifier = jumpTargetPacketIdentifier;
        _children = [children copy];
    }
    return self;
}

@end

@implementation PCPPNativePacketInspectionDescriptor

- (instancetype)initWithPacketIdentifier:(unsigned long long)packetIdentifier
                            packetNumber:(unsigned long long)packetNumber
                                rawBytes:(NSData *)rawBytes
                             detailNodes:(NSArray<PCPPNativePacketDetailNodeDescriptor *> *)detailNodes
                            decodeStatus:(PCPPNativeDecodeStatusDescriptor *)decodeStatus
{
    self = [super init];
    if (self) {
        _packetIdentifier = packetIdentifier;
        _packetNumber = packetNumber;
        _rawBytes = [rawBytes copy];
        _detailNodes = [detailNodes copy];
        _decodeStatus = decodeStatus;
    }
    return self;
}

@end

@implementation PCPPNativePacketLoadProgressDescriptor

- (instancetype)initWithPhase:(NSString *)phase
            loadedPacketCount:(unsigned long long)loadedPacketCount
               processedBytes:(NSNumber *)processedBytes
                   totalBytes:(NSNumber *)totalBytes
                partialResult:(BOOL)partialResult
                      message:(NSString *)message
{
    self = [super init];
    if (self) {
        _phase = [phase copy];
        _loadedPacketCount = loadedPacketCount;
        _processedBytes = processedBytes;
        _totalBytes = totalBytes;
        _partialResult = partialResult;
        _message = [message copy];
    }
    return self;
}

@end

@interface PCPPNativeLiveSession () {
@private
    std::unique_ptr<LiveCaptureState> _state;
}

@end

@implementation PCPPNativeLiveSession

static void OnLivePacketArrives(pcpp::RawPacket *rawPacket, pcpp::PcapLiveDevice *, void *userCookie)
{
    @autoreleasepool {
        auto *session = (__bridge PCPPNativeLiveSession *)userCookie;
        std::lock_guard<std::mutex> lock(session->_state->mutex);

        try {
            const unsigned long long packetIdentifier = session->_state->nextPacketIdentifier;
            session->_state->packetsObserved += 1;

            auto *summary = MakePacketSummary(*rawPacket,
                                              packetIdentifier,
                                              session->_state->interfaceIdentifier_,
                                              session->_state->device == nullptr ? nil : MakeNSString(session->_state->device->getName()),
                                              nil,
                                              session->_state->sniReassembly.get());
            session->_state->packetStore.append(*rawPacket, packetIdentifier);
            session->_state->nextPacketIdentifier += 1;

            try {
                session->_state->writer_.writePacket(*rawPacket, nil);
            } catch (const std::exception &exception) {
                if (session.errorHandler != nil) {
                    session.errorHandler(MakeError(TCPViewerNativeErrorCodeFileWriteFailed, MakeNSString(exception.what())));
                }
            }

            session->_state->statusMessage = @"Capturing live packets.";
            if (session.packetHandler != nil) {
                session.packetHandler(@[summary]);
            }
        } catch (const std::exception &exception) {
            if (session.errorHandler != nil) {
                session.errorHandler(MakeError(TCPViewerNativeErrorCodeFileWriteFailed, MakeNSString(exception.what())));
            }
        }
    }
}

static void OnLiveStatsUpdate(pcpp::IPcapDevice::PcapStats &stats, void *userCookie)
{
    auto *session = (__bridge PCPPNativeLiveSession *)userCookie;
    std::lock_guard<std::mutex> lock(session->_state->mutex);
    session->_state->packetsReceived = stats.packetsRecv;
    session->_state->packetsDropped = stats.packetsDrop;
    session->_state->packetsDroppedByInterface = stats.packetsDropByInterface;

    if (session.healthHandler != nil) {
        session.healthHandler(MakeHealthDescriptor(*session->_state));
    }
}

- (instancetype)initWithInterfaceIdentifier:(NSString *)interfaceIdentifier
                                    options:(PCPPNativeCaptureOptionsDescriptor *)options
                                      error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }

    _state = std::make_unique<LiveCaptureState>(interfaceIdentifier, options);

    try {
        auto &list = pcpp::PcapLiveDeviceList::getInstance();
        _state->device = list.getDeviceByName(MakeStdString(interfaceIdentifier));
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeUnsupportedInterface, MakeNSString(exception.what()));
        }
        return nil;
    }

    if (_state->device == nullptr) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeUnsupportedInterface, @"The selected capture interface could not be found.");
        }
        return nil;
    }

    return self;
}

- (PCPPNativeCaptureHealthDescriptor *)healthSnapshot
{
    std::lock_guard<std::mutex> lock(_state->mutex);
    return MakeHealthDescriptor(*_state);
}

- (BOOL)startAndReturnError:(NSError **)error
{
    std::lock_guard<std::mutex> lock(_state->mutex);

    try {
        if (_state->device == nullptr) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeUnsupportedInterface, @"No native device is associated with this session.");
            }
            return NO;
        }

        if (_state->device->captureActive()) {
            return YES;
        }

        if (_state->phase == PCPPNativeLiveSessionPhaseStopped) {
            _state->packetStore.clear();
            _state->packetsObserved = 0;
            _state->packetsReceived = 0;
            _state->packetsDropped = 0;
            _state->packetsDroppedByInterface = 0;
            _state->nextPacketIdentifier = 1;
            _state->sniReassembly = std::make_unique<SniReassemblyState>();
        }

        pcpp::PcapLiveDevice::DeviceMode deviceMode = _state->options_.promiscuousMode ? pcpp::PcapLiveDevice::Promiscuous : pcpp::PcapLiveDevice::Normal;
        pcpp::PcapLiveDevice::DeviceConfiguration configuration(deviceMode,
                                                                static_cast<int>(_state->options_.readTimeoutMilliseconds),
                                                                static_cast<int>(_state->options_.kernelBufferSizeBytes),
                                                                pcpp::PcapLiveDevice::PCPP_INOUT,
                                                                static_cast<int>(_state->options_.snapshotLength));
        _state->phase = PCPPNativeLiveSessionPhaseStarting;
        _state->statusMessage = @"Starting live capture.";
        if (self.phaseHandler != nil) {
            self.phaseHandler(_state->phase, _state->statusMessage);
        }

        if (!_state->device->isOpened() && !_state->device->open(configuration)) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeOpenFailed, @"TCP Viewer could not open the selected interface for capture.");
            }
            _state->phase = PCPPNativeLiveSessionPhaseFailed;
            _state->statusMessage = @"Failed to open the live capture interface.";
            return NO;
        }

        std::string captureFilter = MakeStdString(_state->options_.captureFilterExpression);
        if (!captureFilter.empty() && !_state->device->setFilter(captureFilter)) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeInvalidFilter, @"TCP Viewer could not apply this capture filter to the selected interface.");
            }
            if (_state->device->isOpened()) {
                _state->device->close();
            }
            _state->phase = PCPPNativeLiveSessionPhaseFailed;
            _state->statusMessage = @"Failed to apply the live capture filter.";
            return NO;
        }

        if (!_state->device->startCapture(OnLivePacketArrives, (__bridge void *)self, 1, OnLiveStatsUpdate, (__bridge void *)self)) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeCaptureStartFailed, @"TCP Viewer could not start packet capture on the selected interface.");
            }
            _state->phase = PCPPNativeLiveSessionPhaseFailed;
            _state->statusMessage = @"Failed to start live capture.";
            return NO;
        }

        _state->phase = PCPPNativeLiveSessionPhaseRunning;
        _state->statusMessage = @"Live capture is running.";
        if (self.phaseHandler != nil) {
            self.phaseHandler(_state->phase, _state->statusMessage);
        }
        return YES;
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeCaptureStartFailed, MakeNSString(exception.what()));
        }
        _state->phase = PCPPNativeLiveSessionPhaseFailed;
        _state->statusMessage = @"Failed to start live capture.";
        return NO;
    }
}

- (BOOL)pauseAndReturnError:(NSError **)error
{
    pcpp::PcapLiveDevice *device = nullptr;

    {
        std::lock_guard<std::mutex> lock(_state->mutex);

        if (_state->device == nullptr || !_state->device->captureActive()) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeCapturePauseFailed, @"Live capture is not currently running.");
            }
            return NO;
        }

        device = _state->device;
    }

    device->stopCapture();

    NSString *statusMessage = nil;
    PCPPNativeLiveSessionPhase phase = PCPPNativeLiveSessionPhasePaused;
    PCPPNativeCaptureHealthDescriptor *health = nil;
    {
        std::lock_guard<std::mutex> lock(_state->mutex);
        UpdateStats(*_state);
        _state->phase = PCPPNativeLiveSessionPhasePaused;
        _state->statusMessage = @"Live capture is paused.";
        phase = _state->phase;
        statusMessage = _state->statusMessage;
        health = MakeHealthDescriptor(*_state);
    }

    if (self.phaseHandler != nil) {
        self.phaseHandler(phase, statusMessage);
    }
    if (self.healthHandler != nil) {
        self.healthHandler(health);
    }
    return YES;
}

- (BOOL)resumeAndReturnError:(NSError **)error
{
    std::lock_guard<std::mutex> lock(_state->mutex);

    if (_state->device == nullptr || _state->phase != PCPPNativeLiveSessionPhasePaused) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeCaptureResumeFailed, @"Live capture must be paused before it can resume.");
        }
        return NO;
    }

    if (!_state->device->startCapture(OnLivePacketArrives, (__bridge void *)self, 1, OnLiveStatsUpdate, (__bridge void *)self)) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeCaptureResumeFailed, @"TCP Viewer could not resume live capture on the selected interface.");
        }
        _state->phase = PCPPNativeLiveSessionPhaseFailed;
        _state->statusMessage = @"Failed to resume live capture.";
        return NO;
    }

    _state->phase = PCPPNativeLiveSessionPhaseRunning;
    _state->statusMessage = @"Live capture resumed.";
    if (self.phaseHandler != nil) {
        self.phaseHandler(_state->phase, _state->statusMessage);
    }
    return YES;
}

- (BOOL)stopAndReturnError:(NSError **)error
{
    pcpp::PcapLiveDevice *device = nullptr;
    bool shouldStopCapture = false;

    try {
        {
            std::lock_guard<std::mutex> lock(_state->mutex);
            if (_state->device == nullptr) {
                return YES;
            }

            device = _state->device;
            shouldStopCapture = _state->device->captureActive();
        }

        if (shouldStopCapture) {
            device->stopCapture();
        }

        NSString *statusMessage = nil;
        PCPPNativeLiveSessionPhase phase = PCPPNativeLiveSessionPhaseStopped;
        PCPPNativeCaptureHealthDescriptor *health = nil;
        {
            std::lock_guard<std::mutex> lock(_state->mutex);
            UpdateStats(*_state);
            _state->writer_.finish();
            if (_state->device->isOpened()) {
                _state->device->close();
            }

            _state->phase = PCPPNativeLiveSessionPhaseStopped;
            _state->statusMessage = @"Live capture stopped.";
            phase = _state->phase;
            statusMessage = _state->statusMessage;
            health = MakeHealthDescriptor(*_state);
        }

        if (self.phaseHandler != nil) {
            self.phaseHandler(phase, statusMessage);
        }
        if (self.healthHandler != nil) {
            self.healthHandler(health);
        }
        return YES;
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeCaptureStopFailed, MakeNSString(exception.what()));
        }
        return NO;
    }
}

- (PCPPNativePacketInspectionDescriptor *)inspectPacketWithIdentifier:(unsigned long long)identifier error:(NSError **)error
{
    std::unique_ptr<pcpp::RawPacket> rawPacket;
    NSString *interfaceName = nil;

    {
        std::lock_guard<std::mutex> lock(_state->mutex);
        try {
            rawPacket = _state->packetStore.packet(identifier);
            if (_state->device != nullptr) {
                interfaceName = MakeNSString(_state->device->getName());
            }
        } catch (const std::exception &exception) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeFileReadFailed, MakeNSString(exception.what()));
            }
            return nil;
        }
    }

    return MakePacketInspection(*rawPacket, identifier, interfaceName, nil);
}

- (BOOL)exportPacketsWithIdentifiers:(NSArray<NSNumber *> *)identifiers
                                toURL:(NSURL *)url
                               format:(NSString *)format
                      progressHandler:(PCPPNativePacketExportProgressHandler)progressHandler
                    cancellationCheck:(PCPPNativeCancellationHandler)cancellationCheck
                                error:(NSError **)error
{
    OfflineDocumentSaveSnapshot snapshot;
    {
        std::lock_guard<std::mutex> lock(_state->mutex);
        if (identifiers.count == 0) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"There are no packets to export.");
            }
            return NO;
        }

        snapshot.operatingSystem = "macOS";
        snapshot.captureApplication = "TCP Viewer";
        snapshot.fileComment = "TCP Viewer live capture export";
        snapshot.packets.reserve(identifiers.count);

        for (NSNumber *boxedIdentifier in identifiers) {
            if (IsExportCancelled(cancellationCheck, error)) {
                return NO;
            }

            if (!AppendLivePacket(snapshot, _state->packetStore, boxedIdentifier.unsignedLongLongValue, error)) {
                return NO;
            }
        }
    }

    return SavePacketsToURL(snapshot, url, MakeStdString(format), progressHandler, cancellationCheck, error);
}

- (void)dealloc
{
    NSError *error = nil;
    [self stopAndReturnError:&error];
}

@end

#if DEBUG

@interface PCPPNativeLivePacketStoreTestProbe () {
@private
    std::unique_ptr<LivePacketDiskStore> _store;
}

@end

@implementation PCPPNativeLivePacketStoreTestProbe

- (instancetype)init
{
    self = [super init];
    if (!self) {
        return nil;
    }

    _store = std::make_unique<LivePacketDiskStore>();

    return self;
}

- (NSUInteger)packetCount
{
    return _store == nullptr ? 0 : static_cast<NSUInteger>(_store->count());
}

- (unsigned long long)backingFileSize
{
    if (_store == nullptr) {
        return 0;
    }

    try {
        return _store->fileSize();
    } catch (const std::exception &) {
        return 0;
    }
}

- (BOOL)backingFileExists
{
    return _store != nullptr && _store->fileExists();
}

- (NSString *)backingFilePath
{
    if (_store == nullptr) {
        return @"";
    }

    return MakeNSString(_store->filePath().string());
}

- (BOOL)appendPacketWithIdentifier:(unsigned long long)identifier
                           rawBytes:(NSData *)rawBytes
                          timestamp:(NSDate *)timestamp
                      linkLayerType:(NSInteger)linkLayerType
                     originalLength:(NSInteger)originalLength
                              error:(NSError **)error
{
    if (_store == nullptr) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"The live packet backing store is not available.");
        }
        return NO;
    }

    timespec packetTimestamp{};
    NSTimeInterval seconds = timestamp.timeIntervalSince1970;
    packetTimestamp.tv_sec = static_cast<time_t>(seconds);
    packetTimestamp.tv_nsec = static_cast<long>((seconds - static_cast<NSTimeInterval>(packetTimestamp.tv_sec)) * 1'000'000'000.0);

    try {
        auto bytes = std::make_unique<uint8_t[]>(static_cast<size_t>(rawBytes.length));
        if (rawBytes.length > 0) {
            std::memcpy(bytes.get(), rawBytes.bytes, static_cast<size_t>(rawBytes.length));
        }

        pcpp::RawPacket packet;
        if (!packet.setRawData(bytes.get(),
                               static_cast<int>(rawBytes.length),
                               packetTimestamp,
                               LinkLayerTypeFromInteger(linkLayerType),
                               static_cast<int>(originalLength))) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"The test packet bytes could not be prepared.");
            }
            return NO;
        }

        bytes.release();
        _store->append(packet, identifier);
        return YES;
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MakeFileError(TCPViewerNativeErrorCodeFileWriteFailed, exception.what());
        }
        return NO;
    }
}

- (PCPPNativePacketInspectionDescriptor *)inspectPacketWithIdentifier:(unsigned long long)identifier error:(NSError **)error
{
    if (_store == nullptr) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeFileReadFailed, @"The live packet backing store is not available.");
        }
        return nil;
    }

    try {
        auto packet = _store->packet(identifier);
        return MakePacketInspection(*packet, identifier, nil, nil);
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MakeFileError(TCPViewerNativeErrorCodeFileReadFailed, exception.what());
        }
        return nil;
    }
}

- (NSNumber *)offsetForPacketWithIdentifier:(unsigned long long)identifier error:(NSError **)error
{
    if (_store == nullptr) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeFileReadFailed, @"The live packet backing store is not available.");
        }
        return nil;
    }

    try {
        return @(_store->offset(identifier));
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MakeFileError(TCPViewerNativeErrorCodeFileReadFailed, exception.what());
        }
        return nil;
    }
}

- (void)cleanup
{
    if (_store != nullptr) {
        _store->clear();
    }
}

@end

#endif

namespace {

struct OfflineDocumentState {
    explicit OfflineDocumentState(NSURL *fileURL) : currentURL(fileURL) {}

    mutable std::mutex mutex;
    NSURL *currentURL = nil;
    std::vector<StoredPacket> packets;
    std::string format;
    std::string operatingSystem;
    std::string hardware;
    std::string captureApplication;
    std::string fileComment;
    bool dirty = false;
    bool loading = false;
    bool partialResult = false;
};

std::string NormalizedCaptureFileFormat(const std::string &rawFormat)
{
    NSString *format = MakeNSString(rawFormat).lowercaseString;
    if ([format isEqualToString:@"pcap"] || [format isEqualToString:@"pcapng"]) {
        return MakeStdString(format);
    }

    return "pcapng";
}

std::string NormalizedFormatForURL(NSURL *url)
{
    NSString *extension = url.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"pcapng"]) {
        return "pcapng";
    }

    if ([extension isEqualToString:@"pcap"]) {
        return "pcap";
    }

    return "pcapng";
}

bool IsExportCancelled(PCPPNativeCancellationHandler cancellationCheck, NSError **error)
{
    if (cancellationCheck == nil || !cancellationCheck()) {
        return false;
    }

    if (error != nullptr) {
        *error = MakeError(TCPViewerNativeErrorCodeOperationCancelled, @"Packet export was cancelled.");
    }
    return true;
}

void EmitExportProgress(PCPPNativePacketExportProgressHandler progressHandler, NSUInteger exportedPacketCount, NSUInteger totalPacketCount)
{
    if (progressHandler != nil) {
        progressHandler(exportedPacketCount, totalPacketCount);
    }
}

PCPPNativeCaptureDocumentMetadataDescriptor *MakeMetadata(const OfflineDocumentState &state)
{
    const std::string format = state.format.empty() ? NormalizedFormatForURL(state.currentURL) : state.format;
    return [[PCPPNativeCaptureDocumentMetadataDescriptor alloc] initWithFormat:MakeNSString(format)
                                                               operatingSystem:NullableNSString(state.operatingSystem)
                                                                      hardware:NullableNSString(state.hardware)
                                                            captureApplication:NullableNSString(state.captureApplication)
                                                                    fileComment:NullableNSString(state.fileComment)];
}

PCPPNativePacketLoadProgressDescriptor *MakeLoadProgressDescriptor(NSString *phase,
                                                                   NSUInteger loadedPacketCount,
                                                                   std::optional<uint64_t> processedBytes,
                                                                   std::optional<uint64_t> totalBytes,
                                                                   bool partialResult,
                                                                   NSString *message)
{
    NSNumber *boxedProcessedBytes = processedBytes ? @(*processedBytes) : nil;
    NSNumber *boxedTotalBytes = totalBytes ? @(*totalBytes) : nil;
    return [[PCPPNativePacketLoadProgressDescriptor alloc] initWithPhase:phase
                                                       loadedPacketCount:loadedPacketCount
                                                          processedBytes:boxedProcessedBytes
                                                              totalBytes:boxedTotalBytes
                                                           partialResult:partialResult
                                                                 message:message];
}

std::optional<uint64_t> FileSizeForURL(NSURL *url)
{
    try {
        const std::filesystem::path path = MakeStdString(url.path);
        if (path.empty() || !std::filesystem::exists(path)) {
            return std::nullopt;
        }

        return static_cast<uint64_t>(std::filesystem::file_size(path));
    } catch (const std::exception &) {
        return std::nullopt;
    }
}

NSURL *TemporarySaveURL(NSURL *targetURL)
{
    NSURL *directoryURL = [targetURL URLByDeletingLastPathComponent];
    NSString *temporaryName = [NSString stringWithFormat:@".%@.%@.tmp",
                                                         targetURL.lastPathComponent,
                                                         NSUUID.UUID.UUIDString];
    return [directoryURL URLByAppendingPathComponent:temporaryName];
}

void RemoveTemporaryItem(NSURL *temporaryURL)
{
    if (temporaryURL == nil) {
        return;
    }

    [[NSFileManager defaultManager] removeItemAtURL:temporaryURL error:nil];
}

bool EnsureParentDirectoryExists(NSURL *targetURL, NSError **error)
{
    NSError *directoryError = nil;
    NSURL *directoryURL = [targetURL URLByDeletingLastPathComponent];
    if ([[NSFileManager defaultManager] createDirectoryAtURL:directoryURL
                                 withIntermediateDirectories:YES
                                                  attributes:nil
                                                       error:&directoryError]) {
        return true;
    }

    if (error != nullptr) {
        *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"TCP Viewer could not prepare the destination directory for saving.");
    }
    return false;
}

bool ReplaceSavedFile(NSURL *temporaryURL, NSURL *targetURL, NSError **error)
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSError *replaceError = nil;

    if ([fileManager fileExistsAtPath:targetURL.path]) {
        if (![fileManager replaceItemAtURL:targetURL
                             withItemAtURL:temporaryURL
                            backupItemName:nil
                                   options:0
                          resultingItemURL:nil
                                     error:&replaceError]) {
            RemoveTemporaryItem(temporaryURL);
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"TCP Viewer could not replace the destination capture file.");
            }
            return false;
        }

        return true;
    }

    if (![fileManager moveItemAtURL:temporaryURL toURL:targetURL error:&replaceError]) {
        RemoveTemporaryItem(temporaryURL);
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"TCP Viewer could not move the saved capture into place.");
        }
        return false;
    }

    return true;
}

OfflineDocumentSaveSnapshot MakeSaveSnapshotLocked(const OfflineDocumentState &state)
{
    OfflineDocumentSaveSnapshot snapshot;
    snapshot.currentURL = state.currentURL;
    snapshot.format = state.format;
    snapshot.operatingSystem = state.operatingSystem;
    snapshot.hardware = state.hardware;
    snapshot.captureApplication = state.captureApplication;
    snapshot.fileComment = state.fileComment;

    snapshot.packets.reserve(state.packets.size());
    for (const auto &packet : state.packets) {
        snapshot.packets.push_back({
            std::unique_ptr<pcpp::RawPacket>(packet.rawPacket == nullptr ? nullptr : packet.rawPacket->clone()),
            packet.packetComment,
        });
    }

    return snapshot;
}

bool AppendStoredPacket(OfflineDocumentSaveSnapshot &snapshot, const StoredPacket &packet, NSError **error)
{
    if (packet.rawPacket == nullptr) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"TCP Viewer could not export a missing packet.");
        }
        return false;
    }

    snapshot.packets.push_back({
        std::unique_ptr<pcpp::RawPacket>(packet.rawPacket->clone()),
        packet.packetComment,
    });
    return true;
}

bool AppendLivePacket(OfflineDocumentSaveSnapshot &snapshot, LivePacketDiskStore &packetStore, unsigned long long identifier, NSError **error)
{
    try {
        auto rawPacket = packetStore.packet(identifier);
        snapshot.packets.push_back({
            std::move(rawPacket),
            std::string(),
        });
        return true;
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, MakeNSString(exception.what()));
        }
        return false;
    }
}

bool PopulateOfflineExportSnapshotLocked(OfflineDocumentSaveSnapshot &snapshot,
                                         const OfflineDocumentState &state,
                                         NSArray<NSNumber *> *identifiers,
                                         PCPPNativeCancellationHandler cancellationCheck,
                                         NSError **error)
{
    if (identifiers.count == 0) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"There are no packets to export.");
        }
        return false;
    }

    snapshot.currentURL = state.currentURL;
    snapshot.format = state.format;
    snapshot.operatingSystem = state.operatingSystem;
    snapshot.hardware = state.hardware;
    snapshot.captureApplication = state.captureApplication;
    snapshot.fileComment = state.fileComment;
    snapshot.packets.reserve(identifiers.count);

    for (NSNumber *boxedIdentifier in identifiers) {
        if (IsExportCancelled(cancellationCheck, error)) {
            return false;
        }

        const unsigned long long identifier = boxedIdentifier.unsignedLongLongValue;
        if (identifier == 0 || identifier > state.packets.size()) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"TCP Viewer could not find a packet selected for export.");
            }
            return false;
        }

        if (!AppendStoredPacket(snapshot, state.packets[identifier - 1], error)) {
            return false;
        }
    }

    return true;
}

NSArray<PCPPNativePacketSummaryDescriptor *> *LoadPacketsFromURLIncrementally(OfflineDocumentState &state,
                                                                              NSUInteger batchSize,
                                                                              PCPPNativePacketBatchHandler batchHandler,
                                                                              PCPPNativeLoadProgressHandler progressHandler,
                                                                              PCPPNativeCancellationHandler cancellationCheck,
                                                                              NSError **error)
{
    NSURL *currentURL = nil;
    {
        std::lock_guard<std::mutex> lock(state.mutex);
        currentURL = state.currentURL;
        state.packets.clear();
        state.format = NormalizedFormatForURL(currentURL);
        state.operatingSystem.clear();
        state.hardware.clear();
        state.captureApplication.clear();
        state.fileComment.clear();
        state.dirty = false;
        state.loading = true;
        state.partialResult = false;
    }

    if (currentURL == nil) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeFileReadFailed, @"A capture URL is required.");
        }
        return nil;
    }

    NSString *fileName = currentURL.lastPathComponent ?: @"capture";
    std::optional<uint64_t> totalBytes = FileSizeForURL(currentURL);
    const NSUInteger effectiveBatchSize = std::max<NSUInteger>(batchSize, 1);

    auto emitProgress = [&](NSString *phase,
                            NSUInteger loadedPacketCount,
                            uint64_t processedBytes,
                            bool partialResult,
                            NSString *message) {
        if (progressHandler == nil) {
            return;
        }

        std::optional<uint64_t> normalizedProcessedBytes;
        if (totalBytes.has_value()) {
            normalizedProcessedBytes = std::min<uint64_t>(processedBytes, *totalBytes);
        } else {
            normalizedProcessedBytes = processedBytes;
        }

        progressHandler(MakeLoadProgressDescriptor(phase,
                                                   loadedPacketCount,
                                                   normalizedProcessedBytes,
                                                   totalBytes,
                                                   partialResult,
                                                   message));
    };

    emitProgress(@"loading",
                 0,
                 0,
                 false,
                 [NSString stringWithFormat:@"Loading %@…", fileName]);

    auto reader = std::unique_ptr<pcpp::IFileReaderDevice>(pcpp::IFileReaderDevice::getReader(MakeStdString(currentURL.path)));
    if (reader == nullptr) {
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            state.loading = false;
        }
        emitProgress(@"failed", 0, 0, false, [NSString stringWithFormat:@"TCP Viewer could not load %@.", fileName]);
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeFileReadFailed, @"TCP Viewer could not determine a file reader for this capture.");
        }
        return nil;
    }

    if (!reader->open()) {
        {
            std::lock_guard<std::mutex> lock(state.mutex);
            state.loading = false;
        }
        emitProgress(@"failed", 0, 0, false, [NSString stringWithFormat:@"TCP Viewer could not open %@.", fileName]);
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeFileReadFailed, @"TCP Viewer could not open the requested capture file.");
        }
        return nil;
    }

    if (auto *pcapngReader = dynamic_cast<pcpp::PcapNgFileReaderDevice *>(reader.get())) {
        std::lock_guard<std::mutex> lock(state.mutex);
        state.operatingSystem = pcapngReader->getOS();
        state.hardware = pcapngReader->getHardware();
        state.captureApplication = pcapngReader->getCaptureApplication();
        state.fileComment = pcapngReader->getCaptureFileComment();
    }

    NSMutableArray<PCPPNativePacketSummaryDescriptor *> *packets = [NSMutableArray array];
    NSMutableArray<PCPPNativePacketSummaryDescriptor *> *pendingBatch = [NSMutableArray array];
    unsigned long long identifier = 1;
    uint64_t processedBytes = 0;
    bool wasCancelled = false;
    NSError *caughtError = nil;
    SniReassemblyState sniReassembly;

    auto flushPendingBatch = [&]() {
        if (pendingBatch.count == 0) {
            return;
        }

        if (batchHandler != nil) {
            batchHandler([pendingBatch copy]);
        }
        [pendingBatch removeAllObjects];
    };

    try {
        while (true) {
            @autoreleasepool {
                if (cancellationCheck != nil && cancellationCheck()) {
                    wasCancelled = true;
                    break;
                }

                pcpp::RawPacket rawPacket;
                std::string packetComment;
                bool didReadPacket = false;

                if (auto *pcapngReader = dynamic_cast<pcpp::PcapNgFileReaderDevice *>(reader.get())) {
                    didReadPacket = pcapngReader->getNextPacket(rawPacket, packetComment);
                } else {
                    didReadPacket = reader->getNextPacket(rawPacket);
                }

                if (!didReadPacket) {
                    break;
                }

                auto *summary = MakePacketSummary(rawPacket,
                                                  identifier,
                                                  nil,
                                                  nil,
                                                  NullableNSString(packetComment),
                                                  &sniReassembly);
                {
                    std::lock_guard<std::mutex> lock(state.mutex);
                    state.packets.push_back({std::make_unique<pcpp::RawPacket>(rawPacket), packetComment});
                }

                [packets addObject:summary];
                [pendingBatch addObject:summary];
                processedBytes += static_cast<uint64_t>(rawPacket.getRawDataLen());
                identifier += 1;

                if (pendingBatch.count >= effectiveBatchSize) {
                    flushPendingBatch();
                    emitProgress(@"loading",
                                 packets.count,
                                 processedBytes,
                                 false,
                                 [NSString stringWithFormat:@"Loaded %lu packets from %@…", (unsigned long)packets.count, fileName]);
                }
            }
        }
    } catch (const std::exception &exception) {
        caughtError = MakeError(TCPViewerNativeErrorCodeFileReadFailed, MakeNSString(exception.what()));
    }

    flushPendingBatch();
    reader->close();

    {
        std::lock_guard<std::mutex> lock(state.mutex);
        state.loading = false;
        state.partialResult = wasCancelled || caughtError != nil;
        state.dirty = false;
    }

    if (caughtError != nil) {
        emitProgress(@"failed",
                     packets.count,
                     processedBytes,
                     packets.count > 0,
                     [NSString stringWithFormat:@"TCP Viewer could not finish loading %@.", fileName]);
        if (error != nullptr) {
            *error = caughtError;
        }
        return nil;
    }

    if (wasCancelled) {
        emitProgress(@"cancelled",
                     packets.count,
                     processedBytes,
                     true,
                     [NSString stringWithFormat:@"Loading cancelled after %lu packets from %@.", (unsigned long)packets.count, fileName]);
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeOperationCancelled,
                               [NSString stringWithFormat:@"Loading %@ was cancelled after %lu packets.", fileName, (unsigned long)packets.count]);
        }
        return nil;
    }

    emitProgress(@"completed",
                 packets.count,
                 totalBytes.value_or(processedBytes),
                 false,
                 [NSString stringWithFormat:@"Loaded %lu packets from %@.", (unsigned long)packets.count, fileName]);
    return packets;
}

bool SavePacketsToURL(const OfflineDocumentSaveSnapshot &state,
                      NSURL *targetURL,
                      const std::string &format,
                      PCPPNativePacketExportProgressHandler progressHandler,
                      PCPPNativeCancellationHandler cancellationCheck,
                      NSError **error)
{
    if (targetURL == nil) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"An export destination is required.");
        }
        return false;
    }

    if (state.packets.empty()) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"There are no packets loaded to save.");
        }
        return false;
    }

    if (!EnsureParentDirectoryExists(targetURL, error)) {
        return false;
    }

    const std::string normalizedFormat = NormalizedCaptureFileFormat(format);
    NSURL *temporaryURL = TemporarySaveURL(targetURL);
    RemoveTemporaryItem(temporaryURL);
    const NSUInteger totalPacketCount = state.packets.size();
    NSUInteger exportedPacketCount = 0;
    EmitExportProgress(progressHandler, exportedPacketCount, totalPacketCount);

    if (normalizedFormat == "pcapng") {
        pcpp::PcapNgFileWriterDevice writer(MakeStdString(temporaryURL.path));
        if (!writer.open(state.operatingSystem, state.hardware, state.captureApplication, state.fileComment)) {
            RemoveTemporaryItem(temporaryURL);
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"TCP Viewer could not open the pcapng destination for writing.");
            }
            return false;
        }

        for (const auto &packet : state.packets) {
            if (IsExportCancelled(cancellationCheck, error)) {
                writer.close();
                RemoveTemporaryItem(temporaryURL);
                return false;
            }

            if (packet.rawPacket == nullptr) {
                if (error != nullptr) {
                    *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"TCP Viewer could not export a missing packet.");
                }
                writer.close();
                RemoveTemporaryItem(temporaryURL);
                return false;
            }

            if (!writer.writePacket(*packet.rawPacket, packet.packetComment)) {
                if (error != nullptr) {
                    *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"TCP Viewer could not write all packets into the pcapng destination.");
                }
                writer.close();
                RemoveTemporaryItem(temporaryURL);
                return false;
            }

            exportedPacketCount += 1;
            EmitExportProgress(progressHandler, exportedPacketCount, totalPacketCount);
        }

        writer.close();
        return ReplaceSavedFile(temporaryURL, targetURL, error);
    }

    if (state.packets.front().rawPacket == nullptr) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"TCP Viewer could not export a missing packet.");
        }
        RemoveTemporaryItem(temporaryURL);
        return false;
    }

    const pcpp::LinkLayerType linkType = state.packets.front().rawPacket->getLinkLayerType();
    for (const auto &packet : state.packets) {
        if (IsExportCancelled(cancellationCheck, error)) {
            RemoveTemporaryItem(temporaryURL);
            return false;
        }

        if (packet.rawPacket == nullptr) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"TCP Viewer could not export a missing packet.");
            }
            RemoveTemporaryItem(temporaryURL);
            return false;
        }

        if (packet.rawPacket->getLinkLayerType() != linkType) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"PCAP export requires all packets to use the same link type. Try exporting as pcapng.");
            }
            RemoveTemporaryItem(temporaryURL);
            return false;
        }
    }

    pcpp::PcapFileWriterDevice writer(MakeStdString(temporaryURL.path), linkType);
    if (!writer.open()) {
        RemoveTemporaryItem(temporaryURL);
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"TCP Viewer could not open the pcap destination for writing.");
        }
        return false;
    }

    for (const auto &packet : state.packets) {
        if (IsExportCancelled(cancellationCheck, error)) {
            writer.close();
            RemoveTemporaryItem(temporaryURL);
            return false;
        }

        if (!writer.writePacket(*packet.rawPacket)) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"TCP Viewer could not write all packets into the pcap destination.");
            }
            writer.close();
            RemoveTemporaryItem(temporaryURL);
            return false;
        }

        exportedPacketCount += 1;
        EmitExportProgress(progressHandler, exportedPacketCount, totalPacketCount);
    }

    writer.close();
    return ReplaceSavedFile(temporaryURL, targetURL, error);
}

}  // namespace

@interface PCPPNativeOfflineDocument () {
@private
    std::unique_ptr<OfflineDocumentState> _state;
}

@end

@implementation PCPPNativeOfflineDocument

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error
{
    self = [super init];
    if (!self) {
        return nil;
    }

    if (url == nil) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeFileReadFailed, @"A capture URL is required.");
        }
        return nil;
    }

    _state = std::make_unique<OfflineDocumentState>(url);
    return self;
}

- (NSURL *)currentURL
{
    std::lock_guard<std::mutex> lock(_state->mutex);
    return _state->currentURL;
}

- (NSString *)currentFormat
{
    std::lock_guard<std::mutex> lock(_state->mutex);
    if (_state->format.empty()) {
        return MakeNSString(NormalizedFormatForURL(_state->currentURL));
    }

    return MakeNSString(_state->format);
}

- (PCPPNativeCaptureDocumentMetadataDescriptor *)documentMetadata
{
    std::lock_guard<std::mutex> lock(_state->mutex);
    return MakeMetadata(*_state);
}

- (BOOL)dirty
{
    std::lock_guard<std::mutex> lock(_state->mutex);
    return _state->dirty;
}

- (NSArray<PCPPNativePacketSummaryDescriptor *> *)openAndReturnError:(NSError **)error
{
    return LoadPacketsFromURLIncrementally(*_state, 256, nil, nil, nil, error);
}

- (NSArray<PCPPNativePacketSummaryDescriptor *> *)reopenAndReturnError:(NSError **)error
{
    return LoadPacketsFromURLIncrementally(*_state, 256, nil, nil, nil, error);
}

- (NSArray<PCPPNativePacketSummaryDescriptor *> *)openIncrementallyWithBatchSize:(NSUInteger)batchSize
                                                                    batchHandler:(PCPPNativePacketBatchHandler)batchHandler
                                                                 progressHandler:(PCPPNativeLoadProgressHandler)progressHandler
                                                               cancellationCheck:(PCPPNativeCancellationHandler)cancellationCheck
                                                                           error:(NSError **)error
{
    return LoadPacketsFromURLIncrementally(*_state, batchSize, batchHandler, progressHandler, cancellationCheck, error);
}

- (NSArray<PCPPNativePacketSummaryDescriptor *> *)reopenIncrementallyWithBatchSize:(NSUInteger)batchSize
                                                                      batchHandler:(PCPPNativePacketBatchHandler)batchHandler
                                                                   progressHandler:(PCPPNativeLoadProgressHandler)progressHandler
                                                                 cancellationCheck:(PCPPNativeCancellationHandler)cancellationCheck
                                                                             error:(NSError **)error
{
    return LoadPacketsFromURLIncrementally(*_state, batchSize, batchHandler, progressHandler, cancellationCheck, error);
}

- (PCPPNativePacketInspectionDescriptor *)inspectPacketWithIdentifier:(unsigned long long)identifier error:(NSError **)error
{
    std::unique_ptr<pcpp::RawPacket> rawPacket;
    NSString *packetComment = nil;

    {
        std::lock_guard<std::mutex> lock(_state->mutex);
        if (identifier == 0 || identifier > _state->packets.size()) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeFileReadFailed, @"TCP Viewer could not find that packet in this capture.");
            }
            return nil;
        }

        const auto &storedPacket = _state->packets[identifier - 1];
        rawPacket = std::unique_ptr<pcpp::RawPacket>(storedPacket.rawPacket == nullptr ? nullptr : storedPacket.rawPacket->clone());
        packetComment = NullableNSString(storedPacket.packetComment);
    }

    if (rawPacket == nullptr) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeFileReadFailed, @"TCP Viewer could not inspect that packet.");
        }
        return nil;
    }

    return MakePacketInspection(*rawPacket, identifier, nil, packetComment);
}

- (BOOL)saveAndReturnError:(NSError **)error
{
    OfflineDocumentSaveSnapshot snapshot;
    {
        std::lock_guard<std::mutex> lock(_state->mutex);
        if (_state->loading) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"TCP Viewer cannot save while the capture is still loading.");
            }
            return NO;
        }

        if (_state->partialResult) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"TCP Viewer cannot save a partially loaded capture. Reload the file to finish loading first.");
            }
            return NO;
        }

        snapshot = MakeSaveSnapshotLocked(*_state);
    }

    if (!SavePacketsToURL(snapshot, snapshot.currentURL, snapshot.format, nil, nil, error)) {
        return NO;
    }

    {
        std::lock_guard<std::mutex> lock(_state->mutex);
        _state->dirty = false;
    }
    return YES;
}

- (BOOL)saveToURL:(NSURL *)url format:(NSString *)format error:(NSError **)error
{
    OfflineDocumentSaveSnapshot snapshot;
    {
        std::lock_guard<std::mutex> lock(_state->mutex);
        if (_state->loading) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"TCP Viewer cannot save while the capture is still loading.");
            }
            return NO;
        }

        if (_state->partialResult) {
            if (error != nullptr) {
                *error = MakeError(TCPViewerNativeErrorCodeFileWriteFailed, @"TCP Viewer cannot save a partially loaded capture. Reload the file to finish loading first.");
            }
            return NO;
        }

        snapshot = MakeSaveSnapshotLocked(*_state);
    }

    std::string normalizedFormat = NormalizedCaptureFileFormat(MakeStdString(format));

    if (!SavePacketsToURL(snapshot, url, normalizedFormat, nil, nil, error)) {
        return NO;
    }

    {
        std::lock_guard<std::mutex> lock(_state->mutex);
        _state->currentURL = url;
        _state->format = normalizedFormat;
        if (normalizedFormat != "pcapng") {
            _state->operatingSystem.clear();
            _state->hardware.clear();
            _state->captureApplication.clear();
            _state->fileComment.clear();
        }
        _state->dirty = false;
    }
    return YES;
}

- (BOOL)exportPacketsWithIdentifiers:(NSArray<NSNumber *> *)identifiers
                                toURL:(NSURL *)url
                               format:(NSString *)format
                      progressHandler:(PCPPNativePacketExportProgressHandler)progressHandler
                    cancellationCheck:(PCPPNativeCancellationHandler)cancellationCheck
                                error:(NSError **)error
{
    OfflineDocumentSaveSnapshot snapshot;
    {
        std::lock_guard<std::mutex> lock(_state->mutex);
        if (!PopulateOfflineExportSnapshotLocked(snapshot, *_state, identifiers, cancellationCheck, error)) {
            return NO;
        }
    }

    return SavePacketsToURL(snapshot, url, MakeStdString(format), progressHandler, cancellationCheck, error);
}

@end

@implementation PCPPNativeCore

- (NSArray<PCPPNativeInterfaceDescriptor *> *)discoverInterfacesAndReturnError:(NSError **)error
{
    NSMutableArray<PCPPNativeInterfaceDescriptor *> *interfaces = [NSMutableArray array];

    try {
        auto &deviceList = pcpp::PcapLiveDeviceList::getInstance();

        for (auto *device : deviceList.getPcapLiveDevicesList()) {
            if (device == nullptr) {
                continue;
            }

            const auto technicalName = device->getName();
            const bool isHidden = IsHiddenInterface(technicalName);
            const bool supportsLink = SupportsLinkType(device->getLinkType());
            const bool loopback = device->getLoopback();
            const bool providesMacOSMetadata = technicalName.rfind("pktap", 0) == 0 || device->getLinkType() == pcpp::LINKTYPE_PKTAP;

            PCPPNativeInterfaceAvailability availability = PCPPNativeInterfaceAvailabilityAvailable;
            NSString *availabilityReason = nil;
            bool canCapture = true;
            if (isHidden) {
                availability = PCPPNativeInterfaceAvailabilityHidden;
                availabilityReason = @"TCP Viewer keeps this system interface out of the normal capture picker by default.";
            } else if (!supportsLink) {
                availability = PCPPNativeInterfaceAvailabilityUnsupported;
                availabilityReason = @"TCP Viewer does not support this interface link type yet.";
            } else {
                try {
                    if (!device->isOpened()) {
                        pcpp::PcapLiveDevice::DeviceConfiguration configuration(pcpp::PcapLiveDevice::Normal,
                                                                                1,
                                                                                0,
                                                                                pcpp::PcapLiveDevice::PCPP_INOUT,
                                                                                65535);
                        if (!device->open(configuration)) {
                            availability = PCPPNativeInterfaceAvailabilityUnavailable;
                            availabilityReason = @"TCP Viewer could not open this interface with the current macOS capture access.";
                            canCapture = false;
                        } else {
                            device->close();
                        }
                    }
                } catch (const std::exception &) {
                    availability = PCPPNativeInterfaceAvailabilityUnavailable;
                    availabilityReason = @"TCP Viewer could not verify capture readiness for this interface.";
                    canCapture = false;
                }
            }

            NSString *friendlyName = device->getDesc().empty() ? nil : MakeNSString(device->getDesc());
            NSString *displayName = friendlyName ?: MakeNSString(technicalName);
            auto *descriptor = [[PCPPNativeInterfaceDescriptor alloc] initWithIdentifier:MakeNSString(technicalName)
                                                                           technicalName:MakeNSString(technicalName)
                                                                             displayName:displayName
                                                                            friendlyName:friendlyName
                                                                    interfaceDescription:friendlyName
                                                                                 loopback:loopback
                                                                             availability:availability
                                                                       availabilityReason:availabilityReason
                                                                                 linkType:MapLinkType(device->getLinkType())
                                                                                addresses:MapAddresses(*device)
                                                                          activityPreview:[[PCPPNativeActivityPreviewDescriptor alloc] initWithPacketsPerSecond:nil observedAt:nil]
                                                                               canCapture:canCapture
                                                                   supportsPromiscuousMode:NO
                                                                requiresBPFPermissionSetup:YES
                                                                       providesMacOSMetadata:providesMacOSMetadata];
            [interfaces addObject:descriptor];
        }
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MakeError(TCPViewerNativeErrorCodeInterfaceDiscoveryFailed, MakeNSString(exception.what()));
        }
        return nil;
    }

    return interfaces;
}

- (PCPPNativeFilterValidationDescriptor *)validateCaptureFilterExpression:(NSString *)expression
{
    NSString *trimmedExpression = [expression stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmedExpression.length == 0) {
        return [[PCPPNativeFilterValidationDescriptor alloc] initWithDisposition:@"invalid"
                                                            normalizedExpression:nil
                                                                         message:@"Capture filters cannot be empty."];
    }

    pcpp::BPFStringFilter filter(MakeStdString(trimmedExpression));
    if (!filter.verifyFilter()) {
        return [[PCPPNativeFilterValidationDescriptor alloc] initWithDisposition:@"invalid"
                                                            normalizedExpression:trimmedExpression
                                                                         message:@"TCP Viewer could not compile this capture filter with libpcap syntax."];
    }

    return [[PCPPNativeFilterValidationDescriptor alloc] initWithDisposition:@"valid"
                                                        normalizedExpression:trimmedExpression
                                                                     message:nil];
}

- (NSArray<NSString *> *)supportedOfflineFormats
{
    return @[@"pcap", @"pcapng"];
}

@end
