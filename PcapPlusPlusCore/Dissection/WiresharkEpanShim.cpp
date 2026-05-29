#include "WiresharkEpanShim.h"

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <iomanip>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <glib.h>

#include <epan/column.h>
#include <epan/column-info.h>
#include <epan/column-utils.h>
#include <epan/epan.h>
#include <epan/epan_dissect.h>
#include <epan/frame_data_sequence.h>
#include <epan/packet.h>
#include <epan/prefs.h>
#include <epan/proto.h>
#include <epan/tvbuff.h>
#include <wiretap/pcap-encap.h>
#include <wiretap/wtap.h>
#include <wiretap/wtap_opttypes.h>
#include <wsutil/buffer.h>

struct packet_provider_data {
    wtap *wth = nullptr;
    const frame_data *ref = nullptr;
    frame_data *prev_dis = nullptr;
    frame_data *prev_cap = nullptr;
    frame_data_sequence *frames = nullptr;
    GTree *frames_modified_blocks = nullptr;
    std::unordered_map<uint64_t, std::string> interfaceNames;
};

namespace {

constexpr const char *kBackendUnavailableReason =
    "Wireshark libwireshark backend is unavailable. Run scripts/bootstrap-wireshark.sh, then rebuild TCP Viewer.";
constexpr const char *kBackendDisabledReason =
    "Wireshark libwireshark backend is disabled for this capture.";
constexpr uint32_t kUnknownFrameNumber = 0;

enum class NodeKind {
    Layer,
    Field,
    Warning,
};

enum class NodeSeverity {
    Normal,
    Info,
    Warning,
    Error,
};

struct ByteRange {
    size_t offset = 0;
    size_t length = 0;
    uint8_t bitOffset = 0;
    uint8_t bitLength = 0;
    bool hasBitRange = false;
    std::string sourceID = "frame";
};

struct DetailNode {
    std::string id;
    std::string title;
    std::string fieldName;
    std::string displayValue;
    std::string rawValue;
    std::optional<ByteRange> range;
    NodeKind kind = NodeKind::Field;
    NodeSeverity severity = NodeSeverity::Normal;
    std::vector<DetailNode> children;
};

struct WiresharkPacketColumns {
    std::string protocol;
    std::string info;
};

struct WiresharkByteSource {
    std::string identifier;
    std::string label;
    std::vector<uint8_t> bytes;
};

struct WiresharkDissectionResult {
    bool usedWireshark = false;
    std::string fallbackReason;
    WiresharkPacketColumns columns;
    std::vector<WiresharkByteSource> byteSources;
    std::vector<DetailNode> nodes;
    std::string sniDomainName;
};

struct PacketSnapshot {
    uint64_t packetIdentifier = 0;
    std::vector<uint8_t> bytes;
    size_t capturedLength = 0;
    size_t originalLength = 0;
    int32_t linkLayerType = 1;
    int64_t timestampSeconds = 0;
    int32_t timestampNanoseconds = 0;
    std::string interfaceName;
    std::string packetComment;
    uint32_t interfaceID = 0;
    uint32_t sectionNumber = 0;
};

struct PacketContextView {
    uint64_t packetIdentifier = 0;
    const uint8_t *bytes = nullptr;
    size_t capturedLength = 0;
    size_t originalLength = 0;
    int32_t linkLayerType = 1;
    int64_t timestampSeconds = 0;
    int32_t timestampNanoseconds = 0;
    std::optional<std::string> interfaceName;
    std::optional<std::string> packetComment;
    uint32_t interfaceID = 0;
    uint32_t sectionNumber = 0;
};

std::mutex &WiresharkAPIMutex()
{
    // libwireshark has process-wide registries, so all epan entry points share one lock.
    // Keep the lock alive until process exit; test runners can tear down Swift objects late.
    static auto *mutex = new std::mutex();
    return *mutex;
}

const char *KindString(NodeKind kind)
{
    switch (kind) {
        case NodeKind::Layer:
            return "layer";
        case NodeKind::Warning:
            return "warning";
        case NodeKind::Field:
        default:
            return "field";
    }
}

const char *SeverityString(NodeSeverity severity)
{
    switch (severity) {
        case NodeSeverity::Info:
            return "info";
        case NodeSeverity::Warning:
            return "warning";
        case NodeSeverity::Error:
            return "error";
        case NodeSeverity::Normal:
        default:
            return "normal";
    }
}

char *CopyCString(const std::string &value, bool allowNull = true)
{
    if (allowNull && value.empty()) {
        return nullptr;
    }
    return strdup(value.c_str());
}

std::string HexBytes(const uint8_t *bytes, size_t length)
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

uint64_t InterfaceMetadataKey(uint32_t interfaceID, uint32_t sectionNumber)
{
    return (static_cast<uint64_t>(sectionNumber) << 32) | static_cast<uint64_t>(interfaceID);
}

void MergeInterfaceMetadata(packet_provider_data &provider, const PacketContextView &context)
{
    if (context.interfaceName.has_value() && !context.interfaceName->empty()) {
        provider.interfaceNames[InterfaceMetadataKey(context.interfaceID, context.sectionNumber)] = *context.interfaceName;
    }
}

const nstime_t *ProviderGetFrameTimestamp(packet_provider_data *provider, uint32_t frameNumber)
{
    if (provider == nullptr) {
        return nullptr;
    }

    const frame_data *frame = nullptr;
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

const char *ProviderGetInterfaceName(packet_provider_data *provider, uint32_t interfaceID, unsigned sectionNumber)
{
    if (provider == nullptr) {
        return "unknown";
    }

    const auto match = provider->interfaceNames.find(InterfaceMetadataKey(interfaceID, sectionNumber));
    return match == provider->interfaceNames.end() ? "unknown" : match->second.c_str();
}

const char *ProviderGetInterfaceDescription(packet_provider_data *, uint32_t, unsigned)
{
    return nullptr;
}

wtap_block_t ProviderGetModifiedBlock(packet_provider_data *provider, const frame_data *frame)
{
    if (provider == nullptr || provider->frames_modified_blocks == nullptr || frame == nullptr) {
        return nullptr;
    }
    return static_cast<wtap_block_t>(g_tree_lookup(provider->frames_modified_blocks, frame));
}

int32_t ProviderGetProcessID(packet_provider_data *, uint32_t, unsigned)
{
    return -1;
}

const char *ProviderGetProcessName(packet_provider_data *, uint32_t, unsigned)
{
    return nullptr;
}

const uint8_t *ProviderGetProcessUUID(packet_provider_data *, uint32_t, unsigned, size_t *uuidSize)
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

struct WiresharkSessionResources {
    epan_t *epan = nullptr;
    std::unique_ptr<packet_provider_data> provider;
};

void FreeWiresharkSessionResources(WiresharkSessionResources &resources)
{
    if (resources.epan != nullptr) {
        epan_free(resources.epan);
        resources.epan = nullptr;
    }
    if (resources.provider == nullptr) {
        return;
    }
    if (resources.provider->frames != nullptr) {
        free_frame_data_sequence(resources.provider->frames);
        resources.provider->frames = nullptr;
    }
    if (resources.provider->frames_modified_blocks != nullptr) {
        g_tree_destroy(resources.provider->frames_modified_blocks);
        resources.provider->frames_modified_blocks = nullptr;
    }
    resources.provider.reset();
}

class WiresharkRecord {
public:
    explicit WiresharkRecord(const PacketContextView &context)
    {
        const int64_t capturedLength = static_cast<int64_t>(context.capturedLength);
        const int64_t reportedLength = static_cast<int64_t>(std::max(context.originalLength, context.capturedLength));
        const int wiretapEncap = wtap_pcap_encap_to_wtap_encap(static_cast<int>(context.linkLayerType));

        if (capturedLength <= 0 || reportedLength < capturedLength || context.bytes == nullptr ||
            capturedLength > std::numeric_limits<uint32_t>::max() || reportedLength > std::numeric_limits<uint32_t>::max()) {
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
        record_.rec_header.packet_header.interface_id = context.interfaceID;
        record_.section_number = context.sectionNumber;
        record_.tsprec = WTAP_TSPREC_NSEC;
        record_.ts.secs = context.timestampSeconds;
        record_.ts.nsecs = context.timestampNanoseconds;
        record_.block = wtap_block_create(WTAP_BLOCK_PACKET);
        if (context.packetComment.has_value()) {
            wtap_block_add_string_option(record_.block, OPT_COMMENT, context.packetComment->c_str(), context.packetComment->size());
        }

        ws_buffer_clean(&record_.data);
        ws_buffer_assure_space(&record_.data, static_cast<size_t>(capturedLength));
        std::memcpy(ws_buffer_start_ptr(&record_.data), context.bytes, static_cast<size_t>(capturedLength));
        ws_buffer_increase_length(&record_.data, static_cast<size_t>(capturedLength));
    }

    ~WiresharkRecord()
    {
        if (initialized_) {
            wtap_rec_cleanup(&record_);
        }
    }

    WiresharkRecord(const WiresharkRecord &) = delete;
    WiresharkRecord &operator=(const WiresharkRecord &) = delete;

    bool isValid() const { return initialized_ && failureReason_.empty(); }
    const std::string &failureReason() const { return failureReason_; }
    wtap_rec *get() { return &record_; }

private:
    wtap_rec record_{};
    bool initialized_ = false;
    std::string failureReason_;
};

class WiresharkColumnInfo {
public:
    WiresharkColumnInfo()
    {
        // TCP Viewer only needs packet-list protocol and info columns from Wireshark.
        col_setup(&info_, 2);
        info_.columns[0].col_fmt = COL_PROTOCOL;
        info_.columns[0].col_title = nullptr;
        info_.columns[0].col_fence = 0;
        info_.columns[1].col_fmt = COL_INFO;
        info_.columns[1].col_title = nullptr;
        info_.columns[1].col_fence = 0;
        col_finalize(&info_);
        initialized_ = true;
    }

    ~WiresharkColumnInfo()
    {
        if (initialized_) {
            col_cleanup(&info_);
        }
    }

    WiresharkColumnInfo(const WiresharkColumnInfo &) = delete;
    WiresharkColumnInfo &operator=(const WiresharkColumnInfo &) = delete;

    column_info *get()
    {
        return initialized_ ? &info_ : nullptr;
    }

private:
    column_info info_{};
    bool initialized_ = false;
};

struct WiresharkSourceSet {
    std::vector<WiresharkByteSource> sources;
    std::unordered_map<const tvbuff_t *, std::string> idsByTVB;
    std::unordered_map<std::string, size_t> indexByID;
};

struct EpanDissectDeleter {
    void operator()(epan_dissect_t *dissect) const
    {
        if (dissect != nullptr) {
            epan_dissect_free(dissect);
        }
    }
};

using EpanDissectPtr = std::unique_ptr<epan_dissect_t, EpanDissectDeleter>;

uint32_t FrameNumberForContext(const PacketContextView &context, uint64_t fallbackFrameNumber)
{
    if (context.packetIdentifier > 0 && context.packetIdentifier <= std::numeric_limits<uint32_t>::max()) {
        return static_cast<uint32_t>(context.packetIdentifier);
    }
    if (fallbackFrameNumber > 0 && fallbackFrameNumber <= std::numeric_limits<uint32_t>::max()) {
        return static_cast<uint32_t>(fallbackFrameNumber);
    }
    return kUnknownFrameNumber;
}

std::string StripByteCountSuffix(std::string label)
{
    const auto suffixStart = label.rfind(" (");
    return suffixStart == std::string::npos ? label : label.substr(0, suffixStart);
}

std::string SlugIdentifier(const std::string &label)
{
    std::string identifier;
    bool lastWasDash = false;
    for (unsigned char character : label) {
        if (std::isalnum(character)) {
            identifier.push_back(static_cast<char>(std::tolower(character)));
            lastWasDash = false;
        } else if (!lastWasDash && !identifier.empty()) {
            identifier.push_back('-');
            lastWasDash = true;
        }
    }
    while (!identifier.empty() && identifier.back() == '-') {
        identifier.pop_back();
    }
    return identifier.empty() ? "bytes" : identifier;
}

std::string UniqueSourceIdentifier(const std::string &baseIdentifier, const WiresharkSourceSet &sourceSet)
{
    std::string candidate = baseIdentifier;
    unsigned suffix = 2;
    while (sourceSet.indexByID.find(candidate) != sourceSet.indexByID.end()) {
        candidate = baseIdentifier + "-" + std::to_string(suffix);
        suffix += 1;
    }
    return candidate;
}

WiresharkPacketColumns ColumnsFromInfo(column_info *cinfo)
{
    WiresharkPacketColumns columns;
    if (cinfo == nullptr) {
        return columns;
    }
    if (const char *protocol = col_get_text(cinfo, COL_PROTOCOL)) {
        columns.protocol = protocol;
    }
    if (const char *info = col_get_text(cinfo, COL_INFO)) {
        columns.info = info;
    }
    return columns;
}

WiresharkSourceSet ExtractByteSources(GSList *dataSources)
{
    WiresharkSourceSet sourceSet;
    unsigned index = 0;
    for (GSList *item = dataSources; item != nullptr; item = item->next) {
        auto *source = static_cast<data_source *>(item->data);
        tvbuff_t *tvb = get_data_source_tvb(source);
        if (tvb == nullptr) {
            continue;
        }

        char *description = get_data_source_description(source);
        const std::string label = description == nullptr ? (index == 0 ? "Frame" : "Bytes") : StripByteCountSuffix(description);
        if (description != nullptr) {
            wmem_free(nullptr, description);
        }

        const std::string baseIdentifier = index == 0 ? "frame" : SlugIdentifier(label);
        WiresharkByteSource byteSource;
        byteSource.identifier = UniqueSourceIdentifier(baseIdentifier, sourceSet);
        byteSource.label = label.empty() ? (index == 0 ? "Frame" : "Bytes") : label;

        const unsigned length = tvb_captured_length(tvb);
        if (length > 0) {
            const uint8_t *bytes = tvb_get_ptr(tvb, 0, static_cast<int>(length));
            if (bytes != nullptr) {
                byteSource.bytes.assign(bytes, bytes + length);
            }
        }

        sourceSet.idsByTVB[tvb] = byteSource.identifier;
        sourceSet.indexByID[byteSource.identifier] = sourceSet.sources.size();
        sourceSet.sources.push_back(std::move(byteSource));
        index += 1;
    }
    return sourceSet;
}

std::string SourceIdentifierForField(const field_info *field, const WiresharkSourceSet &sourceSet)
{
    if (field == nullptr || field->ds_tvb == nullptr) {
        return "frame";
    }
    const auto match = sourceSet.idsByTVB.find(field->ds_tvb);
    return match == sourceSet.idsByTVB.end() ? "frame" : match->second;
}

std::string RawValueForRange(const WiresharkSourceSet &sourceSet, const ByteRange &range)
{
    const auto sourceIndex = sourceSet.indexByID.find(range.sourceID);
    if (sourceIndex == sourceSet.indexByID.end()) {
        return "";
    }
    const auto &bytes = sourceSet.sources[sourceIndex->second].bytes;
    if (range.offset > bytes.size() || range.length > bytes.size() - range.offset) {
        return "";
    }
    return HexBytes(bytes.data() + range.offset, range.length);
}

std::string TrimDisplayValue(std::string value)
{
    while (!value.empty() && (value.front() == ':' || value.front() == ',' || value.front() == ' ')) {
        value.erase(value.begin());
    }
    return value;
}

std::string LabelForField(const field_info *field, size_t &valueOffset)
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

std::optional<ByteRange> MakeRangeForField(const field_info *field, const std::string &sourceIdentifier)
{
    if (field == nullptr || field->start < 0 || field->length <= 0) {
        return std::nullopt;
    }

    const auto offset = static_cast<size_t>(field->start);
    const auto length = static_cast<size_t>(field->length);
    const uint32_t explicitBitOffset = FI_GET_BITS_OFFSET(field);
    const uint32_t explicitBitLength = FI_GET_BITS_SIZE(field);
    std::optional<ByteRange> range;
    if (explicitBitOffset != 0 || explicitBitLength != 0) {
        const uint32_t effectiveBitLength = explicitBitLength == 0 ? static_cast<uint32_t>(field->length * 8) : explicitBitLength;
        const size_t byteDelta = explicitBitOffset / 8;
        const uint8_t bitOffset = static_cast<uint8_t>(explicitBitOffset % 8);
        const size_t byteLength = static_cast<size_t>((bitOffset + effectiveBitLength + 7) / 8);
        range = ByteRange{offset + byteDelta, byteLength, bitOffset, static_cast<uint8_t>(std::min(effectiveBitLength, uint32_t{63})), true};
    } else if (field->hfinfo != nullptr) {
        range = MakeBitRangeFromMask(offset, field->length, field->hfinfo->bitmask);
    }
    if (!range.has_value()) {
        range = ByteRange{offset, length, 0, 0, false};
    }
    range->sourceID = sourceIdentifier;
    return range;
}

NodeSeverity SeverityForField(const field_info *field)
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

NodeKind KindForField(const field_info *field, NodeSeverity severity)
{
    if (severity == NodeSeverity::Warning || severity == NodeSeverity::Error) {
        return NodeKind::Warning;
    }
    if (field != nullptr && field->hfinfo != nullptr && field->hfinfo->type == FT_PROTOCOL) {
        return NodeKind::Layer;
    }
    return NodeKind::Field;
}

std::optional<DetailNode> MapProtoNode(proto_node *protoNode, const WiresharkSourceSet &sourceSet, uint64_t &sequence)
{
    // Wireshark frees proto_tree data with the epan dissector, so copy every field now.
    field_info *field = PNODE_FINFO(protoNode);
    if (field == nullptr || field->hfinfo == nullptr || FI_GET_FLAG(field, FI_HIDDEN)) {
        return std::nullopt;
    }

    size_t valueOffset = 0;
    const std::string label = LabelForField(field, valueOffset);
    const header_field_info *header = field->hfinfo;
    DetailNode node;
    node.fieldName = header->abbrev != nullptr ? header->abbrev : "";
    node.title = header->name != nullptr ? header->name : label;
    node.displayValue = valueOffset < label.size() ? TrimDisplayValue(label.substr(valueOffset)) : "";
    if (node.displayValue.empty() && label != node.title) {
        node.displayValue = TrimDisplayValue(label);
    }
    node.id = node.fieldName.empty() ? "wireshark.node." + std::to_string(sequence) : node.fieldName + "." + std::to_string(sequence);
    sequence += 1;
    node.range = MakeRangeForField(field, SourceIdentifierForField(field, sourceSet));
    node.severity = SeverityForField(field);
    node.kind = KindForField(field, node.severity);
    if (node.range.has_value()) {
        node.rawValue = RawValueForRange(sourceSet, *node.range);
    }
    if (node.range.has_value() && node.rawValue.empty() && !FI_GET_FLAG(field, FI_GENERATED)) {
        node.severity = NodeSeverity::Error;
        node.kind = NodeKind::Warning;
    }

    for (proto_node *child = protoNode->first_child; child != nullptr; child = child->next) {
        if (auto childNode = MapProtoNode(child, sourceSet, sequence)) {
            node.children.push_back(std::move(*childNode));
        }
    }
    return node;
}

std::vector<DetailNode> MapProtoTree(proto_tree *tree, const WiresharkSourceSet &sourceSet)
{
    std::vector<DetailNode> nodes;
    uint64_t sequence = 1;
    if (tree == nullptr) {
        return nodes;
    }
    for (proto_node *child = tree->first_child; child != nullptr; child = child->next) {
        if (auto node = MapProtoNode(child, sourceSet, sequence)) {
            nodes.push_back(std::move(*node));
        }
    }
    return nodes;
}

std::optional<std::string> FindSNIInNodes(const std::vector<DetailNode> &nodes)
{
    for (const auto &node : nodes) {
        if (node.fieldName == "tls.handshake.extensions_server_name" && !node.displayValue.empty()) {
            return node.displayValue;
        }
        if (auto child = FindSNIInNodes(node.children)) {
            return child;
        }
    }
    return std::nullopt;
}

bool ShouldExtractSNIFromTree(const WiresharkPacketColumns &columns)
{
    auto contains = [](std::string value, const char *needle) {
        std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
            return static_cast<char>(std::tolower(character));
        });
        return value.find(needle) != std::string::npos;
    };
    return contains(columns.protocol, "tls") || contains(columns.info, "client hello") || contains(columns.info, "server name");
}

PacketContextView ContextViewFromC(const TCPViewerWiresharkPacketContext *context)
{
    PacketContextView view;
    if (context == nullptr) {
        return view;
    }
    view.packetIdentifier = context->packetIdentifier;
    view.bytes = context->bytes;
    view.capturedLength = context->capturedLength;
    view.originalLength = context->originalLength;
    view.linkLayerType = context->linkLayerType;
    view.timestampSeconds = context->timestampSeconds;
    view.timestampNanoseconds = context->timestampNanoseconds;
    if (context->interfaceName != nullptr && context->interfaceName[0] != '\0') {
        view.interfaceName = context->interfaceName;
    }
    if (context->packetComment != nullptr && context->packetComment[0] != '\0') {
        view.packetComment = context->packetComment;
    }
    view.interfaceID = context->interfaceID;
    view.sectionNumber = context->sectionNumber;
    return view;
}

PacketContextView ContextViewFromSnapshot(const PacketSnapshot &snapshot)
{
    PacketContextView view;
    view.packetIdentifier = snapshot.packetIdentifier;
    view.bytes = snapshot.bytes.data();
    view.capturedLength = snapshot.capturedLength;
    view.originalLength = snapshot.originalLength;
    view.linkLayerType = snapshot.linkLayerType;
    view.timestampSeconds = snapshot.timestampSeconds;
    view.timestampNanoseconds = snapshot.timestampNanoseconds;
    if (!snapshot.interfaceName.empty()) {
        view.interfaceName = snapshot.interfaceName;
    }
    if (!snapshot.packetComment.empty()) {
        view.packetComment = snapshot.packetComment;
    }
    view.interfaceID = snapshot.interfaceID;
    view.sectionNumber = snapshot.sectionNumber;
    return view;
}

PacketSnapshot SnapshotFromContext(const PacketContextView &context, uint32_t frameNumber)
{
    PacketSnapshot snapshot;
    snapshot.packetIdentifier = frameNumber;
    if (context.bytes != nullptr && context.capturedLength > 0) {
        snapshot.bytes.assign(context.bytes, context.bytes + context.capturedLength);
    }
    snapshot.capturedLength = context.capturedLength;
    snapshot.originalLength = context.originalLength;
    snapshot.linkLayerType = context.linkLayerType;
    snapshot.timestampSeconds = context.timestampSeconds;
    snapshot.timestampNanoseconds = context.timestampNanoseconds;
    snapshot.interfaceName = context.interfaceName.value_or("");
    snapshot.packetComment = context.packetComment.value_or("");
    snapshot.interfaceID = context.interfaceID;
    snapshot.sectionNumber = context.sectionNumber;
    return snapshot;
}

TCPViewerWiresharkByteRange *CopyByteRange(const std::optional<ByteRange> &range)
{
    if (!range.has_value()) {
        return nullptr;
    }
    auto *copied = static_cast<TCPViewerWiresharkByteRange *>(std::calloc(1, sizeof(TCPViewerWiresharkByteRange)));
    copied->offset = range->offset;
    copied->length = range->length;
    copied->bitOffset = range->bitOffset;
    copied->bitLength = range->bitLength;
    copied->hasBitRange = range->hasBitRange;
    copied->sourceIdentifier = CopyCString(range->sourceID, false);
    return copied;
}

TCPViewerWiresharkDetailNode CopyDetailNode(const DetailNode &node)
{
    TCPViewerWiresharkDetailNode copied{};
    copied.identifier = CopyCString(node.id, false);
    copied.name = CopyCString(node.title, false);
    copied.fieldName = CopyCString(node.fieldName, false);
    copied.value = CopyCString(node.displayValue);
    copied.rawValue = CopyCString(node.rawValue);
    copied.kind = strdup(KindString(node.kind));
    copied.severity = strdup(SeverityString(node.severity));
    copied.byteRange = CopyByteRange(node.range);
    copied.childCount = node.children.size();
    if (!node.children.empty()) {
        copied.children = static_cast<TCPViewerWiresharkDetailNode *>(std::calloc(node.children.size(), sizeof(TCPViewerWiresharkDetailNode)));
        for (size_t index = 0; index < node.children.size(); index += 1) {
            copied.children[index] = CopyDetailNode(node.children[index]);
        }
    }
    return copied;
}

TCPViewerWiresharkByteSource CopyByteSource(const WiresharkByteSource &source)
{
    TCPViewerWiresharkByteSource copied{};
    copied.identifier = CopyCString(source.identifier, false);
    copied.label = CopyCString(source.label, false);
    copied.byteCount = source.bytes.size();
    if (!source.bytes.empty()) {
        copied.bytes = static_cast<uint8_t *>(std::malloc(source.bytes.size()));
        std::memcpy(copied.bytes, source.bytes.data(), source.bytes.size());
    }
    return copied;
}

void DestroyByteRange(TCPViewerWiresharkByteRange *range)
{
    if (range == nullptr) {
        return;
    }
    std::free(const_cast<char *>(range->sourceIdentifier));
    std::free(range);
}

void DestroyDetailNode(TCPViewerWiresharkDetailNode &node)
{
    std::free(const_cast<char *>(node.identifier));
    std::free(const_cast<char *>(node.name));
    std::free(const_cast<char *>(node.fieldName));
    std::free(const_cast<char *>(node.value));
    std::free(const_cast<char *>(node.rawValue));
    std::free(const_cast<char *>(node.kind));
    std::free(const_cast<char *>(node.severity));
    DestroyByteRange(node.byteRange);
    for (size_t index = 0; index < node.childCount; index += 1) {
        DestroyDetailNode(node.children[index]);
    }
    std::free(node.children);
}

void DestroyByteSource(TCPViewerWiresharkByteSource &source)
{
    std::free(const_cast<char *>(source.identifier));
    std::free(const_cast<char *>(source.label));
    std::free(source.bytes);
}

class WiresharkRuntime {
public:
    static WiresharkRuntime &shared()
    {
        static WiresharkRuntime runtime;
        return runtime;
    }

