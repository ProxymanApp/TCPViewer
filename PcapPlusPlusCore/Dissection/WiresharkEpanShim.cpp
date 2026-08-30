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
#include <epan/dissectors/packet-tcp.h>
#include <epan/dfilter/dfilter.h>
#include <epan/epan.h>
#include <epan/epan_dissect.h>
#include <epan/exceptions.h>
#include <epan/follow.h>
#include <epan/frame_data_sequence.h>
#include <epan/packet.h>
#include <epan/prefs.h>
#include <epan/proto.h>
#include <epan/tap.h>
#include <epan/timestamp.h>
#include <epan/to_str.h>
#include <epan/tvbuff.h>
#include <wiretap/pcap-encap.h>
#include <wiretap/wtap.h>
#include <wiretap/wtap_opttypes.h>
#include <wsutil/buffer.h>
#include <wsutil/filesystem.h>

#if defined(__APPLE__)
#include <mach-o/dyld.h>
#endif

extern "C" void TCPViewerWiresharkIPDisplayFilterPluginRegister(void);

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
constexpr size_t kMaximumInspectorByteSources = 32;
constexpr size_t kMaximumInspectorByteSourceBytes = 16 * 1024 * 1024;
constexpr size_t kMaximumInspectorRawValueBytes = 4 * 1024;
constexpr size_t kMaximumInspectorDisplayFilterValueBytes = 4 * 1024;
constexpr size_t kMaximumInspectorNodes = 20 * 1024;
constexpr size_t kMaximumInspectorDepth = 128;
constexpr size_t kMaximumInspectorTextLength = 16 * 1024;

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
    std::string displayFilterExpression;
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
    bool hasDisplayFilterMatch = false;
    bool displayFilterMatched = false;
    uint64_t displayFilterGeneration = 0;
};

struct DisplayFilterDiagnosticCopy {
    TCPViewerDisplayFilterDiagnosticSeverity severity = TCPViewerDisplayFilterDiagnosticError;
    std::string message;
    size_t utf8StartOffset = 0;
    size_t utf8Length = 0;
    bool hasRange = false;
};

