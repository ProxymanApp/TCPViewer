#include "PacketDissectionEngine.hpp"

#include <arpa/inet.h>
#include <algorithm>
#include <cctype>
#include <cstring>
#include <iomanip>
#include <limits>
#include <sstream>
#include <utility>

#include <pcapplusplus/ArpLayer.h>
#include <pcapplusplus/DnsLayer.h>
#include <pcapplusplus/EthLayer.h>
#include <pcapplusplus/HttpLayer.h>
#include <pcapplusplus/IPv4Layer.h>
#include <pcapplusplus/IPv6Layer.h>
#include <pcapplusplus/IcmpLayer.h>
#include <pcapplusplus/IcmpV6Layer.h>
#include <pcapplusplus/Layer.h>
#include <pcapplusplus/Packet.h>
#include <pcapplusplus/PacketUtils.h>
#include <pcapplusplus/PayloadLayer.h>
#include <pcapplusplus/ProtocolType.h>
#include <pcapplusplus/RawPacket.h>
#include <pcapplusplus/SSLHandshake.h>
#include <pcapplusplus/SSLLayer.h>
#include <pcapplusplus/TcpLayer.h>
#include <pcapplusplus/UdpLayer.h>

namespace tcpviewer::dissection {
namespace {

constexpr size_t kIPv4HeaderLength = 20;
constexpr size_t kIPv6HeaderLength = 40;
constexpr size_t kTCPHeaderLength = 20;
constexpr size_t kUDPHeaderLength = 8;
constexpr size_t kICMPHeaderLength = 4;
constexpr size_t kICMPEchoHeaderLength = 8;

ByteRange MakeByteRange(size_t offset, size_t length)
{
    return ByteRange{offset, length, 0, 0, false};
}

ByteRange MakeBitRange(size_t offset, size_t bitOffset, size_t bitLength)
{
    return ByteRange{offset, 1, static_cast<uint8_t>(bitOffset), static_cast<uint8_t>(bitLength), true};
}

size_t LayerOffset(const pcpp::Layer& layer, const pcpp::RawPacket& rawPacket)
{
    return static_cast<size_t>(layer.getData() - rawPacket.getRawData());
}

bool ContainsRange(const pcpp::RawPacket& rawPacket, size_t offset, size_t length)
{
    const auto capturedLength = static_cast<size_t>(std::max(rawPacket.getRawDataLen(), 0));
    return offset <= capturedLength && length <= capturedLength - offset;
}

std::string HexBytes(const uint8_t* bytes, size_t length)
{
    if (bytes == nullptr || length == 0) {
        return "";
    }

    std::ostringstream stream;
    stream << std::hex << std::setfill('0') << std::nouppercase;
    for (size_t index = 0; index < length; index += 1) {
        if (index > 0) {
            stream << ' ';
        }
        stream << std::setw(2) << static_cast<unsigned>(bytes[index]);
    }
    return stream.str();
}

std::string RawValue(const pcpp::RawPacket& rawPacket, size_t offset, size_t length)
{
    if (!ContainsRange(rawPacket, offset, length)) {
        return "";
    }

    return HexBytes(rawPacket.getRawData() + offset, length);
}

std::string Hex16(uint16_t value)
{
    std::ostringstream stream;
    stream << "0x" << std::hex << std::setfill('0') << std::setw(4) << std::nouppercase << value;
    return stream.str();
}

std::string Hex32(uint32_t value)
{
    std::ostringstream stream;
    stream << "0x" << std::hex << std::setfill('0') << std::setw(8) << std::nouppercase << value;
    return stream.str();
}

std::string Decimal(unsigned long long value)
{
    return std::to_string(value);
}

std::string ByteCount(size_t value)
{
    return std::to_string(value) + " bytes";
}

std::string TimestampValue(const timespec& timestamp)
{
    std::ostringstream stream;
    stream << timestamp.tv_sec << "." << std::setw(9) << std::setfill('0') << timestamp.tv_nsec;
    return stream.str();
}

std::string SetStatus(bool isSet)
{
    return isSet ? "Set" : "Not set";
}

DetailNode MakeNode(std::string id,
                    std::string title,
                    std::string fieldName,
                    std::string displayValue,
                    NodeKind kind,
                    std::optional<ByteRange> range,
                    const pcpp::RawPacket& rawPacket,
                    NodeSeverity severity,
                    std::vector<DetailNode> children = {})
{
    DetailNode node;
    node.id = std::move(id);
    node.title = std::move(title);
    node.fieldName = std::move(fieldName);
    node.displayValue = std::move(displayValue);
    node.kind = kind;
    node.range = range;
    node.severity = severity;
    node.children = std::move(children);

    if (node.range.has_value() && ContainsRange(rawPacket, node.range->offset, node.range->length)) {
        node.rawValue = RawValue(rawPacket, node.range->offset, node.range->length);
    } else if (node.range.has_value()) {
        node.severity = NodeSeverity::Error;
    }

    return node;
}

DetailNode MakeField(const PacketDissectionContext& context,
                     std::string id,
                     std::string title,
                     std::string fieldName,
                     std::string displayValue,
                     size_t baseOffset,
                     size_t relativeOffset,
                     size_t length,
                     std::vector<DetailNode> children = {})
{
    return MakeNode(std::move(id),
                    std::move(title),
                    std::move(fieldName),
                    std::move(displayValue),
                    NodeKind::Field,
                    MakeByteRange(baseOffset + relativeOffset, length),
                    context.rawPacket,
                    NodeSeverity::Normal,
                    std::move(children));
}

DetailNode MakeBitField(const PacketDissectionContext& context,
                        std::string id,
                        std::string title,
                        std::string fieldName,
                        std::string displayValue,
                        size_t offset,
                        size_t bitOffset,
                        size_t bitLength)
{
    return MakeNode(std::move(id),
                    std::move(title),
                    std::move(fieldName),
                    std::move(displayValue),
                    NodeKind::Field,
                    MakeBitRange(offset, bitOffset, bitLength),
                    context.rawPacket,
                    NodeSeverity::Normal);
}

DetailNode MakeBitFieldRange(const PacketDissectionContext& context,
                             std::string id,
                             std::string title,
                             std::string fieldName,
                             std::string displayValue,
                             size_t offset,
                             size_t length,
                             size_t bitOffset,
                             size_t bitLength)
{
    return MakeNode(std::move(id),
                    std::move(title),
                    std::move(fieldName),
                    std::move(displayValue),
                    NodeKind::Field,
                    ByteRange{offset, length, static_cast<uint8_t>(bitOffset), static_cast<uint8_t>(bitLength), true},
                    context.rawPacket,
                    NodeSeverity::Normal);
}

DetailNode MakeSyntheticField(std::string id, std::string title, std::string fieldName, std::string displayValue)
{
    DetailNode node;
    node.id = std::move(id);
    node.title = std::move(title);
    node.fieldName = std::move(fieldName);
    node.displayValue = std::move(displayValue);
    node.kind = NodeKind::Field;
    return node;
}

DetailNode MakeWarning(std::string id, std::string displayValue)
{
    DetailNode node;
    node.id = std::move(id);
    node.title = "Decode Warning";
    node.fieldName = "tcpviewer.warning";
    node.displayValue = std::move(displayValue);
    node.kind = NodeKind::Warning;
    node.severity = NodeSeverity::Warning;
    return node;
}

DetailNode MakeLayer(const PacketDissectionContext& context,
                     std::string id,
                     std::string title,
                     std::string fieldName,
                     std::string displayValue,
                     size_t offset,
                     size_t length,
                     std::vector<DetailNode> children)
{
    return MakeNode(std::move(id),
                    std::move(title),
                    std::move(fieldName),
                    std::move(displayValue),
                    NodeKind::Layer,
                    MakeByteRange(offset, length),
                    context.rawPacket,
                    NodeSeverity::Normal,
                    std::move(children));
}

uint16_t ReadBE16(const uint8_t* bytes)
{
    uint16_t value = 0;
    std::memcpy(&value, bytes, sizeof(value));
    return ntohs(value);
}

uint32_t ReadBE32(const uint8_t* bytes)
{
    uint32_t value = 0;
    std::memcpy(&value, bytes, sizeof(value));
    return ntohl(value);
}

uint32_t ReadBE24(const uint8_t* bytes)
{
    return (static_cast<uint32_t>(bytes[0]) << 16) |
           (static_cast<uint32_t>(bytes[1]) << 8) |
           static_cast<uint32_t>(bytes[2]);
}

uint64_t ReadBE64(const uint8_t* bytes)
{
    uint64_t value = 0;
    for (size_t index = 0; index < sizeof(value); index += 1) {
        value = (value << 8) | bytes[index];
    }
    return value;
}

std::string JoinStrings(const std::vector<std::string>& values, const std::string& separator)
{
    std::ostringstream stream;
    for (size_t index = 0; index < values.size(); index += 1) {
        if (index > 0) {
            stream << separator;
        }
        stream << values[index];
    }
    return stream.str();
}

std::string StringFromBytes(const uint8_t* bytes, size_t length)
{
    return std::string(reinterpret_cast<const char*>(bytes), reinterpret_cast<const char*>(bytes + length));
}

std::string TrimHTTPWhitespace(std::string value)
{
    auto isHTTPWhitespace = [](unsigned char c) {
        return c == ' ' || c == '\t' || c == '\r' || c == '\n';
    };

    while (!value.empty() && isHTTPWhitespace(static_cast<unsigned char>(value.front()))) {
        value.erase(value.begin());
    }
    while (!value.empty() && isHTTPWhitespace(static_cast<unsigned char>(value.back()))) {
        value.pop_back();
    }
    return value;
}

std::string Lowercase(std::string value)
{
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return value;
}

std::string PayloadPreview(const uint8_t* bytes, size_t length, size_t limit = 16)
{
    if (bytes == nullptr || length == 0) {
        return "Empty";
    }

    const size_t visibleLength = std::min(length, limit);
    std::string preview = HexBytes(bytes, visibleLength);
    if (length > visibleLength) {
        preview += " ...";
    }
    return preview;
}

std::string TCPFlagsSummary(const pcpp::tcphdr* header)
{
    std::vector<std::string> flags;
    if (header->synFlag) flags.emplace_back("SYN");
    if (header->ackFlag) flags.emplace_back("ACK");
    if (header->finFlag) flags.emplace_back("FIN");
    if (header->rstFlag) flags.emplace_back("RST");
    if (header->pshFlag) flags.emplace_back("PSH");
    if (header->urgFlag) flags.emplace_back("URG");
    if (header->eceFlag) flags.emplace_back("ECE");
    if (header->cwrFlag) flags.emplace_back("CWR");

    if (flags.empty()) {
        return "No flags";
    }

    std::ostringstream stream;
    for (size_t index = 0; index < flags.size(); index += 1) {
        if (index > 0) {
            stream << ", ";
        }
        stream << flags[index];
    }
    return stream.str();
}

uint16_t TCPFlagsValue(const pcpp::tcphdr* header)
{
    return static_cast<uint16_t>((header->cwrFlag ? 0x080 : 0) |
                                 (header->eceFlag ? 0x040 : 0) |
                                 (header->urgFlag ? 0x020 : 0) |
                                 (header->ackFlag ? 0x010 : 0) |
                                 (header->pshFlag ? 0x008 : 0) |
                                 (header->rstFlag ? 0x004 : 0) |
                                 (header->synFlag ? 0x002 : 0) |
                                 (header->finFlag ? 0x001 : 0));
}

std::string TCPFlagsValueDisplay(const pcpp::tcphdr* header)
{
    std::ostringstream stream;
    stream << "0x" << std::hex << std::setfill('0') << std::setw(3) << TCPFlagsValue(header)
           << " (" << TCPFlagsSummary(header) << ")";
    return stream.str();
}

std::string TCPOptionName(pcpp::TcpOptionEnumType optionType)
{
    switch (optionType) {
        case pcpp::TcpOptionEnumType::Eol:
            return "TCP Option - End of Option List";
        case pcpp::TcpOptionEnumType::Nop:
            return "TCP Option - No-Operation";
        case pcpp::TcpOptionEnumType::Mss:
            return "TCP Option - Maximum segment size";
        case pcpp::TcpOptionEnumType::Window:
            return "TCP Option - Window scale";
        case pcpp::TcpOptionEnumType::SackPerm:
            return "TCP Option - SACK permitted";
        case pcpp::TcpOptionEnumType::Sack:
            return "TCP Option - SACK";
        case pcpp::TcpOptionEnumType::Timestamp:
            return "TCP Option - Timestamps";
        default:
            return "TCP Option";
    }
}

std::string TCPOptionValue(pcpp::TcpOption option)
{
    switch (option.getTcpOptionEnumType()) {
        case pcpp::TcpOptionEnumType::Mss:
            if (option.getDataSize() >= 2) {
                return std::to_string(ntohs(option.getValueAs<uint16_t>())) + " bytes";
            }
            break;
        case pcpp::TcpOptionEnumType::Window:
            if (option.getDataSize() >= 1) {
                uint8_t shift = option.getValueAs<uint8_t>();
                uint32_t multiplier = shift < 31 ? (1u << shift) : 0;
                return multiplier > 0 ? std::to_string(shift) + " (multiply by " + std::to_string(multiplier) + ")"
                                      : std::to_string(shift);
            }
            break;
        case pcpp::TcpOptionEnumType::SackPerm:
            return "Permitted";
        case pcpp::TcpOptionEnumType::Timestamp:
            if (option.getDataSize() >= 8) {
                uint32_t tsValue = ntohl(option.getValueAs<uint32_t>(0));
                uint32_t tsEcho = ntohl(option.getValueAs<uint32_t>(4));
                return "TSval " + std::to_string(tsValue) + ", TSecr " + std::to_string(tsEcho);
            }
            break;
        case pcpp::TcpOptionEnumType::Nop:
        case pcpp::TcpOptionEnumType::Eol:
            return "";
        default:
            break;
    }
    return "Kind " + std::to_string(option.getType()) + ", " + ByteCount(option.getTotalSize());
}

std::string ICMPv4TypeName(uint8_t type)
{
    switch (type) {
        case pcpp::ICMP_ECHO_REPLY:
            return "Echo Reply";
        case pcpp::ICMP_DEST_UNREACHABLE:
            return "Destination Unreachable";
        case pcpp::ICMP_SOURCE_QUENCH:
            return "Source Quench";
        case pcpp::ICMP_REDIRECT:
            return "Redirect";
        case pcpp::ICMP_ECHO_REQUEST:
            return "Echo Request";
        case pcpp::ICMP_ROUTER_ADV:
            return "Router Advertisement";
        case pcpp::ICMP_ROUTER_SOL:
            return "Router Solicitation";
        case pcpp::ICMP_TIME_EXCEEDED:
            return "Time Exceeded";
        case pcpp::ICMP_PARAM_PROBLEM:
            return "Parameter Problem";
        case pcpp::ICMP_TIMESTAMP_REQUEST:
            return "Timestamp Request";
        case pcpp::ICMP_TIMESTAMP_REPLY:
            return "Timestamp Reply";
        case pcpp::ICMP_INFO_REQUEST:
            return "Information Request";
        case pcpp::ICMP_INFO_REPLY:
            return "Information Reply";
        case pcpp::ICMP_ADDRESS_MASK_REQUEST:
            return "Address Mask Request";
        case pcpp::ICMP_ADDRESS_MASK_REPLY:
            return "Address Mask Reply";
        default:
            return "Unknown";
    }
}

std::string ICMPv6TypeName(uint8_t type)
{
    switch (type) {
        case 1:
            return "Destination Unreachable";
        case 2:
            return "Packet Too Big";
        case 3:
            return "Time Exceeded";
        case 4:
            return "Parameter Problem";
        case 128:
            return "Echo Request";
        case 129:
            return "Echo Reply";
        case 133:
            return "Router Solicitation";
        case 134:
            return "Router Advertisement";
        case 135:
            return "Neighbor Solicitation";
        case 136:
            return "Neighbor Advertisement";
        case 137:
            return "Redirect";
        default:
            return "Unknown";
    }
}

std::string UDPChecksumStatus(const pcpp::UdpLayer& layer)
{
    const uint16_t checksum = ntohs(layer.getUdpHeader()->headerChecksum);
    if (checksum == 0) {
        auto* previousLayer = layer.getPrevLayer();
        if (previousLayer != nullptr && previousLayer->getProtocol() == pcpp::IPv6) {
            return "Illegal zero checksum";
        }
        return "Not present";
    }

    return "Present (unverified)";
}

size_t DNSHeaderOffset(const pcpp::DnsLayer& layer, size_t layerOffset)
{
    return dynamic_cast<const pcpp::DnsOverTcpLayer*>(&layer) != nullptr ? layerOffset + sizeof(uint16_t) : layerOffset;
}

std::string DNSRecordTypeName(pcpp::DnsType type)
{
    switch (type) {
        case pcpp::DNS_TYPE_A:
            return "A";
        case pcpp::DNS_TYPE_NS:
            return "NS";
        case pcpp::DNS_TYPE_CNAME:
            return "CNAME";
        case pcpp::DNS_TYPE_SOA:
            return "SOA";
        case pcpp::DNS_TYPE_PTR:
            return "PTR";
        case pcpp::DNS_TYPE_MX:
            return "MX";
        case pcpp::DNS_TYPE_TXT:
            return "TXT";
        case pcpp::DNS_TYPE_AAAA:
            return "AAAA";
        case pcpp::DNS_TYPE_SRV:
            return "SRV";
        case pcpp::DNS_TYPE_OPT:
            return "OPT";
        case pcpp::DNS_TYPE_DS:
            return "DS";
        case pcpp::DNS_TYPE_RRSIG:
            return "RRSIG";
        case pcpp::DNS_TYPE_NSEC:
            return "NSEC";
        case pcpp::DNS_TYPE_DNSKEY:
            return "DNSKEY";
        case pcpp::DNS_TYPE_ALL:
            return "ANY";
        default:
            return "Unknown";
    }
}

std::string DNSRecordTypeValue(pcpp::DnsType type)
{
    return DNSRecordTypeName(type) + " (" + Decimal(static_cast<unsigned>(type)) + ")";
}

std::string DNSClassName(pcpp::DnsClass dnsClass)
{
    switch (dnsClass) {
        case pcpp::DNS_CLASS_IN:
            return "IN";
        case pcpp::DNS_CLASS_IN_QU:
            return "IN QU";
        case pcpp::DNS_CLASS_CH:
            return "CH";
        case pcpp::DNS_CLASS_HS:
            return "HS";
        case pcpp::DNS_CLASS_ANY:
            return "ANY";
        default:
            return "Unknown";
    }
}

std::string DNSClassValue(pcpp::DnsClass dnsClass)
{
    return DNSClassName(dnsClass) + " (" + Decimal(static_cast<unsigned>(dnsClass)) + ")";
}

std::string DNSOpcodeName(uint16_t opcode)
{
    switch (opcode) {
        case 0:
            return "Standard query";
        case 1:
            return "Inverse query";
        case 2:
            return "Status";
        case 4:
            return "Notify";
        case 5:
            return "Update";
        default:
            return "Unknown";
    }
}

std::string DNSResponseCodeName(uint16_t responseCode)
{
    switch (responseCode) {
        case 0:
            return "No error";
        case 1:
            return "Format error";
        case 2:
            return "Server failure";
        case 3:
            return "Non-existent domain";
        case 4:
            return "Not implemented";
        case 5:
            return "Refused";
        default:
            return "Unknown";
    }
}

std::string DNSResourceDataValue(const pcpp::DnsResource& resource)
{
    auto data = const_cast<pcpp::DnsResource&>(resource).getData();
    return data.get() != nullptr ? data->toString() : "";
}

std::string DNSResourceSectionIdentifier(pcpp::DnsResourceType resourceType)
{
    switch (resourceType) {
        case pcpp::DnsAnswerType:
            return "answer";
        case pcpp::DnsAuthorityType:
            return "authority";
        case pcpp::DnsAdditionalType:
            return "additional";
        case pcpp::DnsQueryType:
            return "query";
    }
}

std::string DNSResourceRecordName(pcpp::DnsResourceType resourceType)
{
    switch (resourceType) {
        case pcpp::DnsAnswerType:
            return "Answer";
        case pcpp::DnsAuthorityType:
            return "Authority";
        case pcpp::DnsAdditionalType:
            return "Additional";
        case pcpp::DnsQueryType:
            return "Query";
    }
}

pcpp::DnsResource* FirstDNSResource(pcpp::DnsLayer& layer, pcpp::DnsResourceType resourceType)
{
    switch (resourceType) {
        case pcpp::DnsAnswerType:
            return layer.getFirstAnswer();
        case pcpp::DnsAuthorityType:
            return layer.getFirstAuthority();
        case pcpp::DnsAdditionalType:
            return layer.getFirstAdditionalRecord();
        case pcpp::DnsQueryType:
            return nullptr;
    }
}

pcpp::DnsResource* NextDNSResource(pcpp::DnsLayer& layer, pcpp::DnsResource* resource, pcpp::DnsResourceType resourceType)
{
    switch (resourceType) {
        case pcpp::DnsAnswerType:
            return layer.getNextAnswer(resource);
        case pcpp::DnsAuthorityType:
            return layer.getNextAuthority(resource);
        case pcpp::DnsAdditionalType:
            return layer.getNextAdditionalRecord(resource);
        case pcpp::DnsQueryType:
            return nullptr;
    }
}

std::string TLSVersionLabel(pcpp::SSLVersion version)
{
    switch (version.asEnum(true)) {
        case pcpp::SSLVersion::SSL3:
            return "SSLv3";
        case pcpp::SSLVersion::TLS1_0:
            return "TLSv1.0";
        case pcpp::SSLVersion::TLS1_1:
            return "TLSv1.1";
        case pcpp::SSLVersion::TLS1_2:
            return "TLSv1.2";
        case pcpp::SSLVersion::TLS1_3:
            return "TLSv1.3";
        default:
            return "TLS";
    }
}

std::string TLSVersionFieldValue(pcpp::SSLVersion version)
{
    return TLSVersionLabel(version) + " (" + Hex16(version.asUInt()) + ")";
}

std::string TLSRecordTypeName(pcpp::SSLRecordType recordType)
{
    switch (recordType) {
        case pcpp::SSL_CHANGE_CIPHER_SPEC:
            return "Change Cipher Spec";
        case pcpp::SSL_ALERT:
            return "Alert";
        case pcpp::SSL_HANDSHAKE:
            return "Handshake";
        case pcpp::SSL_APPLICATION_DATA:
            return "Application Data";
        default:
            return "Unknown";
    }
}

std::string TLSRecordTypeFieldValue(pcpp::SSLRecordType recordType)
{
    return TLSRecordTypeName(recordType) + " (" + Decimal(static_cast<unsigned>(recordType)) + ")";
}

std::string TLSHandshakeTypeName(pcpp::SSLHandshakeType handshakeType)
{
    switch (handshakeType) {
        case pcpp::SSL_HELLO_REQUEST:
            return "Hello Request";
        case pcpp::SSL_CLIENT_HELLO:
            return "Client Hello";
        case pcpp::SSL_SERVER_HELLO:
            return "Server Hello";
        case pcpp::SSL_NEW_SESSION_TICKET:
            return "New Session Ticket";
        case pcpp::SSL_END_OF_EARLY_DATE:
            return "End Of Early Data";
        case pcpp::SSL_ENCRYPTED_EXTENSIONS:
            return "Encrypted Extensions";
        case pcpp::SSL_CERTIFICATE:
            return "Certificate";
        case pcpp::SSL_SERVER_KEY_EXCHANGE:
            return "Server Key Exchange";
        case pcpp::SSL_CERTIFICATE_REQUEST:
            return "Certificate Request";
        case pcpp::SSL_SERVER_DONE:
            return "Server Hello Done";
        case pcpp::SSL_CERTIFICATE_VERIFY:
            return "Certificate Verify";
        case pcpp::SSL_CLIENT_KEY_EXCHANGE:
            return "Client Key Exchange";
        case pcpp::SSL_FINISHED:
            return "Finished";
        case pcpp::SSL_KEY_UPDATE:
            return "Key Update";
        default:
            return "Unknown";
    }
}

std::string TLSHandshakeTypeFieldValue(pcpp::SSLHandshakeType handshakeType)
{
    return TLSHandshakeTypeName(handshakeType) + " (" + Decimal(static_cast<unsigned>(handshakeType)) + ")";
}

std::string TLSLayerName(const pcpp::SSLLayer& layer)
{
    return TLSVersionLabel(layer.getRecordVersion());
}

size_t TLSHandshakeDeclaredPayloadLength(const uint8_t* messageData, size_t messageLength)
{
    if (messageData == nullptr || messageLength < 4) {
        return 0;
    }

    return ReadBE24(messageData + 1);
}

std::string TLSCipherSuiteFieldValue(uint16_t cipherSuiteID, pcpp::SSLCipherSuite* cipherSuite)
{
    std::string value = Hex16(cipherSuiteID);
    if (cipherSuite != nullptr) {
        value += " " + cipherSuite->asString();
    }
    return value;
}

std::string TLSSupportedVersionsSummary(pcpp::SSLSupportedVersionsExtension* supportedVersions)
{
    if (supportedVersions == nullptr) {
        return "";
    }

    std::vector<std::string> versions;
    for (auto version : supportedVersions->getSupportedVersions()) {
        versions.push_back(TLSVersionLabel(version));
    }
    return JoinStrings(versions, ", ");
}

std::string TLSAlertLevelName(pcpp::SSLAlertLevel alertLevel)
{
    switch (alertLevel) {
        case pcpp::SSL_ALERT_LEVEL_WARNING:
            return "Warning";
        case pcpp::SSL_ALERT_LEVEL_FATAL:
            return "Fatal";
        case pcpp::SSL_ALERT_LEVEL_ENCRYPTED:
            return "Encrypted";
        default:
            return "Unknown";
    }
}

std::string TLSAlertDescriptionName(pcpp::SSLAlertDescription alertDescription)
{
    switch (alertDescription) {
        case pcpp::SSL_ALERT_CLOSE_NOTIFY:
            return "Close Notify";
        case pcpp::SSL_ALERT_UNEXPECTED_MESSAGE:
            return "Unexpected Message";
        case pcpp::SSL_ALERT_BAD_RECORD_MAC:
            return "Bad Record MAC";
        case pcpp::SSL_ALERT_DECRYPTION_FAILED:
            return "Decryption Failed";
        case pcpp::SSL_ALERT_RECORD_OVERFLOW:
            return "Record Overflow";
        case pcpp::SSL_ALERT_DECOMPRESSION_FAILURE:
            return "Decompression Failure";
        case pcpp::SSL_ALERT_HANDSHAKE_FAILURE:
            return "Handshake Failure";
        case pcpp::SSL_ALERT_BAD_CERTIFICATE:
            return "Bad Certificate";
        case pcpp::SSL_ALERT_UNSUPPORTED_CERTIFICATE:
            return "Unsupported Certificate";
        case pcpp::SSL_ALERT_CERTIFICATE_REVOKED:
            return "Certificate Revoked";
        case pcpp::SSL_ALERT_CERTIFICATE_EXPIRED:
            return "Certificate Expired";
        case pcpp::SSL_ALERT_CERTIFICATE_UNKNOWN:
            return "Certificate Unknown";
        case pcpp::SSL_ALERT_ILLEGAL_PARAMETER:
            return "Illegal Parameter";
        case pcpp::SSL_ALERT_UNKNOWN_CA:
            return "Unknown CA";
        case pcpp::SSL_ALERT_ACCESS_DENIED:
            return "Access Denied";
        case pcpp::SSL_ALERT_DECODE_ERROR:
            return "Decode Error";
        case pcpp::SSL_ALERT_DECRYPT_ERROR:
            return "Decrypt Error";
        case pcpp::SSL_ALERT_PROTOCOL_VERSION:
            return "Protocol Version";
        case pcpp::SSL_ALERT_INSUFFICIENT_SECURITY:
            return "Insufficient Security";
        case pcpp::SSL_ALERT_INTERNAL_ERROR:
            return "Internal Error";
        case pcpp::SSL_ALERT_USER_CANCELLED:
            return "User Cancelled";
        case pcpp::SSL_ALERT_NO_RENEGOTIATION:
            return "No Renegotiation";
        case pcpp::SSL_ALERT_UNSUPPORTED_EXTENSION:
            return "Unsupported Extension";
        case pcpp::SSL_ALERT_ENCRYPTED:
            return "Encrypted";
        default:
            return "Unknown";
    }
}

size_t LineContentLength(const uint8_t* data, size_t start, size_t end)
{
    if (end > start && data[end - 1] == '\n') {
        end -= 1;
    }
    if (end > start && data[end - 1] == '\r') {
        end -= 1;
    }
    return end - start;
}

std::optional<size_t> FindHTTPHeaderEnd(const uint8_t* data, size_t length)
{
    for (size_t index = 0; index + 3 < length; index += 1) {
        if (data[index] == '\r' && data[index + 1] == '\n' && data[index + 2] == '\r' && data[index + 3] == '\n') {
            return index + 4;
        }
    }
    for (size_t index = 0; index + 1 < length; index += 1) {
        if (data[index] == '\n' && data[index + 1] == '\n') {
            return index + 2;
        }
    }
    return std::nullopt;
}

std::vector<std::pair<size_t, size_t>> HTTPLines(const uint8_t* data, size_t length)
{
    std::vector<std::pair<size_t, size_t>> lines;
    size_t start = 0;
    while (start < length) {
        size_t end = start;
        while (end < length && data[end] != '\n') {
            end += 1;
        }
        if (end == start || (end == start + 1 && data[start] == '\r')) {
            break;
        }
        lines.emplace_back(start, end < length ? end + 1 : end);
        start = end < length ? end + 1 : end;
    }
    return lines;
}

std::string WebSocketOpcodeName(uint8_t opcode)
{
    switch (opcode) {
        case 0x0:
            return "Continuation";
        case 0x1:
            return "Text";
        case 0x2:
            return "Binary";
        case 0x8:
            return "Connection Close";
        case 0x9:
            return "Ping";
        case 0x0a:
            return "Pong";
        default:
            return "Reserved";
    }
}

bool IsValidWebSocketOpcode(uint8_t opcode)
{
    return opcode == 0x0 || opcode == 0x1 || opcode == 0x2 || opcode == 0x8 || opcode == 0x9 || opcode == 0x0a;
}

bool IsHTTPPort(const pcpp::Layer& layer)
{
    auto* previous = layer.getPrevLayer();
    if (previous == nullptr || previous->getProtocol() != pcpp::TCP) {
        return false;
    }

    auto* tcp = static_cast<pcpp::TcpLayer*>(previous);
    return pcpp::HttpMessage::isHttpPort(tcp->getSrcPort()) || pcpp::HttpMessage::isHttpPort(tcp->getDstPort());
}

class PhaseOneDissector final : public ProtocolDissector {
public:
    std::optional<DetailNode> dissectLayer(const PacketDissectionContext& context, const pcpp::Layer& layer) const override
    {
        const size_t offset = LayerOffset(layer, context.rawPacket);
        switch (layer.getProtocol()) {
            case pcpp::Ethernet:
                return dissectEthernet(context, static_cast<const pcpp::EthLayer&>(layer), offset);
            case pcpp::ARP:
                return dissectARP(context, static_cast<const pcpp::ArpLayer&>(layer), offset);
            case pcpp::IPv4:
                return dissectIPv4(context, static_cast<const pcpp::IPv4Layer&>(layer), offset);
            case pcpp::IPv6:
                return dissectIPv6(context, static_cast<const pcpp::IPv6Layer&>(layer), offset);
            case pcpp::ICMP:
                return dissectICMPv4(context, static_cast<const pcpp::IcmpLayer&>(layer), offset);
            case pcpp::ICMPv6:
                return dissectICMPv6(context, layer, offset);
            case pcpp::TCP:
                return dissectTCP(context, static_cast<const pcpp::TcpLayer&>(layer), offset);
            case pcpp::UDP:
                return dissectUDP(context, static_cast<const pcpp::UdpLayer&>(layer), offset);
            default:
                return std::nullopt;
        }
    }

private:
    DetailNode dissectEthernet(const PacketDissectionContext& context, const pcpp::EthLayer& layer, size_t offset) const
    {
        auto* header = layer.getEthHeader();
        std::vector<DetailNode> children;
        children.push_back(MakeField(context, "eth.dst", "Destination", "eth.dst", layer.getDestMac().toString(), offset, 0, 6));
        children.push_back(MakeField(context, "eth.src", "Source", "eth.src", layer.getSourceMac().toString(), offset, 6, 6));
        children.push_back(MakeField(context, "eth.type", "Type", "eth.type", Hex16(ntohs(header->etherType)), offset, 12, 2));
        return MakeLayer(context,
                         "eth",
                         "Ethernet",
                         "eth",
                         "Src: " + layer.getSourceMac().toString() + ", Dst: " + layer.getDestMac().toString(),
                         offset,
                         layer.getHeaderLen(),
                         std::move(children));
    }

