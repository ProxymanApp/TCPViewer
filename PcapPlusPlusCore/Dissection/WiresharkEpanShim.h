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

typedef struct TCPViewerWiresharkFollowRecord {
    bool isServer;
    uint64_t packetIdentifier;
    uint32_t sequenceNumber;
    int64_t timestampSeconds;
    int32_t timestampNanoseconds;
    uint8_t *bytes;
    size_t byteCount;
} TCPViewerWiresharkFollowRecord;

typedef struct TCPViewerWiresharkFollowResult {
    bool succeeded;
    bool isTruncated;
    const char *errorMessage;
    const char *clientAddress;
    const char *serverAddress;
    uint16_t clientPort;
    uint16_t serverPort;
    uint64_t clientByteCount;
    uint64_t serverByteCount;
    TCPViewerWiresharkFollowRecord *records;
    size_t recordCount;
} TCPViewerWiresharkFollowResult;

typedef struct TCPViewerWiresharkTCPStreamIndexEntry {
    uint64_t packetIdentifier;
    uint32_t streamIdentifier;
} TCPViewerWiresharkTCPStreamIndexEntry;

typedef struct TCPViewerWiresharkTCPStreamIndexResult {
    TCPViewerWiresharkTCPStreamIndexEntry *entries;
    size_t entryCount;
} TCPViewerWiresharkTCPStreamIndexResult;

typedef struct TCPViewerWiresharkFollowCandidateResult {
    bool succeeded;
    const char *errorMessage;
    uint64_t *packetIdentifiers;
    size_t packetIdentifierCount;
} TCPViewerWiresharkFollowCandidateResult;

typedef enum TCPViewerWiresharkFollowPacketStatus {
    TCPViewerWiresharkFollowPacketFailed = -1,
    TCPViewerWiresharkFollowPacketAccepted = 0,
    TCPViewerWiresharkFollowPacketLimitReached = 1,
} TCPViewerWiresharkFollowPacketStatus;

typedef enum TCPViewerWiresharkFollowDirection {
    TCPViewerWiresharkFollowBothDirections = 0,
    TCPViewerWiresharkFollowClientToServer = 1,
    TCPViewerWiresharkFollowServerToClient = 2,
} TCPViewerWiresharkFollowDirection;

typedef struct TCPViewerWiresharkExceptionReport {
    bool isCriticalException;
    unsigned long exceptionGroup;
    unsigned long exceptionCode;
    uint64_t packetIdentifier;
    bool hasPacketIdentifier;
    const char *operation;
    const char *exceptionName;
    const char *reason;
} TCPViewerWiresharkExceptionReport;

typedef enum TCPViewerDisplayFilterValidationStatus {
    TCPViewerDisplayFilterValidationValid = 0,
    TCPViewerDisplayFilterValidationInvalid = 1,
    TCPViewerDisplayFilterValidationUnavailable = 2,
} TCPViewerDisplayFilterValidationStatus;

typedef enum TCPViewerDisplayFilterDiagnosticSeverity {
    TCPViewerDisplayFilterDiagnosticWarning = 0,
    TCPViewerDisplayFilterDiagnosticError = 1,
} TCPViewerDisplayFilterDiagnosticSeverity;

typedef struct TCPViewerDisplayFilterDiagnostic {
    TCPViewerDisplayFilterDiagnosticSeverity severity;
    const char *message;
    size_t utf8StartOffset;
    size_t utf8Length;
    bool hasRange;
} TCPViewerDisplayFilterDiagnostic;

typedef struct TCPViewerDisplayFilterValidationResult {
    TCPViewerDisplayFilterValidationStatus status;
    const char *normalizedExpression;
    TCPViewerDisplayFilterDiagnostic *diagnostics;
    size_t diagnosticCount;
} TCPViewerDisplayFilterValidationResult;

typedef struct TCPViewerDisplayFilterMatchResult {
    bool succeeded;
    bool matched;
    const char *errorMessage;
} TCPViewerDisplayFilterMatchResult;

