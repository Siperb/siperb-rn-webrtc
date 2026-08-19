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
 * IDLE-CHEAP BY CONTRACT: with no conference up `active` is NO and every caller is expected
 * to return before touching anything else - these hooks sit in the path of every ordinary
 * 1:1 call.
 */
@interface SiperbConferenceAudioBus : NSObject

+ (instancetype)sharedBus;

/** The recording's consumer id. Not a leg, so it excludes nothing. */
@property(class, nonatomic, readonly) NSString *recordingConsumer;

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

// -- membership -------------------------------------------------------------
/** Idempotent: a re-join must patch, never replace, or the leg's rings are discarded mid-call. */
- (void)addLeg:(NSString *)legId;
- (void)removeLeg:(NSString *)legId;
/** Drops every leg, un-mutes, and DRAINS THE MICROPHONE - see the note in the implementation. */
- (void)clear;

// -- consumers --------------------------------------------------------------
/**
 * What leg `legId` should be sent: the microphone plus every other leg.
 *
 * @param out zero-padded on underrun rather than left holding the previous frame - stale
 *            audio repeating is far more noticeable than a gap.
 * @return YES if anything was mixed in; NO means this frame is silence.
 */
- (BOOL)pullForLeg:(NSString *)legId into:(int16_t *)out frames:(NSUInteger)frames;

/**
 * Every remote leg summed, no exclusion and no microphone - the far side of a recording,
 * which is one mixed channel however many parties are on the call.
 */
- (BOOL)pullRemoteSumInto:(int16_t *)out frames:(NSUInteger)frames;

@end
