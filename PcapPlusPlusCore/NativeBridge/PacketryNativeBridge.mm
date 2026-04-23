#import "PacketryNativeBridge.h"

#include <algorithm>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

#include <pcapplusplus/ArpLayer.h>
#include <pcapplusplus/BgpLayer.h>
#include <pcapplusplus/DnsLayer.h>
#include <pcapplusplus/EthLayer.h>
#include <pcapplusplus/HttpLayer.h>
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
#include <pcapplusplus/SSLLayer.h>
#include <pcapplusplus/TcpLayer.h>
#include <pcapplusplus/UdpLayer.h>

static NSString *const PacketryNativeErrorDomain = @"com.proxyman.Packetry.NativeBridge";

typedef NS_ENUM(NSInteger, PacketryNativeErrorCode) {
    PacketryNativeErrorCodeInterfaceDiscoveryFailed = 1000,
    PacketryNativeErrorCodeUnsupportedInterface = 1001,
    PacketryNativeErrorCodeOpenFailed = 1002,
    PacketryNativeErrorCodeCaptureStartFailed = 1003,
    PacketryNativeErrorCodeCapturePauseFailed = 1004,
    PacketryNativeErrorCodeCaptureResumeFailed = 1005,
    PacketryNativeErrorCodeCaptureStopFailed = 1006,
    PacketryNativeErrorCodeFileReadFailed = 1007,
    PacketryNativeErrorCodeFileWriteFailed = 1008,
    PacketryNativeErrorCodeInvalidOptions = 1009,
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

NSError *MakeError(PacketryNativeErrorCode code, NSString *description)
{
    return [NSError errorWithDomain:PacketryNativeErrorDomain
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

NSString *LayerName(const pcpp::Layer &layer)
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
            return @"TLS";
        case pcpp::GenericPayload:
            return @"Payload";
        default:
            return MakeNSString(layer.toString());
    }
}

NSArray<PCPPNativePacketLayerDescriptor *> *MapLayers(const pcpp::Packet &packet)
{
    NSMutableArray<PCPPNativePacketLayerDescriptor *> *layers = [NSMutableArray array];
    for (pcpp::Layer *layer = packet.getFirstLayer(); layer != nullptr; layer = layer->getNextLayer()) {
        NSString *detailSummary = MakeNSString(layer->toString());
        [layers addObject:[[PCPPNativePacketLayerDescriptor alloc] initWithName:LayerName(*layer)
                                                                  detailSummary:detailSummary]];
    }
    return layers;
}

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
        return {PCPPNativeDecodeStatusKindPartial, @"Packet parsing stopped at an opaque payload layer."};
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

PCPPNativePacketSummaryDescriptor *MakePacketSummary(const pcpp::RawPacket &rawPacket,
                                                     unsigned long long identifier,
                                                     NSString * _Nullable interfaceIdentifier,
                                                     NSString * _Nullable interfaceName,
                                                     NSString * _Nullable packetComment)
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
                                                                  infoSummary:InfoSummaryForPacket(packet, rawPacket)
                                                                       layers:MapLayers(packet)
                                                                 decodeStatus:decodeDescriptor
                                                              captureMetadata:captureMetadata];
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
                                                                  infoSummary:@"Packet decoding failed."
                                                                       layers:@[]
                                                                 decodeStatus:decodeDescriptor
                                                              captureMetadata:captureMetadata];
    }
}

struct StoredPacket {
    std::unique_ptr<pcpp::RawPacket> rawPacket;
    std::string packetComment;
};

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
            if (!writer->open("macOS", "", "Packetry", "Packetry live capture")) {
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
    std::vector<StoredPacket> packets;
    NSString *statusMessage = @"Live capture is ready.";
    PCPPNativeLiveSessionPhase phase = PCPPNativeLiveSessionPhaseReady;
    CaptureFileWriter writer_;
};

