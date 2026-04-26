#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, PCPPNativeInterfaceAvailability) {
    PCPPNativeInterfaceAvailabilityAvailable = 0,
    PCPPNativeInterfaceAvailabilityHidden = 1,
    PCPPNativeInterfaceAvailabilityUnavailable = 2,
    PCPPNativeInterfaceAvailabilityUnsupported = 3,
};

typedef NS_ENUM(NSInteger, PCPPNativeAddressFamily) {
    PCPPNativeAddressFamilyIPv4 = 0,
    PCPPNativeAddressFamilyIPv6 = 1,
    PCPPNativeAddressFamilyLinkLayer = 2,
    PCPPNativeAddressFamilyUnknown = 3,
};

typedef NS_ENUM(NSInteger, PCPPNativeLinkType) {
    PCPPNativeLinkTypeEthernet = 0,
    PCPPNativeLinkTypeLoopback = 1,
    PCPPNativeLinkTypeRaw = 2,
    PCPPNativeLinkTypeUnknown = 3,
};

typedef NS_ENUM(NSInteger, PCPPNativeTransportHint) {
    PCPPNativeTransportHintEthernet = 0,
    PCPPNativeTransportHintARP = 1,
    PCPPNativeTransportHintIPv4 = 2,
    PCPPNativeTransportHintIPv6 = 3,
    PCPPNativeTransportHintTCP = 4,
    PCPPNativeTransportHintUDP = 5,
    PCPPNativeTransportHintDNS = 6,
    PCPPNativeTransportHintHTTP1 = 7,
    PCPPNativeTransportHintTLS = 8,
    PCPPNativeTransportHintWebSocket = 9,
    PCPPNativeTransportHintPayload = 10,
    PCPPNativeTransportHintUnknown = 11,
};

typedef NS_ENUM(NSInteger, PCPPNativeDecodeStatusKind) {
    PCPPNativeDecodeStatusKindComplete = 0,
    PCPPNativeDecodeStatusKindPartial = 1,
    PCPPNativeDecodeStatusKindMalformed = 2,
    PCPPNativeDecodeStatusKindUnsupported = 3,
};

typedef NS_ENUM(NSInteger, PCPPNativeLiveSessionPhase) {
    PCPPNativeLiveSessionPhaseReady = 0,
    PCPPNativeLiveSessionPhaseStarting = 1,
    PCPPNativeLiveSessionPhaseRunning = 2,
    PCPPNativeLiveSessionPhasePaused = 3,
    PCPPNativeLiveSessionPhaseStopping = 4,
    PCPPNativeLiveSessionPhaseStopped = 5,
    PCPPNativeLiveSessionPhaseFailed = 6,
};

@interface PCPPNativeAddressDescriptor : NSObject

@property (nonatomic, readonly) PCPPNativeAddressFamily family;
@property (nonatomic, copy, readonly) NSString *value;

- (instancetype)initWithFamily:(PCPPNativeAddressFamily)family value:(NSString *)value NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PCPPNativeActivityPreviewDescriptor : NSObject

@property (nonatomic, readonly, nullable) NSNumber *packetsPerSecond;
@property (nonatomic, readonly, nullable) NSDate *observedAt;

- (instancetype)initWithPacketsPerSecond:(nullable NSNumber *)packetsPerSecond
                              observedAt:(nullable NSDate *)observedAt NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PCPPNativeInterfaceDescriptor : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *technicalName;