    bool isAvailable() const { return available_; }
    const std::string &unavailableReason() const { return unavailableReason_; }

private:
    WiresharkRuntime()
    {
        std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
        wtap_init(true);
        initializedWiretap_ = true;
        if (!epan_init(nullptr, nullptr, true)) {
            available_ = false;
            unavailableReason_ = "Wireshark protocol registry failed to initialize.";
            wtap_cleanup();
            initializedWiretap_ = false;
            return;
        }
        initializedEpan_ = true;
        epan_load_settings();
        prefs_apply_all();
        available_ = true;
        unavailableReason_.clear();
    }

    ~WiresharkRuntime()
    {
        std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
        if (initializedEpan_) {
            epan_cleanup();
        }
        if (initializedWiretap_) {
            wtap_cleanup();
        }
    }

    bool available_ = false;
    bool initializedWiretap_ = false;
    bool initializedEpan_ = false;
    std::string unavailableReason_ = kBackendUnavailableReason;
};

}  // namespace

struct TCPViewerWiresharkSession {
    mutable std::mutex mutex;
    std::string unavailableReason = kBackendUnavailableReason;
    std::unique_ptr<packet_provider_data> provider;
    epan_t *epan = nullptr;
    EpanDissectPtr firstPassDissect;
    nstime_t elapsedTime = NSTIME_INIT_ZERO;
    frame_data referenceFrame{};
    uint32_t cumulativeBytes = 0;
    std::vector<PacketSnapshot> observedPackets;
    std::unordered_set<uint32_t> storedFrameNumbers;
    std::unordered_set<uint32_t> activeFrameNumbers;
    bool disabled = false;
    bool firstPassFinished = false;
    bool backendAvailable = false;