void UpdateStats(LiveCaptureState &state)
{
    pcpp::IPcapDevice::PcapStats stats{};
    if (state.device != nullptr) {
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
                        infoSummary:(NSString *)infoSummary
                             layers:(NSArray<PCPPNativePacketLayerDescriptor *> *)layers
                       decodeStatus:(PCPPNativeDecodeStatusDescriptor *)decodeStatus
                    captureMetadata:(PCPPNativePacketCaptureMetadataDescriptor *)captureMetadata
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
        _infoSummary = [infoSummary copy];
        _layers = [layers copy];
        _decodeStatus = decodeStatus;
        _captureMetadata = captureMetadata;
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

@interface PCPPNativeLiveSession () {
@private
    std::unique_ptr<LiveCaptureState> _state;
}

@end

@implementation PCPPNativeLiveSession

static void OnLivePacketArrives(pcpp::RawPacket *rawPacket, pcpp::PcapLiveDevice *, void *userCookie)
{
    auto *session = (__bridge PCPPNativeLiveSession *)userCookie;
    std::lock_guard<std::mutex> lock(session->_state->mutex);

    auto clonedPacket = std::unique_ptr<pcpp::RawPacket>(rawPacket->clone());
    session->_state->packetsObserved += 1;
    session->_state->packets.push_back({std::move(clonedPacket), ""});

    auto *summary = MakePacketSummary(*session->_state->packets.back().rawPacket,
                                      session->_state->nextPacketIdentifier,
                                      session->_state->interfaceIdentifier_,
                                      session->_state->device == nullptr ? nil : MakeNSString(session->_state->device->getName()),
                                      nil);
    session->_state->nextPacketIdentifier += 1;

    try {
        session->_state->writer_.writePacket(*session->_state->packets.back().rawPacket, nil);
    } catch (const std::exception &exception) {
        if (session.errorHandler != nil) {
            session.errorHandler(MakeError(PacketryNativeErrorCodeFileWriteFailed, MakeNSString(exception.what())));
        }
    }

    session->_state->statusMessage = @"Capturing live packets.";
    if (session.packetHandler != nil) {
        session.packetHandler(@[summary]);
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
            *error = MakeError(PacketryNativeErrorCodeUnsupportedInterface, MakeNSString(exception.what()));
        }
        return nil;
    }

    if (_state->device == nullptr) {
        if (error != nullptr) {
            *error = MakeError(PacketryNativeErrorCodeUnsupportedInterface, @"The selected capture interface could not be found.");
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
                *error = MakeError(PacketryNativeErrorCodeUnsupportedInterface, @"No native device is associated with this session.");
            }
            return NO;
        }

        if (_state->device->captureActive()) {
            return YES;
        }

        if (_state->phase == PCPPNativeLiveSessionPhaseStopped) {
            _state->packets.clear();
            _state->packetsObserved = 0;
            _state->packetsReceived = 0;
            _state->packetsDropped = 0;
            _state->packetsDroppedByInterface = 0;
            _state->nextPacketIdentifier = 1;
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
                *error = MakeError(PacketryNativeErrorCodeOpenFailed, @"Packetry could not open the selected interface for capture.");
            }
            _state->phase = PCPPNativeLiveSessionPhaseFailed;
            _state->statusMessage = @"Failed to open the live capture interface.";
            return NO;
        }

        if (!_state->device->startCapture(OnLivePacketArrives, (__bridge void *)self, 1, OnLiveStatsUpdate, (__bridge void *)self)) {
            if (error != nullptr) {
                *error = MakeError(PacketryNativeErrorCodeCaptureStartFailed, @"Packetry could not start packet capture on the selected interface.");
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
            *error = MakeError(PacketryNativeErrorCodeCaptureStartFailed, MakeNSString(exception.what()));
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
                *error = MakeError(PacketryNativeErrorCodeCapturePauseFailed, @"Live capture is not currently running.");
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
            *error = MakeError(PacketryNativeErrorCodeCaptureResumeFailed, @"Live capture must be paused before it can resume.");
        }
        return NO;
    }

    if (!_state->device->startCapture(OnLivePacketArrives, (__bridge void *)self, 1, OnLiveStatsUpdate, (__bridge void *)self)) {
        if (error != nullptr) {
            *error = MakeError(PacketryNativeErrorCodeCaptureResumeFailed, @"Packetry could not resume live capture on the selected interface.");
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
            *error = MakeError(PacketryNativeErrorCodeCaptureStopFailed, MakeNSString(exception.what()));
        }
        return NO;
    }
}

- (void)dealloc
{
    NSError *error = nil;
    [self stopAndReturnError:&error];
}

@end

namespace {

struct OfflineDocumentState {
    explicit OfflineDocumentState(NSURL *fileURL) : currentURL(fileURL) {}

    NSURL *currentURL = nil;
    std::vector<StoredPacket> packets;
    std::string format;
    std::string operatingSystem;
    std::string hardware;
    std::string captureApplication;
    std::string fileComment;
    bool dirty = false;
};

std::string NormalizedFormatForURL(NSURL *url)
{
    NSString *extension = url.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"pcapng"]) {
        return "pcapng";
    }

    return "pcap";
}