@property (nonatomic, copy, readonly) NSString *displayName;
@property (nonatomic, copy, readonly, nullable) NSString *friendlyName;
@property (nonatomic, copy, readonly, nullable) NSString *interfaceDescription;
@property (nonatomic, copy, readonly, nullable) NSString *availabilityReason;
@property (nonatomic, readonly) BOOL loopback;
@property (nonatomic, readonly) PCPPNativeInterfaceAvailability availability;
@property (nonatomic, readonly) PCPPNativeLinkType linkType;
@property (nonatomic, copy, readonly) NSArray<PCPPNativeAddressDescriptor *> *addresses;
@property (nonatomic, strong, readonly) PCPPNativeActivityPreviewDescriptor *activityPreview;
@property (nonatomic, readonly) BOOL canCapture;
@property (nonatomic, readonly) BOOL supportsPromiscuousMode;
@property (nonatomic, readonly) BOOL requiresBPFPermissionSetup;
@property (nonatomic, readonly) BOOL providesMacOSMetadata;

- (instancetype)initWithIdentifier:(NSString *)identifier
                     technicalName:(NSString *)technicalName
                       displayName:(NSString *)displayName
                      friendlyName:(nullable NSString *)friendlyName
              interfaceDescription:(nullable NSString *)interfaceDescription
                           loopback:(BOOL)loopback
                       availability:(PCPPNativeInterfaceAvailability)availability
                 availabilityReason:(nullable NSString *)availabilityReason
                           linkType:(PCPPNativeLinkType)linkType
                          addresses:(NSArray<PCPPNativeAddressDescriptor *> *)addresses
                    activityPreview:(PCPPNativeActivityPreviewDescriptor *)activityPreview
                         canCapture:(BOOL)canCapture
             supportsPromiscuousMode:(BOOL)supportsPromiscuousMode
          requiresBPFPermissionSetup:(BOOL)requiresBPFPermissionSetup
                 providesMacOSMetadata:(BOOL)providesMacOSMetadata NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PCPPNativePacketEndpointDescriptor : NSObject

@property (nonatomic, copy, readonly, nullable) NSString *address;
@property (nonatomic, readonly, nullable) NSNumber *port;

- (instancetype)initWithAddress:(nullable NSString *)address port:(nullable NSNumber *)port NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PCPPNativePacketLayerDescriptor : NSObject

@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly, nullable) NSString *detailSummary;

- (instancetype)initWithName:(NSString *)name detailSummary:(nullable NSString *)detailSummary NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PCPPNativePacketCaptureMetadataDescriptor : NSObject

@property (nonatomic, readonly) PCPPNativeLinkType linkType;
@property (nonatomic, readonly) BOOL truncated;
@property (nonatomic, copy, readonly, nullable) NSString *packetComment;
@property (nonatomic, copy, readonly, nullable) NSString *interfaceName;

- (instancetype)initWithLinkType:(PCPPNativeLinkType)linkType
                       truncated:(BOOL)truncated
                   packetComment:(nullable NSString *)packetComment
                   interfaceName:(nullable NSString *)interfaceName NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PCPPNativeDecodeStatusDescriptor : NSObject

@property (nonatomic, readonly) PCPPNativeDecodeStatusKind kind;
@property (nonatomic, copy, readonly, nullable) NSString *reason;

- (instancetype)initWithKind:(PCPPNativeDecodeStatusKind)kind reason:(nullable NSString *)reason NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PCPPNativePacketSummaryDescriptor : NSObject

@property (nonatomic, readonly) unsigned long long identifier;
@property (nonatomic, readonly) unsigned long long packetNumber;
@property (nonatomic, strong, readonly) NSDate *timestamp;
@property (nonatomic, copy, readonly, nullable) NSString *interfaceIdentifier;
@property (nonatomic, readonly) PCPPNativeTransportHint transportHint;
@property (nonatomic, strong, readonly) PCPPNativePacketEndpointDescriptor *sourceEndpoint;
@property (nonatomic, strong, readonly) PCPPNativePacketEndpointDescriptor *destinationEndpoint;
@property (nonatomic, readonly) NSInteger originalLength;
@property (nonatomic, readonly) NSInteger capturedLength;
@property (nonatomic, readonly, nullable) NSNumber *streamIdentifier;
@property (nonatomic, copy, readonly, nullable) NSString *tcpFlags;
@property (nonatomic, readonly, nullable) NSNumber *tcpPayloadLength;
@property (nonatomic, copy, readonly) NSString *infoSummary;
@property (nonatomic, copy, readonly) NSArray<PCPPNativePacketLayerDescriptor *> *layers;
@property (nonatomic, strong, readonly) PCPPNativeDecodeStatusDescriptor *decodeStatus;
@property (nonatomic, strong, readonly) PCPPNativePacketCaptureMetadataDescriptor *captureMetadata;
@property (nonatomic, copy, readonly, nullable) NSString *sniDomainName;

