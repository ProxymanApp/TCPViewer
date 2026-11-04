//
//  engine_addon.cc
//  TCPViewer
//
//  Created by Proxyman LLC on 19/10/26.
//

// Spike-only synthetic packet engine. A native thread appends compact rows at a fixed rate,
// and JS pulls bounded viewport slices whose text columns are formatted on demand, either as
// cloned JS values or as one packed ArrayBuffer. No JS value is ever created per stored packet.

#include <napi.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

constexpr size_t kChunkRows = 1 << 16;
constexpr uint64_t kMaxRowsPerRequest = 2000;
constexpr double kMaxRowsPerSecond = 1000000.0;
constexpr size_t kPackedHeaderBytes = 16;

struct PacketRow {
    uint64_t number;
    double relativeTime;
    uint32_t sourceAddress;
    uint32_t destinationAddress;
    uint32_t length;
    uint32_t seed;
    uint16_t sourcePort;
    uint16_t destinationPort;
    uint8_t protocol;
};

const char *const kProtocolNames[] = {"TCP", "TLSv1.3", "UDP", "DNS", "QUIC", "HTTP"};
const uint16_t kProtocolPorts[] = {443, 443, 5353, 53, 443, 80};
constexpr size_t kProtocolCount = sizeof(kProtocolNames) / sizeof(kProtocolNames[0]);

// Mix a packet number into well-spread pseudo-random bits.
uint64_t SplitMix64(uint64_t value) {
    value += 0x9E3779B97F4A7C15ull;
    value = (value ^ (value >> 30)) * 0xBF58476D1CE4E5B9ull;
    value = (value ^ (value >> 27)) * 0x94D049BB133111EBull;
    return value ^ (value >> 31);
}

// Build one deterministic synthetic row; text columns are formatted later, only when requested.
PacketRow MakeRow(uint64_t number, double relativeTime) {
    const uint64_t bits = SplitMix64(number);
    PacketRow row{};
    row.number = number;
    row.relativeTime = relativeTime;
    row.sourceAddress = 0x0A000000u | static_cast<uint32_t>(bits & 0x00FFFFFFu);
    row.destinationAddress = 0xAC100000u | static_cast<uint32_t>((bits >> 24) & 0x000FFFFFu);
    row.length = 54u + static_cast<uint32_t>((bits >> 44) % 1461u);
    row.seed = static_cast<uint32_t>(bits >> 32);
    row.sourcePort = static_cast<uint16_t>(49152u + ((bits >> 8) % 16384u));
    row.protocol = static_cast<uint8_t>((bits >> 56) % kProtocolCount);
    row.destinationPort = kProtocolPorts[row.protocol];
    return row;
}

// Clamp snprintf's would-be length to what actually landed in the buffer.
size_t WrittenLength(int result, size_t size) {
    if (result <= 0) {
        return 0;
    }
    return std::min(static_cast<size_t>(result), size - 1);
}

// Format an IPv4 address as dotted decimal.
size_t FormatAddress(char *out, size_t size, uint32_t address) {
    const int result = std::snprintf(out, size, "%u.%u.%u.%u", (address >> 24) & 0xFFu, (address >> 16) & 0xFFu,
                                     (address >> 8) & 0xFFu, address & 0xFFu);
    return WrittenLength(result, size);
}

// Format the Info column roughly the way Wireshark summarizes each synthetic protocol.
size_t FormatInfo(char *out, size_t size, const PacketRow &row) {
    int result = 0;
    switch (row.protocol) {
    case 0:
        // "\xE2\x86\x92" is U+2192 (→), so the packed path must count UTF-16 units correctly.
        result = std::snprintf(out, size, "%u \xE2\x86\x92 %u [ACK] Seq=%u Ack=%u Win=%u Len=%u", row.sourcePort,
                               row.destinationPort, row.seed, row.seed ^ 0x5BD1E995u, 501u + row.seed % 64000u,
                               row.length - 54u);
        break;
    case 1:
        result = std::snprintf(out, size, "Application Data, Application Data");
        break;
    case 2:
        result = std::snprintf(out, size, "%u \xE2\x86\x92 %u Len=%u", row.sourcePort, row.destinationPort,
                               row.length - 42u);
        break;
    case 3:
        result = std::snprintf(out, size, "Standard query 0x%04x A api%u.example.com", row.seed & 0xFFFFu,
                               row.seed % 1000u);
        break;
    case 4:
        result = std::snprintf(out, size, "Protected Payload (KP0), DCID=%08x", row.seed);
        break;
    default:
        result = std::snprintf(out, size, "GET /v1/items/%u HTTP/1.1", row.seed % 100000u);
        break;
    }
    return WrittenLength(result, size);
}

