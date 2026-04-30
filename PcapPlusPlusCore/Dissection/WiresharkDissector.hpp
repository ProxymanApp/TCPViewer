#pragma once

#include "PacketDissectionEngine.hpp"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace tcpviewer::dissection {

struct WiresharkDissectionResult {
    bool usedWireshark = false;
    std::string fallbackReason;
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
    WiresharkDissectionSession();
    ~WiresharkDissectionSession();

    WiresharkDissectionSession(WiresharkDissectionSession&&) noexcept;
    WiresharkDissectionSession& operator=(WiresharkDissectionSession&&) noexcept;

    WiresharkDissectionSession(const WiresharkDissectionSession&) = delete;
    WiresharkDissectionSession& operator=(const WiresharkDissectionSession&) = delete;

    bool observePacket(const PacketDissectionContext& context);
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