- (instancetype)initWithIdentifier:(unsigned long long)identifier
                       packetNumber:(unsigned long long)packetNumber
                          timestamp:(NSDate *)timestamp
                interfaceIdentifier:(nullable NSString *)interfaceIdentifier
                      transportHint:(PCPPNativeTransportHint)transportHint
                     sourceEndpoint:(PCPPNativePacketEndpointDescriptor *)sourceEndpoint
                destinationEndpoint:(PCPPNativePacketEndpointDescriptor *)destinationEndpoint
                     originalLength:(NSInteger)originalLength
                     capturedLength:(NSInteger)capturedLength
                   streamIdentifier:(nullable NSNumber *)streamIdentifier
                           tcpFlags:(nullable NSString *)tcpFlags
                    tcpPayloadLength:(nullable NSNumber *)tcpPayloadLength
                        infoSummary:(NSString *)infoSummary
                             layers:(NSArray<PCPPNativePacketLayerDescriptor *> *)layers
                       decodeStatus:(PCPPNativeDecodeStatusDescriptor *)decodeStatus
                    captureMetadata:(PCPPNativePacketCaptureMetadataDescriptor *)captureMetadata
                       sniDomainName:(nullable NSString *)sniDomainName NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PCPPNativeCaptureHealthDescriptor : NSObject

@property (nonatomic, readonly) unsigned long long packetsReceived;
@property (nonatomic, readonly) unsigned long long packetsDropped;
@property (nonatomic, readonly) unsigned long long packetsDroppedByInterface;
@property (nonatomic, readonly) unsigned long long packetsObserved;
@property (nonatomic, strong, readonly, nullable) NSDate *lastUpdated;
@property (nonatomic, copy, readonly, nullable) NSString *statusMessage;

- (instancetype)initWithPacketsReceived:(unsigned long long)packetsReceived
                         packetsDropped:(unsigned long long)packetsDropped
              packetsDroppedByInterface:(unsigned long long)packetsDroppedByInterface
                        packetsObserved:(unsigned long long)packetsObserved
                            lastUpdated:(nullable NSDate *)lastUpdated
                          statusMessage:(nullable NSString *)statusMessage NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PCPPNativeCaptureDocumentMetadataDescriptor : NSObject

@property (nonatomic, copy, readonly) NSString *format;
@property (nonatomic, copy, readonly, nullable) NSString *operatingSystem;
@property (nonatomic, copy, readonly, nullable) NSString *hardware;
@property (nonatomic, copy, readonly, nullable) NSString *captureApplication;
@property (nonatomic, copy, readonly, nullable) NSString *fileComment;

- (instancetype)initWithFormat:(NSString *)format
                operatingSystem:(nullable NSString *)operatingSystem
                       hardware:(nullable NSString *)hardware
             captureApplication:(nullable NSString *)captureApplication
                    fileComment:(nullable NSString *)fileComment NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PCPPNativeFilterValidationDescriptor : NSObject

@property (nonatomic, copy, readonly) NSString *disposition;
@property (nonatomic, copy, readonly, nullable) NSString *normalizedExpression;
@property (nonatomic, copy, readonly, nullable) NSString *message;

- (instancetype)initWithDisposition:(NSString *)disposition
               normalizedExpression:(nullable NSString *)normalizedExpression
                            message:(nullable NSString *)message NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PCPPNativeCaptureOptionsDescriptor : NSObject