    DetailNode dissectARP(const PacketDissectionContext& context, const pcpp::ArpLayer& layer, size_t offset) const
    {
        auto* header = layer.getArpHeader();
        std::vector<DetailNode> children;
        children.push_back(MakeField(context, "arp.hardware", "Hardware Type", "arp.hw.type", Decimal(ntohs(header->hardwareType)), offset, 0, 2));
        children.push_back(MakeField(context, "arp.protocol", "Protocol Type", "arp.proto.type", Hex16(ntohs(header->protocolType)), offset, 2, 2));
        children.push_back(MakeField(context, "arp.hardwareSize", "Hardware Size", "arp.hw.size", Decimal(header->hardwareSize), offset, 4, 1));
        children.push_back(MakeField(context, "arp.protocolSize", "Protocol Size", "arp.proto.size", Decimal(header->protocolSize), offset, 5, 1));
        children.push_back(MakeField(context, "arp.opcode", "Opcode", "arp.opcode", Decimal(ntohs(header->opcode)), offset, 6, 2));
        children.push_back(MakeField(context, "arp.senderMac", "Sender MAC", "arp.src.hw_mac", layer.getSenderMacAddress().toString(), offset, 8, 6));
        children.push_back(MakeField(context, "arp.senderIP", "Sender IP", "arp.src.proto_ipv4", layer.getSenderIpAddr().toString(), offset, 14, 4));
        children.push_back(MakeField(context, "arp.targetMac", "Target MAC", "arp.dst.hw_mac", layer.getTargetMacAddress().toString(), offset, 18, 6));
        children.push_back(MakeField(context, "arp.targetIP", "Target IP", "arp.dst.proto_ipv4", layer.getTargetIpAddr().toString(), offset, 24, 4));
        return MakeLayer(context, "arp", "ARP", "arp", layer.toString(), offset, layer.getHeaderLen(), std::move(children));
    }

