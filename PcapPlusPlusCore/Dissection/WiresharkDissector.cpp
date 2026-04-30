#include "WiresharkDissector.hpp"

#include <algorithm>
#include <cstring>
#include <iomanip>
#include <limits>
#include <mutex>
#include <optional>
#include <sstream>
#include <unordered_set>
#include <utility>

#include <pcapplusplus/RawPacket.h>

#if defined(TCPVIEWER_HAS_WIRESHARK) && TCPVIEWER_HAS_WIRESHARK
#include <glib.h>

#include <epan/epan.h>
#include <epan/epan_dissect.h>
#include <epan/frame_data_sequence.h>
#include <epan/proto.h>
#include <wiretap/pcap-encap.h>
#include <wiretap/wtap.h>
#include <wiretap/wtap_opttypes.h>
#include <wsutil/buffer.h>

struct packet_provider_data {
    wtap* wth = nullptr;
    const frame_data* ref = nullptr;
    frame_data* prev_dis = nullptr;
    frame_data* prev_cap = nullptr;
    frame_data_sequence* frames = nullptr;
    GTree* frames_modified_blocks = nullptr;
    std::string interfaceName;
};
#endif

namespace tcpviewer::dissection {
namespace {

constexpr const char* kBackendNotLinkedReason =
    "Wireshark libwireshark backend is not linked in this build. Run scripts/bootstrap-wireshark.sh, then enable "
    "TCPVIEWER_HAS_WIRESHARK=1 for PcapPlusPlusCore to use Wireshark protocol-tree dissection.";

DetailNode MakeUnavailableDetail(const std::string& reason)
{
    DetailNode node;
    node.id = "wireshark.status";
    node.title = "Wireshark Backend";
    node.fieldName = "tcpviewer.wireshark.status";
    node.displayValue = reason;
    node.kind = NodeKind::Field;
    node.severity = NodeSeverity::Info;
    return node;
}

#if defined(TCPVIEWER_HAS_WIRESHARK) && TCPVIEWER_HAS_WIRESHARK

constexpr uint32_t kUnknownFrameNumber = 0;

std::mutex& WiresharkAPIMutex()
{
    static std::mutex mutex;
    return mutex;
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

bool ContainsRange(const pcpp::RawPacket& rawPacket, size_t offset, size_t length)
{
    const auto capturedLength = static_cast<size_t>(std::max(rawPacket.getRawDataLen(), 0));
    return offset <= capturedLength && length <= capturedLength - offset;
}

const nstime_t* ProviderGetFrameTimestamp(packet_provider_data* provider, uint32_t frameNumber)
{
    if (provider == nullptr) {
        return nullptr;
    }

    const frame_data* frame = nullptr;
    if (provider->ref != nullptr && provider->ref->num == frameNumber) {
        frame = provider->ref;
    } else if (provider->prev_dis != nullptr && provider->prev_dis->num == frameNumber) {
        frame = provider->prev_dis;
    } else if (provider->prev_cap != nullptr && provider->prev_cap->num == frameNumber) {
        frame = provider->prev_cap;
    } else if (provider->frames != nullptr) {
        frame = frame_data_sequence_find(provider->frames, frameNumber);
    }

    return frame != nullptr && frame->has_ts ? &frame->abs_ts : nullptr;
}

const char* ProviderGetInterfaceName(packet_provider_data* provider, uint32_t, unsigned)
{
    if (provider == nullptr || provider->interfaceName.empty()) {
        return "unknown";
    }
    return provider->interfaceName.c_str();
}

const char* ProviderGetInterfaceDescription(packet_provider_data*, uint32_t, unsigned)
{
    return nullptr;
}

wtap_block_t ProviderGetModifiedBlock(packet_provider_data* provider, const frame_data* frame)
{
    if (provider == nullptr || provider->frames_modified_blocks == nullptr || frame == nullptr) {
        return nullptr;
    }
    return static_cast<wtap_block_t>(g_tree_lookup(provider->frames_modified_blocks, frame));
}

int32_t ProviderGetProcessID(packet_provider_data*, uint32_t, unsigned)
{
    return -1;
}

const char* ProviderGetProcessName(packet_provider_data*, uint32_t, unsigned)
{
    return nullptr;
}

const uint8_t* ProviderGetProcessUUID(packet_provider_data*, uint32_t, unsigned, size_t* uuidSize)
{
    if (uuidSize != nullptr) {
        *uuidSize = 0;
    }
    return nullptr;
}

const struct packet_provider_funcs kPacketProviderFuncs = {
    ProviderGetFrameTimestamp,
    ProviderGetInterfaceName,
    ProviderGetInterfaceDescription,
    ProviderGetModifiedBlock,
    ProviderGetProcessID,
    ProviderGetProcessName,
    ProviderGetProcessUUID,
};

class WiresharkRecord {
public:
    explicit WiresharkRecord(const PacketDissectionContext& context)
    {
        const int capturedLength = context.rawPacket.getRawDataLen();
        const int reportedLength = context.rawPacket.getFrameLength() > 0 ? context.rawPacket.getFrameLength() : capturedLength;
        const int wiretapEncap = wtap_pcap_encap_to_wtap_encap(static_cast<int>(context.rawPacket.getLinkLayerType()));

        if (capturedLength < 0 || reportedLength < capturedLength || context.rawPacket.getRawData() == nullptr) {
            failureReason_ = "Packet raw bytes are missing or have invalid lengths for Wireshark dissection.";
            return;
        }
        if (wiretapEncap == WTAP_ENCAP_UNKNOWN) {
            failureReason_ = "Wireshark does not support this packet link type.";
            return;
        }

        wtap_rec_init(&record_, static_cast<gsize>(capturedLength));
        initialized_ = true;
        wtap_setup_packet_rec(&record_, wiretapEncap);
        record_.presence_flags = WTAP_HAS_TS | WTAP_HAS_CAP_LEN | WTAP_HAS_INTERFACE_ID;
        record_.rec_header.packet_header.caplen = static_cast<uint32_t>(capturedLength);
        record_.rec_header.packet_header.len = static_cast<uint32_t>(reportedLength);
        record_.rec_header.packet_header.interface_id = 0;
        record_.section_number = 0;
        record_.tsprec = WTAP_TSPREC_NSEC;

        const timespec timestamp = context.rawPacket.getPacketTimeStamp();
        record_.ts.secs = timestamp.tv_sec;
        record_.ts.nsecs = static_cast<int>(timestamp.tv_nsec);
        record_.block = wtap_block_create(WTAP_BLOCK_PACKET);
        if (context.packetComment.has_value()) {
            wtap_block_add_string_option(record_.block, OPT_COMMENT, context.packetComment->c_str(), context.packetComment->size());
        }

        ws_buffer_clean(&record_.data);
        ws_buffer_assure_space(&record_.data, static_cast<size_t>(capturedLength));
        std::memcpy(ws_buffer_start_ptr(&record_.data), context.rawPacket.getRawData(), static_cast<size_t>(capturedLength));
        ws_buffer_increase_length(&record_.data, static_cast<size_t>(capturedLength));
    }

    ~WiresharkRecord()
    {
        if (initialized_) {
            wtap_rec_cleanup(&record_);
        }
    }

    WiresharkRecord(const WiresharkRecord&) = delete;
    WiresharkRecord& operator=(const WiresharkRecord&) = delete;

    bool isValid() const { return initialized_ && failureReason_.empty(); }
    const std::string& failureReason() const { return failureReason_; }
    wtap_rec* get() { return &record_; }

private:
    wtap_rec record_{};
    bool initialized_ = false;
    std::string failureReason_;
};

struct EpanDissectDeleter {
    void operator()(epan_dissect_t* dissect) const
    {
        if (dissect != nullptr) {
            epan_dissect_free(dissect);
        }
    }
};

using EpanDissectPtr = std::unique_ptr<epan_dissect_t, EpanDissectDeleter>;

uint32_t FrameNumberForContext(const PacketDissectionContext& context, uint64_t fallbackFrameNumber)
{
    if (context.packetIdentifier > 0 && context.packetIdentifier <= std::numeric_limits<uint32_t>::max()) {
        return static_cast<uint32_t>(context.packetIdentifier);
    }
    if (fallbackFrameNumber > 0 && fallbackFrameNumber <= std::numeric_limits<uint32_t>::max()) {
        return static_cast<uint32_t>(fallbackFrameNumber);
    }
    return kUnknownFrameNumber;
}

std::string TrimDisplayValue(std::string value)
{
    while (!value.empty() && (value.front() == ':' || value.front() == ',' || value.front() == ' ')) {
        value.erase(value.begin());
    }
    return value;
}

std::string LabelForField(const field_info* field, size_t& valueOffset)
{
    valueOffset = 0;
    if (field == nullptr) {
        return "";
    }

    if (field->rep != nullptr && field->rep->representation[0] != '\0') {
        valueOffset = field->rep->value_pos;
        return field->rep->representation;
    }

    char label[ITEM_LABEL_LENGTH] = {};
    proto_item_fill_label(field, label, &valueOffset);
    if (label[0] != '\0') {
        return label;
    }
    return field->hfinfo != nullptr && field->hfinfo->name != nullptr ? field->hfinfo->name : "";
}

std::optional<ByteRange> MakeBitRangeFromMask(size_t start, int length, uint64_t bitmask)
{
    if (bitmask == 0 || length <= 0) {
        return std::nullopt;
    }

    const int containerBits = std::min(length * 8, 64);
    int lowBitFromRight = 0;
    while (lowBitFromRight < containerBits && (bitmask & (uint64_t{1} << lowBitFromRight)) == 0) {
        lowBitFromRight += 1;
    }
    if (lowBitFromRight >= containerBits) {
        return std::nullopt;
    }

    int highBitFromRight = containerBits - 1;
    while (highBitFromRight >= lowBitFromRight && (bitmask & (uint64_t{1} << highBitFromRight)) == 0) {
        highBitFromRight -= 1;
    }

    const int bitLength = highBitFromRight - lowBitFromRight + 1;
    const int firstBitFromLeft = containerBits - 1 - highBitFromRight;
    const size_t byteDelta = static_cast<size_t>(firstBitFromLeft / 8);
    const uint8_t bitOffset = static_cast<uint8_t>(firstBitFromLeft % 8);
    const size_t byteLength = static_cast<size_t>((bitOffset + bitLength + 7) / 8);
    return ByteRange{start + byteDelta, byteLength, bitOffset, static_cast<uint8_t>(bitLength), true};
}

std::optional<ByteRange> MakeRangeForField(const field_info* field)
{
    if (field == nullptr || field->start < 0 || field->length <= 0) {
        return std::nullopt;
    }

    const auto offset = static_cast<size_t>(field->start);
    const auto length = static_cast<size_t>(field->length);
    const uint32_t explicitBitOffset = FI_GET_BITS_OFFSET(field);
    const uint32_t explicitBitLength = FI_GET_BITS_SIZE(field);
    if (explicitBitOffset != 0 || explicitBitLength != 0) {
        const uint32_t effectiveBitLength = explicitBitLength == 0 ? static_cast<uint32_t>(field->length * 8) : explicitBitLength;
        const size_t byteDelta = explicitBitOffset / 8;
        const uint8_t bitOffset = static_cast<uint8_t>(explicitBitOffset % 8);
        const size_t byteLength = static_cast<size_t>((bitOffset + effectiveBitLength + 7) / 8);
        return ByteRange{offset + byteDelta, byteLength, bitOffset, static_cast<uint8_t>(std::min(effectiveBitLength, uint32_t{63})), true};
    }

    if (field->hfinfo != nullptr) {
        if (auto bitRange = MakeBitRangeFromMask(offset, field->length, field->hfinfo->bitmask)) {
            return bitRange;
        }
    }

    return ByteRange{offset, length, 0, 0, false};
}

NodeSeverity SeverityForField(const field_info* field)
{
    if (field == nullptr) {
        return NodeSeverity::Normal;
    }

    const uint32_t severity = field->flags & PI_SEVERITY_MASK;
    if (severity >= PI_ERROR) {
        return NodeSeverity::Error;
    }
    if (severity >= PI_WARN) {
        return NodeSeverity::Warning;
    }
    if (severity >= PI_NOTE || FI_GET_FLAG(field, FI_GENERATED)) {
        return NodeSeverity::Info;
    }
    return NodeSeverity::Normal;
}

NodeKind KindForField(const field_info* field, NodeSeverity severity)
{
    if (severity == NodeSeverity::Warning || severity == NodeSeverity::Error) {
        return NodeKind::Warning;
    }
    if (field != nullptr && field->hfinfo != nullptr && field->hfinfo->type == FT_PROTOCOL) {
        return NodeKind::Layer;
    }
    return NodeKind::Field;
}

std::optional<DetailNode> MapProtoNode(proto_node* protoNode, const pcpp::RawPacket& rawPacket, uint64_t& sequence)
{
    // Copy Wireshark's transient proto_tree data into stable TCP Viewer nodes before epan frees the tree.
    field_info* field = PNODE_FINFO(protoNode);
    if (field == nullptr || field->hfinfo == nullptr || FI_GET_FLAG(field, FI_HIDDEN)) {
        return std::nullopt;
    }

    size_t valueOffset = 0;
    const std::string label = LabelForField(field, valueOffset);
    const header_field_info* header = field->hfinfo;
    DetailNode node;
    node.fieldName = header->abbrev != nullptr ? header->abbrev : "";
    node.title = header->name != nullptr ? header->name : label;
    node.displayValue = valueOffset < label.size() ? TrimDisplayValue(label.substr(valueOffset)) : "";
    if (node.displayValue.empty() && label != node.title) {
        node.displayValue = TrimDisplayValue(label);
    }
    node.id = node.fieldName.empty() ? "wireshark.node." + std::to_string(sequence) : node.fieldName + "." + std::to_string(sequence);
    sequence += 1;
    node.range = MakeRangeForField(field);
    node.severity = SeverityForField(field);
    node.kind = KindForField(field, node.severity);

    if (node.range.has_value() && ContainsRange(rawPacket, node.range->offset, node.range->length)) {
        node.rawValue = HexBytes(rawPacket.getRawData() + node.range->offset, node.range->length);
    } else if (node.range.has_value() && !FI_GET_FLAG(field, FI_GENERATED)) {
        node.severity = NodeSeverity::Error;
        node.kind = NodeKind::Warning;
    }

    for (proto_node* child = protoNode->first_child; child != nullptr; child = child->next) {
        if (auto childNode = MapProtoNode(child, rawPacket, sequence)) {
            node.children.push_back(std::move(*childNode));
        }
    }
    return node;
}

std::vector<DetailNode> MapProtoTree(proto_tree* tree, const pcpp::RawPacket& rawPacket)
{
    std::vector<DetailNode> nodes;
    uint64_t sequence = 1;
    if (tree == nullptr) {
        return nodes;
    }

    for (proto_node* child = tree->first_child; child != nullptr; child = child->next) {
        if (auto node = MapProtoNode(child, rawPacket, sequence)) {
            nodes.push_back(std::move(*node));
        }
    }
    return nodes;
}

#endif

}  // namespace

struct WiresharkDissectionSession::Impl {
    mutable std::mutex mutex;
    uint64_t observedPacketCount = 0;
    std::string unavailableReason = kBackendNotLinkedReason;
#if defined(TCPVIEWER_HAS_WIRESHARK) && TCPVIEWER_HAS_WIRESHARK
    packet_provider_data provider;
    epan_t* epan = nullptr;
    nstime_t elapsedTime = NSTIME_INIT_ZERO;
    uint32_t cumulativeBytes = 0;
    std::unordered_set<uint32_t> observedFrameNumbers;