struct DisplayFilterValidationCopy {
    TCPViewerDisplayFilterValidationStatus status = TCPViewerDisplayFilterValidationUnavailable;
    std::string normalizedExpression;
    std::vector<DisplayFilterDiagnosticCopy> diagnostics;
    dfilter_t *compiledFilter = nullptr;
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

struct WiresharkCriticalException {
    bool isCriticalException = true;
    unsigned long exceptionGroup = 0;
    unsigned long exceptionCode = 0;
    uint64_t packetIdentifier = 0;
    bool hasPacketIdentifier = false;
    std::string operation;
    std::string exceptionName;
    std::string reason;
};

std::mutex &WiresharkAPIMutex()
{
    // libwireshark has process-wide registries, so all epan entry points share one lock.
    // Keep the lock alive until process exit; test runners can tear down Swift objects late.
    static auto *mutex = new std::mutex();
    return *mutex;
}

#if DEBUG
size_t gDisplayFilterCompilationCount = 0;
#endif

std::string CurrentExecutablePath()
{
#if defined(__APPLE__)
    uint32_t size = 0;
    _NSGetExecutablePath(nullptr, &size);
    if (size > 0) {
        std::vector<char> buffer(size);
        if (_NSGetExecutablePath(buffer.data(), &size) == 0) {
            return std::string(buffer.data());
        }
    }
#endif
    return "TCPViewer";
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

std::string TrimASCIIWhitespace(const char *expression)
{
    if (expression == nullptr) {
        return "";
    }
    std::string value(expression);
    const auto first = value.find_first_not_of(" \t\r\n\f\v");
    if (first == std::string::npos) {
        return "";
    }
    const auto last = value.find_last_not_of(" \t\r\n\f\v");
    return value.substr(first, last - first + 1);
}

std::optional<std::pair<size_t, size_t>> UnsupportedDollarTokenRange(const std::string &expression)
{
    enum class LiteralState { None, Quoted, Raw, Character };
    LiteralState state = LiteralState::None;
    bool escaped = false;

    for (size_t index = 0; index < expression.size(); index += 1) {
        const char character = expression[index];
        switch (state) {
            case LiteralState::Quoted:
            case LiteralState::Character:
                if (escaped) {
                    escaped = false;
                } else if (character == '\\') {
                    escaped = true;
                } else if ((state == LiteralState::Quoted && character == '"')
                           || (state == LiteralState::Character && character == '\'')) {
                    state = LiteralState::None;
                }
                continue;
            case LiteralState::Raw:
                if (character == '"') {
                    state = LiteralState::None;
                }
                continue;
            case LiteralState::None:
                break;
        }

        if ((character == 'r' || character == 'R')
            && index + 1 < expression.size() && expression[index + 1] == '"') {
            state = LiteralState::Raw;
            index += 1;
            continue;
        }
        if (character == '"') {
            state = LiteralState::Quoted;
            continue;
        }
        if (character == '\'') {
            state = LiteralState::Character;
            continue;
        }
        if (character != '$') {
            continue;
        }

        size_t end = index + 1;
        if (end < expression.size() && expression[end] == '{') {
            end += 1;
            while (end < expression.size() && expression[end] != '}') {
                end += 1;
            }
            if (end < expression.size()) {
                end += 1;
            }
        } else {
            while (end < expression.size()) {
                const unsigned char next = static_cast<unsigned char>(expression[end]);
                if (!(std::isalnum(next) || next == '_' || next == '.')) {
                    break;
                }
                end += 1;
            }
        }
        return std::pair<size_t, size_t>{index, end - index};
    }
    return std::nullopt;
}

DisplayFilterValidationCopy CompileDisplayFilter(const char *expression)
{
    DisplayFilterValidationCopy validation;
    const std::string sourceExpression = expression == nullptr ? "" : expression;
    validation.normalizedExpression = TrimASCIIWhitespace(expression);
    if (validation.normalizedExpression.empty()) {
        validation.status = TCPViewerDisplayFilterValidationValid;
        return validation;
    }

    if (auto range = UnsupportedDollarTokenRange(sourceExpression)) {
        validation.status = TCPViewerDisplayFilterValidationInvalid;
        validation.diagnostics.push_back(DisplayFilterDiagnosticCopy{
            TCPViewerDisplayFilterDiagnosticError,
            "Macros and selected-frame $field references are not supported.",
            range->first,
            range->second,
            true,
        });
        return validation;
    }

#if DEBUG
    gDisplayFilterCompilationCount += 1;
#endif
    dfilter_t *compiled = nullptr;
    df_error_t *error = nullptr;
    const bool succeeded = dfilter_compile_full(
        sourceExpression.c_str(),
        &compiled,
        &error,
        DF_OPTIMIZE,
        "TCPViewerDisplayFilter"
    );
    if (!succeeded) {
        validation.status = TCPViewerDisplayFilterValidationInvalid;
        DisplayFilterDiagnosticCopy diagnostic;
        diagnostic.message = error != nullptr && error->msg != nullptr
            ? error->msg
            : "Wireshark could not compile this display filter.";
        if (error != nullptr && error->loc.col_start >= 0) {
            diagnostic.hasRange = true;
            diagnostic.utf8StartOffset = static_cast<size_t>(error->loc.col_start);
            diagnostic.utf8Length = error->loc.col_len;
        } else {
            // Wireshark omits locations for incomplete trailing grammar, so place the caret at the end.
            diagnostic.hasRange = true;
            diagnostic.utf8StartOffset = sourceExpression.size();
            diagnostic.utf8Length = 0;
        }
        validation.diagnostics.push_back(std::move(diagnostic));
        df_error_free(&error);
        dfilter_free(compiled);
        return validation;
    }

    validation.status = TCPViewerDisplayFilterValidationValid;
    validation.compiledFilter = compiled;
    if (compiled != nullptr) {
        for (GSList *item = dfilter_get_warnings(compiled); item != nullptr; item = item->next) {
            const auto *message = static_cast<const char *>(item->data);
            if (message != nullptr && message[0] != '\0') {
                validation.diagnostics.push_back(DisplayFilterDiagnosticCopy{
                    TCPViewerDisplayFilterDiagnosticWarning,
                    message,
                    0,
                    0,
                    false,
                });
            }
        }
        if (GPtrArray *deprecated = dfilter_deprecated_tokens(compiled)) {
            for (guint index = 0; index < deprecated->len; index += 1) {
                const auto *token = static_cast<const char *>(g_ptr_array_index(deprecated, index));
                if (token != nullptr && token[0] != '\0') {
                    validation.diagnostics.push_back(DisplayFilterDiagnosticCopy{
                        TCPViewerDisplayFilterDiagnosticWarning,
                        std::string("Deprecated display-filter token: ") + token,
                        0,
                        0,
                        false,
                    });
                }
            }
        }
    }
    return validation;
}

TCPViewerDisplayFilterValidationResult *CopyDisplayFilterValidation(const DisplayFilterValidationCopy &source)
{
    auto *result = static_cast<TCPViewerDisplayFilterValidationResult *>(std::calloc(1, sizeof(TCPViewerDisplayFilterValidationResult)));
    if (result == nullptr) {
        return nullptr;
    }
    result->status = source.status;
    result->normalizedExpression = CopyCString(source.normalizedExpression, false);
    result->diagnosticCount = source.diagnostics.size();
    if (result->diagnosticCount == 0) {
        return result;
    }
    result->diagnostics = static_cast<TCPViewerDisplayFilterDiagnostic *>(
        std::calloc(result->diagnosticCount, sizeof(TCPViewerDisplayFilterDiagnostic))
    );
    if (result->diagnostics == nullptr) {
        result->diagnosticCount = 0;
        return result;
    }
    for (size_t index = 0; index < result->diagnosticCount; index += 1) {
        const auto &diagnostic = source.diagnostics[index];
        result->diagnostics[index].severity = diagnostic.severity;
        result->diagnostics[index].message = CopyCString(diagnostic.message, false);
        result->diagnostics[index].utf8StartOffset = diagnostic.utf8StartOffset;
        result->diagnostics[index].utf8Length = diagnostic.utf8Length;
        result->diagnostics[index].hasRange = diagnostic.hasRange;
    }
    return result;
}

const char *WiresharkExceptionName(unsigned long code)
{
    switch (code) {
        case BoundsError:
            return "BoundsError";
        case ContainedBoundsError:
            return "ContainedBoundsError";
        case ReportedBoundsError:
            return "ReportedBoundsError";
        case FragmentBoundsError:
            return "FragmentBoundsError";
        case TypeError:
            return "TypeError";
        case DissectorError:
            return "DissectorError";
        case ScsiBoundsError:
            return "ScsiBoundsError";
        case OutOfMemoryError:
            return "OutOfMemoryError";
        case ReassemblyError:
            return "ReassemblyError";
        default:
            return "Unknown";
    }
}

std::string CriticalExceptionReason(const std::string &operation)
{
    return "Wireshark raised a critical exception while " + operation + ". TCP Viewer stopped this operation to keep the app running.";
}

WiresharkCriticalException MakeCriticalException(const char *operation, except_t *exception, std::optional<uint64_t> packetIdentifier)
{
    WiresharkCriticalException report;
    report.exceptionGroup = exception == nullptr ? 0 : except_group(exception);
    report.exceptionCode = exception == nullptr ? 0 : except_code(exception);
    report.operation = operation == nullptr || operation[0] == '\0' ? "running Wireshark" : operation;
    report.exceptionName = WiresharkExceptionName(report.exceptionCode);
    report.reason = CriticalExceptionReason(report.operation);
    if (packetIdentifier.has_value()) {
        report.packetIdentifier = *packetIdentifier;
        report.hasPacketIdentifier = true;
    }
    return report;
}

template <typename Body>
std::optional<WiresharkCriticalException> CatchWiresharkException(const char *operation, std::optional<uint64_t> packetIdentifier, Body body)
{
    static const except_id_t catchSpec[] = {{XCEPT_GROUP_WIRESHARK, XCEPT_CODE_ANY}};
    struct except_stacknode stackNode;
    struct except_catch catcher;
    std::optional<WiresharkCriticalException> report;

    except_setup_try(&stackNode, &catcher, catchSpec, 1);
    if (setjmp(catcher.except_jmp) == 0) {
        body();
    } else {
        report = MakeCriticalException(operation, &catcher.except_obj, packetIdentifier);
    }
    except_free(catcher.except_obj.except_dyndata);
    except_pop();
    return report;
}

using WiresharkCriticalExceptionReports = std::vector<WiresharkCriticalException>;

void AppendCriticalExceptionIfNeeded(WiresharkCriticalExceptionReports &reports, std::optional<WiresharkCriticalException> report)
{
    if (report.has_value()) {
        reports.push_back(std::move(*report));
    }
}

TCPViewerWiresharkExceptionReport *CopyExceptionReport(const WiresharkCriticalException &report)
{
    auto *copy = static_cast<TCPViewerWiresharkExceptionReport *>(std::calloc(1, sizeof(TCPViewerWiresharkExceptionReport)));
    if (copy == nullptr) {
        return nullptr;
    }
    copy->isCriticalException = report.isCriticalException;
    copy->exceptionGroup = report.exceptionGroup;
    copy->exceptionCode = report.exceptionCode;
    copy->packetIdentifier = report.packetIdentifier;
    copy->hasPacketIdentifier = report.hasPacketIdentifier;
    copy->operation = CopyCString(report.operation);
    copy->exceptionName = CopyCString(report.exceptionName);
    copy->reason = CopyCString(report.reason, false);
    return copy;
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

std::optional<WiresharkCriticalException> FreeEpanDissect(epan_dissect_t *&dissect, const char *operation, std::optional<uint64_t> packetIdentifier)
{
    if (dissect == nullptr) {
        return std::nullopt;
    }
    auto *dissectToFree = dissect;
    dissect = nullptr;
    return CatchWiresharkException(operation, packetIdentifier, [dissectToFree] {
        epan_dissect_free(dissectToFree);
    });
}

WiresharkCriticalExceptionReports FreeWiresharkSessionResources(WiresharkSessionResources &resources)
{
    WiresharkCriticalExceptionReports reports;
    if (resources.epan != nullptr) {
        auto *epan = resources.epan;
        AppendCriticalExceptionIfNeeded(
            reports,
            CatchWiresharkException("freeing Wireshark session", std::nullopt, [epan] {
                epan_free(epan);
            })
        );
        resources.epan = nullptr;
    }
    if (resources.provider == nullptr) {
        return reports;
    }
    if (resources.provider->frames != nullptr) {
        auto *frames = resources.provider->frames;
        AppendCriticalExceptionIfNeeded(
            reports,
            CatchWiresharkException("freeing Wireshark frame storage", std::nullopt, [frames] {
                free_frame_data_sequence(frames);
            })
        );
        resources.provider->frames = nullptr;
    }
    if (resources.provider->frames_modified_blocks != nullptr) {
        auto *blocks = resources.provider->frames_modified_blocks;
        AppendCriticalExceptionIfNeeded(
            reports,
            CatchWiresharkException("freeing Wireshark frame metadata", std::nullopt, [blocks] {
                g_tree_destroy(blocks);
            })
        );
        resources.provider->frames_modified_blocks = nullptr;
    }
    resources.provider.reset();
    return reports;
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
    WiresharkColumnInfo(bool isNeeded, bool includesAllRegisteredColumns)
    {
        if (!isNeeded) {
            return;
        }
        if (includesAllRegisteredColumns) {
            // Mirror Wireshark's registered preference columns so _ws.col.* fields use valid column metadata.
            build_column_format_array(&info_, prefs.num_cols, true);
            initialized_ = true;
            return;
        }

        const int formats[] = {COL_PROTOCOL, COL_INFO};
        const int columnCount = 2;
        col_setup(&info_, columnCount);
        for (int index = 0; index < columnCount; index += 1) {
            info_.columns[index].col_fmt = formats[index];
            info_.columns[index].col_title = nullptr;
            info_.columns[index].col_fence = 0;
        }
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
    size_t remainingBytes = kMaximumInspectorByteSourceBytes;
    for (GSList *item = dataSources; item != nullptr; item = item->next) {
        if (sourceSet.sources.size() >= kMaximumInspectorByteSources || remainingBytes == 0) {
            break;
        }
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

        const size_t length = std::min(static_cast<size_t>(tvb_captured_length(tvb)), remainingBytes);
        if (length > 0 && length <= static_cast<size_t>(std::numeric_limits<int>::max())) {
            const uint8_t *bytes = tvb_get_ptr(tvb, 0, static_cast<int>(length));
            if (bytes != nullptr) {
                byteSource.bytes.assign(bytes, bytes + length);
                remainingBytes -= length;
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
    const size_t displayedLength = std::min(range.length, kMaximumInspectorRawValueBytes);
    auto value = HexBytes(bytes.data() + range.offset, displayedLength);
    if (displayedLength < range.length) {
        value += " … (truncated)";
    }
    return value;
}

std::string TruncateInspectorText(std::string value)
{
    if (value.size() <= kMaximumInspectorTextLength) {
        return value;
    }
    value.resize(kMaximumInspectorTextLength);
    value += "…";
    return value;
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

struct InspectorTreeBudget {
    size_t remainingNodes = kMaximumInspectorNodes;
    bool reportedTruncation = false;
};

std::optional<DetailNode> InspectorTruncationNode(InspectorTreeBudget &budget, uint64_t &sequence)
{
    if (budget.reportedTruncation) {
        return std::nullopt;
    }
    budget.reportedTruncation = true;
    DetailNode node;
    node.id = "tcpviewer.inspector.truncated." + std::to_string(sequence++);
    node.title = "Inspector output truncated";
    node.fieldName = "tcpviewer.inspector.truncated";
    node.displayValue = "Wireshark returned more detail than TCP Viewer can safely display.";
    node.kind = NodeKind::Warning;
    node.severity = NodeSeverity::Warning;
    return node;
}

bool HasOversizedDisplayFilterValue(const field_info *field)
{
    const auto type = field->hfinfo->type;
    switch (type) {
        case FT_NONE:
        case FT_STRING:
        case FT_STRINGZ:
        case FT_UINT_STRING:
        case FT_BYTES:
        case FT_UINT_BYTES:
        case FT_OID:
        case FT_REL_OID:
        case FT_SYSTEM_ID:
        case FT_STRINGZPAD:
        case FT_STRINGZTRUNC:
            if (field->length > static_cast<int>(kMaximumInspectorDisplayFilterValueBytes)) {
                return true;
            }
            return field->value != nullptr
                && ftype_can_length(type)
                && fvalue_length2(field->value) > kMaximumInspectorDisplayFilterValueBytes;
        default:
            return false;
    }
}

// Copy Wireshark's typed match-selected filter without serializing oversized payload values.
std::string DisplayFilterExpressionForField(field_info *field, epan_dissect_t *dissect)
{
    if (HasOversizedDisplayFilterValue(field)) {
        return "";
    }
    char *expression = proto_construct_match_selected_string(field, dissect);
    if (expression == nullptr) {
        return "";
    }
    const size_t expressionLength = std::strlen(expression);
    if (expressionLength > kMaximumInspectorTextLength) {
        wmem_free(nullptr, expression);
        return "";
    }
    std::string copiedExpression(expression, expressionLength);
    wmem_free(nullptr, expression);
    return copiedExpression;
}

std::optional<DetailNode> MapProtoNode(
    proto_node *protoNode,
    const WiresharkSourceSet &sourceSet,
    epan_dissect_t *dissect,
    uint64_t &sequence,
    InspectorTreeBudget &budget,
    size_t depth
)
{
    // Wireshark frees proto_tree data with the epan dissector, so copy every field now.
    if (depth >= kMaximumInspectorDepth || budget.remainingNodes == 0) {
        return InspectorTruncationNode(budget, sequence);
    }
    field_info *field = PNODE_FINFO(protoNode);
    if (field == nullptr || field->hfinfo == nullptr || FI_GET_FLAG(field, FI_HIDDEN)) {
        return std::nullopt;
    }
    budget.remainingNodes -= 1;

    size_t valueOffset = 0;
    const std::string label = LabelForField(field, valueOffset);
    const header_field_info *header = field->hfinfo;
    DetailNode node;
    node.fieldName = header->abbrev != nullptr ? header->abbrev : "";
    node.title = TruncateInspectorText(header->name != nullptr ? header->name : label);
    node.displayValue = valueOffset < label.size() ? TruncateInspectorText(TrimDisplayValue(label.substr(valueOffset))) : "";
    if (node.displayValue.empty() && label != node.title) {
        node.displayValue = TruncateInspectorText(TrimDisplayValue(label));
    }
    node.displayFilterExpression = DisplayFilterExpressionForField(field, dissect);
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
        if (auto childNode = MapProtoNode(child, sourceSet, dissect, sequence, budget, depth + 1)) {
            node.children.push_back(std::move(*childNode));
        }
        if (budget.remainingNodes == 0) {
            break;
        }
    }
    return node;
}

std::vector<DetailNode> MapProtoTree(proto_tree *tree, const WiresharkSourceSet &sourceSet, epan_dissect_t *dissect)
{
    std::vector<DetailNode> nodes;
    uint64_t sequence = 1;
    InspectorTreeBudget budget;
    if (tree == nullptr) {
        return nodes;
    }
    for (proto_node *child = tree->first_child; child != nullptr; child = child->next) {
        if (auto node = MapProtoNode(child, sourceSet, dissect, sequence, budget, 0)) {
            nodes.push_back(std::move(*node));
        }
        if (budget.remainingNodes == 0) {
            break;
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
    copied.displayFilterExpression = CopyCString(node.displayFilterExpression);
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
    std::free(const_cast<char *>(node.displayFilterExpression));
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
    static WiresharkRuntime &shared(const char *personalConfigurationDirectory)
    {
        static WiresharkRuntime runtime(personalConfigurationDirectory);
        return runtime;
    }

    bool isAvailable() const { return available_; }
    const std::string &unavailableReason() const { return unavailableReason_; }
    const std::optional<WiresharkCriticalException> &criticalException() const { return criticalException_; }
    const WiresharkCriticalExceptionReports &criticalExceptionReports() const { return criticalExceptionReports_; }

private:
    void recordCriticalException(WiresharkCriticalException report)
    {
        if (!criticalException_.has_value()) {
            criticalException_ = report;
        }
        criticalExceptionReports_.push_back(std::move(report));
    }

    void cleanupEpanAfterSetupFailure()
    {
        if (auto report = CatchWiresharkException("cleaning up Wireshark protocol registry after setup failure", std::nullopt, [] {
                epan_cleanup();
            })) {
            recordCriticalException(std::move(*report));
        }
    }

    void cleanupWiretapAfterSetupFailure()
    {
        if (auto report = CatchWiresharkException("cleaning up Wireshark Wiretap after setup failure", std::nullopt, [] {
                wtap_cleanup();
            })) {
            recordCriticalException(std::move(*report));
        }
    }

    explicit WiresharkRuntime(const char *personalConfigurationDirectory)
    {
        std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
        if (personalConfigurationDirectory == nullptr || personalConfigurationDirectory[0] == '\0') {
            available_ = false;
            unavailableReason_ = "Wireshark personal configuration directory is unavailable.";
            return;
        }
        // Wireshark resolves bundled data relative to the host executable path.
        const auto executablePath = CurrentExecutablePath();
        if (char *configurationError = configuration_init(executablePath.c_str())) {
            available_ = false;
            unavailableReason_ = std::string("Wireshark configuration initialization failed: ") + configurationError;
            g_free(configurationError);
            return;
        }
        set_persconffile_dir(personalConfigurationDirectory);
        if (except_init() == 0) {
            available_ = false;
            unavailableReason_ = "Wireshark exception handling failed to initialize.";
            return;
        }
        initializedExceptions_ = true;
        // Column-backed filters need the same timestamp defaults as Wireshark's command-line tools.
        timestamp_set_type(TS_RELATIVE);
        timestamp_set_precision(TS_PREC_AUTO);
        timestamp_set_seconds_type(TS_SECONDS_DEFAULT);
        if (auto report = CatchWiresharkException("initializing Wireshark Wiretap", std::nullopt, [] {
                wtap_init(false);
            })) {
            recordCriticalException(std::move(*report));
            available_ = false;
            unavailableReason_ = criticalException_->reason;
            return;
        }
        initializedWiretap_ = true;
        TCPViewerWiresharkIPDisplayFilterPluginRegister();
        bool didInitializeEpan = false;
        if (auto report = CatchWiresharkException("initializing Wireshark protocol registry", std::nullopt, [&didInitializeEpan] {
                didInitializeEpan = epan_init(nullptr, nullptr, false);
            })) {
            recordCriticalException(std::move(*report));
            available_ = false;
            unavailableReason_ = criticalException_->reason;
            cleanupEpanAfterSetupFailure();
            cleanupWiretapAfterSetupFailure();
            initializedWiretap_ = false;
            return;
        }
        if (!didInitializeEpan) {
            available_ = false;
            unavailableReason_ = "Wireshark protocol registry failed to initialize.";
            cleanupEpanAfterSetupFailure();
            cleanupWiretapAfterSetupFailure();
            initializedWiretap_ = false;
            return;
        }
        initializedEpan_ = true;
        if (auto report = CatchWiresharkException("loading Wireshark settings", std::nullopt, [] {
                epan_load_settings();
                prefs_apply_all();
            })) {
            recordCriticalException(std::move(*report));
            available_ = false;
            unavailableReason_ = criticalException_->reason;
            cleanupEpanAfterSetupFailure();
            cleanupWiretapAfterSetupFailure();
            initializedEpan_ = false;
            initializedWiretap_ = false;
            return;
        }
        available_ = true;
        unavailableReason_.clear();
    }

    ~WiresharkRuntime()
    {
        std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
        if (initializedEpan_) {
            if (auto report = CatchWiresharkException("cleaning up Wireshark protocol registry", std::nullopt, [] {
                    epan_cleanup();
                })) {
                recordCriticalException(std::move(*report));
            }
        }
        if (initializedWiretap_) {
            if (auto report = CatchWiresharkException("cleaning up Wireshark Wiretap", std::nullopt, [] {
                    wtap_cleanup();
                })) {
                recordCriticalException(std::move(*report));
            }
        }
        if (initializedExceptions_) {
            except_deinit();
        }
    }

    bool available_ = false;
    bool initializedExceptions_ = false;
    bool initializedWiretap_ = false;
    bool initializedEpan_ = false;
    std::string unavailableReason_ = kBackendUnavailableReason;
    std::optional<WiresharkCriticalException> criticalException_;
    WiresharkCriticalExceptionReports criticalExceptionReports_;
};

}  // namespace

struct TCPViewerWiresharkSession {
    struct TCPFollowTapContext {
        TCPViewerWiresharkSession *session = nullptr;
        TCPViewerWiresharkFollowDirection direction = TCPViewerWiresharkFollowBothDirections;
    };

    mutable std::mutex mutex;
    std::string unavailableReason = kBackendUnavailableReason;
    std::unique_ptr<packet_provider_data> provider;
    epan_t *epan = nullptr;
    epan_dissect_t *firstPassDissect = nullptr;
    nstime_t elapsedTime = NSTIME_INIT_ZERO;
    frame_data referenceFrame{};
    uint32_t cumulativeBytes = 0;
    std::unordered_set<uint32_t> storedFrameNumbers;
    std::unordered_set<uint32_t> activeFrameNumbers;
    std::unordered_map<uint64_t, uint32_t> frameNumberByPacketIdentifier;
    std::vector<uint64_t> packetIdentifierByFrameNumber;
    std::vector<std::optional<uint32_t>> tcpStreamNumberByFrameNumber;
    std::unordered_map<uint64_t, uint32_t> tcpStreamNumberByPacketIdentifier;
    std::vector<std::pair<uint32_t, uint32_t>> pendingTCPStreamFrames;
    std::vector<std::pair<uint64_t, uint32_t>> pendingTCPStreamIndexUpdates;
    std::deque<WiresharkCriticalException> pendingCriticalExceptions;
    dfilter_t *activeDisplayFilter = nullptr;
    std::string activeDisplayFilterExpression;
    uint64_t activeDisplayFilterGeneration = 0;
    follow_info_t *followInfo = nullptr;
    TCPFollowTapContext *followTapContext = nullptr;
    register_follow_t *tcpFollower = nullptr;
    const frame_data *followReference = nullptr;
    frame_data followReferenceFrame{};
    frame_data *followPreviousFrame = nullptr;
    nstime_t followElapsedTime = NSTIME_INIT_ZERO;
    bool followTapRegistered = false;
    bool processingFollowPacket = false;
    bool tcpIndexTapRegistered = false;
    bool collectingTCPStreamIndex = false;
    bool followTruncated = false;
    uint64_t followPayloadByteCount = 0;
    GList *followNewestPayloadItem = nullptr;
    std::string personalConfigurationDirectory;
    bool disabled = false;
    bool livePriority = false;
    bool firstPassFinished = false;
    bool backendAvailable = false;

    static TCPViewerWiresharkSession *&activeSession()
    {
        static TCPViewerWiresharkSession *session = nullptr;
        return session;
    }

    static TCPViewerWiresharkSession *&activeFollowSession()
    {
        static TCPViewerWiresharkSession *session = nullptr;
        return session;
    }

    static tap_packet_status indexTCPPacket(
        void *tapData,
        packet_info *packetInfo,
        epan_dissect_t *,
        const void *data,
        tap_flags_t
    ) {
        auto *session = static_cast<TCPViewerWiresharkSession *>(tapData);
        auto *header = static_cast<const tcp_info_t *>(data);
        if (session == nullptr || packetInfo == nullptr || header == nullptr || !session->collectingTCPStreamIndex) {
            return TAP_PACKET_DONT_REDRAW;
        }

        session->recordTCPStreamFrameLocked(packetInfo->num, header->th_stream);
        if (packetInfo->fd != nullptr && packetInfo->fd->dependent_frames != nullptr) {
            GHashTableIter iterator;
            gpointer frameNumber = nullptr;
            g_hash_table_iter_init(&iterator, packetInfo->fd->dependent_frames);
            while (g_hash_table_iter_next(&iterator, &frameNumber, nullptr)) {
                session->recordTCPStreamFrameLocked(GPOINTER_TO_UINT(frameNumber), header->th_stream);
            }
        }
        return TAP_PACKET_DONT_REDRAW;
    }

    static tap_packet_status followTCPPacket(
        void *tapData,
        packet_info *packetInfo,
        epan_dissect_t *dissect,
        const void *data,
        tap_flags_t flags
    ) {
        auto *context = static_cast<TCPFollowTapContext *>(tapData);
        auto *session = context == nullptr ? nullptr : context->session;
        if (session == nullptr || !session->processingFollowPacket
            || session->followInfo == nullptr || session->tcpFollower == nullptr) {
            return TAP_PACKET_DONT_REDRAW;
        }
        const auto status = get_follow_tap_handler(session->tcpFollower)(
            session->followInfo,
            packetInfo,
            dissect,
            data,
            flags
        );
        session->discardExcludedNewestFollowPayloadLocked(context->direction);
        return status;
    }

    void recordTCPStreamFrameLocked(uint32_t frameNumber, uint32_t streamNumber)
    {
        if (frameNumber == kUnknownFrameNumber) {
            return;
        }
        if (tcpStreamNumberByFrameNumber.size() <= frameNumber) {
            tcpStreamNumberByFrameNumber.resize(static_cast<size_t>(frameNumber) + 1);
        }
        const auto existing = tcpStreamNumberByFrameNumber[frameNumber];
        if (existing.has_value() && existing.value() == streamNumber) {
            return;
        }
        tcpStreamNumberByFrameNumber[frameNumber] = streamNumber;
        pendingTCPStreamFrames.emplace_back(frameNumber, streamNumber);
    }

    // Translate tap frame numbers only after observePacketLocked has published its packet-ID mapping.
    void finalizeTCPStreamIndexUpdatesLocked()
    {
        for (const auto &[frameNumber, streamNumber] : pendingTCPStreamFrames) {
            if (frameNumber >= packetIdentifierByFrameNumber.size()) {
                continue;
            }
            const uint64_t packetIdentifier = packetIdentifierByFrameNumber[frameNumber];
            const auto existing = tcpStreamNumberByPacketIdentifier.find(packetIdentifier);
            // A reactivated offline session may assign new local stream numbers to isolated packets.
            // Preserve the authoritative index built while the complete capture was first observed.
            if (existing != tcpStreamNumberByPacketIdentifier.end()) {
                continue;
            }
            tcpStreamNumberByPacketIdentifier[packetIdentifier] = streamNumber;
            pendingTCPStreamIndexUpdates.emplace_back(packetIdentifier, streamNumber);
        }
        pendingTCPStreamFrames.clear();
    }

    TCPViewerWiresharkSession(bool disablesWireshark, bool hasLivePriority, const char *personalConfigurationDirectory)
    {
        livePriority = hasLivePriority;
        this->personalConfigurationDirectory = personalConfigurationDirectory == nullptr ? "" : personalConfigurationDirectory;
        if (disablesWireshark) {
            disabled = true;
            unavailableReason = kBackendDisabledReason;
            firstPassFinished = true;
            return;
        }
        auto &runtime = WiresharkRuntime::shared(this->personalConfigurationDirectory.c_str());
        backendAvailable = runtime.isAvailable();
        unavailableReason = runtime.unavailableReason();
        for (const auto &report : runtime.criticalExceptionReports()) {
            pendingCriticalExceptions.push_back(report);
        }
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

    void clearCriticalExceptionsLocked()
    {
        pendingCriticalExceptions.clear();
    }

    bool hasCriticalExceptionLocked() const
    {
        return !pendingCriticalExceptions.empty();
    }

    void recordCriticalExceptionLocked(WiresharkCriticalException report, bool updateUnavailableReason)
    {
        if (updateUnavailableReason || unavailableReason.empty()) {
            unavailableReason = report.reason;
        }
        pendingCriticalExceptions.push_back(std::move(report));
    }

    void recordCriticalExceptionsLocked(WiresharkCriticalExceptionReports reports, bool updateUnavailableReason)
    {
        for (auto &report : reports) {
            recordCriticalExceptionLocked(std::move(report), updateUnavailableReason);
            updateUnavailableReason = false;
        }
    }

    bool failWithCriticalExceptionLocked(WiresharkCriticalException report)
    {
        recordCriticalExceptionLocked(std::move(report), true);
        releaseWiresharkResourcesLocked(unavailableReason, true);
        return false;
    }

    void resetActiveFrameStateLocked()
    {
        storedFrameNumbers.clear();
        activeFrameNumbers.clear();
        frameNumberByPacketIdentifier.clear();
        packetIdentifierByFrameNumber.clear();
        tcpStreamNumberByFrameNumber.clear();
        pendingTCPStreamFrames.clear();
        pendingTCPStreamIndexUpdates.clear();
        collectingTCPStreamIndex = false;
        nstime_set_zero(&elapsedTime);
        referenceFrame = frame_data{};
        cumulativeBytes = 0;
        if (provider != nullptr) {
            provider->ref = nullptr;
            provider->prev_dis = nullptr;
            provider->prev_cap = nullptr;
        }
    }

    void clearActiveDisplayFilterLocked()
    {
        if (activeDisplayFilter != nullptr) {
            dfilter_free(activeDisplayFilter);
            activeDisplayFilter = nullptr;
        }
        activeDisplayFilterExpression.clear();
        activeDisplayFilterGeneration = 0;
    }

    void releaseWiresharkResourcesLocked(const std::string &reason, bool finishSession)
    {
        cancelFollowLocked();
        clearActiveDisplayFilterLocked();
        if (tcpIndexTapRegistered) {
            if (auto report = CatchWiresharkException("removing Wireshark TCP stream index listener", std::nullopt, [&] {
                    remove_tap_listener(this);
                })) {
                recordCriticalExceptionLocked(std::move(*report), false);
            }
            tcpIndexTapRegistered = false;
        }
        if (activeSession() == this) {
            activeSession() = nullptr;
        }
        if (auto report = FreeEpanDissect(firstPassDissect, "freeing Wireshark first-pass dissector", std::nullopt)) {
            recordCriticalExceptionLocked(std::move(*report), false);
        }
        WiresharkSessionResources resources{epan, std::move(provider)};
        epan = nullptr;
        if (!reason.empty()) {
            unavailableReason = reason;
        }
        recordCriticalExceptionsLocked(FreeWiresharkSessionResources(resources), false);
        resetActiveFrameStateLocked();
        if (finishSession) {
            firstPassFinished = true;
        }
    }

    DisplayFilterValidationCopy activateDisplayFilterLocked(const char *expression, uint64_t generation)
    {
        DisplayFilterValidationCopy validation;
        if (!ensureActiveSessionLocked()) {
            validation.normalizedExpression = TrimASCIIWhitespace(expression);
            validation.status = TCPViewerDisplayFilterValidationUnavailable;
            validation.diagnostics.push_back(DisplayFilterDiagnosticCopy{
                TCPViewerDisplayFilterDiagnosticError,
                unavailableReason.empty() ? kBackendUnavailableReason : unavailableReason,
                0,
                0,
                false,
            });
            return validation;
        }

        const std::string normalizedExpression = TrimASCIIWhitespace(expression);
        if (activeDisplayFilter != nullptr
            && activeDisplayFilterExpression == normalizedExpression
            && activeDisplayFilterGeneration == generation) {
            validation.normalizedExpression = normalizedExpression;
            validation.status = TCPViewerDisplayFilterValidationValid;
            return validation;
        }

        validation = CompileDisplayFilter(expression);
        if (validation.status != TCPViewerDisplayFilterValidationValid) {
            return validation;
        }
        clearActiveDisplayFilterLocked();
        activeDisplayFilter = validation.compiledFilter;
        validation.compiledFilter = nullptr;
        activeDisplayFilterExpression = validation.normalizedExpression;
        activeDisplayFilterGeneration = generation;
        return validation;
    }

    bool initializeWiresharkResourcesLocked()
    {
        if (auto *active = activeSession(); active != nullptr && active != this) {
            if (active->livePriority) {
                unavailableReason = "Wireshark is busy with another capture; this packet uses the built-in fallback dissector.";
                return false;
            }
            // Switching offline documents is bounded to explicit work and never replays the previous capture.
            std::lock_guard<std::mutex> activeLock(active->mutex);
            const char *reason = livePriority
                ? "Wireshark details were released because a live capture started."
                : "Wireshark details were released because another offline capture became active.";
            active->releaseWiresharkResourcesLocked(reason, false);
        }

        provider = std::make_unique<packet_provider_data>();
        frame_data_sequence *frames = nullptr;
        if (auto report = CatchWiresharkException("creating Wireshark frame storage", std::nullopt, [&frames] {
                frames = new_frame_data_sequence();
            })) {
            provider.reset();
            return failWithCriticalExceptionLocked(std::move(*report));
        }
        provider->frames = frames;
        if (provider->frames == nullptr) {
            unavailableReason = "Wireshark frame storage could not be created.";
            provider.reset();
            return false;
        }

        epan_t *newEpan = nullptr;
        auto *providerPointer = provider.get();
        if (auto report = CatchWiresharkException("creating Wireshark session", std::nullopt, [&newEpan, providerPointer] {
                newEpan = epan_new(providerPointer, &kPacketProviderFuncs);
            })) {
            WiresharkSessionResources resources{nullptr, std::move(provider)};
            recordCriticalExceptionLocked(std::move(*report), true);
            recordCriticalExceptionsLocked(FreeWiresharkSessionResources(resources), false);
            releaseWiresharkResourcesLocked(unavailableReason, true);
            return false;
        }
        epan = newEpan;
        if (epan == nullptr) {
            WiresharkSessionResources resources{nullptr, std::move(provider)};
            recordCriticalExceptionsLocked(FreeWiresharkSessionResources(resources), false);
            unavailableReason = "Wireshark session could not be created.";
            return false;
        }

        epan_dissect_t *firstPass = nullptr;
        auto *currentEpan = epan;
        if (auto report = CatchWiresharkException("creating Wireshark first-pass dissector", std::nullopt, [&firstPass, currentEpan] {
                firstPass = epan_dissect_new(currentEpan, false, false);
            })) {
            return failWithCriticalExceptionLocked(std::move(*report));
        }
        firstPassDissect = firstPass;
        if (firstPassDissect == nullptr) {
            releaseWiresharkResourcesLocked("Wireshark could not allocate a first-pass dissector.", true);
            return false;
        }

        GString *tapError = register_tap_listener(
            "tcp",
            this,
            nullptr,
            0,
            nullptr,
            indexTCPPacket,
            nullptr,
            nullptr
        );
        if (tapError != nullptr) {
            const std::string message = tapError->str == nullptr || tapError->str[0] == '\0'
                ? "Wireshark TCP stream indexing is unavailable."
                : tapError->str;
            g_string_free(tapError, TRUE);
            releaseWiresharkResourcesLocked(message, true);
            return false;
        }
        tcpIndexTapRegistered = true;

        activeSession() = this;
        resetActiveFrameStateLocked();
        firstPassFinished = false;
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
        frame_data *storedFrame = nullptr;
        collectingTCPStreamIndex = true;
        auto dissectionReport = CatchWiresharkException("running Wireshark first-pass dissection", context.packetIdentifier, [&] {
                frame_data_init(&frame, frameNumber, record.get(), cumulativeBytes, cumulativeBytes);
                frame_data_set_before_dissect(&frame, &elapsedTime, &provider->ref, provider->prev_dis);
                if (provider->ref == &frame) {
                    referenceFrame = frame;
                    provider->ref = &referenceFrame;
                }
                epan_dissect_run_with_taps(firstPassDissect, WTAP_FILE_TYPE_SUBTYPE_UNKNOWN, record.get(), &frame, nullptr);
                frame_data_set_after_dissect(&frame, &cumulativeBytes);
                storedFrame = frame_data_sequence_add(provider->frames, &frame);
                epan_dissect_reset(firstPassDissect);
            });
        collectingTCPStreamIndex = false;
        if (dissectionReport) {
            pendingTCPStreamFrames.clear();
            return failWithCriticalExceptionLocked(std::move(*dissectionReport));
        }

        provider->prev_cap = provider->prev_dis = storedFrame;
        activeFrameNumbers.insert(frameNumber);
        return true;
    }

    bool ensureActiveSessionLocked()
    {
        if (disabled) {
            return false;
        }
        auto &runtime = WiresharkRuntime::shared(personalConfigurationDirectory.c_str());
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
        unavailableReason.clear();
        return true;
    }

    bool observePacketLocked(const PacketContextView &context)
    {
        if (disabled || !backendAvailable) {
            return false;
        }
        if (frameNumberByPacketIdentifier.find(context.packetIdentifier) != frameNumberByPacketIdentifier.end()) {
            return ensureActiveSessionLocked();
        }
        const uint64_t nextFrameNumber = storedFrameNumbers.size() + 1;
        if (nextFrameNumber > std::numeric_limits<uint32_t>::max()) {
            unavailableReason = "Wireshark requires a 32-bit frame number for dissection state.";
            return false;
        }
        const auto frameNumber = static_cast<uint32_t>(nextFrameNumber);
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

        storedFrameNumbers.insert(frameNumber);
        frameNumberByPacketIdentifier[context.packetIdentifier] = frameNumber;
        if (packetIdentifierByFrameNumber.size() <= frameNumber) {
            packetIdentifierByFrameNumber.resize(static_cast<size_t>(frameNumber) + 1);
        }
        packetIdentifierByFrameNumber[frameNumber] = context.packetIdentifier;
        finalizeTCPStreamIndexUpdatesLocked();
        return true;
    }

    bool finishActiveFirstPassLocked()
    {
        if (auto report = FreeEpanDissect(firstPassDissect, "freeing Wireshark first-pass dissector", std::nullopt)) {
            return failWithCriticalExceptionLocked(std::move(*report));
        }
        if (provider != nullptr) {
            provider->prev_dis = nullptr;
            provider->prev_cap = nullptr;
        }
        return true;
    }

    bool finishFirstPassLocked()
    {
        if (firstPassFinished) {
            return true;
        }
        if (!ensureActiveSessionLocked()) {
            return false;
        }
        if (!finishActiveFirstPassLocked()) {
            return false;
        }
        firstPassFinished = true;
        return true;
    }

    void cancelFollowLocked()
    {
        if (followTapRegistered && followTapContext != nullptr) {
            if (auto report = CatchWiresharkException("removing Wireshark TCP follow listener", std::nullopt, [&] {
                    remove_tap_listener(followTapContext);
                })) {
                recordCriticalExceptionLocked(std::move(*report), false);
            }
        }
        followTapRegistered = false;
        processingFollowPacket = false;
        g_free(followTapContext);
        followTapContext = nullptr;
        if (activeFollowSession() == this) {
            activeFollowSession() = nullptr;
        }
        if (followInfo != nullptr) {
            follow_info_free(followInfo);
            followInfo = nullptr;
        }
        tcpFollower = nullptr;
        followReference = nullptr;
        followPreviousFrame = nullptr;
        followReferenceFrame = frame_data{};
        nstime_set_zero(&followElapsedTime);
        followTruncated = false;
        followPayloadByteCount = 0;
        followNewestPayloadItem = nullptr;
    }

    bool beginTCPFollowLocked(
        const PacketContextView &selectedContext,
        TCPViewerWiresharkFollowDirection direction
    )
    {
        cancelFollowLocked();
        if (!hasSession() || activeSession() != this) {
            unavailableReason = "Wireshark details are no longer active for this capture. Reload it before following a stream.";
            return false;
        }
        if (activeFollowSession() != nullptr && activeFollowSession() != this) {
            unavailableReason = "Another TCP stream is already being reassembled.";
            return false;
        }

        // Followers are keyed by Wireshark's case-sensitive protocol short name.
        tcpFollower = get_follow_by_name("TCP");
        if (tcpFollower == nullptr) {
            unavailableReason = "Wireshark TCP stream following is unavailable.";
            return false;
        }
        const auto frameMatch = frameNumberByPacketIdentifier.find(selectedContext.packetIdentifier);
        if (frameMatch == frameNumberByPacketIdentifier.end()) {
            unavailableReason = "The selected packet is not present in the TCP stream snapshot.";
            return false;
        }
        frame_data *frame = frame_data_sequence_find(provider->frames, frameMatch->second);
        if (frame == nullptr) {
            unavailableReason = "Wireshark frame state is unavailable for the selected packet.";
            return false;
        }

        WiresharkRecord record(selectedContext);
        if (!record.isValid()) {
            unavailableReason = record.failureReason();
            return false;
        }

        epan_dissect_t *dissect = nullptr;
        auto *currentEpan = epan;
        if (auto report = CatchWiresharkException("creating Wireshark TCP follow selector", selectedContext.packetIdentifier, [&] {
                dissect = epan_dissect_new(currentEpan, true, true);
            })) {
            return failWithCriticalExceptionLocked(std::move(*report));
        }
        if (dissect == nullptr) {
            unavailableReason = "Wireshark could not allocate the TCP stream selector.";
            return false;
        }

        bool selectedTCP = false;
        char *followFilter = nullptr;
        uint32_t cumulativeBytesForPacket = frame->cum_bytes >= frame->pkt_len ? frame->cum_bytes - frame->pkt_len : 0;
        nstime_t elapsed = NSTIME_INIT_ZERO;
        const frame_data *reference = nullptr;
        wtap_block_t block = record.get()->block != nullptr ? wtap_block_ref(record.get()->block) : nullptr;
        if (auto report = CatchWiresharkException("selecting Wireshark TCP stream", selectedContext.packetIdentifier, [&] {
                frame_data_set_before_dissect(frame, &elapsed, &reference, nullptr);
                epan_dissect_run(dissect, WTAP_FILE_TYPE_SUBTYPE_UNKNOWN, record.get(), frame, nullptr);
                frame_data_set_after_dissect(frame, &cumulativeBytesForPacket);
                const int protocolID = get_follow_proto_id(tcpFollower);
                selectedTCP = proto_is_frame_protocol(
                    dissect->pi.layers,
                    proto_get_protocol_filter_name(protocolID)
                );
                if (selectedTCP) {
                    unsigned streamNumber = 0;
                    unsigned substreamNumber = 0;
                    followFilter = get_follow_conv_func(tcpFollower)(
                        dissect,
                        &dissect->pi,
                        &streamNumber,
                        &substreamNumber
                    );
                }
                epan_dissect_reset(dissect);
            })) {
            record.get()->block = block;
            if (followFilter != nullptr) {
                g_free(followFilter);
            }
            FreeEpanDissect(dissect, "freeing Wireshark TCP follow selector", selectedContext.packetIdentifier);
            return failWithCriticalExceptionLocked(std::move(*report));
        }
        record.get()->block = block;
        if (auto cleanupReport = FreeEpanDissect(dissect, "freeing Wireshark TCP follow selector", selectedContext.packetIdentifier)) {
            if (followFilter != nullptr) {
                g_free(followFilter);
            }
            return failWithCriticalExceptionLocked(std::move(*cleanupReport));
        }
        if (!selectedTCP || followFilter == nullptr || followFilter[0] == '\0') {
            if (followFilter != nullptr) {
                g_free(followFilter);
            }
            unavailableReason = "Select a TCP packet to follow its stream.";
            return false;
        }

        followInfo = g_try_new0(follow_info_t, 1);
        if (followInfo == nullptr) {
            g_free(followFilter);
            unavailableReason = "TCP stream follower state could not be allocated.";
            return false;
        }
        followInfo->show_stream = BOTH_HOSTS;
        followInfo->substream_id = SUBSTREAM_UNUSED;
        followInfo->filter_out_filter = followFilter;
        followTapContext = g_try_new0(TCPFollowTapContext, 1);
        if (followTapContext == nullptr) {
            follow_info_free(followInfo);
            followInfo = nullptr;
            tcpFollower = nullptr;
            unavailableReason = "TCP stream tap context could not be allocated.";
            return false;
        }
        followTapContext->session = this;
        followTapContext->direction = direction;
        GString *registrationError = register_tap_listener(
            get_follow_tap_string(tcpFollower),
            followTapContext,
            followInfo->filter_out_filter,
            0,
            nullptr,
            followTCPPacket,
            nullptr,
            nullptr
        );
        if (registrationError != nullptr) {
            unavailableReason = registrationError->str == nullptr || registrationError->str[0] == '\0'
                ? "Wireshark could not register the TCP follow listener."
                : registrationError->str;
            g_string_free(registrationError, TRUE);
            g_free(followTapContext);
            followTapContext = nullptr;
            follow_info_free(followInfo);
            followInfo = nullptr;
            tcpFollower = nullptr;
            return false;
        }

        followTapRegistered = true;
        activeFollowSession() = this;
        followReference = nullptr;
        followPreviousFrame = nullptr;
        followReferenceFrame = frame_data{};
        nstime_set_zero(&followElapsedTime);
        followTruncated = false;
        followPayloadByteCount = 0;
        followNewestPayloadItem = nullptr;
        return true;
    }

    TCPViewerWiresharkFollowPacketStatus processFollowPacketLocked(
        const PacketContextView &context,
        size_t maximumPayloadBytes,
        TCPViewerWiresharkFollowDirection direction
    ) {
        if (!followTapRegistered || followInfo == nullptr || activeFollowSession() != this) {
            unavailableReason = "The TCP stream reassembly is not active.";
            return TCPViewerWiresharkFollowPacketFailed;
        }
        const auto frameMatch = frameNumberByPacketIdentifier.find(context.packetIdentifier);
        if (frameMatch == frameNumberByPacketIdentifier.end()) {
            unavailableReason = "A TCP stream packet is missing from the Wireshark snapshot.";
            return TCPViewerWiresharkFollowPacketFailed;
        }
        frame_data *frame = frame_data_sequence_find(provider->frames, frameMatch->second);
        if (frame == nullptr) {
            unavailableReason = "Wireshark frame state is unavailable while following the TCP stream.";
            return TCPViewerWiresharkFollowPacketFailed;
        }

        WiresharkRecord record(context);
        if (!record.isValid()) {
            unavailableReason = record.failureReason();
            return TCPViewerWiresharkFollowPacketFailed;
        }

        epan_dissect_t *dissect = nullptr;
        auto *currentEpan = epan;
        if (auto report = CatchWiresharkException("creating Wireshark TCP follow dissector", context.packetIdentifier, [&] {
                dissect = epan_dissect_new(currentEpan, tap_listeners_require_dissection(), false);
            })) {
            failWithCriticalExceptionLocked(std::move(*report));
            return TCPViewerWiresharkFollowPacketFailed;
        }
        if (dissect == nullptr) {
            unavailableReason = "Wireshark could not allocate a TCP follow dissector.";
            return TCPViewerWiresharkFollowPacketFailed;
        }

        uint32_t cumulativeBytesForPacket = frame->cum_bytes >= frame->pkt_len ? frame->cum_bytes - frame->pkt_len : 0;
        wtap_block_t block = record.get()->block != nullptr ? wtap_block_ref(record.get()->block) : nullptr;
        if (auto report = CatchWiresharkException("reassembling Wireshark TCP stream", context.packetIdentifier, [&] {
                processingFollowPacket = true;
                frame_data_set_before_dissect(frame, &followElapsedTime, &followReference, followPreviousFrame);
                if (followReference == frame) {
                    followReferenceFrame = *frame;
                    followReference = &followReferenceFrame;
                }
                epan_dissect_run_with_taps(
                    dissect,
                    WTAP_FILE_TYPE_SUBTYPE_UNKNOWN,
                    record.get(),
                    frame,
                    nullptr
                );
                frame_data_set_after_dissect(frame, &cumulativeBytesForPacket);
                epan_dissect_reset(dissect);
            })) {
            processingFollowPacket = false;
            record.get()->block = block;
            FreeEpanDissect(dissect, "freeing Wireshark TCP follow dissector", context.packetIdentifier);
            failWithCriticalExceptionLocked(std::move(*report));
            return TCPViewerWiresharkFollowPacketFailed;
        }
        processingFollowPacket = false;
        record.get()->block = block;
        followPreviousFrame = frame;
        if (auto cleanupReport = FreeEpanDissect(dissect, "freeing Wireshark TCP follow dissector", context.packetIdentifier)) {
            failWithCriticalExceptionLocked(std::move(*cleanupReport));
            return TCPViewerWiresharkFollowPacketFailed;
        }

        // Wireshark does not add released out-of-order fragments to bytes_written, so count new payload records directly.
        for (GList *item = followInfo->payload; item != followNewestPayloadItem; item = g_list_next(item)) {
            auto *record = static_cast<follow_record_t *>(item->data);
            if (record != nullptr && record->data != nullptr && includesFollowRecord(record, direction)) {
                followPayloadByteCount += record->data->len;
            }
        }
        followNewestPayloadItem = followInfo->payload;
        if (followPayloadByteCount > maximumPayloadBytes) {
            followTruncated = true;
            return TCPViewerWiresharkFollowPacketLimitReached;
        }
        return TCPViewerWiresharkFollowPacketAccepted;
    }

    TCPViewerWiresharkFollowResult *finishTCPFollowLocked(
        size_t maximumPayloadBytes,
        size_t maximumRecordCount,
        TCPViewerWiresharkFollowDirection direction
    )
    {
        auto *result = static_cast<TCPViewerWiresharkFollowResult *>(std::calloc(1, sizeof(TCPViewerWiresharkFollowResult)));
        if (result == nullptr) {
            cancelFollowLocked();
            return nullptr;
        }
        if (!followTapRegistered || followInfo == nullptr || activeFollowSession() != this) {
            result->errorMessage = CopyCString("The TCP stream reassembly is not active.", false);
            cancelFollowLocked();
            return result;
        }

        if (auto report = CatchWiresharkException("removing Wireshark TCP follow listener", std::nullopt, [&] {
                remove_tap_listener(followTapContext);
            })) {
            followTapRegistered = false;
            processingFollowPacket = false;
            g_free(followTapContext);
            followTapContext = nullptr;
            activeFollowSession() = nullptr;
            result->errorMessage = CopyCString(report->reason, false);
            recordCriticalExceptionLocked(std::move(*report), true);
            follow_info_free(followInfo);
            followInfo = nullptr;
            tcpFollower = nullptr;
            return result;
        }
        followTapRegistered = false;
        processingFollowPacket = false;
        g_free(followTapContext);
        followTapContext = nullptr;
        activeFollowSession() = nullptr;

        char clientAddress[256] = {};
        char serverAddress[256] = {};
        address_to_str_buf(&followInfo->client_ip, clientAddress, sizeof(clientAddress));
        address_to_str_buf(&followInfo->server_ip, serverAddress, sizeof(serverAddress));
        result->clientAddress = CopyCString(clientAddress);
        result->serverAddress = CopyCString(serverAddress);
        result->clientPort = static_cast<uint16_t>(std::min(followInfo->client_port, static_cast<unsigned>(UINT16_MAX)));
        result->serverPort = static_cast<uint16_t>(std::min(followInfo->server_port, static_cast<unsigned>(UINT16_MAX)));
        for (GList *item = followInfo->payload; item != nullptr; item = g_list_next(item)) {
            auto *record = static_cast<follow_record_t *>(item->data);
            if (record == nullptr || record->data == nullptr) {
                continue;
            }
            if (record->is_server) {
                result->serverByteCount += record->data->len;
            } else {
                result->clientByteCount += record->data->len;
            }
        }

        size_t availableRecordCount = 0;
        for (GList *item = followInfo->payload; item != nullptr; item = g_list_next(item)) {
            auto *record = static_cast<follow_record_t *>(item->data);
            if (record != nullptr && record->data != nullptr && record->data->len > 0
                && includesFollowRecord(record, direction)) {
                availableRecordCount += 1;
            }
        }
        const size_t allocatedRecordCount = std::min(availableRecordCount, maximumRecordCount);
        result->recordCount = allocatedRecordCount;
        result->isTruncated = followTruncated
            || followPayloadByteCount > maximumPayloadBytes
            || availableRecordCount > maximumRecordCount;
        if (allocatedRecordCount > 0) {
            result->records = static_cast<TCPViewerWiresharkFollowRecord *>(
                std::calloc(allocatedRecordCount, sizeof(TCPViewerWiresharkFollowRecord))
            );
            if (result->records == nullptr) {
                result->recordCount = 0;
                result->errorMessage = CopyCString("TCP stream output could not be allocated.", false);
                cancelFollowLocked();
                return result;
            }
        }

        size_t outputIndex = 0;
        size_t remainingPayloadBytes = maximumPayloadBytes;
        for (GList *item = g_list_last(followInfo->payload);
             item != nullptr && outputIndex < allocatedRecordCount && remainingPayloadBytes > 0;
             item = g_list_previous(item)) {
            auto *source = static_cast<follow_record_t *>(item->data);
            if (source == nullptr || source->data == nullptr || source->data->len == 0
                || !includesFollowRecord(source, direction)) {
                continue;
            }
            auto &destination = result->records[outputIndex];
            destination.isServer = source->is_server;
            destination.packetIdentifier = source->packet_num < packetIdentifierByFrameNumber.size()
                ? packetIdentifierByFrameNumber[source->packet_num]
                : static_cast<uint64_t>(source->packet_num);
            destination.sequenceNumber = source->seq;
            destination.timestampSeconds = source->abs_ts.secs;
            destination.timestampNanoseconds = source->abs_ts.nsecs;
            destination.byteCount = std::min(static_cast<size_t>(source->data->len), remainingPayloadBytes);
            if (destination.byteCount > 0) {
                destination.bytes = static_cast<uint8_t *>(std::malloc(destination.byteCount));
                if (destination.bytes == nullptr) {
                    result->errorMessage = CopyCString("TCP stream payload could not be allocated.", false);
                    cancelFollowLocked();
                    return result;
                }
                std::memcpy(destination.bytes, source->data->data, destination.byteCount);
            }
            if (destination.byteCount < source->data->len) {
                result->isTruncated = true;
            }
            remainingPayloadBytes -= destination.byteCount;
            outputIndex += 1;
        }
        result->recordCount = outputIndex;

        result->succeeded = true;
        follow_info_free(followInfo);
        followInfo = nullptr;
        tcpFollower = nullptr;
        followReference = nullptr;
        followPreviousFrame = nullptr;
        followReferenceFrame = frame_data{};
        nstime_set_zero(&followElapsedTime);
        followTruncated = false;
        followPayloadByteCount = 0;
        followNewestPayloadItem = nullptr;
        return result;
    }

    static bool includesFollowRecord(
        const follow_record_t *record,
        TCPViewerWiresharkFollowDirection direction
    ) {
        switch (direction) {
            case TCPViewerWiresharkFollowClientToServer:
                return !record->is_server;
            case TCPViewerWiresharkFollowServerToClient:
                return record->is_server;
            case TCPViewerWiresharkFollowBothDirections:
            default:
                return true;
        }
    }

    // Remove completed payload from the unrequested side before it can consume the follow budget.
    void discardExcludedNewestFollowPayloadLocked(TCPViewerWiresharkFollowDirection direction)
    {
        if (direction == TCPViewerWiresharkFollowBothDirections || followInfo == nullptr) {
            return;
        }

        for (GList *item = followInfo->payload; item != followNewestPayloadItem;) {
            GList *next = g_list_next(item);
            auto *record = static_cast<follow_record_t *>(item->data);
            if (record != nullptr && !includesFollowRecord(record, direction)) {
                if (record->data != nullptr) {
                    g_byte_array_free(record->data, true);
                }
                g_free(record);
                followInfo->payload = g_list_delete_link(followInfo->payload, item);
            }
            item = next;
        }
    }

    WiresharkDissectionResult runSecondPassLocked(
        const PacketContextView &context,
        bool buildTree,
        bool includesSummaryColumns = true
    )
    {
        WiresharkDissectionResult result;
        if (!ensureActiveSessionLocked()) {
            result.fallbackReason = unavailableReason;
            return result;
        }

        auto frameNumberMatch = frameNumberByPacketIdentifier.find(context.packetIdentifier);
        if (frameNumberMatch == frameNumberByPacketIdentifier.end() && !observePacketLocked(context)) {
            result.fallbackReason = unavailableReason;
            return result;
        }
        frameNumberMatch = frameNumberByPacketIdentifier.find(context.packetIdentifier);

        MergeInterfaceMetadata(*provider, context);
        const uint32_t frameNumber = frameNumberMatch == frameNumberByPacketIdentifier.end() ? kUnknownFrameNumber : frameNumberMatch->second;
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

        const bool evaluatesDisplayFilter = activeDisplayFilter != nullptr;
        const bool filterRequiresColumns = evaluatesDisplayFilter && dfilter_requires_columns(activeDisplayFilter);
        WiresharkColumnInfo columnInfo(includesSummaryColumns || filterRequiresColumns, filterRequiresColumns);
        const bool createsProtocolTree = buildTree || evaluatesDisplayFilter;
        epan_dissect_t *rawDissect = nullptr;
        auto *currentEpan = epan;
        if (auto report = CatchWiresharkException("creating Wireshark second-pass dissector", context.packetIdentifier, [&rawDissect, currentEpan, createsProtocolTree, buildTree] {
                rawDissect = epan_dissect_new(currentEpan, createsProtocolTree, buildTree);
            })) {
            failWithCriticalExceptionLocked(std::move(*report));
            result.fallbackReason = unavailableReason;
            return result;
        }
        if (rawDissect == nullptr) {
            result.fallbackReason = "Wireshark could not allocate a second-pass dissector.";
            return result;
        }

        auto failWithLocalCriticalException = [&](WiresharkCriticalException report) {
            recordCriticalExceptionLocked(std::move(report), true);
            if (auto cleanupReport = FreeEpanDissect(rawDissect, "freeing Wireshark second-pass dissector", context.packetIdentifier)) {
                recordCriticalExceptionLocked(std::move(*cleanupReport), false);
            }
            releaseWiresharkResourcesLocked(unavailableReason, true);
            result = WiresharkDissectionResult{};
            result.fallbackReason = unavailableReason;
        };
        auto freeSecondPassDissector = [&]() -> bool {
            if (auto cleanupReport = FreeEpanDissect(rawDissect, "freeing Wireshark second-pass dissector", context.packetIdentifier)) {
                failWithCriticalExceptionLocked(std::move(*cleanupReport));
                result = WiresharkDissectionResult{};
                result.fallbackReason = unavailableReason;
                return false;
            }
            return true;
        };

        if (columnInfo.get() != nullptr) {
            if (auto report = CatchWiresharkException("priming Wireshark custom columns", context.packetIdentifier, [&] {
                    col_custom_prime_edt(rawDissect, columnInfo.get());
                })) {
                failWithLocalCriticalException(std::move(*report));
                return result;
            }
        }

        if (evaluatesDisplayFilter) {
            if (auto report = CatchWiresharkException("priming Wireshark display filter", context.packetIdentifier, [&] {
                    epan_dissect_prime_with_dfilter(rawDissect, activeDisplayFilter);
                })) {
                failWithLocalCriticalException(std::move(*report));
                return result;
            }
        }

        wtap_block_t block = record.get()->block != nullptr ? wtap_block_ref(record.get()->block) : nullptr;
        if (auto report = CatchWiresharkException("running Wireshark second-pass dissection", context.packetIdentifier, [&] {
                frame_data_set_before_dissect(frame, &elapsedTime, &provider->ref, provider->prev_dis);
                if (provider->ref == frame) {
                    referenceFrame = *frame;
                    provider->ref = &referenceFrame;
                }
                if (buildTree && activeFollowSession() == nullptr) {
                    epan_dissect_run_with_taps(rawDissect, WTAP_FILE_TYPE_SUBTYPE_UNKNOWN, record.get(), frame, columnInfo.get());
                } else {
                    epan_dissect_run(rawDissect, WTAP_FILE_TYPE_SUBTYPE_UNKNOWN, record.get(), frame, columnInfo.get());
                }
                uint32_t secondPassCumulativeBytes = frame->cum_bytes >= frame->pkt_len ? frame->cum_bytes - frame->pkt_len : 0;
                frame_data_set_after_dissect(frame, &secondPassCumulativeBytes);
            })) {
            record.get()->block = block;
            failWithLocalCriticalException(std::move(*report));
            return result;
        }

        result.columns = ColumnsFromInfo(columnInfo.get());
        if (evaluatesDisplayFilter) {
            bool matched = false;
            if (auto report = CatchWiresharkException("applying Wireshark display filter", context.packetIdentifier, [&] {
                    matched = dfilter_apply_edt(activeDisplayFilter, rawDissect);
                })) {
                failWithLocalCriticalException(std::move(*report));
                return result;
            }
            result.hasDisplayFilterMatch = true;
            result.displayFilterMatched = matched;
            result.displayFilterGeneration = activeDisplayFilterGeneration;
        }
        if (buildTree) {
            auto sourceSet = ExtractByteSources(rawDissect->pi.data_src);
            result.nodes = MapProtoTree(rawDissect->tree, sourceSet, rawDissect);
            if (auto sni = FindSNIInNodes(result.nodes)) {
                result.sniDomainName = *sni;
            }
            result.byteSources = std::move(sourceSet.sources);
        }
        if (auto report = CatchWiresharkException("resetting Wireshark second-pass dissector", context.packetIdentifier, [&] {
                epan_dissect_reset(rawDissect);
            })) {
            record.get()->block = block;
            failWithLocalCriticalException(std::move(*report));
            return result;
        }
        record.get()->block = block;
        result.usedWireshark = buildTree ? !result.nodes.empty() : (!result.columns.protocol.empty() || !result.columns.info.empty());
        if (!result.usedWireshark && buildTree) {
            result.fallbackReason = "Wireshark protocol-tree dissection returned no nodes for this packet.";
        }
        if (!freeSecondPassDissector()) {
            return result;
        }
        return result;
    }

    TCPViewerDisplayFilterMatchResult *evaluateDisplayFilterLocked(
        const PacketContextView &context,
        uint64_t generation
    ) {
        auto *result = static_cast<TCPViewerDisplayFilterMatchResult *>(std::calloc(1, sizeof(TCPViewerDisplayFilterMatchResult)));
        if (result == nullptr) {
            return nullptr;
        }
        if (generation != activeDisplayFilterGeneration || activeDisplayFilter == nullptr) {
            result->errorMessage = CopyCString("The Wireshark display-filter generation is no longer active.", false);
            return result;
        }
        const auto dissection = runSecondPassLocked(context, false, false);
        if (!dissection.hasDisplayFilterMatch || dissection.displayFilterGeneration != generation) {
            result->errorMessage = CopyCString(
                dissection.fallbackReason.empty() ? "Wireshark could not evaluate this packet." : dissection.fallbackReason,
                false
            );
            return result;
        }
        result->succeeded = true;
        result->matched = dissection.displayFilterMatched;
        return result;
    }

    WiresharkDissectionResult summarizePacketLocked(const PacketContextView &context)
    {
        auto result = runSecondPassLocked(context, false);
        if (result.usedWireshark && ShouldExtractSNIFromTree(result.columns)) {
            auto treeResult = runSecondPassLocked(context, true);
            if (!treeResult.usedWireshark && hasCriticalExceptionLocked()) {
                return treeResult;
            }
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

TCPViewerWiresharkSession *TCPViewerWiresharkSessionCreate(bool disabled, bool livePriority, const char *personalConfigurationDirectory)
{
    return new TCPViewerWiresharkSession(disabled, livePriority, personalConfigurationDirectory);
}

void TCPViewerWiresharkSessionDestroy(TCPViewerWiresharkSession *session)
{
    delete session;
}

void TCPViewerWiresharkSessionReleaseResources(TCPViewerWiresharkSession *session)
{
    if (session == nullptr || (session->epan == nullptr && session->provider == nullptr && session->firstPassDissect == nullptr)) {
        return;
    }
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    session->releaseWiresharkResourcesLocked("", false);
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

TCPViewerDisplayFilterValidationResult *TCPViewerWiresharkValidateDisplayFilter(
    const char *expression,
    const char *personalConfigurationDirectory
) {
    auto &runtime = WiresharkRuntime::shared(personalConfigurationDirectory);
    if (!runtime.isAvailable()) {
        DisplayFilterValidationCopy validation;
        validation.normalizedExpression = TrimASCIIWhitespace(expression);
        validation.status = TCPViewerDisplayFilterValidationUnavailable;
        validation.diagnostics.push_back(DisplayFilterDiagnosticCopy{
            TCPViewerDisplayFilterDiagnosticError,
            runtime.unavailableReason(),
            0,
            0,
            false,
        });
        return CopyDisplayFilterValidation(validation);
    }

    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    DisplayFilterValidationCopy validation;
    if (auto report = CatchWiresharkException("compiling Wireshark display filter", std::nullopt, [&] {
            validation = CompileDisplayFilter(expression);
        })) {
        validation.status = TCPViewerDisplayFilterValidationUnavailable;
        validation.normalizedExpression = TrimASCIIWhitespace(expression);
        validation.diagnostics = {DisplayFilterDiagnosticCopy{
            TCPViewerDisplayFilterDiagnosticError,
            report->reason,
            0,
            0,
            false,
        }};
    }
    auto *result = CopyDisplayFilterValidation(validation);
    dfilter_free(validation.compiledFilter);
    return result;
}

TCPViewerDisplayFilterValidationResult *TCPViewerWiresharkSessionActivateDisplayFilter(
    TCPViewerWiresharkSession *session,
    const char *expression,
    uint64_t generation
) {
    if (session == nullptr) {
        DisplayFilterValidationCopy validation;
        validation.normalizedExpression = TrimASCIIWhitespace(expression);
        validation.status = TCPViewerDisplayFilterValidationUnavailable;
        validation.diagnostics.push_back(DisplayFilterDiagnosticCopy{
            TCPViewerDisplayFilterDiagnosticError,
            kBackendUnavailableReason,
            0,
            0,
            false,
        });
        return CopyDisplayFilterValidation(validation);
    }

    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    session->clearCriticalExceptionsLocked();
    DisplayFilterValidationCopy validation;
    if (auto report = CatchWiresharkException("activating Wireshark display filter", std::nullopt, [&] {
            validation = session->activateDisplayFilterLocked(expression, generation);
        })) {
        session->failWithCriticalExceptionLocked(*report);
        validation.status = TCPViewerDisplayFilterValidationUnavailable;
        validation.normalizedExpression = TrimASCIIWhitespace(expression);
        validation.diagnostics = {DisplayFilterDiagnosticCopy{
            TCPViewerDisplayFilterDiagnosticError,
            report->reason,
            0,
            0,
            false,
        }};
    }
    auto *result = CopyDisplayFilterValidation(validation);
    dfilter_free(validation.compiledFilter);
    return result;
}

TCPViewerDisplayFilterMatchResult *TCPViewerWiresharkSessionEvaluateDisplayFilter(
    TCPViewerWiresharkSession *session,
    const TCPViewerWiresharkPacketContext *context,
    uint64_t generation
) {
    if (session == nullptr || context == nullptr) {
        auto *result = static_cast<TCPViewerDisplayFilterMatchResult *>(std::calloc(1, sizeof(TCPViewerDisplayFilterMatchResult)));
        if (result != nullptr) {
            result->errorMessage = CopyCString("The Wireshark display-filter request is invalid.", false);
        }
        return result;
    }
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    session->clearCriticalExceptionsLocked();
    return session->evaluateDisplayFilterLocked(ContextViewFromC(context), generation);
}

void TCPViewerWiresharkSessionClearDisplayFilter(TCPViewerWiresharkSession *session)
{
    if (session == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    session->clearActiveDisplayFilterLocked();
}

bool TCPViewerWiresharkSessionObservePacket(TCPViewerWiresharkSession *session, const TCPViewerWiresharkPacketContext *context)
{
    if (session == nullptr || context == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    session->clearCriticalExceptionsLocked();
    return session->observePacketLocked(ContextViewFromC(context));
}

TCPViewerWiresharkTCPStreamIndexResult *TCPViewerWiresharkSessionCopyPendingTCPStreamIndexUpdates(
    TCPViewerWiresharkSession *session
) {
    auto *result = static_cast<TCPViewerWiresharkTCPStreamIndexResult *>(
        std::calloc(1, sizeof(TCPViewerWiresharkTCPStreamIndexResult))
    );
    if (result == nullptr || session == nullptr) {
        return result;
    }

    std::lock_guard<std::mutex> sessionLock(session->mutex);
    result->entryCount = session->pendingTCPStreamIndexUpdates.size();
    if (result->entryCount > 0) {
        result->entries = static_cast<TCPViewerWiresharkTCPStreamIndexEntry *>(
            std::calloc(result->entryCount, sizeof(TCPViewerWiresharkTCPStreamIndexEntry))
        );
        if (result->entries == nullptr) {
            result->entryCount = 0;
            return result;
        }
        for (size_t index = 0; index < result->entryCount; index += 1) {
            result->entries[index].packetIdentifier = session->pendingTCPStreamIndexUpdates[index].first;
            result->entries[index].streamIdentifier = session->pendingTCPStreamIndexUpdates[index].second;
        }
    }
    session->pendingTCPStreamIndexUpdates.clear();
    return result;
}

bool TCPViewerWiresharkSessionFinishFirstPass(TCPViewerWiresharkSession *session)
{
    if (session == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    session->clearCriticalExceptionsLocked();
    return session->finishFirstPassLocked();
}

bool TCPViewerWiresharkSessionCanFollowObservedPacket(TCPViewerWiresharkSession *session, uint64_t packetIdentifier)
{
    if (session == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    return session->hasSession()
        && TCPViewerWiresharkSession::activeSession() == session
        && session->frameNumberByPacketIdentifier.find(packetIdentifier) != session->frameNumberByPacketIdentifier.end();
}

bool TCPViewerWiresharkSessionCanFollowObservedPackets(
    TCPViewerWiresharkSession *session,
    const uint64_t *packetIdentifiers,
    size_t packetIdentifierCount
) {
    if (session == nullptr || packetIdentifiers == nullptr || packetIdentifierCount == 0) {
        return false;
    }
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    if (!session->hasSession() || TCPViewerWiresharkSession::activeSession() != session) {
        return false;
    }
    for (size_t index = 0; index < packetIdentifierCount; index += 1) {
        if (session->frameNumberByPacketIdentifier.find(packetIdentifiers[index])
            == session->frameNumberByPacketIdentifier.end()) {
            return false;
        }
    }
    return true;
}

TCPViewerWiresharkFollowCandidateResult *TCPViewerWiresharkSessionCopyTCPFollowCandidates(
    TCPViewerWiresharkSession *session,
    uint64_t packetIdentifier,
    size_t maximumPacketCount
) {
    auto *result = static_cast<TCPViewerWiresharkFollowCandidateResult *>(
        std::calloc(1, sizeof(TCPViewerWiresharkFollowCandidateResult))
    );
    if (result == nullptr) {
        return nullptr;
    }
    if (session == nullptr || maximumPacketCount == 0) {
        result->errorMessage = CopyCString("The TCP stream candidate request is invalid.", false);
        return result;
    }

    std::lock_guard<std::mutex> sessionLock(session->mutex);
    const auto selected = session->tcpStreamNumberByPacketIdentifier.find(packetIdentifier);
    if (selected == session->tcpStreamNumberByPacketIdentifier.end()) {
        result->errorMessage = CopyCString("Select a TCP packet to follow its stream.", false);
        return result;
    }

    std::vector<uint64_t> identifiers;
    for (const auto &[candidateIdentifier, streamNumber] : session->tcpStreamNumberByPacketIdentifier) {
        if (streamNumber == selected->second) {
            identifiers.push_back(candidateIdentifier);
        }
    }
    std::sort(identifiers.begin(), identifiers.end());
    if (identifiers.size() > maximumPacketCount) {
        result->errorMessage = CopyCString(
            "This TCP stream exceeds the packet candidate safety limit.",
            false
        );
        return result;
    }

    result->packetIdentifierCount = identifiers.size();
    if (!identifiers.empty()) {
        result->packetIdentifiers = static_cast<uint64_t *>(
            std::calloc(identifiers.size(), sizeof(uint64_t))
        );
        if (result->packetIdentifiers == nullptr) {
            result->packetIdentifierCount = 0;
            result->errorMessage = CopyCString("TCP stream candidates could not be allocated.", false);
            return result;
        }
        std::copy(identifiers.begin(), identifiers.end(), result->packetIdentifiers);
    }
    result->succeeded = true;
    return result;
}

bool TCPViewerWiresharkSessionTCPStreamIdentifier(
    TCPViewerWiresharkSession *session,
    uint64_t packetIdentifier,
    uint32_t *streamIdentifier
) {
    if (session == nullptr || streamIdentifier == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    const auto match = session->tcpStreamNumberByPacketIdentifier.find(packetIdentifier);
    if (match == session->tcpStreamNumberByPacketIdentifier.end()) {
        return false;
    }
    *streamIdentifier = match->second;
    return true;
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
    session->clearCriticalExceptionsLocked();
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
    session->clearCriticalExceptionsLocked();
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

bool TCPViewerWiresharkSessionBeginFollowTCPStream(
    TCPViewerWiresharkSession *session,
    const TCPViewerWiresharkPacketContext *selectedContext,
    TCPViewerWiresharkFollowDirection direction
)
{
    if (session == nullptr || selectedContext == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    session->clearCriticalExceptionsLocked();
    return session->beginTCPFollowLocked(ContextViewFromC(selectedContext), direction);
}

TCPViewerWiresharkFollowPacketStatus TCPViewerWiresharkSessionProcessFollowPacket(
    TCPViewerWiresharkSession *session,
    const TCPViewerWiresharkPacketContext *context,
    size_t maximumPayloadBytes,
    TCPViewerWiresharkFollowDirection direction
) {
    if (session == nullptr || context == nullptr || maximumPayloadBytes == 0) {
        return TCPViewerWiresharkFollowPacketFailed;
    }
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    return session->processFollowPacketLocked(ContextViewFromC(context), maximumPayloadBytes, direction);
}

TCPViewerWiresharkFollowResult *TCPViewerWiresharkSessionFinishFollowTCPStream(
    TCPViewerWiresharkSession *session,
    size_t maximumPayloadBytes,
    size_t maximumRecordCount,
    TCPViewerWiresharkFollowDirection direction
) {
    if (session == nullptr || maximumPayloadBytes == 0 || maximumRecordCount == 0) {
        auto *result = static_cast<TCPViewerWiresharkFollowResult *>(std::calloc(1, sizeof(TCPViewerWiresharkFollowResult)));
        if (result != nullptr) {
            result->errorMessage = CopyCString("The TCP stream reassembly request is invalid.", false);
        }
        return result;
    }
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    return session->finishTCPFollowLocked(maximumPayloadBytes, maximumRecordCount, direction);
}

void TCPViewerWiresharkSessionCancelFollowTCPStream(TCPViewerWiresharkSession *session)
{
    if (session == nullptr) {
        return;
    }
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    session->cancelFollowLocked();
}

TCPViewerWiresharkExceptionReport *TCPViewerWiresharkSessionCopyLastCriticalException(TCPViewerWiresharkSession *session)
{
    if (session == nullptr) {
        return nullptr;
    }
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    if (session->pendingCriticalExceptions.empty()) {
        return nullptr;
    }
    return CopyExceptionReport(session->pendingCriticalExceptions.back());
}

TCPViewerWiresharkExceptionReport *TCPViewerWiresharkSessionCopyNextCriticalException(TCPViewerWiresharkSession *session)
{
    if (session == nullptr) {
        return nullptr;
    }
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    if (session->pendingCriticalExceptions.empty()) {
        return nullptr;
    }
    auto report = CopyExceptionReport(session->pendingCriticalExceptions.front());
    session->pendingCriticalExceptions.pop_front();
    return report;
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

void TCPViewerWiresharkTCPStreamIndexResultDestroy(TCPViewerWiresharkTCPStreamIndexResult *result)
{
    if (result == nullptr) {
        return;
    }
    std::free(result->entries);
    std::free(result);
}

void TCPViewerWiresharkFollowCandidateResultDestroy(TCPViewerWiresharkFollowCandidateResult *result)
{
    if (result == nullptr) {
        return;
    }
    std::free(const_cast<char *>(result->errorMessage));
    std::free(result->packetIdentifiers);
    std::free(result);
}

void TCPViewerWiresharkFollowResultDestroy(TCPViewerWiresharkFollowResult *result)
{
    if (result == nullptr) {
        return;
    }
    std::free(const_cast<char *>(result->errorMessage));
    std::free(const_cast<char *>(result->clientAddress));
    std::free(const_cast<char *>(result->serverAddress));
    if (result->records != nullptr) {
        for (size_t index = 0; index < result->recordCount; index += 1) {
            std::free(result->records[index].bytes);
        }
    }
    std::free(result->records);
    std::free(result);
}

void TCPViewerWiresharkExceptionReportDestroy(TCPViewerWiresharkExceptionReport *report)
{
    if (report == nullptr) {
        return;
    }
    std::free(const_cast<char *>(report->operation));
    std::free(const_cast<char *>(report->exceptionName));
    std::free(const_cast<char *>(report->reason));
    std::free(report);
}

void TCPViewerDisplayFilterValidationResultDestroy(TCPViewerDisplayFilterValidationResult *result)
{
    if (result == nullptr) {
        return;
    }
    std::free(const_cast<char *>(result->normalizedExpression));
    for (size_t index = 0; index < result->diagnosticCount; index += 1) {
        std::free(const_cast<char *>(result->diagnostics[index].message));
    }
    std::free(result->diagnostics);
    std::free(result);
}

void TCPViewerDisplayFilterMatchResultDestroy(TCPViewerDisplayFilterMatchResult *result)
{
    if (result == nullptr) {
        return;
    }
    std::free(const_cast<char *>(result->errorMessage));
    std::free(result);
}

#if DEBUG
TCPViewerWiresharkExceptionReport *TCPViewerWiresharkTestCopyCaughtExceptionReport(const char *personalConfigurationDirectory)
{
    auto &runtime = WiresharkRuntime::shared(personalConfigurationDirectory);
    if (!runtime.isAvailable()) {
        return runtime.criticalException().has_value() ? CopyExceptionReport(*runtime.criticalException()) : nullptr;
    }

    std::optional<WiresharkCriticalException> report;
    {
        std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
        report = CatchWiresharkException("testing Wireshark exception handling", uint64_t{42}, [] {
            except_throw(XCEPT_GROUP_WIRESHARK, DissectorError, "test-only private message");
        });
    }
    return report.has_value() ? CopyExceptionReport(*report) : nullptr;
}

bool TCPViewerWiresharkSessionTestInjectCriticalException(TCPViewerWiresharkSession *session)
{
    if (session == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    session->clearCriticalExceptionsLocked();
    if (auto report = CatchWiresharkException("testing Wireshark session exception handling", uint64_t{42}, [] {
            except_throw(XCEPT_GROUP_WIRESHARK, DissectorError, "test-only private message");
        })) {
        return session->failWithCriticalExceptionLocked(std::move(*report));
    }
    return true;
}

void TCPViewerWiresharkTestResetDisplayFilterCompilationCount(void)
{
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    gDisplayFilterCompilationCount = 0;
}

size_t TCPViewerWiresharkTestDisplayFilterCompilationCount(void)
{
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    return gDisplayFilterCompilationCount;
}

bool TCPViewerWiresharkSessionTestHasActiveDisplayFilter(TCPViewerWiresharkSession *session)
{
    if (session == nullptr) {
        return false;
    }
    std::lock_guard<std::mutex> apiLock(WiresharkAPIMutex());
    std::lock_guard<std::mutex> sessionLock(session->mutex);
    return session->activeDisplayFilter != nullptr;
}
#endif