    DetailNode dissectIPv4(const PacketDissectionContext& context, const pcpp::IPv4Layer& layer, size_t offset) const
    {
        auto* header = layer.getIPv4Header();
        const uint8_t* data = layer.getData();
        uint16_t flagsAndOffset = ntohs(header->fragmentOffset);
        std::vector<DetailNode> flagsChildren;
        flagsChildren.push_back(MakeBitField(context, "ipv4.flags.reserved", "Reserved bit", "ip.flags.rb", SetStatus((flagsAndOffset & 0x8000) != 0), offset + 6, 0, 1));
        flagsChildren.push_back(MakeBitField(context, "ipv4.flags.df", "Don't Fragment", "ip.flags.df", SetStatus((flagsAndOffset & 0x4000) != 0), offset + 6, 1, 1));
        flagsChildren.push_back(MakeBitField(context, "ipv4.flags.mf", "More Fragments", "ip.flags.mf", SetStatus((flagsAndOffset & 0x2000) != 0), offset + 6, 2, 1));
        flagsChildren.push_back(MakeNode("ipv4.fragOffset",
                                         "Fragment Offset",
                                         "ip.frag_offset",
                                         Decimal(flagsAndOffset & 0x1fff),
                                         NodeKind::Field,
                                         ByteRange{offset + 6, 2, 3, 13, true},
                                         context.rawPacket,
                                         NodeSeverity::Normal));

        std::vector<DetailNode> children;
        children.push_back(MakeBitField(context, "ipv4.version", "Version", "ip.version", Decimal(data[0] >> 4), offset, 0, 4));
        children.push_back(MakeBitField(context, "ipv4.ihl", "Header Length", "ip.hdr_len", ByteCount(layer.getHeaderLen()), offset, 4, 4));
        children.push_back(MakeBitField(context, "ipv4.dscp", "Differentiated Services Codepoint", "ip.dsfield.dscp", Decimal(data[1] >> 2), offset + 1, 0, 6));
        children.push_back(MakeBitField(context, "ipv4.ecn", "Explicit Congestion Notification", "ip.dsfield.ecn", Decimal(data[1] & 0x03), offset + 1, 6, 2));
        children.push_back(MakeField(context, "ipv4.totalLength", "Total Length", "ip.len", Decimal(ntohs(header->totalLength)), offset, 2, 2));
        children.push_back(MakeField(context, "ipv4.identification", "Identification", "ip.id", Hex16(ntohs(header->ipId)), offset, 4, 2));
        children.push_back(MakeField(context, "ipv4.flagsOffset", "Flags / Fragment Offset", "ip.flags", Hex16(flagsAndOffset), offset, 6, 2, std::move(flagsChildren)));
        children.push_back(MakeField(context, "ipv4.ttl", "Time To Live", "ip.ttl", Decimal(header->timeToLive), offset, 8, 1));
        children.push_back(MakeField(context, "ipv4.protocol", "Protocol", "ip.proto", Decimal(header->protocol), offset, 9, 1));
        children.push_back(MakeField(context, "ipv4.checksum", "Header Checksum", "ip.checksum", Hex16(ntohs(header->headerChecksum)), offset, 10, 2));
        children.push_back(MakeField(context, "ipv4.src", "Source", "ip.src", layer.getSrcIPv4Address().toString(), offset, 12, 4));
        children.push_back(MakeField(context, "ipv4.dst", "Destination", "ip.dst", layer.getDstIPv4Address().toString(), offset, 16, 4));
        if (layer.getHeaderLen() > kIPv4HeaderLength) {
            children.push_back(MakeField(context, "ipv4.options", "Options", "ip.options", ByteCount(layer.getHeaderLen() - kIPv4HeaderLength), offset, kIPv4HeaderLength, layer.getHeaderLen() - kIPv4HeaderLength));
        }
        return MakeLayer(context,
                         "ipv4",
                         "IPv4",
                         "ip",
                         "Src: " + layer.getSrcIPv4Address().toString() + ", Dst: " + layer.getDstIPv4Address().toString(),
                         offset,
                         layer.getHeaderLen(),
                         std::move(children));
    }