    static TCPViewerWiresharkSession *&activeSession()
    {
        static TCPViewerWiresharkSession *session = nullptr;
        return session;
    }

    explicit TCPViewerWiresharkSession(bool disablesWireshark)
    {
        if (disablesWireshark) {
            disabled = true;
            unavailableReason = kBackendDisabledReason;
            firstPassFinished = true;
            return;
        }
        auto &runtime = WiresharkRuntime::shared();
        backendAvailable = runtime.isAvailable();
        unavailableReason = runtime.unavailableReason();
        if (!backendAvailable) {
            return;
        }

        std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
        ensureActiveSessionLocked();
    }

    ~TCPViewerWiresharkSession()
    {
        if (epan == nullptr && provider == nullptr && firstPassDissect == nullptr) {
            return;
        }
        std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
        std::lock_guard<std::mutex> sessionLock(mutex);
        releaseWiresharkResourcesLocked("", false);
    }

    bool hasSession() const
    {
        return epan != nullptr && provider != nullptr && provider->frames != nullptr;
    }

    void resetActiveFrameStateLocked()
    {
        activeFrameNumbers.clear();
        nstime_set_zero(&elapsedTime);
        referenceFrame = frame_data{};
        cumulativeBytes = 0;
        if (provider != nullptr) {
            provider->ref = nullptr;
            provider->prev_dis = nullptr;
            provider->prev_cap = nullptr;
        }
    }

