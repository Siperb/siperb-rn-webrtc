#import <Foundation/Foundation.h>

/**
 * The one place a conference's audio is summed on iOS. Mirrors the Android
 * ConferenceAudioBus exactly, including the parts that are not obvious.
 *
 * Holds the microphone and one source per remote leg, and answers a single question:
 * "what should leg X be sent?" - the microphone plus every OTHER leg, never itself. That
 * exclusion is the whole reason the class exists; a leg hearing its own audio back is the
 * failure a three-way call has to avoid, and it cannot be fixed downstream because by then
 * the legs are indistinguishable.
 *
 * ONE RING PER CONSUMER, AND THAT IS THE LOAD-BEARING DETAIL. A ring read is destructive,
 * and a three-way call reads the microphone TWICE per tick - once for the mix going to the
 * host, once for the mix going to the child - plus a third time for a recording. A single
 * ring per source silently gives the second reader an empty buffer: the first mix is right
 * and every one after it is missing the mic, which sounds like "the other party cannot hear
 * me" and is invisible in review. Sources therefore fan out to one ring per consumer at
 * PUSH time. Found on Android by a test that pulled two mixes from one frame.
 *
 * Fanning out at push also removes any requirement that consumers be aligned in time, which
 * matters because the capture callbacks driving the outbound mixes belong to different
 * factories with different clocks and will never agree.
 *
 * AUX SOURCES are the third kind of input: audio that is neither the microphone nor a remote
 * party - a presented video file's soundtrack. An aux is summed into EVERY leg's mix beside
 * the microphone (every far end hears it, a conference too), it is never muted by micMuted
 * (mute silences the presenter, not the file), it joins the recording on the NEAR side with
 * the mic (the web records presentation audio on the local channel), and it is the only kind
 * of source that fans into the render consumer - the local playout the presenter hears,
 * drained by the APM render hook so the file sits in the echo canceller's reference. It is
 * NOT a leg: it has no mix of its own, and `active` does not count it. Membership outlives a
 * conference: `clear` prunes an aux's leg rings and keeps the aux.
 *
 * IDLE-CHEAP BY CONTRACT: with no conference up `active` is NO and every caller is expected
 * to return before touching anything else - these hooks sit in the path of every ordinary
 * 1:1 call.
 */
@interface SiperbConferenceAudioBus : NSObject

+ (instancetype)sharedBus;

/** The recording's consumer id. Not a leg, so it excludes nothing. */
@property(class, nonatomic, readonly) NSString *recordingConsumer;
/** The local-playout consumer id. Only AUX sources fan into it. */
@property(class, nonatomic, readonly) NSString *renderConsumer;

/** YES while at least one leg is on the bus. */
@property(nonatomic, readonly) BOOL active;
@property(nonatomic, readonly) NSArray<NSString *> *legIds;

/**
 * Mute is a property of the MIX, not of the sender track. In a conference the outbound
 * track is whatever we assemble, so muting it would mute everyone; leaving the microphone
 * out of the sum is the only thing that mutes just us.
 */
@property(nonatomic, assign) BOOL micMuted;

// -- producers, called from real-time audio threads ------------------------
- (void)pushMicrophone:(const int16_t *)samples count:(NSUInteger)count sampleRate:(double)sampleRate;
- (void)pushLeg:(NSString *)legId
        samples:(const int16_t *)samples
          count:(NSUInteger)count
     sampleRate:(double)sampleRate;
/** Feed one aux source. No-op for an aux that is not on the bus. */
- (void)pushAux:(NSString *)auxId
        samples:(const int16_t *)samples
          count:(NSUInteger)count
     sampleRate:(double)sampleRate;

// -- membership -------------------------------------------------------------
/** Idempotent: a re-join must patch, never replace, or the leg's rings are discarded mid-call. */
- (void)addLeg:(NSString *)legId;
- (void)removeLeg:(NSString *)legId;
/** Drops every leg, un-mutes, and DRAINS THE MICROPHONE - see the note in the implementation. */
- (void)clear;

/** Register an aux source. Idempotent; attach order relative to legs does not matter. */
- (void)addAux:(NSString *)auxId;
/** Take an aux off the bus. Safe for one never added, or already gone. */
- (void)removeAux:(NSString *)auxId;
- (BOOL)hasAux;
/** Local-playout gain for one aux, 0..1 - the render consumer only; legs and the recording stay at unity. */
- (void)setAuxRenderGain:(NSString *)auxId gain:(float)gain;
/**
 * Empty the recording consumer's rings on every source. They fill to capacity while nothing
 * records; the recorder calls this at start so it does not open with half a second of stale audio.
 */
- (void)clearRecordingRings;

/**
 * Is a conference up? True exactly while at least one leg is on the bus, and legs are only ever
 * added by BuildConferenceMix - so this is "a conference is live", not "the bus object exists".
 * The call recorder reads it per tick to decide where its far-side channel comes from.
 */
- (BOOL)isActive;

// -- consumers --------------------------------------------------------------
/**
 * What leg `legId` should be sent: the microphone plus every other leg.
 *
 * @param out         zero-padded on underrun rather than left holding the previous frame -
 *                    stale audio repeating is far more noticeable than a gap.
 * @param accumulator CALLER-OWNED, at least `frames` wide.
 * @param scratch     CALLER-OWNED, at least `frames` wide.
 *
 * The two buffers are parameters and NOT ivars, which is the whole reason two factories can
 * mix at once: the host leg's capture thread and every synthesised leg's capture thread call
 * this CONCURRENTLY. Shared scratch would let one leg's memset zero another's half-summed
 * mix, producing cross-leg bleed that worsens with each leg and cannot be reproduced in a
 * debugger. Android passes them for the same reason.
 * @return YES if anything was mixed in; NO means this frame is silence.
 */
- (BOOL)pullForLeg:(NSString *)legId
              into:(int16_t *)out
            frames:(NSUInteger)frames
       accumulator:(int32_t *)accumulator
           scratch:(int16_t *)scratch;

/**
 * Every remote leg summed, no exclusion and no microphone - the far side of a recording,
 * which is one mixed channel however many parties are on the call.
 */
- (BOOL)pullRemoteSumInto:(int16_t *)out
                   frames:(NSUInteger)frames
              accumulator:(int32_t *)accumulator
                  scratch:(int16_t *)scratch;

/**
 * Every aux source summed for one non-leg consumer - `recordingConsumer` (the recorder adds it
 * on the NEAR side beside the mic) or `renderConsumer` (the local playout, with each aux's
 * render gain applied). Separate from pullRemoteSumInto: on purpose, so the far side of a
 * recording stays legs-only.
 */
- (BOOL)pullAuxSumForConsumer:(NSString *)consumerId
                         into:(int16_t *)out
                       frames:(NSUInteger)frames
                  accumulator:(int32_t *)accumulator
                      scratch:(int16_t *)scratch;

@end