@property (nonatomic, readonly) BOOL promiscuousMode;
@property (nonatomic, readonly) NSInteger snapshotLength;
@property (nonatomic, readonly) NSInteger kernelBufferSizeBytes;
@property (nonatomic, readonly) NSInteger readTimeoutMilliseconds;
@property (nonatomic, copy, readonly, nullable) NSString *captureFilterExpression;
@property (nonatomic, copy, readonly) NSString *stopMode;
@property (nonatomic, readonly) unsigned long long stopValue;
@property (nonatomic, copy, readonly) NSString *fileWritingMode;
@property (nonatomic, strong, readonly, nullable) NSURL *captureDirectoryURL;
@property (nonatomic, copy, readonly, nullable) NSString *fileNameStem;
@property (nonatomic, copy, readonly, nullable) NSString *fileFormat;
@property (nonatomic, readonly) unsigned long long maxFileSizeBytes;
@property (nonatomic, readonly) NSUInteger ringFileCount;

- (instancetype)initWithPromiscuousMode:(BOOL)promiscuousMode
                         snapshotLength:(NSInteger)snapshotLength
                  kernelBufferSizeBytes:(NSInteger)kernelBufferSizeBytes
                readTimeoutMilliseconds:(NSInteger)readTimeoutMilliseconds
                captureFilterExpression:(nullable NSString *)captureFilterExpression
                               stopMode:(NSString *)stopMode
                              stopValue:(unsigned long long)stopValue
                        fileWritingMode:(NSString *)fileWritingMode
                    captureDirectoryURL:(nullable NSURL *)captureDirectoryURL
                           fileNameStem:(nullable NSString *)fileNameStem
                             fileFormat:(nullable NSString *)fileFormat
                       maxFileSizeBytes:(unsigned long long)maxFileSizeBytes
                          ringFileCount:(NSUInteger)ringFileCount NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PCPPNativePacketByteRangeDescriptor : NSObject

@property (nonatomic, readonly) NSInteger offset;
@property (nonatomic, readonly) NSInteger length;

- (instancetype)initWithOffset:(NSInteger)offset length:(NSInteger)length NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PCPPNativePacketDetailNodeDescriptor : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly, nullable) NSString *value;
@property (nonatomic, copy, readonly) NSString *kind;
@property (nonatomic, strong, readonly, nullable) PCPPNativePacketByteRangeDescriptor *byteRange;
@property (nonatomic, readonly, nullable) NSNumber *jumpTargetPacketIdentifier;
@property (nonatomic, copy, readonly) NSArray<PCPPNativePacketDetailNodeDescriptor *> *children;

- (instancetype)initWithIdentifier:(NSString *)identifier
                              name:(NSString *)name
                             value:(nullable NSString *)value
                              kind:(NSString *)kind
                         byteRange:(nullable PCPPNativePacketByteRangeDescriptor *)byteRange
          jumpTargetPacketIdentifier:(nullable NSNumber *)jumpTargetPacketIdentifier
                           children:(NSArray<PCPPNativePacketDetailNodeDescriptor *> *)children NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PCPPNativePacketInspectionDescriptor : NSObject

@property (nonatomic, readonly) unsigned long long packetIdentifier;
@property (nonatomic, readonly) unsigned long long packetNumber;
@property (nonatomic, copy, readonly) NSData *rawBytes;
@property (nonatomic, copy, readonly) NSArray<PCPPNativePacketDetailNodeDescriptor *> *detailNodes;
@property (nonatomic, strong, readonly) PCPPNativeDecodeStatusDescriptor *decodeStatus;

- (instancetype)initWithPacketIdentifier:(unsigned long long)packetIdentifier
                            packetNumber:(unsigned long long)packetNumber
                                rawBytes:(NSData *)rawBytes
                             detailNodes:(NSArray<PCPPNativePacketDetailNodeDescriptor *> *)detailNodes
                            decodeStatus:(PCPPNativeDecodeStatusDescriptor *)decodeStatus NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