// Count UTF-16 code units in valid UTF-8 so JS can slice the decoded blob without rescanning it.
uint32_t Utf16Length(const char *text, size_t length) {
    uint32_t units = 0;
    for (size_t index = 0; index < length; ++index) {
        const auto byte = static_cast<unsigned char>(text[index]);
        if ((byte & 0xC0u) != 0x80u) {
            units += byte >= 0xF0u ? 2u : 1u;
        }
    }
    return units;
}

class SyntheticEngine {
public:
    // Start (or restart) appending rows at the requested rate on a native thread.
    void Start(double rowsPerSecond) {
        Stop();
        running_.store(true);
        worker_ = std::thread([this, rowsPerSecond] { Run(rowsPerSecond); });
    }

    // Stop the generator thread and keep the rows already stored.
    void Stop() {
        running_.store(false);
        if (worker_.joinable()) {
            worker_.join();
        }
    }

    uint64_t Count() const {
        return count_.load(std::memory_order_acquire);
    }

    // Report the bytes reserved for row storage (whole chunks).
    size_t MemoryBytes() const {
        std::lock_guard<std::mutex> lock(mutex_);
        return chunks_.size() * kChunkRows * sizeof(PacketRow);
    }

    // Copy a bounded slice of stored rows; the lock is held only for the copy.
    void CopyRows(uint64_t first, uint64_t count, std::vector<PacketRow> &out) const {
        out.clear();
        const uint64_t available = Count();
        if (first >= available) {
            return;
        }
        const uint64_t last = std::min(available, first + std::min(count, kMaxRowsPerRequest));
        out.reserve(static_cast<size_t>(last - first));
        std::lock_guard<std::mutex> lock(mutex_);
        for (uint64_t number = first; number < last; ++number) {
            out.push_back(chunks_[number / kChunkRows][number % kChunkRows]);
        }
    }

private:
    // Append rows in small batches so viewport reads never wait behind a long critical section.
    void Run(double rowsPerSecond) {
        using Clock = std::chrono::steady_clock;
        const auto startedAt = Clock::now();
        const uint64_t base = Count();
        const double baseTime = nextRowTime_;
        uint64_t produced = base;
        std::vector<PacketRow> batch;
        std::vector<std::unique_ptr<PacketRow[]>> newChunks;

        while (running_.load(std::memory_order_relaxed)) {
            const double elapsed = std::chrono::duration<double>(Clock::now() - startedAt).count();
            const uint64_t target = base + static_cast<uint64_t>(elapsed * rowsPerSecond);
            if (target > produced) {
                batch.clear();
                for (uint64_t number = produced; number < target; ++number) {
                    batch.push_back(MakeRow(number, baseTime + static_cast<double>(number - base) / rowsPerSecond));
                }

                // Only this thread grows chunks_, so sizing it here without the lock is safe.
                const size_t neededChunks = static_cast<size_t>((target + kChunkRows - 1) / kChunkRows);
                newChunks.clear();
                while (chunks_.size() + newChunks.size() < neededChunks) {
                    newChunks.push_back(std::make_unique<PacketRow[]>(kChunkRows));
                }

                {
                    std::lock_guard<std::mutex> lock(mutex_);
                    for (auto &chunk : newChunks) {
                        chunks_.push_back(std::move(chunk));
                    }
                    for (const PacketRow &row : batch) {
                        chunks_[row.number / kChunkRows][row.number % kChunkRows] = row;
                    }
                }

                produced = target;
                count_.store(produced, std::memory_order_release);
                nextRowTime_ = baseTime + static_cast<double>(produced - base) / rowsPerSecond;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(1));
        }
    }

    mutable std::mutex mutex_;
    std::vector<std::unique_ptr<PacketRow[]>> chunks_;
    std::atomic<uint64_t> count_{0};
    std::atomic<bool> running_{false};
    double nextRowTime_ = 0;
    std::thread worker_;
};