    void releaseWiresharkResourcesLocked(const std::string &reason, bool finishSession)
    {
        if (activeSession() == this) {
            activeSession() = nullptr;
        }
        firstPassDissect.reset();
        WiresharkSessionResources resources{epan, std::move(provider)};
        epan = nullptr;
        if (!reason.empty()) {
            unavailableReason = reason;
        }
        FreeWiresharkSessionResources(resources);
        resetActiveFrameStateLocked();
        if (finishSession) {
            firstPassFinished = true;
        }
    }

    bool initializeWiresharkResourcesLocked()
    {
        if (auto *active = activeSession(); active != nullptr && active != this) {
            std::lock_guard<std::mutex> activeLock(active->mutex);
            active->releaseWiresharkResourcesLocked("Wireshark session is inactive until this capture is inspected again.", false);
        }

        provider = std::make_unique<packet_provider_data>();
        provider->frames = new_frame_data_sequence();
        if (provider->frames == nullptr) {
            unavailableReason = "Wireshark frame storage could not be created.";
            provider.reset();
            return false;
        }

        epan = epan_new(provider.get(), &kPacketProviderFuncs);
        if (epan == nullptr) {
            WiresharkSessionResources resources{nullptr, std::move(provider)};
            FreeWiresharkSessionResources(resources);
            unavailableReason = "Wireshark session could not be created.";
            return false;
        }

        firstPassDissect.reset(epan_dissect_new(epan, false, false));
        if (!firstPassDissect) {
            releaseWiresharkResourcesLocked("Wireshark could not allocate a first-pass dissector.", true);
            return false;
        }

        activeSession() = this;
        resetActiveFrameStateLocked();
        return true;
    }