@interface PCPPNativePacketLoadProgressDescriptor : NSObject

@property (nonatomic, copy, readonly) NSString *phase;
@property (nonatomic, readonly) unsigned long long loadedPacketCount;
@property (nonatomic, readonly, nullable) NSNumber *processedBytes;
@property (nonatomic, readonly, nullable) NSNumber *totalBytes;
@property (nonatomic, readonly, getter=isPartialResult) BOOL partialResult;
@property (nonatomic, copy, readonly) NSString *message;

- (instancetype)initWithPhase:(NSString *)phase
            loadedPacketCount:(unsigned long long)loadedPacketCount
               processedBytes:(nullable NSNumber *)processedBytes
                   totalBytes:(nullable NSNumber *)totalBytes
                partialResult:(BOOL)partialResult
                      message:(NSString *)message NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@end

typedef void (^PCPPNativePacketBatchHandler)(NSArray<PCPPNativePacketSummaryDescriptor *> *packets);
typedef void (^PCPPNativeSessionPhaseHandler)(PCPPNativeLiveSessionPhase phase, NSString *message);
typedef void (^PCPPNativeHealthHandler)(PCPPNativeCaptureHealthDescriptor *health);
typedef void (^PCPPNativeErrorHandler)(NSError *error);
typedef void (^PCPPNativeLoadProgressHandler)(PCPPNativePacketLoadProgressDescriptor *progress);
typedef void (^PCPPNativePacketExportProgressHandler)(NSUInteger exportedPacketCount, NSUInteger totalPacketCount);
typedef BOOL (^PCPPNativeCancellationHandler)(void);

@interface PCPPNativeLiveSession : NSObject

@property (nonatomic, copy, nullable) PCPPNativePacketBatchHandler packetHandler;
@property (nonatomic, copy, nullable) PCPPNativeSessionPhaseHandler phaseHandler;
@property (nonatomic, copy, nullable) PCPPNativeHealthHandler healthHandler;
@property (nonatomic, copy, nullable) PCPPNativeErrorHandler errorHandler;
@property (nonatomic, strong, readonly) PCPPNativeCaptureHealthDescriptor *healthSnapshot;

- (instancetype)initWithInterfaceIdentifier:(NSString *)interfaceIdentifier
                                    options:(PCPPNativeCaptureOptionsDescriptor *)options
                                      error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (BOOL)startAndReturnError:(NSError **)error NS_SWIFT_NAME(start());
- (BOOL)pauseAndReturnError:(NSError **)error NS_SWIFT_NAME(pause());
- (BOOL)resumeAndReturnError:(NSError **)error NS_SWIFT_NAME(resume());
- (BOOL)stopAndReturnError:(NSError **)error NS_SWIFT_NAME(stop());
- (nullable PCPPNativePacketInspectionDescriptor *)inspectPacketWithIdentifier:(unsigned long long)identifier error:(NSError **)error;
- (BOOL)exportPacketsWithIdentifiers:(NSArray<NSNumber *> *)identifiers
                                toURL:(NSURL *)url
                               format:(NSString *)format
                      progressHandler:(nullable PCPPNativePacketExportProgressHandler)progressHandler
                    cancellationCheck:(nullable PCPPNativeCancellationHandler)cancellationCheck
                                error:(NSError **)error NS_SWIFT_NAME(exportPackets(withIdentifiers:to:format:progressHandler:cancellationCheck:));

@end

@interface PCPPNativeOfflineDocument : NSObject

@property (nonatomic, strong, readonly) NSURL *currentURL;
@property (nonatomic, copy, readonly) NSString *currentFormat;
@property (nonatomic, strong, readonly) PCPPNativeCaptureDocumentMetadataDescriptor *documentMetadata;
@property (nonatomic, readonly) BOOL dirty;

- (instancetype)initWithURL:(NSURL *)url error:(NSError **)error NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