TCPViewerWiresharkSession *TCPViewerWiresharkSessionCreate(bool disabled, bool livePriority, const char *personalConfigurationDirectory);
void TCPViewerWiresharkSessionDestroy(TCPViewerWiresharkSession *session);
void TCPViewerWiresharkSessionReleaseResources(TCPViewerWiresharkSession *session);
bool TCPViewerWiresharkSessionIsAvailable(TCPViewerWiresharkSession *session);
const char *TCPViewerWiresharkSessionUnavailableReason(TCPViewerWiresharkSession *session);
bool TCPViewerWiresharkSessionObservePacket(TCPViewerWiresharkSession *session, const TCPViewerWiresharkPacketContext *context);
TCPViewerWiresharkTCPStreamIndexResult *TCPViewerWiresharkSessionCopyPendingTCPStreamIndexUpdates(TCPViewerWiresharkSession *session);
bool TCPViewerWiresharkSessionFinishFirstPass(TCPViewerWiresharkSession *session);
bool TCPViewerWiresharkSessionCanFollowObservedPacket(TCPViewerWiresharkSession *session, uint64_t packetIdentifier);
bool TCPViewerWiresharkSessionCanFollowObservedPackets(
    TCPViewerWiresharkSession *session,
    const uint64_t *packetIdentifiers,
    size_t packetIdentifierCount
);
TCPViewerWiresharkFollowCandidateResult *TCPViewerWiresharkSessionCopyTCPFollowCandidates(
    TCPViewerWiresharkSession *session,
    uint64_t packetIdentifier,
    size_t maximumPacketCount
);
bool TCPViewerWiresharkSessionTCPStreamIdentifier(
    TCPViewerWiresharkSession *session,
    uint64_t packetIdentifier,
    uint32_t *streamIdentifier
);
TCPViewerWiresharkSummaryResult *TCPViewerWiresharkSessionSummarizePacket(TCPViewerWiresharkSession *session, const TCPViewerWiresharkPacketContext *context);
TCPViewerWiresharkInspectionResult *TCPViewerWiresharkSessionInspectPacket(TCPViewerWiresharkSession *session, const TCPViewerWiresharkPacketContext *context);
bool TCPViewerWiresharkSessionBeginFollowTCPStream(
    TCPViewerWiresharkSession *session,
    const TCPViewerWiresharkPacketContext *selectedContext,
    TCPViewerWiresharkFollowDirection direction
);
TCPViewerWiresharkFollowPacketStatus TCPViewerWiresharkSessionProcessFollowPacket(
    TCPViewerWiresharkSession *session,
    const TCPViewerWiresharkPacketContext *context,
    size_t maximumPayloadBytes,
    TCPViewerWiresharkFollowDirection direction
);
TCPViewerWiresharkFollowResult *TCPViewerWiresharkSessionFinishFollowTCPStream(
    TCPViewerWiresharkSession *session,
    size_t maximumPayloadBytes,
    size_t maximumRecordCount,
    TCPViewerWiresharkFollowDirection direction
);
void TCPViewerWiresharkSessionCancelFollowTCPStream(TCPViewerWiresharkSession *session);
TCPViewerWiresharkExceptionReport *TCPViewerWiresharkSessionCopyLastCriticalException(TCPViewerWiresharkSession *session);
TCPViewerWiresharkExceptionReport *TCPViewerWiresharkSessionCopyNextCriticalException(TCPViewerWiresharkSession *session);
TCPViewerDisplayFilterValidationResult *TCPViewerWiresharkValidateDisplayFilter(
    const char *expression,
    const char *personalConfigurationDirectory
);
TCPViewerDisplayFilterValidationResult *TCPViewerWiresharkSessionActivateDisplayFilter(
    TCPViewerWiresharkSession *session,
    const char *expression,
    uint64_t generation
);
TCPViewerDisplayFilterMatchResult *TCPViewerWiresharkSessionEvaluateDisplayFilter(
    TCPViewerWiresharkSession *session,
    const TCPViewerWiresharkPacketContext *context,
    uint64_t generation
);
void TCPViewerWiresharkSessionClearDisplayFilter(TCPViewerWiresharkSession *session);
void TCPViewerWiresharkSummaryResultDestroy(TCPViewerWiresharkSummaryResult *result);
void TCPViewerWiresharkInspectionResultDestroy(TCPViewerWiresharkInspectionResult *result);
void TCPViewerWiresharkTCPStreamIndexResultDestroy(TCPViewerWiresharkTCPStreamIndexResult *result);
void TCPViewerWiresharkFollowCandidateResultDestroy(TCPViewerWiresharkFollowCandidateResult *result);
void TCPViewerWiresharkFollowResultDestroy(TCPViewerWiresharkFollowResult *result);
void TCPViewerWiresharkExceptionReportDestroy(TCPViewerWiresharkExceptionReport *report);
void TCPViewerDisplayFilterValidationResultDestroy(TCPViewerDisplayFilterValidationResult *result);
void TCPViewerDisplayFilterMatchResultDestroy(TCPViewerDisplayFilterMatchResult *result);

#if DEBUG
TCPViewerWiresharkExceptionReport *TCPViewerWiresharkTestCopyCaughtExceptionReport(const char *personalConfigurationDirectory);
bool TCPViewerWiresharkSessionTestInjectCriticalException(TCPViewerWiresharkSession *session);
void TCPViewerWiresharkTestResetDisplayFilterCompilationCount(void);
size_t TCPViewerWiresharkTestDisplayFilterCompilationCount(void);
bool TCPViewerWiresharkSessionTestHasActiveDisplayFilter(TCPViewerWiresharkSession *session);
#endif

#ifdef __cplusplus
}
#endif
