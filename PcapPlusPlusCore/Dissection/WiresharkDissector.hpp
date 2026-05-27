#pragma once

#include "PacketDissectionEngine.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace tcpviewer::dissection {

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
    // Set when a libwireshark dissector raised a DissectorError exception (e.g. "Unregistered hf!").
    // Callers should suppress the user-facing "Wireshark Dissector Unavailable" panel and route the
    // message to a developer log instead.
    bool dissectorBugDetected = false;
    std::string fallbackReason;
    WiresharkPacketColumns columns;
    std::vector<WiresharkByteSource> byteSources;
    std::vector<DetailNode> nodes;
};

class WiresharkRuntime {
public:
    static WiresharkRuntime& shared();

    WiresharkRuntime(const WiresharkRuntime&) = delete;
    WiresharkRuntime& operator=(const WiresharkRuntime&) = delete;

    bool isAvailable() const;
    std::string unavailableReason() const;

private:
    WiresharkRuntime();
    ~WiresharkRuntime();

    bool available_ = false;
    std::string unavailableReason_;
};

class WiresharkDissectionSession {
public:
    explicit WiresharkDissectionSession(bool disabled = false);
    ~WiresharkDissectionSession();

    WiresharkDissectionSession(WiresharkDissectionSession&&) noexcept;
    WiresharkDissectionSession& operator=(WiresharkDissectionSession&&) noexcept;

    WiresharkDissectionSession(const WiresharkDissectionSession&) = delete;
    WiresharkDissectionSession& operator=(const WiresharkDissectionSession&) = delete;

    bool observePacket(const PacketDissectionContext& context);
    bool finishFirstPass();
    WiresharkDissectionResult summarizePacket(const PacketDissectionContext& context);
    bool isAvailable() const;
    uint64_t observedPacketCount() const;
    std::string unavailableReason() const;

private:
    friend class WiresharkPacketDissector;

    struct Impl;
    std::unique_ptr<Impl> impl_;
};

class WiresharkPacketDissector {
public:
    explicit WiresharkPacketDissector(WiresharkDissectionSession* session = nullptr);

    WiresharkDissectionResult dissect(const PacketDissectionContext& context) const;

private:
    WiresharkDissectionSession* session_ = nullptr;
};

DetailNode MakeWiresharkFallbackWarning(const std::string& reason);

}  // namespace tcpviewer::dissection