    Impl()
    {
        auto& runtime = WiresharkRuntime::shared();
        unavailableReason = runtime.unavailableReason();
        if (!runtime.isAvailable()) {
            return;
        }

        std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
        provider.frames = new_frame_data_sequence();
        epan = epan_new(&provider, &kPacketProviderFuncs);
        if (epan == nullptr) {
            unavailableReason = "Wireshark session could not be created.";
        }
    }

    ~Impl()
    {
        std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
        if (epan != nullptr) {
            epan_free(epan);
            epan = nullptr;
        }
        if (provider.frames != nullptr) {
            free_frame_data_sequence(provider.frames);
            provider.frames = nullptr;
        }
        if (provider.frames_modified_blocks != nullptr) {
            g_tree_destroy(provider.frames_modified_blocks);
            provider.frames_modified_blocks = nullptr;
        }
    }

    bool hasSession() const
    {
        return epan != nullptr && provider.frames != nullptr;
    }

    bool observePacketLocked(const PacketDissectionContext& context)
    {
        // First pass feeds Wireshark's conversation/reassembly state before the UI asks for a detail tree.
        if (!hasSession()) {
            return false;
        }

        const uint32_t frameNumber = FrameNumberForContext(context, observedPacketCount + 1);
        if (frameNumber == kUnknownFrameNumber) {
            unavailableReason = "Wireshark requires a 32-bit frame number for dissection state.";
            return false;
        }
        if (observedFrameNumbers.find(frameNumber) != observedFrameNumbers.end()) {
            return true;
        }

        if (context.interfaceName.has_value()) {
            provider.interfaceName = *context.interfaceName;
        }

        WiresharkRecord record(context);
        if (!record.isValid()) {
            unavailableReason = record.failureReason();
            return false;
        }

        EpanDissectPtr dissect(epan_dissect_new(epan, false, false));
        if (!dissect) {
            unavailableReason = "Wireshark could not allocate a first-pass dissector.";
            return false;
        }

        frame_data frame{};
        frame_data_init(&frame, frameNumber, record.get(), cumulativeBytes, cumulativeBytes);
        frame_data_set_before_dissect(&frame, &elapsedTime, &provider.ref, provider.prev_dis);
        epan_dissect_run(dissect.get(), WTAP_FILE_TYPE_SUBTYPE_UNKNOWN, record.get(), &frame, nullptr);
        frame_data_set_after_dissect(&frame, &cumulativeBytes);

        provider.prev_cap = provider.prev_dis = frame_data_sequence_add(provider.frames, &frame);
        observedFrameNumbers.insert(frameNumber);
        observedPacketCount += 1;
        return true;
    }