- (NSArray<PCPPNativePacketSummaryDescriptor *> *)openAndReturnError:(NSError **)error;
- (NSArray<PCPPNativePacketSummaryDescriptor *> *)reopenAndReturnError:(NSError **)error;
- (NSArray<PCPPNativePacketSummaryDescriptor *> *)openIncrementallyWithBatchSize:(NSUInteger)batchSize
                                                                    batchHandler:(nullable PCPPNativePacketBatchHandler)batchHandler
                                                                 progressHandler:(nullable PCPPNativeLoadProgressHandler)progressHandler
                                                               cancellationCheck:(nullable PCPPNativeCancellationHandler)cancellationCheck
                                                                           error:(NSError **)error;
- (NSArray<PCPPNativePacketSummaryDescriptor *> *)reopenIncrementallyWithBatchSize:(NSUInteger)batchSize
                                                                      batchHandler:(nullable PCPPNativePacketBatchHandler)batchHandler
                                                                   progressHandler:(nullable PCPPNativeLoadProgressHandler)progressHandler
                                                                 cancellationCheck:(nullable PCPPNativeCancellationHandler)cancellationCheck
                                                                             error:(NSError **)error;
- (nullable PCPPNativePacketInspectionDescriptor *)inspectPacketWithIdentifier:(unsigned long long)identifier error:(NSError **)error;
- (BOOL)saveAndReturnError:(NSError **)error NS_SWIFT_NAME(save());
- (BOOL)saveToURL:(NSURL *)url format:(NSString *)format error:(NSError **)error NS_SWIFT_NAME(save(to:format:));
- (BOOL)exportPacketsWithIdentifiers:(NSArray<NSNumber *> *)identifiers
                                toURL:(NSURL *)url
                               format:(NSString *)format
                      progressHandler:(nullable PCPPNativePacketExportProgressHandler)progressHandler
                    cancellationCheck:(nullable PCPPNativeCancellationHandler)cancellationCheck
                                error:(NSError **)error NS_SWIFT_NAME(exportPackets(withIdentifiers:to:format:progressHandler:cancellationCheck:));

@end

#if DEBUG

@interface PCPPNativeLivePacketStoreTestProbe : NSObject

@property (nonatomic, readonly) NSUInteger packetCount;
@property (nonatomic, readonly) unsigned long long backingFileSize;
@property (nonatomic, readonly) BOOL backingFileExists;
@property (nonatomic, copy, readonly) NSString *backingFilePath;

- (instancetype)init NS_DESIGNATED_INITIALIZER;

- (BOOL)appendPacketWithIdentifier:(unsigned long long)identifier
                           rawBytes:(NSData *)rawBytes
                          timestamp:(NSDate *)timestamp
                      linkLayerType:(NSInteger)linkLayerType
                     originalLength:(NSInteger)originalLength
                              error:(NSError **)error NS_SWIFT_NAME(appendPacket(identifier:rawBytes:timestamp:linkLayerType:originalLength:));
- (nullable PCPPNativePacketInspectionDescriptor *)inspectPacketWithIdentifier:(unsigned long long)identifier
                                                                         error:(NSError **)error NS_SWIFT_NAME(inspectPacket(identifier:));
- (nullable NSNumber *)offsetForPacketWithIdentifier:(unsigned long long)identifier
                                               error:(NSError **)error NS_SWIFT_NAME(offset(identifier:));
- (void)cleanup;

@end

#endif

@interface PCPPNativeCore : NSObject

- (NSArray<PCPPNativeInterfaceDescriptor *> *)discoverInterfacesAndReturnError:(NSError **)error;
- (PCPPNativeFilterValidationDescriptor *)validateCaptureFilterExpression:(NSString *)expression NS_SWIFT_NAME(validateCaptureFilter(_:));
- (NSArray<NSString *> *)supportedOfflineFormats;

@end

NS_ASSUME_NONNULL_END