    DetailNode dissectIPv6(const PacketDissectionContext& context, const pcpp::IPv6Layer& layer, size_t offset) const
    {
        auto* header = layer.getIPv6Header();
        uint32_t versionTrafficFlow = ReadBE32(layer.getData());
        std::vector<DetailNode> splitChildren;
        splitChildren.push_back(MakeBitField(context, "ipv6.version", "Version", "ipv6.version", Decimal((versionTrafficFlow >> 28) & 0x0f), offset, 0, 4));
        splitChildren.push_back(MakeNode("ipv6.trafficClass",
                                         "Traffic Class",
                                         "ipv6.tclass",
                                         Decimal((versionTrafficFlow >> 20) & 0xff),
                                         NodeKind::Field,
                                         ByteRange{offset, 2, 4, 8, true},
                                         context.rawPacket,
                                         NodeSeverity::Normal));
        splitChildren.push_back(MakeNode("ipv6.flowLabel",
                                         "Flow Label",
                                         "ipv6.flow",
                                         Decimal(versionTrafficFlow & 0x000fffff),
                                         NodeKind::Field,
                                         ByteRange{offset + 1, 3, 4, 20, true},
                                         context.rawPacket,
                                         NodeSeverity::Normal));

        std::vector<DetailNode> children;
        children.push_back(MakeField(context, "ipv6.versionTraffic", "Version / Traffic Class / Flow Label", "ipv6.vtcflow", Hex32(versionTrafficFlow), offset, 0, 4, std::move(splitChildren)));
        children.push_back(MakeField(context, "ipv6.payloadLength", "Payload Length", "ipv6.plen", Decimal(ntohs(header->payloadLength)), offset, 4, 2));
        children.push_back(MakeField(context, "ipv6.nextHeader", "Next Header", "ipv6.nxt", Decimal(header->nextHeader), offset, 6, 1));
        children.push_back(MakeField(context, "ipv6.hopLimit", "Hop Limit", "ipv6.hlim", Decimal(header->hopLimit), offset, 7, 1));
        children.push_back(MakeField(context, "ipv6.src", "Source", "ipv6.src", layer.getSrcIPv6Address().toString(), offset, 8, 16));
        children.push_back(MakeField(context, "ipv6.dst", "Destination", "ipv6.dst", layer.getDstIPv6Address().toString(), offset, 24, 16));
        if (layer.getHeaderLen() > kIPv6HeaderLength) {
            children.push_back(MakeField(context, "ipv6.extensions", "Extension Headers", "ipv6.ext", ByteCount(layer.getHeaderLen() - kIPv6HeaderLength), offset, kIPv6HeaderLength, layer.getHeaderLen() - kIPv6HeaderLength));
        }
        return MakeLayer(context,
                         "ipv6",
                         "IPv6",
                         "ipv6",
                         "Src: " + layer.getSrcIPv6Address().toString() + ", Dst: " + layer.getDstIPv6Address().toString(),
                         offset,
                         layer.getHeaderLen(),
                         std::move(children));
    }

    DetailNode dissectTCP(const PacketDissectionContext& context, const pcpp::TcpLayer& layer, size_t offset) const
    {
        auto* header = layer.getTcpHeader();
        std::vector<DetailNode> flagChildren;
        flagChildren.push_back(MakeBitField(context, "tcp.flags.cwr", "Congestion Window Reduced", "tcp.flags.cwr", SetStatus(header->cwrFlag), offset + 13, 0, 1));
        flagChildren.push_back(MakeBitField(context, "tcp.flags.ece", "ECN-Echo", "tcp.flags.ece", SetStatus(header->eceFlag), offset + 13, 1, 1));
        flagChildren.push_back(MakeBitField(context, "tcp.flags.urg", "Urgent", "tcp.flags.urg", SetStatus(header->urgFlag), offset + 13, 2, 1));
        flagChildren.push_back(MakeBitField(context, "tcp.flags.ack", "Acknowledgment", "tcp.flags.ack", SetStatus(header->ackFlag), offset + 13, 3, 1));
        flagChildren.push_back(MakeBitField(context, "tcp.flags.psh", "Push", "tcp.flags.push", SetStatus(header->pshFlag), offset + 13, 4, 1));
        flagChildren.push_back(MakeBitField(context, "tcp.flags.rst", "Reset", "tcp.flags.reset", SetStatus(header->rstFlag), offset + 13, 5, 1));
        flagChildren.push_back(MakeBitField(context, "tcp.flags.syn", "Syn", "tcp.flags.syn", SetStatus(header->synFlag), offset + 13, 6, 1));
        flagChildren.push_back(MakeBitField(context, "tcp.flags.fin", "Fin", "tcp.flags.fin", SetStatus(header->finFlag), offset + 13, 7, 1));

        std::vector<DetailNode> children;
        uint32_t streamID = pcpp::hash5Tuple(const_cast<pcpp::Packet*>(&context.packet), false);
        if (streamID != 0) {
            children.push_back(MakeSyntheticField("tcp.streamID", "Stream ID", "tcp.stream", Decimal(streamID)));
        }
        children.push_back(MakeSyntheticField("tcp.segmentLength", "TCP Segment Len", "tcp.len", Decimal(layer.getLayerPayloadSize())));
        children.push_back(MakeField(context, "tcp.srcPort", "Source Port", "tcp.srcport", Decimal(layer.getSrcPort()), offset, 0, 2));
        children.push_back(MakeField(context, "tcp.dstPort", "Destination Port", "tcp.dstport", Decimal(layer.getDstPort()), offset, 2, 2));
        children.push_back(MakeField(context, "tcp.sequence.raw", "Sequence Number (raw)", "tcp.seq_raw", Decimal(ntohl(header->sequenceNumber)), offset, 4, 4));
        children.push_back(MakeField(context, "tcp.ack.raw", "Acknowledgment Number (raw)", "tcp.ack_raw", Decimal(ntohl(header->ackNumber)), offset, 8, 4));
        children.push_back(MakeBitField(context, "tcp.dataOffset", "Header Length", "tcp.hdr_len", ByteCount(layer.getHeaderLen()) + " (" + Decimal(header->dataOffset) + ")", offset + 12, 0, 4));
        children.push_back(MakeField(context, "tcp.flags", "Flags", "tcp.flags", TCPFlagsValueDisplay(header), offset, 12, 2, std::move(flagChildren)));
        children.push_back(MakeField(context, "tcp.window", "Window", "tcp.window_size_value", Decimal(ntohs(header->windowSize)), offset, 14, 2));
        children.push_back(MakeField(context, "tcp.checksum", "Checksum", "tcp.checksum", Hex16(ntohs(header->headerChecksum)), offset, 16, 2));
        children.push_back(MakeField(context, "tcp.urgentPointer", "Urgent Pointer", "tcp.urgent_pointer", Decimal(ntohs(header->urgentPointer)), offset, 18, 2));

        if (layer.getHeaderLen() > kTCPHeaderLength) {
            children.push_back(MakeNode("tcp.options",
                                        "Options",
                                        "tcp.options",
                                        ByteCount(layer.getHeaderLen() - kTCPHeaderLength),
                                        NodeKind::Field,
                                        MakeByteRange(offset + kTCPHeaderLength, layer.getHeaderLen() - kTCPHeaderLength),
                                        context.rawPacket,
                                        NodeSeverity::Normal,
                                        tcpOptions(context, layer, offset)));
        }

        return MakeLayer(context,
                         "tcp",
                         "TCP",
                         "tcp",
                         Decimal(layer.getSrcPort()) + " \342\206\222 " + Decimal(layer.getDstPort()) + " (" + TCPFlagsSummary(header) + ")",
                         offset,
                         layer.getHeaderLen(),
                         std::move(children));
    }

    std::vector<DetailNode> tcpOptions(const PacketDissectionContext& context, const pcpp::TcpLayer& layer, size_t layerOffset) const
    {
        std::vector<DetailNode> nodes;
        pcpp::TcpOption option = const_cast<pcpp::TcpLayer&>(layer).getFirstTcpOption();
        size_t index = 0;
        while (option.isNotNull() && index < 64) {
            ptrdiff_t relativeOffset = option.getRecordBasePtr() - layer.getData();
            if (relativeOffset >= 0) {
                std::string prefix = "tcp.option." + std::to_string(index);
                std::vector<DetailNode> children;
                children.push_back(MakeSyntheticField(prefix + ".kind", "Kind", "tcp.option_kind", Decimal(option.getType())));
                children.push_back(MakeSyntheticField(prefix + ".length", "Length", "tcp.option_len", Decimal(option.getTotalSize())));
                nodes.push_back(MakeNode(prefix,
                                         TCPOptionName(option.getTcpOptionEnumType()),
                                         "tcp.option",
                                         TCPOptionValue(option),
                                         NodeKind::Field,
                                         MakeByteRange(layerOffset + static_cast<size_t>(relativeOffset), option.getTotalSize()),
                                         context.rawPacket,
                                         NodeSeverity::Normal,
                                         std::move(children)));
            }

            option = const_cast<pcpp::TcpLayer&>(layer).getNextTcpOption(option);
            index += 1;
        }
        return nodes;
    }

