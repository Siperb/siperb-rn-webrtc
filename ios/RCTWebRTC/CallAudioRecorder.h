#import <Foundation/Foundation.h>

extern NSString *const kCallRecordingErrorDomain;

typedef NS_ENUM(NSInteger, CallRecordingErrorCode) {
    CallRecordingErrorIO = 1,
    CallRecordingErrorEncode = 2,
    CallRecordingErrorDuplicate = 3,
};

/**
 * Records one call segment: real-time audio threads push mono int16 PCM into per-source
 * ring buffers, a 10 ms writer clock mixes them (zero-padding underruns) and streams a
 * 48 kHz 16-bit WAV to disk, and stop finalizes the WAV into an AAC .m4a. The WAV is
 * streamed so a crash mid-recording loses at most the buffered tail; the orphaned file
 * is salvageable via finalizeWavAtPath:toM4aPath:error:.
 *
 * Stereo recordings are CHANNEL-SPLIT, not true stereo — a SIP call carries no stereo
 * material to capture. Left is us (the mic), right is every remote party summed into one
 * side, matching the web recorder's CHANNEL_LOCAL / CHANNEL_REMOTE split so a recording
 * means the same thing whichever client made it. Mono sums everything into one channel.
 */
@interface CallAudioRecorder : NSObject

@property(nonatomic, copy, readonly) NSString *recordingId;
@property(nonatomic, copy, readonly) NSString *wavPath;
@property(nonatomic, copy, readonly) NSString *m4aPath;
@property(nonatomic, readonly) BOOL includesMic;
@property(nonatomic, readonly) BOOL stereo;

- (instancetype)initWithRecordingId:(NSString *)recordingId
                            wavPath:(NSString *)wavPath
                            m4aPath:(NSString *)m4aPath
                        includesMic:(BOOL)includesMic
                             stereo:(BOOL)stereo
                  remoteSourceCount:(NSUInteger)remoteSourceCount;

/** Opens the WAV file and starts the writer clock. NO + error (CallRecordingErrorIO) on failure. */
- (BOOL)start:(NSError **)error;

/**
 * Pushes from real-time audio threads. Samples are mono int16 at the given source rate and
 * are linearly resampled to 48 kHz at push time (the rate may change between pushes).
 */
- (void)pushMicSamples:(const int16_t *)samples count:(NSUInteger)count sampleRate:(double)sampleRate;
- (void)pushRemoteSamples:(const int16_t *)samples
                    count:(NSUInteger)count
               sampleRate:(double)sampleRate
              sourceIndex:(NSUInteger)sourceIndex;

/**
 * Stops the writer clock, drains buffered samples, patches the WAV header and encodes the
 * .m4a on a background queue. On success the WAV is deleted and result is
 * @{ @"filePath", @"durationMs", @"size" }; on failure error is non-nil and the WAV is kept
 * on disk so it can be salvaged later.
 */
- (void)stopWithCompletion:(void (^)(NSDictionary *result, NSError *error))completion;

/**
 * Finalizes a WAV into an .m4a: patches the header sizes from the file length (covers
 * headers never patched because the app died mid-recording), AAC-encodes, deletes the WAV
 * on success. Returns @{ @"filePath", @"durationMs", @"size" } or nil + error.
 */
+ (NSDictionary *)finalizeWavAtPath:(NSString *)wavPath toM4aPath:(NSString *)m4aPath error:(NSError **)error;

@end