    WiresharkDissectionResult dissectPacketLocked(const PacketDissectionContext& context)
    {
        // Second pass builds the visible proto_tree using the frame state captured during observePacketLocked().
        WiresharkDissectionResult result;
        if (!hasSession() && !observePacketLocked(context)) {
            result.fallbackReason = unavailableReason;
            result.nodes.push_back(MakeUnavailableDetail(result.fallbackReason));
            return result;
        }

        if (!observePacketLocked(context)) {
            result.fallbackReason = unavailableReason;
            result.nodes.push_back(MakeUnavailableDetail(result.fallbackReason));
            return result;
        }

        const uint32_t frameNumber = FrameNumberForContext(context, observedPacketCount);
        frame_data* frame = frameNumber == kUnknownFrameNumber ? nullptr : frame_data_sequence_find(provider.frames, frameNumber);
        if (frame == nullptr) {
            result.fallbackReason = "Wireshark first-pass frame state was not available for this packet.";
            result.nodes.push_back(MakeUnavailableDetail(result.fallbackReason));
            return result;
        }

        WiresharkRecord record(context);
        if (!record.isValid()) {
            result.fallbackReason = record.failureReason();
            result.nodes.push_back(MakeUnavailableDetail(result.fallbackReason));
            return result;
        }

        EpanDissectPtr dissect(epan_dissect_new(epan, true, true));
        if (!dissect) {
            result.fallbackReason = "Wireshark could not allocate a second-pass dissector.";
            result.nodes.push_back(MakeUnavailableDetail(result.fallbackReason));
            return result;
        }

        frame_data_set_before_dissect(frame, &elapsedTime, &provider.ref, provider.prev_dis);
        epan_dissect_run_with_taps(dissect.get(), WTAP_FILE_TYPE_SUBTYPE_UNKNOWN, record.get(), frame, nullptr);
        uint32_t secondPassCumulativeBytes = frame->cum_bytes >= frame->pkt_len ? frame->cum_bytes - frame->pkt_len : 0;
        frame_data_set_after_dissect(frame, &secondPassCumulativeBytes);

        result.nodes = MapProtoTree(dissect->tree, context.rawPacket);
        result.usedWireshark = !result.nodes.empty();
        if (!result.usedWireshark) {
            result.fallbackReason = "Wireshark protocol-tree dissection returned no nodes for this packet.";
            result.nodes.push_back(MakeUnavailableDetail(result.fallbackReason));
        }
        return result;
    }
#else
    Impl() = default;
    ~Impl() = default;
#endif
};

WiresharkRuntime& WiresharkRuntime::shared()
{
    // Function-local static keeps the libwireshark lifetime process-wide and deterministic.
    static WiresharkRuntime runtime;
    return runtime;
}

WiresharkRuntime::WiresharkRuntime()
{
#if defined(TCPVIEWER_HAS_WIRESHARK) && TCPVIEWER_HAS_WIRESHARK
    // libwireshark has process-wide registries, so runtime setup is deliberately one-time and serialized.
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    wtap_init(true);
    if (!epan_init(nullptr, nullptr, true)) {
        available_ = false;
        unavailableReason_ = "Wireshark protocol registry failed to initialize.";
        wtap_cleanup();
        return;
    }
    epan_load_settings();
    available_ = true;
    unavailableReason_.clear();
#else
    available_ = false;
    unavailableReason_ = kBackendNotLinkedReason;
#endif
}

WiresharkRuntime::~WiresharkRuntime()
{
#if defined(TCPVIEWER_HAS_WIRESHARK) && TCPVIEWER_HAS_WIRESHARK
    if (available_) {
        std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
        epan_cleanup();
        wtap_cleanup();
    }
#endif
}

bool WiresharkRuntime::isAvailable() const
{
    return available_;
}

std::string WiresharkRuntime::unavailableReason() const
{
    return unavailableReason_;
}

WiresharkDissectionSession::WiresharkDissectionSession()
    : impl_(std::make_unique<Impl>())
{
}

WiresharkDissectionSession::~WiresharkDissectionSession() = default;

WiresharkDissectionSession::WiresharkDissectionSession(WiresharkDissectionSession&&) noexcept = default;

WiresharkDissectionSession& WiresharkDissectionSession::operator=(WiresharkDissectionSession&&) noexcept = default;

bool WiresharkDissectionSession::observePacket(const PacketDissectionContext& context)
{
    auto& runtime = WiresharkRuntime::shared();
#if defined(TCPVIEWER_HAS_WIRESHARK) && TCPVIEWER_HAS_WIRESHARK
    if (runtime.isAvailable()) {
        std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
        std::lock_guard<std::mutex> sessionLock(impl_->mutex);
        return impl_->observePacketLocked(context);
    }
#else
    (void)context;
#endif
    std::lock_guard<std::mutex> sessionLock(impl_->mutex);
    // Count packets in fallback builds so live/offline plumbing remains observable and testable.
    impl_->observedPacketCount += 1;
    impl_->unavailableReason = runtime.unavailableReason();
    return false;
}

uint64_t WiresharkDissectionSession::observedPacketCount() const
{
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->observedPacketCount;
}

std::string WiresharkDissectionSession::unavailableReason() const
{
    std::lock_guard<std::mutex> lock(impl_->mutex);
    return impl_->unavailableReason;
}

WiresharkPacketDissector::WiresharkPacketDissector(WiresharkDissectionSession* session)
    : session_(session)
{
}

WiresharkDissectionResult WiresharkPacketDissector::dissect(const PacketDissectionContext& context) const
{
    WiresharkDissectionResult result;
    auto& runtime = WiresharkRuntime::shared();
    if (!runtime.isAvailable()) {
        result.usedWireshark = false;
        result.fallbackReason = session_ == nullptr ? runtime.unavailableReason() : session_->unavailableReason();
        result.nodes.push_back(MakeUnavailableDetail(result.fallbackReason));
        return result;
    }

#if defined(TCPVIEWER_HAS_WIRESHARK) && TCPVIEWER_HAS_WIRESHARK
    if (session_ == nullptr) {
        result.fallbackReason = "Wireshark dissection requires a per-session first-pass state.";
        result.nodes.push_back(MakeUnavailableDetail(result.fallbackReason));
        return result;
    }

    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session_->impl_->mutex);
    return session_->impl_->dissectPacketLocked(context);
#else
    (void)context;
    result.fallbackReason = kBackendNotLinkedReason;
    result.nodes.push_back(MakeUnavailableDetail(result.fallbackReason));
    return result;
#endif
}

DetailNode MakeWiresharkFallbackWarning(const std::string& reason)
{
    DetailNode node;
    node.id = "wireshark.fallback";
    node.title = "Wireshark Dissector Unavailable";
    node.fieldName = "tcpviewer.wireshark.fallback";
    node.displayValue = reason.empty() ? kBackendNotLinkedReason : reason;
    node.kind = NodeKind::Warning;
    node.severity = NodeSeverity::Warning;
    return node;
}

}  // namespace tcpviewer::dissection