    DetailNode dissectUDP(const PacketDissectionContext& context, const pcpp::UdpLayer& layer, size_t offset) const
    {
        auto* header = layer.getUdpHeader();
        uint16_t udpLength = ntohs(header->length);
        uint16_t payloadLength = udpLength >= kUDPHeaderLength ? udpLength - kUDPHeaderLength : 0;

        std::vector<DetailNode> children;
        uint32_t streamID = pcpp::hash5Tuple(const_cast<pcpp::Packet*>(&context.packet), false);
        if (streamID != 0) {
            children.push_back(MakeSyntheticField("udp.streamID", "Stream ID", "udp.stream", Decimal(streamID)));
        }
        children.push_back(MakeField(context, "udp.srcPort", "Source Port", "udp.srcport", Decimal(layer.getSrcPort()), offset, 0, 2));
        children.push_back(MakeField(context, "udp.dstPort", "Destination Port", "udp.dstport", Decimal(layer.getDstPort()), offset, 2, 2));
        children.push_back(MakeField(context, "udp.length", "Length", "udp.length", Decimal(udpLength), offset, 4, 2));
        children.push_back(MakeField(context, "udp.payloadLength", "Payload Length", "udp.payload_length", ByteCount(payloadLength), offset, 4, 2));
        children.push_back(MakeField(context, "udp.checksum", "Checksum", "udp.checksum", Hex16(ntohs(header->headerChecksum)), offset, 6, 2));
        children.push_back(MakeSyntheticField("udp.checksum.status", "Checksum Status", "udp.checksum.status", UDPChecksumStatus(layer)));
        children.push_back(MakeSyntheticField("udp.checksum.calculated", "Calculated Checksum", "udp.checksum.calculated", Hex16(const_cast<pcpp::UdpLayer&>(layer).calculateChecksum(false))));
        return MakeLayer(context,
                         "udp",
                         "UDP",
                         "udp",
                         Decimal(layer.getSrcPort()) + " \342\206\222 " + Decimal(layer.getDstPort()),
                         offset,
                         layer.getHeaderLen(),
                         std::move(children));
    }

    DetailNode dissectICMPv4(const PacketDissectionContext& context, const pcpp::IcmpLayer& layer, size_t offset) const
    {
        auto* header = layer.getIcmpHeader();
        uint8_t type = header->type;
        std::vector<DetailNode> children;
        children.push_back(MakeField(context, "icmp.type", "Type", "icmp.type", ICMPv4TypeName(type) + " (" + Decimal(type) + ")", offset, 0, 1));
        children.push_back(MakeField(context, "icmp.code", "Code", "icmp.code", Decimal(header->code), offset, 1, 1));
        children.push_back(MakeField(context, "icmp.checksum", "Checksum", "icmp.checksum", Hex16(ntohs(header->checksum)), offset, 2, 2));

        if ((type == pcpp::ICMP_ECHO_REQUEST || type == pcpp::ICMP_ECHO_REPLY) && layer.getDataLen() >= kICMPEchoHeaderLength) {
            children.push_back(MakeField(context, "icmp.identifier", "Identifier", "icmp.ident", Decimal(ReadBE16(layer.getData() + 4)), offset, 4, 2));
            children.push_back(MakeField(context, "icmp.sequence", "Sequence Number", "icmp.seq", Decimal(ReadBE16(layer.getData() + 6)), offset, 6, 2));
        }

        return MakeLayer(context,
                         "icmp",
                         "ICMP",
                         "icmp",
                         ICMPv4TypeName(type),
                         offset,
                         std::max(layer.getDataLen(), kICMPHeaderLength),
                         std::move(children));
    }

    DetailNode dissectICMPv6(const PacketDissectionContext& context, const pcpp::Layer& layer, size_t offset) const
    {
        const uint8_t* data = layer.getData();
        uint8_t type = layer.getDataLen() > 0 ? data[0] : 0;
        uint8_t code = layer.getDataLen() > 1 ? data[1] : 0;
        uint16_t checksum = layer.getDataLen() >= kICMPHeaderLength ? ReadBE16(data + 2) : 0;
        std::vector<DetailNode> children;
        children.push_back(MakeField(context, "icmpv6.type", "Type", "icmpv6.type", ICMPv6TypeName(type) + " (" + Decimal(type) + ")", offset, 0, 1));
        children.push_back(MakeField(context, "icmpv6.code", "Code", "icmpv6.code", Decimal(code), offset, 1, 1));
        children.push_back(MakeField(context, "icmpv6.checksum", "Checksum", "icmpv6.checksum", Hex16(checksum), offset, 2, 2));

        if ((type == 128 || type == 129) && layer.getDataLen() >= kICMPEchoHeaderLength) {
            children.push_back(MakeField(context, "icmpv6.identifier", "Identifier", "icmpv6.echo.identifier", Decimal(ReadBE16(data + 4)), offset, 4, 2));
            children.push_back(MakeField(context, "icmpv6.sequence", "Sequence Number", "icmpv6.echo.sequence_number", Decimal(ReadBE16(data + 6)), offset, 6, 2));
        }

        return MakeLayer(context,
                         "icmpv6",
                         "ICMPv6",
                         "icmpv6",
                         ICMPv6TypeName(type),
                         offset,
                         std::max(layer.getDataLen(), kICMPHeaderLength),
                         std::move(children));
    }
};

// Phase 2 dissector lets optional Spicy adapters override native fallback parsers.
class PhaseTwoDissector final : public ProtocolDissector {
public:
    explicit PhaseTwoDissector(const std::vector<std::unique_ptr<SpicyParserAdapter>>& spicyAdapters)
        : spicyAdapters_(spicyAdapters)
    {}

    std::optional<DetailNode> dissectLayer(const PacketDissectionContext& context, const pcpp::Layer& layer) const override
    {
        const size_t offset = LayerOffset(layer, context.rawPacket);
        switch (layer.getProtocol()) {
            case pcpp::DNS:
                if (auto node = spicyNode(context, SpicyProtocol::DNS, "TCPViewer::DNS", layer, offset)) {
                    return node;
                }
                return dissectDNS(context, static_cast<const pcpp::DnsLayer&>(layer), offset);
            case pcpp::SSL:
                if (auto node = spicyNode(context, SpicyProtocol::TLS, "TCPViewer::TLS", layer, offset)) {
                    return node;
                }
                return dissectTLS(context, static_cast<const pcpp::SSLLayer&>(layer), offset);
            case pcpp::HTTPRequest:
            case pcpp::HTTPResponse:
                if (auto node = spicyNode(context, SpicyProtocol::HTTP1, "TCPViewer::HTTP1", layer, offset)) {
                    return node;
                }
                return dissectHTTP(context, layer, offset);
            case pcpp::GenericPayload:
                if (auto websocket = dissectWebSocket(context, static_cast<const pcpp::PayloadLayer&>(layer), offset)) {
                    return websocket;
                }
                return dissectPayload(context, static_cast<const pcpp::PayloadLayer&>(layer), offset);
            default:
                return std::nullopt;
        }
    }

private:
    const std::vector<std::unique_ptr<SpicyParserAdapter>>& spicyAdapters_;

    std::optional<DetailNode> spicyNode(const PacketDissectionContext& context,
                                        SpicyProtocol protocol,
                                        const std::string& parserName,
                                        const pcpp::Layer& layer,
                                        size_t offset) const
    {
        // Generated Spicy parsers emit the same native tree model as built-in parsers.
        for (const auto& adapter : spicyAdapters_) {
            if (adapter == nullptr || !adapter->supports(protocol)) {
                continue;
            }

            SpicyParseInput input{protocol, parserName, layer.getData(), layer.getDataLen(), offset};
            std::vector<DetailNode> nodes = adapter->parse(input);
            if (nodes.empty()) {
                continue;
            }
            if (nodes.size() == 1) {
                return std::move(nodes.front());
            }

            return MakeLayer(context,
                             "spicy." + parserName,
                             parserName,
                             "spicy",
                             "Parsed by Spicy",
                             offset,
                             layer.getHeaderLen(),
                             std::move(nodes));
        }

        return std::nullopt;
    }

    DetailNode dnsFlagsNode(const PacketDissectionContext& context, uint16_t flags, size_t headerOffset) const
    {
        std::vector<DetailNode> flagChildren;
        flagChildren.push_back(MakeBitFieldRange(context,
                                                 "dns.flags.response",
                                                 "Query/Response",
                                                 "dns.flags.response",
                                                 (flags & 0x8000) ? "Response" : "Query",
                                                 headerOffset + 2,
                                                 2,
                                                 0,
                                                 1));
        const uint16_t opcode = static_cast<uint16_t>((flags >> 11) & 0x0f);
        flagChildren.push_back(MakeBitFieldRange(context,
                                                 "dns.flags.opcode",
                                                 "Opcode",
                                                 "dns.flags.opcode",
                                                 DNSOpcodeName(opcode) + " (" + Decimal(opcode) + ")",
                                                 headerOffset + 2,
                                                 2,
                                                 1,
                                                 4));
        flagChildren.push_back(MakeBitFieldRange(context, "dns.flags.authoritative", "Authoritative", "dns.flags.authoritative", SetStatus(flags & 0x0400), headerOffset + 2, 2, 5, 1));
        flagChildren.push_back(MakeBitFieldRange(context, "dns.flags.truncated", "Truncated", "dns.flags.truncated", SetStatus(flags & 0x0200), headerOffset + 2, 2, 6, 1));
        flagChildren.push_back(MakeBitFieldRange(context, "dns.flags.recursionDesired", "Recursion Desired", "dns.flags.recursion_desired", SetStatus(flags & 0x0100), headerOffset + 2, 2, 7, 1));
        flagChildren.push_back(MakeBitFieldRange(context, "dns.flags.recursionAvailable", "Recursion Available", "dns.flags.recursion_available", SetStatus(flags & 0x0080), headerOffset + 2, 2, 8, 1));
        flagChildren.push_back(MakeBitFieldRange(context, "dns.flags.authenticData", "Authentic Data", "dns.flags.authentic_data", SetStatus(flags & 0x0020), headerOffset + 2, 2, 10, 1));
        flagChildren.push_back(MakeBitFieldRange(context, "dns.flags.checkingDisabled", "Checking Disabled", "dns.flags.checking_disabled", SetStatus(flags & 0x0010), headerOffset + 2, 2, 11, 1));
        const uint16_t responseCode = static_cast<uint16_t>(flags & 0x0f);
        flagChildren.push_back(MakeBitFieldRange(context,
                                                 "dns.flags.rcode",
                                                 "Response Code",
                                                 "dns.flags.rcode",
                                                 DNSResponseCodeName(responseCode) + " (" + Decimal(responseCode) + ")",
                                                 headerOffset + 2,
                                                 2,
                                                 12,
                                                 4));

        return MakeNode("dns.flags",
                        "Flags",
                        "dns.flags",
                        Hex16(flags),
                        NodeKind::Field,
                        MakeByteRange(headerOffset + 2, 2),
                        context.rawPacket,
                        NodeSeverity::Normal,
                        std::move(flagChildren));
    }

