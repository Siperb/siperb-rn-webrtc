#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

#import <WebRTC/WebRTC.h>

NS_ASSUME_NONNULL_BEGIN

/** The layouts this compositor implements. Mirrors CallRecordingLayout in CallRecorder.ts. */
typedef NS_ENUM(NSInteger, CallVideoLayout) {
    CallVideoLayoutThemPnp = 0,
    CallVideoLayoutSideBySide,
    CallVideoLayoutUsOnly,
    CallVideoLayoutThemOnly,
};

/** Maps the JS layout string. Unknown values fall back to them-pnp, the web's default. */
FOUNDATION_EXPORT CallVideoLayout CallVideoLayoutFromString(NSString *_Nullable name);

/**
 * Everything the video leg of a recording needs, resolved.
 *
 * An object rather than eight more parameters, because it crosses three boundaries unchanged —
 * the module parses it, the manager stores it to serve `updateVideoSources`, and the recorder
 * reads its geometry — and a signature that long is misread at exactly one of the three.
 *
 * `width` is the FINAL frame width, already doubled by the caller for `side-by-side`. The
 * SD/HD/FHD table lives in JS next to the settings it reads; nothing here re-derives it.
 */
@interface CallVideoRecordingConfig : NSObject
@property(nonatomic, assign) NSInteger width;
@property(nonatomic, assign) NSInteger height;
@property(nonatomic, assign) NSInteger fps;
@property(nonatomic, assign) NSInteger pnpSize;
@property(nonatomic, assign) CallVideoLayout layout;
/** nil is a legitimate remote-only composite — the camera may simply be off. */
@property(nonatomic, strong, nullable) RTCVideoTrack *localTrack;
@property(nonatomic, strong) NSArray<RTCVideoTrack *> *remoteTracks;
@end

/**
 * The video half of a call recording: composites the local and remote video tracks at a fixed
 * frame rate, encodes H.264, and muxes it with the audio recorder's mixed PCM into an mp4.
 *
 * ONE MIXER, TWO CONSUMERS. Nothing here mixes audio. CallAudioRecorder's 10 ms writer clock
 * already produces the interleaved int16 mix it streams to the WAV, and that same buffer is
 * handed to `appendAudioTick:` on the same tick. A second tap would be a second mix, and two
 * mixes of the same call drift.
 *
 * WHY THE WAV STILL EXISTS ALONGSIDE THIS. An mp4's moov atom is written at stop, so a process
 * killed mid-recording leaves an unplayable file. The WAV keeps streaming, so a crashed video
 * segment still salvages as audio through finalizeWavAtPath:. A deliberate double-write: the
 * only crash-recoverable copy is the one nobody has to finalize.
 *
 * DEGRADES, NEVER FAILS THE SEGMENT. If AVAssetWriter dies mid-recording — and it does, because
 * iOS revokes hardware video encode when the app is backgrounded — the video leg is torn down,
 * `videoUsable` goes NO, and the audio recorder carries on to a normal .m4a. Losing the picture
 * is a worse recording; losing the call is a lost recording.
 *
 * THREADING. Frames arrive on WebRTC decoder threads and are stored under a lock as
 * "latest per slot". The composite timer runs on its own serial queue and is the only thing that
 * reads them. Audio ticks arrive on CallAudioRecorder's writer queue. Every append goes through
 * the same serial queue so AVAssetWriter sees one writer.
 */
@interface CallVideoRecorder : NSObject

/** NO once the writer has failed or been torn down; the stop result reports it as withVideo. */
@property(nonatomic, readonly) BOOL videoUsable;

/** Where the mp4 is being written. */
@property(nonatomic, copy, readonly) NSString *outputPath;

- (instancetype)initWithOutputPath:(NSString *)outputPath
                            config:(CallVideoRecordingConfig *)config
                            stereo:(BOOL)stereo;

/** Opens the writer and starts the composite timer. NO + error (CallRecordingErrorIO) on failure. */
- (BOOL)start:(NSError **)error;

/**
 * Latest frame for a slot. `slot` is -1 for the local/presentation source and 0..n for remotes.
 * Called from WebRTC decoder threads; copies nothing but the buffer reference.
 */
- (void)submitFrame:(RTCVideoFrame *)frame forSlot:(NSInteger)slot;

/** Forget a slot's picture — its area draws black from the next tick. Used when a source detaches. */
- (void)clearSlot:(NSInteger)slot;

/**
 * The audio recorder's mixed tick: interleaved int16, `count` shorts, already at 48 kHz and in
 * the recorder's channel layout. Appended verbatim.
 */
- (void)appendAudioTick:(const int16_t *)samples count:(NSUInteger)count;

/**
 * Stops the timer, finishes the writer and reports what was produced. `result` carries
 * `filePath`, `durationMs`, `size`; it is nil with a non-nil error only when nothing usable was
 * written, in which case the caller should fall back to the audio-only path.
 */
- (void)stopWithCompletion:(void (^)(NSDictionary *_Nullable result, NSError *_Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