// The engine lives for the whole process; the env cleanup hook stops its thread.
SyntheticEngine &Engine() {
    static SyntheticEngine *engine = new SyntheticEngine();
    return *engine;
}

// Throw a TypeError into JS and return undefined.
Napi::Value ThrowTypeError(Napi::Env env, const char *message) {
    Napi::TypeError::New(env, message).ThrowAsJavaScriptException();
    return env.Undefined();
}

// Read a non-negative safe-integer argument; renderer-supplied values are untrusted.
bool ReadIndex(const Napi::CallbackInfo &info, size_t position, uint64_t &value) {
    if (info.Length() <= position || !info[position].IsNumber()) {
        return false;
    }
    const double number = info[position].As<Napi::Number>().DoubleValue();
    if (!(number >= 0) || number > 9007199254740991.0) {
        return false;
    }
    value = static_cast<uint64_t>(number);
    return true;
}

// start(rowsPerSecond): begin synthetic ingest.
Napi::Value Start(const Napi::CallbackInfo &info) {
    Napi::Env env = info.Env();
    if (info.Length() < 1 || !info[0].IsNumber()) {
        return ThrowTypeError(env, "start(rowsPerSecond) expects a number");
    }
    const double rate = info[0].As<Napi::Number>().DoubleValue();
    if (!(rate >= 1) || rate > kMaxRowsPerSecond) {
        return ThrowTypeError(env, "rowsPerSecond must be between 1 and 1,000,000");
    }
    Engine().Start(rate);
    return env.Undefined();
}

// stop(): pause synthetic ingest.
Napi::Value Stop(const Napi::CallbackInfo &info) {
    Engine().Stop();
    return info.Env().Undefined();
}

// count(): rows stored so far.
Napi::Value Count(const Napi::CallbackInfo &info) {
    return Napi::Number::New(info.Env(), static_cast<double>(Engine().Count()));
}

// memoryBytes(): bytes reserved for native row storage.
Napi::Value MemoryBytes(const Napi::CallbackInfo &info) {
    return Napi::Number::New(info.Env(), static_cast<double>(Engine().MemoryBytes()));
}

// rowsClone(first, count): one JS object of column arrays, cloned to the renderer by structured clone.
Napi::Value RowsClone(const Napi::CallbackInfo &info) {
    Napi::Env env = info.Env();
    uint64_t first = 0;
    uint64_t requested = 0;
    if (!ReadIndex(info, 0, first) || !ReadIndex(info, 1, requested)) {
        return ThrowTypeError(env, "rowsClone(first, count) expects non-negative integers");
    }

    std::vector<PacketRow> rows;
    Engine().CopyRows(first, requested, rows);
    const size_t count = rows.size();

    Napi::Float64Array numbers = Napi::Float64Array::New(env, count);
    Napi::Float64Array times = Napi::Float64Array::New(env, count);
    Napi::Uint32Array lengths = Napi::Uint32Array::New(env, count);
    Napi::Array sources = Napi::Array::New(env, count);
    Napi::Array destinations = Napi::Array::New(env, count);
    Napi::Array protocols = Napi::Array::New(env, count);
    Napi::Array infos = Napi::Array::New(env, count);

    char buffer[192];
    for (size_t index = 0; index < count; ++index) {
        const PacketRow &row = rows[index];
        const auto slot = static_cast<uint32_t>(index);
        numbers[index] = static_cast<double>(row.number);
        times[index] = row.relativeTime;
        lengths[index] = row.length;
        sources.Set(slot, Napi::String::New(env, buffer, FormatAddress(buffer, sizeof(buffer), row.sourceAddress)));
        destinations.Set(slot,
                         Napi::String::New(env, buffer, FormatAddress(buffer, sizeof(buffer), row.destinationAddress)));
        protocols.Set(slot, Napi::String::New(env, kProtocolNames[row.protocol]));
        infos.Set(slot, Napi::String::New(env, buffer, FormatInfo(buffer, sizeof(buffer), row)));
    }

    Napi::Object result = Napi::Object::New(env);
    result.Set("count", Napi::Number::New(env, static_cast<double>(count)));
    result.Set("numbers", numbers);
    result.Set("times", times);
    result.Set("lengths", lengths);
    result.Set("sources", sources);
    result.Set("destinations", destinations);
    result.Set("protocols", protocols);
    result.Set("infos", infos);
    return result;
}