    DetailNode dnsQueryNode(const PacketDissectionContext& context, const pcpp::DnsQuery& query, size_t layerOffset, size_t index) const
    {
        const size_t recordOffset = query.getNameOffset();
        const size_t recordLength = query.getSize();
        const size_t nameLength = recordLength >= 4 ? recordLength - 4 : 0;
        const std::string identifier = "dns.query." + std::to_string(index);

        std::vector<DetailNode> children;
        children.push_back(MakeField(context, identifier + ".name", "Name", "dns.qry.name", query.getName(), layerOffset, recordOffset, nameLength));
        children.push_back(MakeField(context, identifier + ".type", "Type", "dns.qry.type", DNSRecordTypeValue(query.getDnsType()), layerOffset, recordOffset + nameLength, 2));
        children.push_back(MakeField(context, identifier + ".class", "Class", "dns.qry.class", DNSClassValue(query.getDnsClass()), layerOffset, recordOffset + nameLength + 2, 2));

        return MakeNode(identifier,
                        "Query: " + query.getName(),
                        "dns.query",
                        DNSRecordTypeValue(query.getDnsType()),
                        NodeKind::Field,
                        MakeByteRange(layerOffset + recordOffset, recordLength),
                        context.rawPacket,
                        NodeSeverity::Normal,
                        std::move(children));
    }

    void appendDNSQueries(const PacketDissectionContext& context,
                          const pcpp::DnsLayer& layer,
                          size_t layerOffset,
                          std::vector<DetailNode>& children) const
    {
        std::vector<DetailNode> queryNodes;
        pcpp::DnsQuery* query = layer.getFirstQuery();
        size_t index = 0;
        while (query != nullptr && index < 256) {
            queryNodes.push_back(dnsQueryNode(context, *query, layerOffset, index));
            query = layer.getNextQuery(query);
            index += 1;
        }

        if (queryNodes.empty()) {
            return;
        }

        DetailNode node = MakeSyntheticField("dns.queries", "Queries", "dns.queries", Decimal(queryNodes.size()));
        node.children = std::move(queryNodes);
        children.push_back(std::move(node));
    }

    DetailNode dnsResourceNode(const PacketDissectionContext& context,
                               const pcpp::DnsResource& resource,
                               pcpp::DnsResourceType resourceType,
                               size_t layerOffset,
                               size_t index) const
    {
        const size_t recordOffset = resource.getNameOffset();
        const size_t recordLength = resource.getSize();
        const size_t dataOffset = resource.getDataOffset();
        const size_t dataLength = resource.getDataLength();
        const size_t fixedFieldsLength = 10;
        const size_t nameLength = dataOffset >= recordOffset + fixedFieldsLength ? dataOffset - recordOffset - fixedFieldsLength : 0;
        const std::string identifier = "dns." + DNSResourceSectionIdentifier(resourceType) + "." + std::to_string(index);

        std::vector<DetailNode> children;
        children.push_back(MakeField(context, identifier + ".name", "Name", "dns.resp.name", resource.getName(), layerOffset, recordOffset, nameLength));
        children.push_back(MakeField(context, identifier + ".type", "Type", "dns.resp.type", DNSRecordTypeValue(resource.getDnsType()), layerOffset, recordOffset + nameLength, 2));
        children.push_back(MakeField(context, identifier + ".class", "Class", "dns.resp.class", DNSClassValue(resource.getDnsClass()), layerOffset, recordOffset + nameLength + 2, 2));
        children.push_back(MakeField(context, identifier + ".ttl", "Time to Live", "dns.resp.ttl", Decimal(resource.getTTL()), layerOffset, recordOffset + nameLength + 4, 4));
        children.push_back(MakeField(context, identifier + ".dataLength", "Data Length", "dns.resp.len", Decimal(dataLength), layerOffset, recordOffset + nameLength + 8, 2));

        std::string dataValue = DNSResourceDataValue(resource);
        if (!dataValue.empty()) {
            children.push_back(MakeField(context, identifier + ".data", "Data", "dns.resp.data", dataValue, layerOffset, dataOffset, dataLength));
        }

        return MakeNode(identifier,
                        DNSResourceRecordName(resourceType) + ": " + resource.getName(),
                        "dns.resource",
                        dataValue.empty() ? DNSRecordTypeValue(resource.getDnsType()) : dataValue,
                        NodeKind::Field,
                        MakeByteRange(layerOffset + recordOffset, recordLength),
                        context.rawPacket,
                        NodeSeverity::Normal,
                        std::move(children));
    }

    void appendDNSResources(const PacketDissectionContext& context,
                            const pcpp::DnsLayer& layer,
                            pcpp::DnsResourceType resourceType,
                            std::string identifier,
                            std::string name,
                            size_t layerOffset,
                            std::vector<DetailNode>& children) const
    {
        auto& mutableLayer = const_cast<pcpp::DnsLayer&>(layer);
        std::vector<DetailNode> resourceNodes;
        pcpp::DnsResource* resource = FirstDNSResource(mutableLayer, resourceType);
        size_t index = 0;
        while (resource != nullptr && index < 512) {
            resourceNodes.push_back(dnsResourceNode(context, *resource, resourceType, layerOffset, index));
            resource = NextDNSResource(mutableLayer, resource, resourceType);
            index += 1;
        }

        if (resourceNodes.empty()) {
            return;
        }

        DetailNode node = MakeSyntheticField(std::move(identifier), std::move(name), "dns.resources", Decimal(resourceNodes.size()));
        node.children = std::move(resourceNodes);
        children.push_back(std::move(node));
    }

    DetailNode dissectDNS(const PacketDissectionContext& context, const pcpp::DnsLayer& layer, size_t offset) const
    {
        const size_t headerOffset = DNSHeaderOffset(layer, offset);
        const size_t headerRelativeOffset = headerOffset - offset;
        const uint8_t* data = layer.getData();
        const size_t dataLength = layer.getDataLen();
        const bool hasHeader = dataLength >= headerRelativeOffset + sizeof(pcpp::dnshdr);
        const uint16_t transactionID = hasHeader ? ReadBE16(data + headerRelativeOffset) : 0;
        const uint16_t flags = hasHeader ? ReadBE16(data + headerRelativeOffset + 2) : 0;
        const uint16_t questions = hasHeader ? ReadBE16(data + headerRelativeOffset + 4) : 0;
        const uint16_t answers = hasHeader ? ReadBE16(data + headerRelativeOffset + 6) : 0;
        const uint16_t authorities = hasHeader ? ReadBE16(data + headerRelativeOffset + 8) : 0;
        const uint16_t additional = hasHeader ? ReadBE16(data + headerRelativeOffset + 10) : 0;

        std::vector<DetailNode> children;
        if (!hasHeader) {
            children.push_back(MakeWarning("dns.malformed", "DNS header is truncated"));
        }
        children.push_back(MakeField(context, "dns.id", "Transaction ID", "dns.id", Hex16(transactionID), headerOffset, 0, 2));
        children.push_back(dnsFlagsNode(context, flags, headerOffset));
        children.push_back(MakeField(context, "dns.count.queries", "Questions", "dns.count.queries", Decimal(questions), headerOffset, 4, 2));
        children.push_back(MakeField(context, "dns.count.answers", "Answer RRs", "dns.count.answers", Decimal(answers), headerOffset, 6, 2));
        children.push_back(MakeField(context, "dns.count.authorities", "Authority RRs", "dns.count.auth_rr", Decimal(authorities), headerOffset, 8, 2));
        children.push_back(MakeField(context, "dns.count.additional", "Additional RRs", "dns.count.add_rr", Decimal(additional), headerOffset, 10, 2));

        appendDNSQueries(context, layer, offset, children);
        appendDNSResources(context, layer, pcpp::DnsAnswerType, "dns.answers", "Answers", offset, children);
        appendDNSResources(context, layer, pcpp::DnsAuthorityType, "dns.authorities", "Authoritative nameservers", offset, children);
        appendDNSResources(context, layer, pcpp::DnsAdditionalType, "dns.additional", "Additional records", offset, children);

        return MakeLayer(context, "dns", "Domain Name System", "dns", layer.toString(), offset, layer.getHeaderLen(), std::move(children));
    }

    void appendTLSHandshakeMetadata(const PacketDissectionContext& context,
                                    const pcpp::SSLHandshakeMessage& message,
                                    size_t messageOffset,
                                    size_t messageLength,
                                    const std::string& identifier,
                                    std::vector<DetailNode>& children) const
    {
        if (auto* clientHello = dynamic_cast<const pcpp::SSLClientHelloMessage*>(&message)) {
            if (messageLength >= sizeof(pcpp::ssl_tls_client_server_hello)) {
                children.push_back(MakeField(context,
                                             identifier + ".handshakeVersion",
                                             "Handshake Version",
                                             "tls.handshake.version",
                                             TLSVersionFieldValue(clientHello->getHandshakeVersion()),
                                             messageOffset,
                                             4,
                                             2));
            }

            if (auto* sniExtension = clientHello->getExtensionOfType<pcpp::SSLServerNameIndicationExtension>()) {
                std::string hostName = sniExtension->getHostName();
                if (!hostName.empty()) {
                    children.push_back(MakeSyntheticField(identifier + ".sni", "Server Name Indication", "tls.handshake.extensions_server_name", hostName));
                }
            }
            children.push_back(MakeSyntheticField(identifier + ".cipherSuiteCount", "Cipher Suites", "tls.handshake.ciphersuites", Decimal(clientHello->getCipherSuiteCount())));
            children.push_back(MakeSyntheticField(identifier + ".extensionCount", "Extensions", "tls.handshake.extensions", Decimal(clientHello->getExtensionCount())));
            std::string supportedVersions = TLSSupportedVersionsSummary(clientHello->getExtensionOfType<pcpp::SSLSupportedVersionsExtension>());
            if (!supportedVersions.empty()) {
                children.push_back(MakeSyntheticField(identifier + ".supportedVersions", "Supported Versions", "tls.handshake.extensions.supported_versions", supportedVersions));
            }
            return;
        }

        if (auto* serverHello = dynamic_cast<const pcpp::SSLServerHelloMessage*>(&message)) {
            if (messageLength >= sizeof(pcpp::ssl_tls_client_server_hello)) {
                children.push_back(MakeField(context,
                                             identifier + ".handshakeVersion",
                                             "Handshake Version",
                                             "tls.handshake.version",
                                             TLSVersionFieldValue(serverHello->getHandshakeVersion()),
                                             messageOffset,
                                             4,
                                             2));
            }

            bool isValid = false;
            uint16_t cipherSuiteID = serverHello->getCipherSuiteID(isValid);
            if (isValid) {
                children.push_back(MakeSyntheticField(identifier + ".cipherSuite", "Cipher Suite", "tls.handshake.ciphersuite", TLSCipherSuiteFieldValue(cipherSuiteID, serverHello->getCipherSuite())));
            }
            children.push_back(MakeSyntheticField(identifier + ".extensionCount", "Extensions", "tls.handshake.extensions", Decimal(serverHello->getExtensionCount())));
            std::string supportedVersions = TLSSupportedVersionsSummary(serverHello->getExtensionOfType<pcpp::SSLSupportedVersionsExtension>());
            if (!supportedVersions.empty()) {
                children.push_back(MakeSyntheticField(identifier + ".supportedVersions", "Supported Versions", "tls.handshake.extensions.supported_versions", supportedVersions));
            }
            return;
        }

        if (auto* certificate = dynamic_cast<const pcpp::SSLCertificateMessage*>(&message)) {
            children.push_back(MakeSyntheticField(identifier + ".certificateCount", "Certificates", "tls.handshake.certificates", Decimal(certificate->getNumOfCertificates())));
        }
    }