PCPPNativeCaptureDocumentMetadataDescriptor *MakeMetadata(const OfflineDocumentState &state)
{
    return [[PCPPNativeCaptureDocumentMetadataDescriptor alloc] initWithFormat:MakeNSString(state.format)
                                                               operatingSystem:NullableNSString(state.operatingSystem)
                                                                      hardware:NullableNSString(state.hardware)
                                                            captureApplication:NullableNSString(state.captureApplication)
                                                                   fileComment:NullableNSString(state.fileComment)];
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
        *error = MakeError(PacketryNativeErrorCodeFileWriteFailed, @"Packetry could not prepare the destination directory for saving.");
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
                *error = MakeError(PacketryNativeErrorCodeFileWriteFailed, @"Packetry could not replace the destination capture file.");
            }
            return false;
        }

        return true;
    }

    if (![fileManager moveItemAtURL:temporaryURL toURL:targetURL error:&replaceError]) {
        RemoveTemporaryItem(temporaryURL);
        if (error != nullptr) {
            *error = MakeError(PacketryNativeErrorCodeFileWriteFailed, @"Packetry could not move the saved capture into place.");
        }
        return false;
    }

    return true;
}

NSArray<PCPPNativePacketSummaryDescriptor *> *LoadPacketsFromURL(OfflineDocumentState &state, NSError **error)
{
    state.packets.clear();
    state.format = NormalizedFormatForURL(state.currentURL);
    state.operatingSystem.clear();
    state.hardware.clear();
    state.captureApplication.clear();
    state.fileComment.clear();

    auto reader = std::unique_ptr<pcpp::IFileReaderDevice>(pcpp::IFileReaderDevice::getReader(MakeStdString(state.currentURL.path)));
    if (reader == nullptr) {
        if (error != nullptr) {
            *error = MakeError(PacketryNativeErrorCodeFileReadFailed, @"Packetry could not determine a file reader for this capture.");
        }
        return nil;
    }

    if (!reader->open()) {
        if (error != nullptr) {
            *error = MakeError(PacketryNativeErrorCodeFileReadFailed, @"Packetry could not open the requested capture file.");
        }
        return nil;
    }

    if (auto *pcapngReader = dynamic_cast<pcpp::PcapNgFileReaderDevice *>(reader.get())) {
        state.operatingSystem = pcapngReader->getOS();
        state.hardware = pcapngReader->getHardware();
        state.captureApplication = pcapngReader->getCaptureApplication();
        state.fileComment = pcapngReader->getCaptureFileComment();
    }

    NSMutableArray<PCPPNativePacketSummaryDescriptor *> *packets = [NSMutableArray array];
    unsigned long long identifier = 1;
    while (true) {
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

        state.packets.push_back({std::make_unique<pcpp::RawPacket>(rawPacket), packetComment});
        [packets addObject:MakePacketSummary(*state.packets.back().rawPacket,
                                             identifier,
                                             nil,
                                             nil,
                                             NullableNSString(packetComment))];
        identifier += 1;
    }

    reader->close();
    state.dirty = false;
    return packets;
}

bool SavePacketsToURL(const OfflineDocumentState &state, NSURL *targetURL, const std::string &format, NSError **error)
{
    if (state.packets.empty()) {
        if (error != nullptr) {
            *error = MakeError(PacketryNativeErrorCodeFileWriteFailed, @"There are no packets loaded to save.");
        }
        return false;
    }

    if (!EnsureParentDirectoryExists(targetURL, error)) {
        return false;
    }

    NSURL *temporaryURL = TemporarySaveURL(targetURL);
    RemoveTemporaryItem(temporaryURL);

    if (format == "pcapng") {
        pcpp::PcapNgFileWriterDevice writer(MakeStdString(temporaryURL.path));
        if (!writer.open(state.operatingSystem, state.hardware, state.captureApplication, state.fileComment)) {
            RemoveTemporaryItem(temporaryURL);
            if (error != nullptr) {
                *error = MakeError(PacketryNativeErrorCodeFileWriteFailed, @"Packetry could not open the pcapng destination for writing.");
            }
            return false;
        }

        for (const auto &packet : state.packets) {
            if (!writer.writePacket(*packet.rawPacket, packet.packetComment)) {
                if (error != nullptr) {
                    *error = MakeError(PacketryNativeErrorCodeFileWriteFailed, @"Packetry could not write all packets into the pcapng destination.");
                }
                writer.close();
                RemoveTemporaryItem(temporaryURL);
                return false;
            }
        }

        writer.close();
        return ReplaceSavedFile(temporaryURL, targetURL, error);
    }

    pcpp::PcapFileWriterDevice writer(MakeStdString(temporaryURL.path), state.packets.front().rawPacket->getLinkLayerType());
    if (!writer.open()) {
        RemoveTemporaryItem(temporaryURL);
        if (error != nullptr) {
            *error = MakeError(PacketryNativeErrorCodeFileWriteFailed, @"Packetry could not open the pcap destination for writing.");
        }
        return false;
    }

    for (const auto &packet : state.packets) {
        if (!writer.writePacket(*packet.rawPacket)) {
            if (error != nullptr) {
                *error = MakeError(PacketryNativeErrorCodeFileWriteFailed, @"Packetry could not write all packets into the pcap destination.");
            }
            writer.close();
            RemoveTemporaryItem(temporaryURL);
            return false;
        }
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
            *error = MakeError(PacketryNativeErrorCodeFileReadFailed, @"A capture URL is required.");
        }
        return nil;
    }

    _state = std::make_unique<OfflineDocumentState>(url);
    return self;
}