// rowsPacked(first, count): one ArrayBuffer holding numeric columns, string end offsets, and a UTF-8 blob.
// Layout: u32[4] header {count, firstLow, firstHigh, blobBytes}, f64 numbers[n], f64 times[n],
// u32 lengths[n], u32 stringEnds[4n] (cumulative UTF-16 offsets), then the UTF-8 blob.
Napi::Value RowsPacked(const Napi::CallbackInfo &info) {
    Napi::Env env = info.Env();
    uint64_t first = 0;
    uint64_t requested = 0;
    if (!ReadIndex(info, 0, first) || !ReadIndex(info, 1, requested)) {
        return ThrowTypeError(env, "rowsPacked(first, count) expects non-negative integers");
    }

    std::vector<PacketRow> rows;
    Engine().CopyRows(first, requested, rows);
    const size_t count = rows.size();

    std::string blob;
    blob.reserve(count * 96);
    std::vector<uint32_t> stringEnds(count * 4);
    uint32_t units = 0;
    char buffer[192];
    const auto append = [&](const char *text, size_t length, size_t slot) {
        blob.append(text, length);
        units += Utf16Length(text, length);
        stringEnds[slot] = units;
    };
    for (size_t index = 0; index < count; ++index) {
        const PacketRow &row = rows[index];
        append(buffer, FormatAddress(buffer, sizeof(buffer), row.sourceAddress), index * 4);
        append(buffer, FormatAddress(buffer, sizeof(buffer), row.destinationAddress), index * 4 + 1);
        const char *protocol = kProtocolNames[row.protocol];
        append(protocol, std::strlen(protocol), index * 4 + 2);
        append(buffer, FormatInfo(buffer, sizeof(buffer), row), index * 4 + 3);
    }

    const size_t numericBytes = count * (sizeof(double) * 2 + sizeof(uint32_t));
    const size_t offsetBytes = stringEnds.size() * sizeof(uint32_t);
    const size_t totalBytes = kPackedHeaderBytes + numericBytes + offsetBytes + blob.size();

    // Electron's V8 memory cage rejects external buffers, so this must be a V8-owned buffer we copy into.
    Napi::ArrayBuffer packed = Napi::ArrayBuffer::New(env, totalBytes);
    auto *base = static_cast<uint8_t *>(packed.Data());
    const uint32_t header[4] = {static_cast<uint32_t>(count), static_cast<uint32_t>(first & 0xFFFFFFFFu),
                                static_cast<uint32_t>(first >> 32), static_cast<uint32_t>(blob.size())};
    std::memcpy(base, header, sizeof(header));

    size_t offset = kPackedHeaderBytes;
    for (size_t index = 0; index < count; ++index) {
        const double number = static_cast<double>(rows[index].number);
        std::memcpy(base + offset + index * sizeof(double), &number, sizeof(double));
    }
    offset += count * sizeof(double);
    for (size_t index = 0; index < count; ++index) {
        std::memcpy(base + offset + index * sizeof(double), &rows[index].relativeTime, sizeof(double));
    }
    offset += count * sizeof(double);
    for (size_t index = 0; index < count; ++index) {
        std::memcpy(base + offset + index * sizeof(uint32_t), &rows[index].length, sizeof(uint32_t));
    }
    offset += count * sizeof(uint32_t);
    if (offsetBytes > 0) {
        std::memcpy(base + offset, stringEnds.data(), offsetBytes);
    }
    offset += offsetBytes;
    if (!blob.empty()) {
        std::memcpy(base + offset, blob.data(), blob.size());
    }
    return packed;
}

// Register the addon's functions and stop the generator when the environment shuts down.
Napi::Object Init(Napi::Env env, Napi::Object exports) {
    env.AddCleanupHook([] { Engine().Stop(); });
    exports.Set("start", Napi::Function::New(env, Start));
    exports.Set("stop", Napi::Function::New(env, Stop));
    exports.Set("count", Napi::Function::New(env, Count));
    exports.Set("memoryBytes", Napi::Function::New(env, MemoryBytes));
    exports.Set("rowsClone", Napi::Function::New(env, RowsClone));
    exports.Set("rowsPacked", Napi::Function::New(env, RowsPacked));
    return exports;
}

} // namespace

NODE_API_MODULE(tcpv_engine, Init)