    bool appendFirstPassPacketLocked(const PacketContextView &context, uint32_t frameNumber)
    {
        // First pass feeds Wireshark conversation and reassembly state before detail extraction.
        if (!hasSession()) {
            return false;
        }
        if (frameNumber == kUnknownFrameNumber) {
            unavailableReason = "Wireshark requires a 32-bit frame number for dissection state.";
            return false;
        }
        if (activeFrameNumbers.find(frameNumber) != activeFrameNumbers.end()) {
            return true;
        }
        if (firstPassDissect == nullptr || firstPassFinished) {
            unavailableReason = "Wireshark first-pass state is already finalized for this packet set.";
            return false;
        }

        MergeInterfaceMetadata(*provider, context);
        WiresharkRecord record(context);
        if (!record.isValid()) {
            unavailableReason = record.failureReason();
            return false;
        }

        frame_data frame{};
        frame_data_init(&frame, frameNumber, record.get(), cumulativeBytes, cumulativeBytes);
        frame_data_set_before_dissect(&frame, &elapsedTime, &provider->ref, provider->prev_dis);
        if (provider->ref == &frame) {
            referenceFrame = frame;
            provider->ref = &referenceFrame;
        }
        epan_dissect_run(firstPassDissect.get(), WTAP_FILE_TYPE_SUBTYPE_UNKNOWN, record.get(), &frame, nullptr);
        frame_data_set_after_dissect(&frame, &cumulativeBytes);

        provider->prev_cap = provider->prev_dis = frame_data_sequence_add(provider->frames, &frame);
        epan_dissect_reset(firstPassDissect.get());
        activeFrameNumbers.insert(frameNumber);
        return true;
    }