    void appendTLSHandshake(const PacketDissectionContext& context,
                            const pcpp::SSLHandshakeLayer& layer,
                            size_t offset,
                            const std::string& identifier,
                            std::vector<DetailNode>& children) const
    {
        children.push_back(MakeSyntheticField(identifier + ".handshake.count", "Handshake Message Count", "tls.handshake.count", Decimal(layer.getHandshakeMessagesCount())));

        size_t messageRelativeOffset = sizeof(pcpp::ssl_tls_record_layer);
        const size_t layerLength = layer.getHeaderLen();
        for (int index = 0; index < static_cast<int>(layer.getHandshakeMessagesCount()); index += 1) {
            auto* message = layer.getHandshakeMessageAt(index);
            if (message == nullptr || messageRelativeOffset >= layerLength) {
                break;
            }

            const size_t messageLength = std::min(message->getMessageLength(), layerLength - messageRelativeOffset);
            if (messageLength == 0) {
                break;
            }

            const size_t messageOffset = offset + messageRelativeOffset;
            const uint8_t* messageData = layer.getData() + messageRelativeOffset;
            const std::string messageIdentifier = identifier + ".handshake." + std::to_string(index);
            const pcpp::SSLHandshakeType handshakeType = message->getHandshakeType();
            std::vector<DetailNode> messageChildren;
            messageChildren.push_back(MakeField(context,
                                                messageIdentifier + ".type",
                                                "Handshake Type",
                                                "tls.handshake.type",
                                                TLSHandshakeTypeFieldValue(handshakeType),
                                                messageOffset,
                                                0,
                                                1));
            messageChildren.push_back(MakeField(context,
                                                messageIdentifier + ".length",
                                                "Length",
                                                "tls.handshake.length",
                                                ByteCount(TLSHandshakeDeclaredPayloadLength(messageData, messageLength)),
                                                messageOffset,
                                                1,
                                                3));
            messageChildren.push_back(MakeSyntheticField(messageIdentifier + ".complete", "Complete", "tls.handshake.complete", message->isMessageComplete() ? "Yes" : "No"));

            appendTLSHandshakeMetadata(context, *message, messageOffset, messageLength, messageIdentifier, messageChildren);
            children.push_back(MakeNode(messageIdentifier,
                                        "Handshake Protocol: " + TLSHandshakeTypeName(handshakeType),
                                        "tls.handshake",
                                        message->toString(),
                                        NodeKind::Field,
                                        MakeByteRange(messageOffset, messageLength),
                                        context.rawPacket,
                                        NodeSeverity::Normal,
                                        std::move(messageChildren)));
            messageRelativeOffset += messageLength;
        }
    }

    void appendTLSApplicationData(const PacketDissectionContext& context,
                                  const pcpp::SSLApplicationDataLayer& layer,
                                  size_t offset,
                                  const std::string& identifier,
                                  std::vector<DetailNode>& children) const
    {
        const size_t encryptedDataLength = layer.getEncryptedDataLen();
        const size_t encryptedDataOffset = offset + sizeof(pcpp::ssl_tls_record_layer);
        children.push_back(MakeField(context,
                                     identifier + ".encryptedData",
                                     "Encrypted Application Data",
                                     "tls.app_data",
                                     ByteCount(encryptedDataLength),
                                     encryptedDataOffset,
                                     0,
                                     encryptedDataLength));
        children.push_back(MakeField(context,
                                     identifier + ".encryptedDataPreview",
                                     "Encrypted Data Preview",
                                     "tls.app_data.preview",
                                     PayloadPreview(layer.getEncryptedData(), encryptedDataLength),
                                     encryptedDataOffset,
                                     0,
                                     encryptedDataLength));
    }

    void appendTLSAlert(const PacketDissectionContext& context,
                        const pcpp::SSLAlertLayer& layer,
                        size_t offset,
                        const std::string& identifier,
                        std::vector<DetailNode>& children) const
    {
        if (layer.getHeaderLen() > sizeof(pcpp::ssl_tls_record_layer)) {
            const auto alertLevel = layer.getAlertLevel();
            children.push_back(MakeField(context,
                                         identifier + ".alert.level",
                                         "Alert Level",
                                         "tls.alert_message.level",
                                         TLSAlertLevelName(alertLevel) + " (" + Decimal(static_cast<unsigned>(alertLevel)) + ")",
                                         offset,
                                         sizeof(pcpp::ssl_tls_record_layer),
                                         1));
        }

        if (layer.getHeaderLen() > sizeof(pcpp::ssl_tls_record_layer) + 1) {
            auto& mutableLayer = const_cast<pcpp::SSLAlertLayer&>(layer);
            const auto alertDescription = mutableLayer.getAlertDescription();
            children.push_back(MakeField(context,
                                         identifier + ".alert.description",
                                         "Alert Description",
                                         "tls.alert_message.desc",
                                         TLSAlertDescriptionName(alertDescription) + " (" + Decimal(static_cast<unsigned>(alertDescription)) + ")",
                                         offset,
                                         sizeof(pcpp::ssl_tls_record_layer) + 1,
                                         1));
        }
    }

    void appendTLSChangeCipherSpec(const PacketDissectionContext& context,
                                   const pcpp::SSLChangeCipherSpecLayer& layer,
                                   size_t offset,
                                   const std::string& identifier,
                                   std::vector<DetailNode>& children) const
    {
        if (layer.getHeaderLen() <= sizeof(pcpp::ssl_tls_record_layer)) {
            return;
        }

        children.push_back(MakeField(context,
                                     identifier + ".changeCipherSpec",
                                     "Change Cipher Spec",
                                     "tls.change_cipher_spec",
                                     Decimal(layer.getData()[sizeof(pcpp::ssl_tls_record_layer)]),
                                     offset,
                                     sizeof(pcpp::ssl_tls_record_layer),
                                     1));
    }

    DetailNode dissectTLS(const PacketDissectionContext& context, const pcpp::SSLLayer& layer, size_t offset) const
    {
        const std::string identifier = "tls." + std::to_string(offset);
        const pcpp::SSLRecordType recordType = layer.getRecordType();
        const uint16_t recordLength = layer.getDataLen() >= sizeof(pcpp::ssl_tls_record_layer) ? ReadBE16(layer.getData() + 3) : 0;

        std::vector<DetailNode> children;
        children.push_back(MakeField(context, identifier + ".contentType", "Content Type", "tls.record.content_type", TLSRecordTypeFieldValue(recordType), offset, 0, 1));
        children.push_back(MakeField(context, identifier + ".version", "Version", "tls.record.version", TLSVersionFieldValue(layer.getRecordVersion()), offset, 1, 2));
        children.push_back(MakeField(context, identifier + ".length", "Length", "tls.record.length", ByteCount(recordLength), offset, 3, 2));

        if (auto* handshakeLayer = dynamic_cast<const pcpp::SSLHandshakeLayer*>(&layer)) {
            appendTLSHandshake(context, *handshakeLayer, offset, identifier, children);
        } else if (auto* applicationDataLayer = dynamic_cast<const pcpp::SSLApplicationDataLayer*>(&layer)) {
            appendTLSApplicationData(context, *applicationDataLayer, offset, identifier, children);
        } else if (auto* alertLayer = dynamic_cast<const pcpp::SSLAlertLayer*>(&layer)) {
            appendTLSAlert(context, *alertLayer, offset, identifier, children);
        } else if (auto* changeCipherSpecLayer = dynamic_cast<const pcpp::SSLChangeCipherSpecLayer*>(&layer)) {
            appendTLSChangeCipherSpec(context, *changeCipherSpecLayer, offset, identifier, children);
        }

        return MakeLayer(context,
                         identifier,
                         "Transport Layer Security",
                         "tls",
                         TLSLayerName(layer) + ", " + TLSRecordTypeName(recordType),
                         offset,
                         layer.getHeaderLen(),
                         std::move(children));
    }

    std::string httpHeaderFieldName(const std::string& name) const
    {
        const std::string lower = Lowercase(name);
        if (lower == "host") return "http.host";
        if (lower == "user-agent") return "http.user_agent";
        if (lower == "connection") return "http.connection";
        if (lower == "upgrade") return "http.upgrade";
        if (lower == "content-length") return "http.content_length";
        if (lower == "content-type") return "http.content_type";
        if (lower == "sec-websocket-key") return "http.sec_websocket_key";
        if (lower == "sec-websocket-accept") return "http.sec_websocket_accept";
        if (lower == "sec-websocket-version") return "http.sec_websocket_version";
        if (lower == "sec-websocket-protocol") return "http.sec_websocket_protocol";
        return "http.header";
    }

    void appendHTTPHeaders(const PacketDissectionContext& context,
                           const uint8_t* data,
                           const std::vector<std::pair<size_t, size_t>>& lines,
                           size_t layerOffset,
                           const std::string& identifier,
                           std::vector<DetailNode>& children) const
    {
        std::vector<DetailNode> headerNodes;
        for (size_t lineIndex = 1; lineIndex < lines.size(); lineIndex += 1) {
            const size_t lineStart = lines[lineIndex].first;
            const size_t lineEnd = lines[lineIndex].second;
            const size_t contentLength = LineContentLength(data, lineStart, lineEnd);
            auto* colon = static_cast<const uint8_t*>(std::memchr(data + lineStart, ':', contentLength));
            if (colon == nullptr) {
                headerNodes.push_back(MakeWarning(identifier + ".header." + std::to_string(lineIndex - 1) + ".malformed", "HTTP header line has no ':' separator"));
                continue;
            }

            const size_t colonOffset = static_cast<size_t>(colon - data);
            size_t valueStart = colonOffset + 1;
            while (valueStart < lineStart + contentLength && (data[valueStart] == ' ' || data[valueStart] == '\t')) {
                valueStart += 1;
            }

            std::string name = TrimHTTPWhitespace(StringFromBytes(data + lineStart, colonOffset - lineStart));
            std::string value = TrimHTTPWhitespace(StringFromBytes(data + valueStart, lineStart + contentLength - valueStart));
            const std::string headerIdentifier = identifier + ".header." + std::to_string(headerNodes.size());
            std::vector<DetailNode> headerChildren;
            headerChildren.push_back(MakeField(context, headerIdentifier + ".name", "Name", "http.header.name", name, layerOffset, lineStart, colonOffset - lineStart));
            headerChildren.push_back(MakeField(context, headerIdentifier + ".value", "Value", httpHeaderFieldName(name), value, layerOffset, valueStart, lineStart + contentLength - valueStart));
            headerNodes.push_back(MakeNode(headerIdentifier,
                                           "Header: " + name,
                                           httpHeaderFieldName(name),
                                           value,
                                           NodeKind::Field,
                                           MakeByteRange(layerOffset + lineStart, lineEnd - lineStart),
                                           context.rawPacket,
                                           NodeSeverity::Normal,
                                           std::move(headerChildren)));
        }

        children.push_back(MakeSyntheticField(identifier + ".header.count", "Header Count", "http.header.count", Decimal(headerNodes.size())));
        DetailNode headers = MakeSyntheticField(identifier + ".headers", "Headers", "http.headers", Decimal(headerNodes.size()));
        headers.children = std::move(headerNodes);
        children.push_back(std::move(headers));
    }