- (NSURL *)currentURL
{
    return _state->currentURL;
}

- (NSString *)currentFormat
{
    return MakeNSString(_state->format);
}

- (PCPPNativeCaptureDocumentMetadataDescriptor *)documentMetadata
{
    return MakeMetadata(*_state);
}

- (BOOL)dirty
{
    return _state->dirty;
}

- (NSArray<PCPPNativePacketSummaryDescriptor *> *)openAndReturnError:(NSError **)error
{
    return LoadPacketsFromURL(*_state, error);
}

- (NSArray<PCPPNativePacketSummaryDescriptor *> *)reopenAndReturnError:(NSError **)error
{
    return LoadPacketsFromURL(*_state, error);
}

- (BOOL)saveAndReturnError:(NSError **)error
{
    if (!SavePacketsToURL(*_state, _state->currentURL, _state->format, error)) {
        return NO;
    }

    _state->dirty = false;
    return YES;
}

- (BOOL)saveToURL:(NSURL *)url format:(NSString *)format error:(NSError **)error
{
    std::string normalizedFormat = MakeStdString(format);
    if (normalizedFormat.empty()) {
        normalizedFormat = NormalizedFormatForURL(url);
    }

    if (!SavePacketsToURL(*_state, url, normalizedFormat, error)) {
        return NO;
    }

    _state->currentURL = url;
    _state->format = normalizedFormat;
    if (normalizedFormat != "pcapng") {
        _state->operatingSystem.clear();
        _state->hardware.clear();
        _state->captureApplication.clear();
        _state->fileComment.clear();
    }
    _state->dirty = false;
    return YES;
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
                availabilityReason = @"Packetry keeps this system interface out of the normal capture picker by default.";
            } else if (!supportsLink) {
                availability = PCPPNativeInterfaceAvailabilityUnsupported;
                availabilityReason = @"Packetry does not support this interface link type yet.";
            } else {
                try {
                    if (!device->isOpened()) {
                        pcpp::PcapLiveDevice::DeviceMode mode = loopback ? pcpp::PcapLiveDevice::Normal : pcpp::PcapLiveDevice::Promiscuous;
                        pcpp::PcapLiveDevice::DeviceConfiguration configuration(mode, 1, 0, pcpp::PcapLiveDevice::PCPP_INOUT, 65535);
                        if (!device->open(configuration)) {
                            availability = PCPPNativeInterfaceAvailabilityUnavailable;
                            availabilityReason = @"Packetry could not open this interface with the current macOS capture access.";
                            canCapture = false;
                        } else {
                            device->close();
                        }
                    }
                } catch (const std::exception &) {
                    availability = PCPPNativeInterfaceAvailabilityUnavailable;
                    availabilityReason = @"Packetry could not verify capture readiness for this interface.";
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
                                                                   supportsPromiscuousMode:!loopback && supportsLink
                                                                requiresBPFPermissionSetup:YES
                                                                       providesMacOSMetadata:providesMacOSMetadata];
            [interfaces addObject:descriptor];
        }
    } catch (const std::exception &exception) {
        if (error != nullptr) {
            *error = MakeError(PacketryNativeErrorCodeInterfaceDiscoveryFailed, MakeNSString(exception.what()));
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
                                                                         message:@"Packetry could not compile this capture filter with libpcap syntax."];
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