    bool replayFirstPassPacketsLocked()
    {
        const bool shouldFinishFirstPass = firstPassFinished;
        firstPassFinished = false;

        for (const auto &snapshot : observedPackets) {
            const auto context = ContextViewFromSnapshot(snapshot);
            if (!appendFirstPassPacketLocked(context, static_cast<uint32_t>(snapshot.packetIdentifier))) {
                firstPassFinished = shouldFinishFirstPass;
                return false;
            }
        }

        if (shouldFinishFirstPass) {
            finishActiveFirstPassLocked();
        }
        firstPassFinished = shouldFinishFirstPass;
        return true;
    }

    bool ensureActiveSessionLocked()
    {
        if (disabled) {
            return false;
        }
        auto &runtime = WiresharkRuntime::shared();
        backendAvailable = runtime.isAvailable();
        if (!backendAvailable) {
            unavailableReason = runtime.unavailableReason();
            return false;
        }
        if (hasSession() && activeSession() == this) {
            return true;
        }
        if (!initializeWiresharkResourcesLocked()) {
            return false;
        }
        if (!replayFirstPassPacketsLocked()) {
            releaseWiresharkResourcesLocked(unavailableReason, true);
            return false;
        }
        unavailableReason.clear();
        return true;
    }

    bool observePacketLocked(const PacketContextView &context)
    {
        if (disabled || !backendAvailable) {
            return false;
        }
        const uint32_t frameNumber = FrameNumberForContext(context, observedPackets.size() + 1);
        if (frameNumber == kUnknownFrameNumber) {
            unavailableReason = "Wireshark requires a 32-bit frame number for dissection state.";
            return false;
        }
        if (storedFrameNumbers.find(frameNumber) != storedFrameNumbers.end()) {
            return ensureActiveSessionLocked();
        }
        if (firstPassFinished) {
            unavailableReason = "Wireshark first-pass state is already finalized for this packet set.";
            return false;
        }
        if (!ensureActiveSessionLocked()) {
            return false;
        }
        if (!appendFirstPassPacketLocked(context, frameNumber)) {
            return false;
        }

        observedPackets.push_back(SnapshotFromContext(context, frameNumber));
        storedFrameNumbers.insert(frameNumber);
        return true;
    }

