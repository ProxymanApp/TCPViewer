#include "WiresharkDissector.hpp"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <cstdlib>
#include <iomanip>
#include <limits>
#include <mutex>
#include <optional>
#include <sstream>
#include <unordered_map>
#include <unordered_set>
#include <utility>
#include <vector>

#include <pcapplusplus/RawPacket.h>

#if defined(TCPVIEWER_HAS_WIRESHARK) && TCPVIEWER_HAS_WIRESHARK
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
constexpr const char* kBackendDisabledReason =
    "Wireshark libwireshark backend is linked but disabled for this process by TCPVIEWER_DISABLE_WIRESHARK.";

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

bool WiresharkDisabledByEnvironment()
{
    // Keep fallback-focused tests deterministic while the Debug app uses Wireshark by default.
    const char* value = std::getenv("TCPVIEWER_DISABLE_WIRESHARK");
    return value != nullptr && value[0] != '\0' && std::strcmp(value, "0") != 0;
}

std::mutex& WiresharkAPIMutex()
{
    static std::mutex mutex;
    return mutex;
}

struct WiresharkSessionResources {
    epan_t* epan = nullptr;
    frame_data_sequence* frames = nullptr;
    GTree* framesModifiedBlocks = nullptr;
};

void FreeWiresharkSessionResources(WiresharkSessionResources& resources)
{
    if (resources.epan != nullptr) {
        epan_free(resources.epan);
        resources.epan = nullptr;
    }
    if (resources.frames != nullptr) {
        free_frame_data_sequence(resources.frames);
        resources.frames = nullptr;
    }
    if (resources.framesModifiedBlocks != nullptr) {
        g_tree_destroy(resources.framesModifiedBlocks);
        resources.framesModifiedBlocks = nullptr;
    }
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

class WiresharkColumnInfo {
public:
    WiresharkColumnInfo()
    {
        // TCPViewer only needs Wireshark's dissector-owned packet list columns; omit time columns that need cfile UI state.
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

    WiresharkColumnInfo(const WiresharkColumnInfo&) = delete;
    WiresharkColumnInfo& operator=(const WiresharkColumnInfo&) = delete;

    column_info* get()
    {
        return initialized_ ? &info_ : nullptr;
    }

private:
    column_info info_{};
    bool initialized_ = false;
};

struct WiresharkSourceSet {
    std::vector<WiresharkByteSource> sources;
    std::unordered_map<const tvbuff_t*, std::string> idsByTVB;
    std::unordered_map<std::string, size_t> indexByID;
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

std::string StripByteCountSuffix(std::string label)
{
    const auto suffixStart = label.rfind(" (");
    if (suffixStart == std::string::npos) {
        return label;
    }
    return label.substr(0, suffixStart);
}

std::string SlugIdentifier(const std::string& label)
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

std::string UniqueSourceIdentifier(const std::string& baseIdentifier, const WiresharkSourceSet& sourceSet)
{
    std::string candidate = baseIdentifier;
    unsigned suffix = 2;
    while (sourceSet.indexByID.find(candidate) != sourceSet.indexByID.end()) {
        candidate = baseIdentifier + "-" + std::to_string(suffix);
        suffix += 1;
    }
    return candidate;
}

WiresharkPacketColumns ColumnsFromInfo(column_info* cinfo)
{
    WiresharkPacketColumns columns;
    if (cinfo == nullptr) {
        return columns;
    }

    if (const char* protocol = col_get_text(cinfo, COL_PROTOCOL)) {
        columns.protocol = protocol;
    }
    if (const char* info = col_get_text(cinfo, COL_INFO)) {
        columns.info = info;
    }
    return columns;
}

WiresharkSourceSet ExtractByteSources(GSList* dataSources)
{
    WiresharkSourceSet sourceSet;
    unsigned index = 0;
    for (GSList* item = dataSources; item != nullptr; item = item->next) {
        auto* source = static_cast<data_source*>(item->data);
        tvbuff_t* tvb = get_data_source_tvb(source);
        if (tvb == nullptr) {
            continue;
        }

        char* description = get_data_source_description(source);
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
            const uint8_t* bytes = tvb_get_ptr(tvb, 0, static_cast<int>(length));
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

std::string SourceIdentifierForField(const field_info* field, const WiresharkSourceSet& sourceSet)
{
    if (field == nullptr || field->ds_tvb == nullptr) {
        return "frame";
    }

    auto match = sourceSet.idsByTVB.find(field->ds_tvb);
    return match == sourceSet.idsByTVB.end() ? "frame" : match->second;
}

std::string RawValueForRange(const WiresharkSourceSet& sourceSet, const ByteRange& range)
{
    auto sourceIndex = sourceSet.indexByID.find(range.sourceID);
    if (sourceIndex == sourceSet.indexByID.end()) {
        return "";
    }

    const auto& bytes = sourceSet.sources[sourceIndex->second].bytes;
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

std::optional<ByteRange> MakeRangeForField(const field_info* field, const std::string& sourceIdentifier)
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
        if (auto bitRange = MakeBitRangeFromMask(offset, field->length, field->hfinfo->bitmask)) {
            range = bitRange;
        }
    }

    if (!range.has_value()) {
        range = ByteRange{offset, length, 0, 0, false};
    }
    range->sourceID = sourceIdentifier;
    return range;
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

std::optional<DetailNode> MapProtoNode(proto_node* protoNode, const WiresharkSourceSet& sourceSet, uint64_t& sequence)
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

    for (proto_node* child = protoNode->first_child; child != nullptr; child = child->next) {
        if (auto childNode = MapProtoNode(child, sourceSet, sequence)) {
            node.children.push_back(std::move(*childNode));
        }
    }
    return node;
}

std::vector<DetailNode> MapProtoTree(proto_tree* tree, const WiresharkSourceSet& sourceSet)
{
    std::vector<DetailNode> nodes;
    uint64_t sequence = 1;
    if (tree == nullptr) {
        return nodes;
    }

    for (proto_node* child = tree->first_child; child != nullptr; child = child->next) {
        if (auto node = MapProtoNode(child, sourceSet, sequence)) {
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
    EpanDissectPtr firstPassDissect;
    nstime_t elapsedTime = NSTIME_INIT_ZERO;
    frame_data referenceFrame{};
    uint32_t cumulativeBytes = 0;
    std::unordered_set<uint32_t> observedFrameNumbers;
    bool firstPassFinished = false;

    static Impl*& activeSession()
    {
        static Impl* session = nullptr;
        return session;
    }

    void releaseWiresharkResourcesLocked(const std::string& reason)
    {
        firstPassDissect.reset();
        WiresharkSessionResources resources{epan, provider.frames, provider.frames_modified_blocks};
        epan = nullptr;
        provider.frames = nullptr;
        provider.frames_modified_blocks = nullptr;
        if (!reason.empty()) {
            unavailableReason = reason;
        }
        FreeWiresharkSessionResources(resources);
        firstPassFinished = true;
    }

    Impl()
    {
        auto& runtime = WiresharkRuntime::shared();
        unavailableReason = runtime.unavailableReason();
        if (!runtime.isAvailable()) {
            return;
        }

        std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
        if (auto* active = activeSession(); active != nullptr && active != this) {
            std::lock_guard<std::mutex> activeLock(active->mutex);
            active->releaseWiresharkResourcesLocked("Wireshark session was replaced by another capture.");
            activeSession() = nullptr;
        }

        provider.frames = new_frame_data_sequence();
        if (provider.frames == nullptr) {
            unavailableReason = "Wireshark frame storage could not be created.";
            return;
        }

        epan = epan_new(&provider, &kPacketProviderFuncs);
        if (epan == nullptr) {
            WiresharkSessionResources resources{nullptr, provider.frames, provider.frames_modified_blocks};
            provider.frames = nullptr;
            provider.frames_modified_blocks = nullptr;
            FreeWiresharkSessionResources(resources);
            unavailableReason = "Wireshark session could not be created.";
            return;
        }
        activeSession() = this;
        firstPassDissect.reset(epan_dissect_new(epan, false, false));
        if (!firstPassDissect) {
            unavailableReason = "Wireshark could not allocate a first-pass dissector.";
        }
    }

    ~Impl()
    {
        std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
        if (activeSession() == this) {
            activeSession() = nullptr;
        }
        releaseWiresharkResourcesLocked("");
    }

    bool hasSession() const
    {
        return epan != nullptr && provider.frames != nullptr;
    }

    bool canObservePackets() const
    {
        return hasSession() && firstPassDissect != nullptr && !firstPassFinished;
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
        if (!canObservePackets()) {
            unavailableReason = "Wireshark first-pass state is already finalized for this packet set.";
            return false;
        }

        if (context.interfaceName.has_value()) {
            provider.interfaceName = *context.interfaceName;
        }

        WiresharkRecord record(context);
        if (!record.isValid()) {
            unavailableReason = record.failureReason();
            return false;
        }

        if (!firstPassDissect) {
            unavailableReason = "Wireshark could not allocate a first-pass dissector.";
            return false;
        }

        frame_data frame{};
        frame_data_init(&frame, frameNumber, record.get(), cumulativeBytes, cumulativeBytes);
        frame_data_set_before_dissect(&frame, &elapsedTime, &provider.ref, provider.prev_dis);
        if (provider.ref == &frame) {
            referenceFrame = frame;
            provider.ref = &referenceFrame;
        }
        epan_dissect_run(firstPassDissect.get(), WTAP_FILE_TYPE_SUBTYPE_UNKNOWN, record.get(), &frame, nullptr);
        frame_data_set_after_dissect(&frame, &cumulativeBytes);

        provider.prev_cap = provider.prev_dis = frame_data_sequence_add(provider.frames, &frame);
        epan_dissect_reset(firstPassDissect.get());
        observedFrameNumbers.insert(frameNumber);
        observedPacketCount += 1;
        return true;
    }

    bool finishFirstPassLocked()
    {
        if (!hasSession()) {
            return false;
        }
        if (firstPassFinished) {
            return true;
        }

        // Keep sequence state alive for the second pass; Wireshark's postseq cleanup is process-global.
        firstPassDissect.reset();
        provider.prev_dis = nullptr;
        provider.prev_cap = nullptr;
        firstPassFinished = true;
        return true;
    }

    WiresharkDissectionResult runSecondPassLocked(const PacketDissectionContext& context, bool buildTree)
    {
        // Second pass uses the frame state captured during observePacketLocked() so columns and reassembly match Wireshark.
        WiresharkDissectionResult result;
        if (!hasSession()) {
            result.fallbackReason = unavailableReason;
            result.nodes.push_back(MakeUnavailableDetail(result.fallbackReason));
            return result;
        }

        const uint32_t expectedFrameNumber = FrameNumberForContext(context, observedPacketCount);
        if (expectedFrameNumber != kUnknownFrameNumber && observedFrameNumbers.find(expectedFrameNumber) == observedFrameNumbers.end() &&
            !observePacketLocked(context)) {
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

        WiresharkColumnInfo columnInfo;
        EpanDissectPtr dissect(epan_dissect_new(epan, buildTree, buildTree));
        if (!dissect) {
            result.fallbackReason = "Wireshark could not allocate a second-pass dissector.";
            result.nodes.push_back(MakeUnavailableDetail(result.fallbackReason));
            return result;
        }

        if (columnInfo.get() != nullptr) {
            col_custom_prime_edt(dissect.get(), columnInfo.get());
        }

        frame_data_set_before_dissect(frame, &elapsedTime, &provider.ref, provider.prev_dis);
        if (provider.ref == frame) {
            referenceFrame = *frame;
            provider.ref = &referenceFrame;
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
            result.byteSources = std::move(sourceSet.sources);
        }
        epan_dissect_reset(dissect.get());
        record.get()->block = block;
        result.usedWireshark = buildTree ? !result.nodes.empty() : (!result.columns.protocol.empty() || !result.columns.info.empty());
        if (!result.usedWireshark && buildTree) {
            result.fallbackReason = "Wireshark protocol-tree dissection returned no nodes for this packet.";
            result.nodes.push_back(MakeUnavailableDetail(result.fallbackReason));
        }
        return result;
    }

    WiresharkDissectionResult summarizePacketLocked(const PacketDissectionContext& context)
    {
        return runSecondPassLocked(context, false);
    }

    WiresharkDissectionResult dissectPacketLocked(const PacketDissectionContext& context)
    {
        return runSecondPassLocked(context, true);
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
    prefs_apply_all();
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
    return available_ && !WiresharkDisabledByEnvironment();
}

std::string WiresharkRuntime::unavailableReason() const
{
    if (WiresharkDisabledByEnvironment()) {
        return kBackendDisabledReason;
    }
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

bool WiresharkDissectionSession::finishFirstPass()
{
    auto& runtime = WiresharkRuntime::shared();
#if defined(TCPVIEWER_HAS_WIRESHARK) && TCPVIEWER_HAS_WIRESHARK
    if (runtime.isAvailable()) {
        std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
        std::lock_guard<std::mutex> sessionLock(impl_->mutex);
        return impl_->finishFirstPassLocked();
    }
#endif
    std::lock_guard<std::mutex> sessionLock(impl_->mutex);
    impl_->unavailableReason = runtime.unavailableReason();
    return false;
}

WiresharkDissectionResult WiresharkDissectionSession::summarizePacket(const PacketDissectionContext& context)
{
    auto& runtime = WiresharkRuntime::shared();
    WiresharkDissectionResult result;
#if defined(TCPVIEWER_HAS_WIRESHARK) && TCPVIEWER_HAS_WIRESHARK
    if (runtime.isAvailable()) {
        std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
        std::lock_guard<std::mutex> sessionLock(impl_->mutex);
        return impl_->summarizePacketLocked(context);
    }
#else
    (void)context;
#endif
    std::lock_guard<std::mutex> sessionLock(impl_->mutex);
    result.usedWireshark = false;
    result.fallbackReason = runtime.unavailableReason();
    impl_->unavailableReason = result.fallbackReason;
    return result;
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
        result.fallbackReason = runtime.unavailableReason();
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
