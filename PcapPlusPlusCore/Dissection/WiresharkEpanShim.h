#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TCPViewerWiresharkSession TCPViewerWiresharkSession;

typedef struct TCPViewerWiresharkPacketContext {
    uint64_t packetIdentifier;
    const uint8_t *bytes;
    size_t capturedLength;
    size_t originalLength;
    int32_t linkLayerType;
    int64_t timestampSeconds;
    int32_t timestampNanoseconds;
    const char *interfaceName;
    const char *packetComment;
    uint32_t interfaceID;
    uint32_t sectionNumber;
} TCPViewerWiresharkPacketContext;

typedef struct TCPViewerWiresharkByteRange {
    size_t offset;
    size_t length;
    uint8_t bitOffset;
    uint8_t bitLength;
    bool hasBitRange;
    const char *sourceIdentifier;
} TCPViewerWiresharkByteRange;

typedef struct TCPViewerWiresharkDetailNode {
    const char *identifier;
    const char *name;
    const char *fieldName;
    const char *value;
    const char *rawValue;
    const char *kind;
    const char *severity;
    TCPViewerWiresharkByteRange *byteRange;
    uint64_t jumpTargetPacketIdentifier;
    bool hasJumpTargetPacketIdentifier;
    struct TCPViewerWiresharkDetailNode *children;
    size_t childCount;
} TCPViewerWiresharkDetailNode;

typedef struct TCPViewerWiresharkByteSource {
    const char *identifier;
    const char *label;
    uint8_t *bytes;
    size_t byteCount;
} TCPViewerWiresharkByteSource;

typedef struct TCPViewerWiresharkSummaryResult {
    bool succeeded;
    const char *errorMessage;
    const char *protocol;
    const char *info;
    const char *sniDomainName;
} TCPViewerWiresharkSummaryResult;

typedef struct TCPViewerWiresharkInspectionResult {
    bool succeeded;
    const char *errorMessage;
    const char *sniDomainName;
    TCPViewerWiresharkByteSource *byteSources;
    size_t byteSourceCount;
    TCPViewerWiresharkDetailNode *nodes;
    size_t nodeCount;
} TCPViewerWiresharkInspectionResult;

TCPViewerWiresharkSession *TCPViewerWiresharkSessionCreate(bool disabled);
void TCPViewerWiresharkSessionDestroy(TCPViewerWiresharkSession *session);
bool TCPViewerWiresharkSessionIsAvailable(TCPViewerWiresharkSession *session);
const char *TCPViewerWiresharkSessionUnavailableReason(TCPViewerWiresharkSession *session);
bool TCPViewerWiresharkSessionObservePacket(TCPViewerWiresharkSession *session, const TCPViewerWiresharkPacketContext *context);
bool TCPViewerWiresharkSessionFinishFirstPass(TCPViewerWiresharkSession *session);
TCPViewerWiresharkSummaryResult *TCPViewerWiresharkSessionSummarizePacket(TCPViewerWiresharkSession *session, const TCPViewerWiresharkPacketContext *context);
TCPViewerWiresharkInspectionResult *TCPViewerWiresharkSessionInspectPacket(TCPViewerWiresharkSession *session, const TCPViewerWiresharkPacketContext *context);
void TCPViewerWiresharkSummaryResultDestroy(TCPViewerWiresharkSummaryResult *result);
void TCPViewerWiresharkInspectionResultDestroy(TCPViewerWiresharkInspectionResult *result);

#ifdef __cplusplus
}
#endif