    void finishActiveFirstPassLocked()
    {
        firstPassDissect.reset();
        if (provider != nullptr) {
            provider->prev_dis = nullptr;
            provider->prev_cap = nullptr;
        }
    }

    bool finishFirstPassLocked()
    {
        if (firstPassFinished) {
            return true;
        }
        if (!ensureActiveSessionLocked()) {
            return false;
        }
        finishActiveFirstPassLocked();
        firstPassFinished = true;
        return true;
    }

    WiresharkDissectionResult runSecondPassLocked(const PacketContextView &context, bool buildTree)
    {
        WiresharkDissectionResult result;
        if (!ensureActiveSessionLocked()) {
            result.fallbackReason = unavailableReason;
            return result;
        }

        const uint32_t expectedFrameNumber = FrameNumberForContext(context, observedPackets.size());
        if (expectedFrameNumber != kUnknownFrameNumber && activeFrameNumbers.find(expectedFrameNumber) == activeFrameNumbers.end() &&
            !observePacketLocked(context)) {
            result.fallbackReason = unavailableReason;
            return result;
        }

        MergeInterfaceMetadata(*provider, context);
        const uint32_t frameNumber = FrameNumberForContext(context, observedPackets.size());
        frame_data *frame = frameNumber == kUnknownFrameNumber ? nullptr : frame_data_sequence_find(provider->frames, frameNumber);
        if (frame == nullptr) {
            result.fallbackReason = "Wireshark first-pass frame state was not available for this packet.";
            return result;
        }

        WiresharkRecord record(context);
        if (!record.isValid()) {
            result.fallbackReason = record.failureReason();
            return result;
        }

        WiresharkColumnInfo columnInfo;
        EpanDissectPtr dissect(epan_dissect_new(epan, buildTree, buildTree));
        if (!dissect) {
            result.fallbackReason = "Wireshark could not allocate a second-pass dissector.";
            return result;
        }

        if (columnInfo.get() != nullptr) {
            col_custom_prime_edt(dissect.get(), columnInfo.get());
        }

        frame_data_set_before_dissect(frame, &elapsedTime, &provider->ref, provider->prev_dis);
        if (provider->ref == frame) {
            referenceFrame = *frame;
            provider->ref = &referenceFrame;
        }
        wtap_block_t block = record.get()->block != nullptr ? wtap_block_ref(record.get()->block) : nullptr;
        if (buildTree) {
            epan_dissect_run_with_taps(dissect.get(), WTAP_FILE_TYPE_SUBTYPE_UNKNOWN, record.get(), frame, columnInfo.get());
        } else {
            epan_dissect_run(dissect.get(), WTAP_FILE_TYPE_SUBTYPE_UNKNOWN, record.get(), frame, columnInfo.get());
        }
        uint32_t secondPassCumulativeBytes = frame->cum_bytes >= frame->pkt_len ? frame->cum_bytes - frame->pkt_len : 0;
        frame_data_set_after_dissect(frame, &secondPassCumulativeBytes);

        result.columns = ColumnsFromInfo(columnInfo.get());
        if (buildTree) {
            auto sourceSet = ExtractByteSources(dissect->pi.data_src);
            result.nodes = MapProtoTree(dissect->tree, sourceSet);
            if (auto sni = FindSNIInNodes(result.nodes)) {
                result.sniDomainName = *sni;
            }
            result.byteSources = std::move(sourceSet.sources);
        }
        epan_dissect_reset(dissect.get());
        record.get()->block = block;
        result.usedWireshark = buildTree ? !result.nodes.empty() : (!result.columns.protocol.empty() || !result.columns.info.empty());
        if (!result.usedWireshark && buildTree) {
            result.fallbackReason = "Wireshark protocol-tree dissection returned no nodes for this packet.";
        }
        return result;
    }