    DetailNode dissectHTTP(const PacketDissectionContext& context, const pcpp::Layer& layer, size_t offset) const
    {
        const uint8_t* data = layer.getData();
        const size_t dataLength = layer.getDataLen();
        const auto headerEnd = FindHTTPHeaderEnd(data, dataLength);
        const size_t headerLength = headerEnd.value_or(std::min(layer.getHeaderLen(), dataLength));
        const bool isRequest = layer.getProtocol() == pcpp::HTTPRequest;
        const std::string identifier = isRequest ? "http.request." + std::to_string(offset) : "http.response." + std::to_string(offset);
        const std::string title = isRequest ? "HTTP Request" : "HTTP Response";
        std::vector<DetailNode> children;

        std::vector<std::pair<size_t, size_t>> lines = HTTPLines(data, headerLength);
        if (lines.empty()) {
            children.push_back(MakeWarning(identifier + ".malformed", "HTTP first line is missing"));
        } else {
            const size_t firstLineStart = lines.front().first;
            const size_t firstLineEnd = lines.front().second;
            const size_t firstLineLength = LineContentLength(data, firstLineStart, firstLineEnd);
            const std::string firstLine = StringFromBytes(data + firstLineStart, firstLineLength);
            std::vector<DetailNode> firstLineChildren;
            auto firstSpace = firstLine.find(' ');
            auto secondSpace = firstSpace == std::string::npos ? std::string::npos : firstLine.find(' ', firstSpace + 1);

            if (isRequest) {
                if (firstSpace != std::string::npos) {
                    firstLineChildren.push_back(MakeField(context, identifier + ".method", "Method", "http.request.method", firstLine.substr(0, firstSpace), offset, 0, firstSpace));
                }
                if (firstSpace != std::string::npos && secondSpace != std::string::npos) {
                    firstLineChildren.push_back(MakeField(context, identifier + ".uri", "Request URI", "http.request.uri", firstLine.substr(firstSpace + 1, secondSpace - firstSpace - 1), offset, firstSpace + 1, secondSpace - firstSpace - 1));
                    firstLineChildren.push_back(MakeField(context, identifier + ".version", "Version", "http.request.version", firstLine.substr(secondSpace + 1), offset, secondSpace + 1, firstLineLength - secondSpace - 1));
                }
            } else {
                if (firstSpace != std::string::npos) {
                    firstLineChildren.push_back(MakeField(context, identifier + ".version", "Version", "http.response.version", firstLine.substr(0, firstSpace), offset, 0, firstSpace));
                }
                if (firstSpace != std::string::npos && secondSpace != std::string::npos) {
                    firstLineChildren.push_back(MakeField(context, identifier + ".code", "Status Code", "http.response.code", firstLine.substr(firstSpace + 1, secondSpace - firstSpace - 1), offset, firstSpace + 1, secondSpace - firstSpace - 1));
                    firstLineChildren.push_back(MakeField(context, identifier + ".phrase", "Reason Phrase", "http.response.phrase", firstLine.substr(secondSpace + 1), offset, secondSpace + 1, firstLineLength - secondSpace - 1));
                }
            }

            children.push_back(MakeNode(identifier + ".firstLine",
                                        isRequest ? "Request Line" : "Status Line",
                                        isRequest ? "http.request.line" : "http.response.line",
                                        firstLine,
                                        NodeKind::Field,
                                        MakeByteRange(offset + firstLineStart, firstLineEnd - firstLineStart),
                                        context.rawPacket,
                                        NodeSeverity::Normal,
                                        std::move(firstLineChildren)));
        }

        appendHTTPHeaders(context, data, lines, offset, identifier, children);
        const auto* message = dynamic_cast<const pcpp::HttpMessage*>(&layer);
        const bool headerComplete = message != nullptr ? message->isHeaderComplete() : headerEnd.has_value();
        children.push_back(MakeSyntheticField(identifier + ".header.complete", "Header Complete", "http.header.complete", headerComplete ? "Yes" : "No"));
        if (!headerComplete) {
            children.push_back(MakeWarning(identifier + ".incomplete", "HTTP header is truncated or spread across packets"));
        }

        return MakeLayer(context, identifier, title, "http", layer.toString(), offset, headerLength, std::move(children));
    }

    std::optional<DetailNode> dissectWebSocket(const PacketDissectionContext& context, const pcpp::PayloadLayer& layer, size_t offset) const
    {
        // Without stream state, only parse clear single-frame payloads on known HTTP ports.
        if (!IsHTTPPort(layer) || layer.getPayloadLen() < 2) {
            return std::nullopt;
        }

        const uint8_t* data = layer.getPayload();
        const size_t dataLength = layer.getPayloadLen();
        const uint8_t firstByte = data[0];
        const uint8_t secondByte = data[1];
        const uint8_t opcode = static_cast<uint8_t>(firstByte & 0x0f);
        if (!IsValidWebSocketOpcode(opcode)) {
            return std::nullopt;
        }

        const bool fin = (firstByte & 0x80) != 0;
        const bool rsv1 = (firstByte & 0x40) != 0;
        const bool rsv2 = (firstByte & 0x20) != 0;
        const bool rsv3 = (firstByte & 0x10) != 0;
        const bool masked = (secondByte & 0x80) != 0;
        const uint8_t lengthCode = static_cast<uint8_t>(secondByte & 0x7f);
        size_t headerLength = 2;
        size_t declaredPayloadLength = lengthCode;
        std::vector<DetailNode> children;
        const std::string identifier = "websocket." + std::to_string(offset);

        children.push_back(MakeBitField(context, identifier + ".fin", "Fin", "websocket.fin", SetStatus(fin), offset, 0, 1));
        children.push_back(MakeBitField(context, identifier + ".rsv1", "RSV1", "websocket.rsv1", SetStatus(rsv1), offset, 1, 1));
        children.push_back(MakeBitField(context, identifier + ".rsv2", "RSV2", "websocket.rsv2", SetStatus(rsv2), offset, 2, 1));
        children.push_back(MakeBitField(context, identifier + ".rsv3", "RSV3", "websocket.rsv3", SetStatus(rsv3), offset, 3, 1));
        children.push_back(MakeBitField(context, identifier + ".opcode", "Opcode", "websocket.opcode", WebSocketOpcodeName(opcode) + " (" + Decimal(opcode) + ")", offset, 4, 4));
        children.push_back(MakeBitField(context, identifier + ".mask", "Mask", "websocket.mask", SetStatus(masked), offset + 1, 0, 1));
        children.push_back(MakeBitField(context,
                                        identifier + ".payloadLength",
                                        "Payload Length",
                                        "websocket.payload_length",
                                        lengthCode <= 125 ? Decimal(lengthCode) : Decimal(lengthCode) + " (extended)",
                                        offset + 1,
                                        1,
                                        7));

        if (lengthCode == 126) {
            if (dataLength < headerLength + 2) {
                children.push_back(MakeWarning(identifier + ".malformed", "WebSocket extended 16-bit length is truncated"));
            } else {
                declaredPayloadLength = ReadBE16(data + headerLength);
                children.push_back(MakeField(context, identifier + ".extendedPayloadLength", "Extended Payload Length", "websocket.payload_length_ext", Decimal(declaredPayloadLength), offset, headerLength, 2));
            }
            headerLength += 2;
        } else if (lengthCode == 127) {
            if (dataLength < headerLength + 8) {
                children.push_back(MakeWarning(identifier + ".malformed", "WebSocket extended 64-bit length is truncated"));
            } else {
                uint64_t length64 = ReadBE64(data + headerLength);
                if (length64 > static_cast<uint64_t>(std::numeric_limits<size_t>::max())) {
                    children.push_back(MakeWarning(identifier + ".malformed.length", "WebSocket payload length exceeds this platform's size_t"));
                    declaredPayloadLength = 0;
                } else {
                    declaredPayloadLength = static_cast<size_t>(length64);
                }
                children.push_back(MakeField(context, identifier + ".extendedPayloadLength", "Extended Payload Length", "websocket.payload_length_ext", Decimal(length64), offset, headerLength, 8));
            }
            headerLength += 8;
        }

        if (masked) {
            if (dataLength < headerLength + 4) {
                children.push_back(MakeWarning(identifier + ".malformed.mask", "WebSocket masking key is truncated"));
            } else {
                children.push_back(MakeField(context, identifier + ".maskingKey", "Masking Key", "websocket.masking_key", RawValue(context.rawPacket, offset + headerLength, 4), offset, headerLength, 4));
            }
            headerLength += 4;
        }

        if (rsv1 || rsv2 || rsv3) {
            children.push_back(MakeWarning(identifier + ".reserved", "WebSocket RSV bits are set without negotiated extension context"));
        }

        const size_t availablePayload = dataLength > headerLength ? dataLength - headerLength : 0;
        if (availablePayload < declaredPayloadLength) {
            children.push_back(MakeWarning(identifier + ".truncated", "WebSocket payload is shorter than the declared length"));
        }

        const size_t emittedPayloadLength = std::min(availablePayload, declaredPayloadLength);
        if (emittedPayloadLength > 0) {
            children.push_back(MakeField(context,
                                         identifier + ".payload",
                                         "Payload Data",
                                         "websocket.payload",
                                         PayloadPreview(data + headerLength, emittedPayloadLength),
                                         offset,
                                         headerLength,
                                         emittedPayloadLength));
        }

        const size_t rootLength = std::min(dataLength, headerLength + emittedPayloadLength);
        return MakeLayer(context,
                         identifier,
                         "WebSocket",
                         "websocket",
                         WebSocketOpcodeName(opcode) + ", " + ByteCount(declaredPayloadLength),
                         offset,
                         rootLength,
                         std::move(children));
    }

    DetailNode dissectPayload(const PacketDissectionContext& context, const pcpp::PayloadLayer& layer, size_t offset) const
    {
        std::vector<DetailNode> children;
        children.push_back(MakeField(context, "payload.length", "Length", "data.len", ByteCount(layer.getPayloadLen()), offset, 0, layer.getPayloadLen()));
        children.push_back(MakeField(context, "payload.preview", "Preview", "data.data", PayloadPreview(layer.getPayload(), layer.getPayloadLen()), offset, 0, layer.getPayloadLen()));
        return MakeLayer(context, "payload", "Payload", "data", ByteCount(layer.getPayloadLen()), offset, layer.getPayloadLen(), std::move(children));
    }
};

}  // namespace

void ProtocolDissectorRegistry::add(std::vector<std::unique_ptr<ProtocolDissector>> dissectors)
{
    for (auto& dissector : dissectors) {
        dissectors_.push_back(std::move(dissector));
    }
}

std::optional<DetailNode> ProtocolDissectorRegistry::dissectLayer(const PacketDissectionContext& context, const pcpp::Layer& layer) const
{
    for (const auto& dissector : dissectors_) {
        auto node = dissector->dissectLayer(context, layer);
        if (node.has_value()) {
            return node;
        }
    }

    return std::nullopt;
}

PacketDissectionEngine::PacketDissectionEngine()
    : PacketDissectionEngine(std::vector<std::unique_ptr<SpicyParserAdapter>>())
{}

PacketDissectionEngine::PacketDissectionEngine(std::vector<std::unique_ptr<SpicyParserAdapter>> spicyAdapters)
    : spicyAdapters_(std::move(spicyAdapters))
{
    std::vector<std::unique_ptr<ProtocolDissector>> dissectors;
    dissectors.push_back(std::make_unique<PhaseOneDissector>());
    dissectors.push_back(std::make_unique<PhaseTwoDissector>(spicyAdapters_));
    registry_.add(std::move(dissectors));
}

DissectionResult PacketDissectionEngine::dissect(const PacketDissectionContext& context) const
{
    DissectionResult result;
    result.nodes.push_back(dissectFrame(context));
    for (pcpp::Layer* layer = context.packet.getFirstLayer(); layer != nullptr; layer = layer->getNextLayer()) {
        auto node = dissectLayer(context, *layer);
        if (node.has_value()) {
            result.nodes.push_back(std::move(*node));
        }
    }
    return result;
}

DetailNode PacketDissectionEngine::dissectFrame(const PacketDissectionContext& context) const
{
    std::vector<DetailNode> children;
    children.push_back(MakeSyntheticField("frame.number", "Frame Number", "frame.number", Decimal(context.packetIdentifier)));
    children.push_back(MakeSyntheticField("frame.arrival", "Arrival Time", "frame.time", TimestampValue(context.rawPacket.getPacketTimeStamp())));
    children.push_back(MakeSyntheticField("frame.length", "Frame Length", "frame.len", ByteCount(context.rawPacket.getFrameLength())));
    children.push_back(MakeSyntheticField("frame.captureLength", "Captured Length", "frame.cap_len", ByteCount(context.rawPacket.getRawDataLen())));
    if (context.interfaceName.has_value()) {
        children.push_back(MakeSyntheticField("frame.interface", "Interface", "frame.interface_name", *context.interfaceName));
    }
    if (context.packetComment.has_value()) {
        children.push_back(MakeSyntheticField("frame.comment", "Packet Comment", "frame.comment", *context.packetComment));
    }

    return MakeLayer(context,
                     "frame",
                     "Frame",
                     "frame",
                     "Packet " + Decimal(context.packetIdentifier) + ": " + ByteCount(context.rawPacket.getFrameLength()) +
                         " on wire (" + ByteCount(context.rawPacket.getRawDataLen()) + " captured)",
                     0,
                     static_cast<size_t>(std::max(context.rawPacket.getRawDataLen(), 0)),
                     std::move(children));
}

std::optional<DetailNode> PacketDissectionEngine::dissectLayer(const PacketDissectionContext& context, const pcpp::Layer& layer) const
{
    return registry_.dissectLayer(context, layer);
}

}  // namespace tcpviewer::dissection
