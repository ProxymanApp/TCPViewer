#pragma once

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace pcpp {
class Layer;
class Packet;
class RawPacket;
}

namespace tcpviewer::dissection {

struct ByteRange {
    size_t offset = 0;
    size_t length = 0;
    uint8_t bitOffset = 0;
    uint8_t bitLength = 0;
    bool hasBitRange = false;
    std::string sourceID = "frame";
};

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

struct PacketDissectionContext {
    const pcpp::Packet& packet;
    const pcpp::RawPacket& rawPacket;
    uint64_t packetIdentifier = 0;
    std::optional<std::string> interfaceName;
    std::optional<std::string> packetComment;
};

struct DissectionResult {
    std::vector<DetailNode> nodes;
};

enum class SpicyProtocol {
    DNS,
    TLS,
    HTTP1,
    WebSocket,
};

struct SpicyParseInput {
    SpicyProtocol protocol;
    std::string parserName;
    const uint8_t* bytes = nullptr;
    size_t length = 0;
    size_t baseOffset = 0;
};

class ProtocolDissector {
public:
    virtual ~ProtocolDissector() = default;
    virtual std::optional<DetailNode> dissectLayer(const PacketDissectionContext& context, const pcpp::Layer& layer) const = 0;
};

class ProtocolDissectorRegistry {
public:
    void add(std::vector<std::unique_ptr<ProtocolDissector>> dissectors);
    std::optional<DetailNode> dissectLayer(const PacketDissectionContext& context, const pcpp::Layer& layer) const;

private:
    std::vector<std::unique_ptr<ProtocolDissector>> dissectors_;
};

class SpicyParserAdapter {
public:
    virtual ~SpicyParserAdapter() = default;
    virtual bool supports(SpicyProtocol protocol) const = 0;
    virtual std::vector<DetailNode> parse(const SpicyParseInput& input) const = 0;
};

class PacketDissectionEngine {
public:
    PacketDissectionEngine();
    explicit PacketDissectionEngine(std::vector<std::unique_ptr<SpicyParserAdapter>> spicyAdapters);

    DissectionResult dissect(const PacketDissectionContext& context) const;
    DetailNode dissectFrame(const PacketDissectionContext& context) const;
    std::optional<DetailNode> dissectLayer(const PacketDissectionContext& context, const pcpp::Layer& layer) const;

private:
    std::vector<std::unique_ptr<SpicyParserAdapter>> spicyAdapters_;
    ProtocolDissectorRegistry registry_;
};

}  // namespace tcpviewer::dissection