    WiresharkDissectionResult summarizePacketLocked(const PacketContextView &context)
    {
        auto result = runSecondPassLocked(context, false);
        if (result.usedWireshark && ShouldExtractSNIFromTree(result.columns)) {
            auto treeResult = runSecondPassLocked(context, true);
            if (!treeResult.sniDomainName.empty()) {
                result.sniDomainName = treeResult.sniDomainName;
            }
        }
        return result;
    }

    WiresharkDissectionResult inspectPacketLocked(const PacketContextView &context)
    {
        return runSecondPassLocked(context, true);
    }
};

TCPViewerWiresharkSession *TCPViewerWiresharkSessionCreate(bool disabled)
{
    return new TCPViewerWiresharkSession(disabled);
}

void TCPViewerWiresharkSessionDestroy(TCPViewerWiresharkSession *session)
{
    delete session;
}

bool TCPViewerWiresharkSessionIsAvailable(TCPViewerWiresharkSession *session)
{
    if (session == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> lock(session->mutex);
    return session->backendAvailable && !session->disabled;
}

const char *TCPViewerWiresharkSessionUnavailableReason(TCPViewerWiresharkSession *session)
{
    if (session == nullptr) {
        return kBackendUnavailableReason;
    }
    std::lock_guard<std::mutex> lock(session->mutex);
    return session->unavailableReason.empty() ? kBackendUnavailableReason : session->unavailableReason.c_str();
}

bool TCPViewerWiresharkSessionObservePacket(TCPViewerWiresharkSession *session, const TCPViewerWiresharkPacketContext *context)
{
    if (session == nullptr || context == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    return session->observePacketLocked(ContextViewFromC(context));
}

bool TCPViewerWiresharkSessionFinishFirstPass(TCPViewerWiresharkSession *session)
{
    if (session == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    return session->finishFirstPassLocked();
}

TCPViewerWiresharkSummaryResult *TCPViewerWiresharkSessionSummarizePacket(TCPViewerWiresharkSession *session, const TCPViewerWiresharkPacketContext *context)
{
    auto *result = static_cast<TCPViewerWiresharkSummaryResult *>(std::calloc(1, sizeof(TCPViewerWiresharkSummaryResult)));
    if (session == nullptr || context == nullptr) {
        result->errorMessage = CopyCString("Wireshark session is not available.", false);
        return result;
    }

    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    const auto dissection = session->summarizePacketLocked(ContextViewFromC(context));
    result->succeeded = dissection.usedWireshark;
    if (!dissection.usedWireshark) {
        result->errorMessage = CopyCString(dissection.fallbackReason.empty() ? session->unavailableReason : dissection.fallbackReason, false);
        return result;
    }
    result->protocol = CopyCString(dissection.columns.protocol);
    result->info = CopyCString(dissection.columns.info);
    result->sniDomainName = CopyCString(dissection.sniDomainName);
    return result;
}

TCPViewerWiresharkInspectionResult *TCPViewerWiresharkSessionInspectPacket(TCPViewerWiresharkSession *session, const TCPViewerWiresharkPacketContext *context)
{
    auto *result = static_cast<TCPViewerWiresharkInspectionResult *>(std::calloc(1, sizeof(TCPViewerWiresharkInspectionResult)));
    if (session == nullptr || context == nullptr) {
        result->errorMessage = CopyCString("Wireshark session is not available.", false);
        return result;
    }

    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    const auto dissection = session->inspectPacketLocked(ContextViewFromC(context));
    result->succeeded = dissection.usedWireshark;
    if (!dissection.usedWireshark) {
        result->errorMessage = CopyCString(dissection.fallbackReason.empty() ? session->unavailableReason : dissection.fallbackReason, false);
        return result;
    }
    result->sniDomainName = CopyCString(dissection.sniDomainName);
    result->byteSourceCount = dissection.byteSources.size();
    if (!dissection.byteSources.empty()) {
        result->byteSources = static_cast<TCPViewerWiresharkByteSource *>(std::calloc(dissection.byteSources.size(), sizeof(TCPViewerWiresharkByteSource)));
        for (size_t index = 0; index < dissection.byteSources.size(); index += 1) {
            result->byteSources[index] = CopyByteSource(dissection.byteSources[index]);
        }
    }
    result->nodeCount = dissection.nodes.size();
    if (!dissection.nodes.empty()) {
        result->nodes = static_cast<TCPViewerWiresharkDetailNode *>(std::calloc(dissection.nodes.size(), sizeof(TCPViewerWiresharkDetailNode)));
        for (size_t index = 0; index < dissection.nodes.size(); index += 1) {
            result->nodes[index] = CopyDetailNode(dissection.nodes[index]);
        }
    }
    return result;
}

void TCPViewerWiresharkSummaryResultDestroy(TCPViewerWiresharkSummaryResult *result)
{
    if (result == nullptr) {
        return;
    }
    std::free(const_cast<char *>(result->errorMessage));
    std::free(const_cast<char *>(result->protocol));
    std::free(const_cast<char *>(result->info));
    std::free(const_cast<char *>(result->sniDomainName));
    std::free(result);
}

void TCPViewerWiresharkInspectionResultDestroy(TCPViewerWiresharkInspectionResult *result)
{
    if (result == nullptr) {
        return;
    }
    std::free(const_cast<char *>(result->errorMessage));
    std::free(const_cast<char *>(result->sniDomainName));
    for (size_t index = 0; index < result->byteSourceCount; index += 1) {
        DestroyByteSource(result->byteSources[index]);
    }
    std::free(result->byteSources);
    for (size_t index = 0; index < result->nodeCount; index += 1) {
        DestroyDetailNode(result->nodes[index]);
    }
    std::free(result->nodes);
    std::free(result);
}
