//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "SRGMediaPlayerController.h"

#import "AVAudioSession+SRGMediaPlayer.h"
#import "AVPlayer+SRGMediaPlayer.h"
#import "CMTime+SRGMediaPlayer.h"
#import "CMTimeRange+SRGMediaPlayer.h"
#import "MAKVONotificationCenter+SRGMediaPlayer.h"
#import "NSBundle+SRGMediaPlayer.h"
#import "NSTimer+SRGMediaPlayer.h"
#import "SRGActivityGestureRecognizer.h"
#import "SRGMediaPlayerError.h"
#import "SRGMediaPlayerLogger.h"
#import "SRGMediaPlayerView.h"
#import "SRGMediaPlayerView+Private.h"
#import "SRGPeriodicTimeObserver.h"
#import "SRGSegment+Private.h"
#import "UIScreen+SRGMediaPlayer.h"

#import <libextobjc/libextobjc.h>
#import <MAKVONotificationCenter/MAKVONotificationCenter.h>
#import <MediaAccessibility/MediaAccessibility.h>
#import <objc/runtime.h>

static const NSTimeInterval SRGSegmentSeekOffsetInSeconds = 0.1;

static NSError *SRGMediaPlayerControllerError(NSError *underlyingError);
static NSString *SRGMediaPlayerControllerNameForPlaybackState(SRGMediaPlayerPlaybackState playbackState);
static NSString *SRGMediaPlayerControllerNameForMediaType(SRGMediaPlayerMediaType mediaType);
static NSString *SRGMediaPlayerControllerNameForStreamType(SRGMediaPlayerStreamType streamType);

static SRGPosition *SRGMediaPlayerControllerOffset(SRGPosition *position,CMTime offset);
static SRGPosition *SRGMediaPlayerControllerPositionInTimeRange(SRGPosition *position, CMTimeRange timeRange);

@interface SRGMediaPlayerController () {
@private
    SRGMediaPlayerPlaybackState _playbackState;
    BOOL _selected;
    CMTimeRange _timeRange;
}

@property (nonatomic) AVPlayer *player;

@property (nonatomic) NSURL *contentURL;
@property (nonatomic) AVURLAsset *URLAsset;

@property (nonatomic) NSArray<id<SRGSegment>> *visibleSegments;

@property (nonatomic) NSMutableDictionary<NSString *, SRGPeriodicTimeObserver *> *periodicTimeObservers;
@property (nonatomic) id playerPeriodicTimeObserver;
@property (nonatomic, weak) id controllerPeriodicTimeObserver;

@property (nonatomic) NSTimer *stallDetectionTimer;
@property (nonatomic) CMTime lastPlaybackTime;
@property (nonatomic) NSDate *lastStallDetectionDate;

// Saved values supplied when playback is started
@property (nonatomic, weak) id<SRGSegment> initialTargetSegment;
@property (nonatomic) SRGPosition *initialPosition;

@property (nonatomic, weak) id<SRGSegment> previousSegment;
@property (nonatomic, weak) id<SRGSegment> targetSegment;           // Will be nilled when reached
@property (nonatomic, weak) id<SRGSegment> currentSegment;

@property (nonatomic) AVPictureInPictureController *pictureInPictureController;

@property (nonatomic) SRGPosition *startPosition;                   // Will be nilled when reached
@property (nonatomic, copy) void (^startCompletionHandler)(void);

@property (nonatomic) NSValue *presentationSizeValue;

@property (nonatomic) CMTime seekStartTime;
@property (nonatomic) CMTime seekTargetTime;

@property (nonatomic) NSArray<NSString *> *availableAudioTrackLocalizations;
@property (nonatomic) NSArray<NSString *> *availableSubtitleLocalizations;

@property (nonatomic, copy) NSString *preferredAudioTrackLocalization;
@property (nonatomic, copy) NSString *preferredSubtitleLocalization;

@property (nonatomic) AVMediaSelectionOption *audioTrackOption;
@property (nonatomic) AVMediaSelectionOption *subtitleOption;

@property (nonatomic, copy) NSString *audioTrackLocalization;
@property (nonatomic, copy) NSString *subtitleLocalization;

@property (nonatomic, copy) void (^pictureInPictureControllerCreationBlock)(AVPictureInPictureController *pictureInPictureController);

@end

@implementation SRGMediaPlayerController

@synthesize view = _view;
@synthesize pictureInPictureController = _pictureInPictureController;

#pragma mark Object lifecycle

- (instancetype)init
{
    if (self = [super init]) {
        _playbackState = SRGMediaPlayerPlaybackStateIdle;
        
        self.liveTolerance = SRGMediaPlayerDefaultLiveTolerance;
        self.endTolerance = SRGMediaPlayerDefaultEndTolerance;
        self.endToleranceRatio = SRGMediaPlayerDefaultEndToleranceRatio;
        
        self.periodicTimeObservers = [NSMutableDictionary dictionary];
        
        self.seekStartTime = kCMTimeIndefinite;
        self.seekTargetTime = kCMTimeIndefinite;
        
        self.lastPlaybackTime = kCMTimeIndefinite;
    }
    return self;
}

- (void)dealloc
{
    [self reset];
}

#pragma mark Getters and setters

- (void)setPlayer:(AVPlayer *)player
{
    BOOL hadPlayer = (_player != nil);
    
    if (_player) {
        [self unregisterTimeObserversForPlayer:_player];
        
        [_player removeObserver:self keyPath:@keypath(_player.currentItem.status)];
        [_player removeObserver:self keyPath:@keypath(_player.rate)];
        [_player removeObserver:self keyPath:@keypath(_player.externalPlaybackActive)];
        [_player removeObserver:self keyPath:@keypath(_player.currentItem.playbackLikelyToKeepUp)];
        [_player removeObserver:self keyPath:@keypath(_player.currentItem.presentationSize)];
        
        self.stallDetectionTimer = nil;
        
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:AVPlayerItemDidPlayToEndTimeNotification
                                                    object:_player.currentItem];
        [NSNotificationCenter.defaultCenter removeObserver:self
                                                      name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                    object:_player.currentItem];
        
        self.playerDestructionBlock ? self.playerDestructionBlock(_player) : nil;
    }
    
    _player = player;
    self.view.player = player;
    
    if (player) {
        if (! hadPlayer) {
            self.playerCreationBlock ? self.playerCreationBlock(player) : nil;
        }
        
        [self registerTimeObserversForPlayer:player];
        
        @weakify(self)
        @weakify(player)
        [player srg_addMainThreadObserver:self keyPath:@keypath(player.currentItem.status) options:0 block:^(MAKVONotification *notification) {
            @strongify(self)
            @strongify(player)
            
            AVPlayerItem *playerItem = player.currentItem;
            if (playerItem.status == AVPlayerItemStatusReadyToPlay) {    
                // Playback start. Use received start parameters, do not update the playback state yet, wait until the
                // completion handler has been executed (since it might immediately start playback)
                if (self.startPosition) {
                    void (^completionBlock)(BOOL) = ^(BOOL finished) {
                        if (! finished) {
                            return;
                        }
                        
                        self.view.playbackViewHidden = NO;
                        
                        // Reset start time first so that the playback state induced change made in the completion handler
                        // does not loop back here
                        self.startPosition = nil;
                        
                        self.startCompletionHandler ? self.startCompletionHandler() : nil;
                        self.startCompletionHandler = nil;
                        
                        // If the state of the player was not changed in the completion handler (still preparing), update
                        // it
                        if (self.playbackState == SRGMediaPlayerPlaybackStatePreparing) {
                            [self setPlaybackState:(player.rate == 0.f) ? SRGMediaPlayerPlaybackStatePaused : SRGMediaPlayerPlaybackStatePlaying withUserInfo:nil];
                        }
                    };
                    
                    SRGPosition *startPosition = self.startPosition;
                    
                    // Default position. Nothing to do.
                    if (CMTIME_COMPARE_INLINE(self.startPosition.time, ==, kCMTimeZero) && ! self.targetSegment) {
                        completionBlock(YES);
                    }
                    // Non-default start position. Calculate a valid position to seek to.
                    else {
                        // If a segment is targeted, add a small offset so that playback is guaranteed to start within the segment
                        if (self.targetSegment) {
                            startPosition = SRGMediaPlayerControllerOffset(startPosition, CMTimeMakeWithSeconds(SRGSegmentSeekOffsetInSeconds, NSEC_PER_SEC));
                        }
                        
                        // Take into account tolerance at the end of the content being played. If near the end enough, start
                        // at the default position instead.
                        CMTimeRange timeRange = self.targetSegment ? self.targetSegment.srg_timeRange : self.timeRange;
                        CMTime tolerance = SRGMediaPlayerEffectiveEndTolerance(self.endTolerance, self.endToleranceRatio, CMTimeGetSeconds(timeRange.duration));
                        CMTime toleratedStartTime = CMTIME_COMPARE_INLINE(startPosition.time, >=, CMTimeSubtract(timeRange.duration, tolerance)) ? kCMTimeZero : startPosition.time;
                        
                        // Positions in segments are relative. If not within a segment, they are absolute (relative positions
                        // are misleading for a DVR stream with a sliding window, and match the absolute position in other cases)
                        if (self.targetSegment) {
                            toleratedStartTime = CMTimeAdd(toleratedStartTime, timeRange.start);
                        }
                        SRGPosition *toleratedPosition = [SRGPosition positionWithTime:toleratedStartTime toleranceBefore:startPosition.toleranceBefore toleranceAfter:startPosition.toleranceAfter];
                        
                        SRGPosition *seekPosition = SRGMediaPlayerControllerPositionInTimeRange(toleratedPosition, timeRange);
                        
                        // Call system method to avoid unwanted seek state in this special case
                        [player seekToTime:seekPosition.time toleranceBefore:seekPosition.toleranceBefore toleranceAfter:seekPosition.toleranceAfter completionHandler:^(BOOL finished) {
                            completionBlock(finished);
                        }];
                    }
                }
            }
            else if (playerItem.status == AVPlayerItemStatusFailed) {
                [self stopWithUserInfo:nil];
                
                NSError *error = SRGMediaPlayerControllerError(playerItem.error);
                [NSNotificationCenter.defaultCenter postNotificationName:SRGMediaPlayerPlaybackDidFailNotification
                                                                  object:self
                                                                userInfo:@{ SRGMediaPlayerErrorKey: error }];
                
                SRGMediaPlayerLogDebug(@"Controller", @"Playback did fail with error: %@", error);
            }
        }];
        
        [player srg_addMainThreadObserver:self keyPath:@keypath(player.rate) options:0 block:^(MAKVONotification *notification) {
            @strongify(self)
            @strongify(player)
            
            AVPlayerItem *playerItem = player.currentItem;
            
            // Only respond to rate changes when the item is ready to play 
            if (playerItem.status != AVPlayerItemStatusReadyToPlay) {
                return;
            }
            
            CMTime currentTime = playerItem.currentTime;
            CMTimeRange timeRange = self.timeRange;
            
            // Update the playback state immediately, except when reaching the end or seeking. Non-streamed medias will namely reach the paused state right before
            // the item end notification is received. We can eliminate this pause by checking if we are at the end or not. Also update the state for
            // live streams (empty range)
            if (self.playbackState != SRGMediaPlayerPlaybackStateEnded
                     && self.playbackState != SRGMediaPlayerPlaybackStateSeeking
                     && (CMTIMERANGE_IS_EMPTY(timeRange) || CMTIME_COMPARE_INLINE(currentTime, !=, CMTimeRangeGetEnd(timeRange)))) {
                [self setPlaybackState:(player.rate == 0.f) ? SRGMediaPlayerPlaybackStatePaused : SRGMediaPlayerPlaybackStatePlaying withUserInfo:nil];
            }
            // Playback restarted after it ended (see -play and -pause)
            else if (self.playbackState == SRGMediaPlayerPlaybackStateEnded && player.rate != 0.f) {
                [self setPlaybackState:SRGMediaPlayerPlaybackStatePlaying withUserInfo:nil];
            }
        }];
        
        [player srg_addMainThreadObserver:self keyPath:@keypath(player.externalPlaybackActive) options:0 block:^(MAKVONotification *notification) {
            @strongify(self)
            
            [NSNotificationCenter.defaultCenter postNotificationName:SRGMediaPlayerExternalPlaybackStateDidChangeNotification object:self];
        }];
        
        [player srg_addMainThreadObserver:self keyPath:@keypath(player.currentItem.playbackLikelyToKeepUp) options:0 block:^(MAKVONotification *notification) {
            @strongify(self)
            @strongify(player)
            
            if (player.currentItem.playbackLikelyToKeepUp && self.playbackState == SRGMediaPlayerPlaybackStateStalled) {
                [self setPlaybackState:(player.rate == 0.f) ? SRGMediaPlayerPlaybackStatePaused : SRGMediaPlayerPlaybackStatePlaying withUserInfo:nil];
            }
        }];
        
        [player srg_addMainThreadObserver:self keyPath:@keypath(player.currentItem.presentationSize) options:0 block:^(MAKVONotification * _Nonnull notification) {
            @strongify(self)
            @strongify(player)
            
            self.presentationSizeValue = [NSValue valueWithCGSize:player.currentItem.presentationSize];
        }];
        
        self.stallDetectionTimer = [NSTimer srgmediaplayer_timerWithTimeInterval:1. repeats:YES block:^(NSTimer * _Nonnull timer) {
            @strongify(self)
            
            AVPlayerItem *playerItem = player.currentItem;
            CMTime currentTime = playerItem.currentTime;
            if (self.playbackState == SRGMediaPlayerPlaybackStatePlaying) {
                if (CMTIME_COMPARE_INLINE(self.lastPlaybackTime, ==, currentTime)) {
                    [self setPlaybackState:SRGMediaPlayerPlaybackStateStalled withUserInfo:nil];
                    self.lastStallDetectionDate = NSDate.date;
                }
                else {
                    self.lastStallDetectionDate = nil;
                }
            }
            else if ([NSDate.date timeIntervalSinceDate:self.lastStallDetectionDate] >= 5.) {
                [player srg_playImmediatelyIfPossible];
            }
            
            self.lastPlaybackTime = currentTime;
        }];
        
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(srg_mediaPlayerController_playerItemDidPlayToEndTime:)
                                                   name:AVPlayerItemDidPlayToEndTimeNotification
                                                 object:player.currentItem];
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(srg_mediaPlayerController_playerItemFailedToPlayToEndTime:)
                                                   name:AVPlayerItemFailedToPlayToEndTimeNotification
                                                 object:player.currentItem];
        
        self.playerConfigurationBlock ? self.playerConfigurationBlock(player) : nil;
    }
}

- (void)setStallDetectionTimer:(NSTimer *)stallDetectionTimer
{
    [_stallDetectionTimer invalidate];
    _stallDetectionTimer = stallDetectionTimer;
}

- (AVPlayerLayer *)playerLayer
{
    return self.view.playerLayer;
}

- (void)setPlaybackState:(SRGMediaPlayerPlaybackState)playbackState withUserInfo:(NSDictionary *)userInfo
{
    NSAssert([NSThread isMainThread], @"Not the main thread. Ensure important changes must be notified on the main thread. Fix");
    
    if (_playbackState == playbackState) {
        return;
    }
    
    SRGMediaPlayerPlaybackState previousPlaybackState = _playbackState;
    
    NSMutableDictionary *fullUserInfo = [@{ SRGMediaPlayerPlaybackStateKey : @(playbackState),
                                            SRGMediaPlayerPreviousPlaybackStateKey: @(previousPlaybackState) } mutableCopy];
    fullUserInfo[SRGMediaPlayerSelectionKey] = @(self.targetSegment && ! self.targetSegment.srg_blocked);
    if (userInfo) {
        [fullUserInfo addEntriesFromDictionary:userInfo];
    }
    
    [self willChangeValueForKey:@keypath(self.playbackState)];
    _playbackState = playbackState;
    [self didChangeValueForKey:@keypath(self.playbackState)];
    
    // Ensure segment status is up to date
    [self updateSegmentStatusForPlaybackState:playbackState previousPlaybackState:previousPlaybackState time:self.player.currentTime];
    
    [NSNotificationCenter.defaultCenter postNotificationName:SRGMediaPlayerPlaybackStateDidChangeNotification
                                                      object:self
                                                    userInfo:[fullUserInfo copy]];
    
    SRGMediaPlayerLogDebug(@"Controller", @"Playback state did change to %@ with info %@", SRGMediaPlayerControllerNameForPlaybackState(playbackState), fullUserInfo);
}

- (void)setSegments:(NSArray<id<SRGSegment>> *)segments
{
    if (segments && self.previousSegment) {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id<SRGSegment> _Nonnull segment, NSDictionary<NSString *, id> *_Nullable bindings) {
            return SRGMediaPlayerAreEqualSegments(segment, self.previousSegment);
        }];
        
        // Only update if a segment equivalent to the previous one was found (segment transition processing will update
        // the previous segment otherwise)
        id<SRGSegment> segment = [segments filteredArrayUsingPredicate:predicate].firstObject;
        if (segment) {
            self.previousSegment = segment;
        }
    }
    if (segments && self.targetSegment) {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id<SRGSegment> _Nonnull segment, NSDictionary<NSString *, id> *_Nullable bindings) {
            return SRGMediaPlayerAreEqualSegments(segment, self.targetSegment);
        }];
        
        // Similar to comment above
        id<SRGSegment> segment = [segments filteredArrayUsingPredicate:predicate].firstObject;
        if (segment) {
            self.targetSegment = segment;
        }
    }
    if (segments && self.currentSegment) {
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(id<SRGSegment> _Nonnull segment, NSDictionary<NSString *, id> *_Nullable bindings) {
            return SRGMediaPlayerAreEqualSegments(segment, self.currentSegment);
        }];
        
        // Similar to comment above
        id<SRGSegment> segment = [segments filteredArrayUsingPredicate:predicate].firstObject;
        if (segment) {
            self.currentSegment = segment;
        }
    }
    
    _segments = segments;
    
    // Reset the cached visible segment list
    _visibleSegments = nil;
}

- (NSArray<id<SRGSegment>> *)visibleSegments
{
    // Cached for faster access
    if (! _visibleSegments) {
        NSPredicate *predicate = [NSPredicate predicateWithFormat:@"srg_hidden == NO"];
        _visibleSegments = [self.segments filteredArrayUsingPredicate:predicate];
    }
    return _visibleSegments;
}

// Called when installing the view by binding it in a storyboard or xib
- (void)setView:(SRGMediaPlayerView *)view
{
    if (_view != view) {
        _view = view;
        _view.player = self.player;
    }
}

// Called when lazily creating the view, not binding it
- (UIView *)view
{
    if (! _view) {
        _view = [[SRGMediaPlayerView alloc] init];
        _view.player = self.player;
    }
    return _view;
}

- (CMTimeRange)timeRange
{
    // Cached value available. Use it
    if (CMTIMERANGE_IS_VALID(_timeRange)) {
        return _timeRange;
    }
    
    AVPlayerItem *playerItem = self.player.currentItem;
    
    NSValue *firstSeekableTimeRangeValue = [playerItem.seekableTimeRanges firstObject];
    NSValue *lastSeekableTimeRangeValue = [playerItem.seekableTimeRanges lastObject];
    
    CMTimeRange firstSeekableTimeRange = [firstSeekableTimeRangeValue CMTimeRangeValue];
    CMTimeRange lastSeekableTimeRange = [lastSeekableTimeRangeValue CMTimeRangeValue];
    
    if (! firstSeekableTimeRangeValue || CMTIMERANGE_IS_INVALID(firstSeekableTimeRange)
            || ! lastSeekableTimeRangeValue || CMTIMERANGE_IS_INVALID(lastSeekableTimeRange)) {
        return (playerItem.loadedTimeRanges.count != 0) ? kCMTimeRangeZero : kCMTimeRangeInvalid;
    }
    
    CMTimeRange timeRange = CMTimeRangeFromTimeToTime(firstSeekableTimeRange.start, CMTimeRangeGetEnd(lastSeekableTimeRange));
    
    // DVR window size too small. Check that we the stream is not an on-demand one first, of course
    if (CMTIME_IS_INDEFINITE(playerItem.duration) && CMTimeGetSeconds(timeRange.duration) < self.minimumDVRWindowLength) {
        timeRange = CMTimeRangeMake(timeRange.start, kCMTimeZero);
    }
    
    // On-demand time ranges are cached because they might become unreliable in some situations (e.g. when AirPlay is
    // connected or disconnected)
    if (SRG_CMTIME_IS_DEFINITE(playerItem.duration) && SRG_CMTIMERANGE_IS_NOT_EMPTY(timeRange)) {
        _timeRange = timeRange;
    }
    
    return timeRange;
}

- (CMTime)currentTime
{
    return self.player.currentTime;
}

- (SRGMediaPlayerMediaType)mediaType
{
    NSValue *presentationSizeValue = self.presentationSizeValue;
    if (! presentationSizeValue) {
        return SRGMediaPlayerMediaTypeUnknown;
    }
    
    return CGSizeEqualToSize(presentationSizeValue.CGSizeValue, CGSizeZero) ? SRGMediaPlayerMediaTypeAudio : SRGMediaPlayerMediaTypeVideo;
}

- (SRGMediaPlayerStreamType)streamType
{
    CMTimeRange timeRange = self.timeRange;
    
    if (CMTIMERANGE_IS_INVALID(timeRange)) {
        return SRGMediaPlayerStreamTypeUnknown;
    }
    else if (CMTIMERANGE_IS_EMPTY(timeRange)) {
        return SRGMediaPlayerStreamTypeLive;
    }
    else if (CMTIME_IS_INDEFINITE(self.player.currentItem.duration)) {
        return SRGMediaPlayerStreamTypeDVR;
    }
    else {
        return SRGMediaPlayerStreamTypeOnDemand;
    }
}

- (void)setMinimumDVRWindowLength:(NSTimeInterval)minimumDVRWindowLength
{
    if (minimumDVRWindowLength < 0.) {
        SRGMediaPlayerLogWarning(@"Controller", @"The minimum DVR window length cannot be negative. Set to 0");
        _minimumDVRWindowLength = 0.;
    }
    else {
        _minimumDVRWindowLength = minimumDVRWindowLength;
    }
}

- (void)setLiveTolerance:(NSTimeInterval)liveTolerance
{
    if (liveTolerance < 0.) {
        SRGMediaPlayerLogWarning(@"Controller", @"Live tolerance cannot be negative. Set to 0");
        _liveTolerance = 0.;
    }
    else {
        _liveTolerance = liveTolerance;
    }
}

- (void)setEndTolerance:(NSTimeInterval)endTolerance
{
    if (endTolerance < 0.) {
        SRGMediaPlayerLogWarning(@"Controller", @"End tolerance cannot be negative. Set to 0");
        _endTolerance = 0.;
    }
    else {
        _endTolerance = endTolerance;
    }
}

- (void)setEndToleranceRatio:(float)endToleranceRatio
{
    if (endToleranceRatio < 0.) {
        SRGMediaPlayerLogWarning(@"Controller", @"End tolerance ratio cannot be negative. Set to 0");
        _endToleranceRatio = 0.f;
    }
    else if (endToleranceRatio > 1.) {
        SRGMediaPlayerLogWarning(@"Controller", @"End tolerance ratio cannot be larger than 1. Set to 1");
        _endToleranceRatio = 1.f;
    }
    else {
        _endToleranceRatio = endToleranceRatio;
    }
}

- (NSDate *)date
{
    CMTimeRange timeRange = self.timeRange;
    if (CMTIMERANGE_IS_INVALID(timeRange)) {
        return nil;
    }
    
    if (self.streamType == SRGMediaPlayerStreamTypeLive) {
        return NSDate.date;
    }
    else if (self.streamType == SRGMediaPlayerStreamTypeDVR) {
        return [NSDate dateWithTimeIntervalSinceNow:-CMTimeGetSeconds(CMTimeSubtract(CMTimeRangeGetEnd(timeRange), self.player.currentTime))];
    }
    else {
        return nil;
    }
}

- (BOOL)isLive
{
    AVPlayerItem *playerItem = self.player.currentItem;
    if (! playerItem) {
        return NO;
    }
    
    if (self.streamType == SRGMediaPlayerStreamTypeLive) {
        return YES;
    }
    else if (self.streamType == SRGMediaPlayerStreamTypeDVR) {
        return CMTimeGetSeconds(CMTimeSubtract(CMTimeRangeGetEnd(self.timeRange), playerItem.currentTime)) < self.liveTolerance;
    }
    else {
        return NO;
    }
}

- (void)setPictureInPictureController:(AVPictureInPictureController *)pictureInPictureController
{
    if (_pictureInPictureController) {
        [_pictureInPictureController removeObserver:self keyPath:@keypath(_pictureInPictureController.pictureInPicturePossible)];
        [_pictureInPictureController removeObserver:self keyPath:@keypath(_pictureInPictureController.pictureInPictureActive)];
    }
    
    _pictureInPictureController = pictureInPictureController;
    [NSNotificationCenter.defaultCenter postNotificationName:SRGMediaPlayerPictureInPictureStateDidChangeNotification object:self];
    
    if (pictureInPictureController) {
        @weakify(self)
        void (^observationBlock)(MAKVONotification *) = ^(MAKVONotification *notification) {
            @strongify(self)
            [NSNotificationCenter.defaultCenter postNotificationName:SRGMediaPlayerPictureInPictureStateDidChangeNotification object:self];
        };
        
        [pictureInPictureController srg_addMainThreadObserver:self keyPath:@keypath(pictureInPictureController.pictureInPicturePossible) options:0 block:observationBlock];
        [pictureInPictureController srg_addMainThreadObserver:self keyPath:@keypath(pictureInPictureController.pictureInPictureActive) options:0 block:observationBlock];
    }
}

- (BOOL)allowsExternalNonMirroredPlayback
{
    AVPlayer *player = self.player;
    if (! player) {
        return NO;
    }
    
    if (! player.allowsExternalPlayback) {
        return NO;
    }
    
    if (! UIScreen.srg_isMirroring) {
        return YES;
    }
    
    // If the player switches to external playback, then it does not mirror the display
    return player.usesExternalPlaybackWhileExternalScreenIsActive;
}

- (BOOL)isExternalNonMirroredPlaybackActive
{
    if (! AVAudioSession.srg_isAirPlayActive) {
        return NO;
    }
    
    AVPlayer *player = self.player;
    if (! player) {
        return NO;
    }
    
    // We do not test the `externalPlaybackActive` property here, on purpose: The fact that AirPlay is active was
    // tested just above, and the `externalPlaybackActive` property is less reliable in some cases where AirPlay
    // settings are changed, but AirPlay is still active
    if (! player.allowsExternalPlayback) {
        return NO;
    }
    
    if (! UIScreen.srg_isMirroring) {
        return player.externalPlaybackActive;
    }
    
    // If the player switches to external playback, then it does not mirror the display
    return player.usesExternalPlaybackWhileExternalScreenIsActive;
}

#pragma mark Playback

- (void)prepareToPlayURL:(NSURL *)URL
              atPosition:(SRGPosition *)position
            withSegments:(NSArray<id<SRGSegment>> *)segments
                userInfo:(NSDictionary *)userInfo
       completionHandler:(void (^)(void))completionHandler
{
    [self prepareToPlayURLAsset:nil URL:URL atPosition:position withSegments:segments targetSegment:nil userInfo:userInfo completionHandler:completionHandler];
}

- (void)prepareToPlayURLAsset:(AVURLAsset *)URLAsset
                   atPosition:(SRGPosition *)position
                 withSegments:(NSArray<id<SRGSegment>> *)segments
                     userInfo:(NSDictionary *)userInfo
            completionHandler:(void (^)(void))completionHandler
{
    [self prepareToPlayURLAsset:URLAsset URL:nil atPosition:position withSegments:segments targetSegment:nil userInfo:userInfo completionHandler:completionHandler];
}

- (void)play
{
    // Player is available
    if (self.player) {
        // Normal conditions. Simply forward to the player
        if (self.playbackState != SRGMediaPlayerPlaybackStateEnded) {
            [self.player srg_playImmediatelyIfPossible];
        }
        // Playback ended. Restart at the beginning. Use low-level API to avoid sending seek events
        else {
            [self.player seekToTime:kCMTimeZero toleranceBefore:kCMTimePositiveInfinity toleranceAfter:kCMTimePositiveInfinity completionHandler:^(BOOL finished) {
                if (finished) {
                    [self.player srg_playImmediatelyIfPossible];
                }
            }];
        }
    }
    // Player has been removed (e.g. after a -stop). Restart playback with the same conditions (if not cleared)
    else if (self.contentURL) {
        [self prepareToPlayURLAsset:nil URL:self.contentURL atPosition:self.initialPosition withSegments:self.segments targetSegment:self.initialTargetSegment userInfo:self.userInfo completionHandler:^{
            [self play];
        }];
    }
    else if (self.URLAsset) {
        [self prepareToPlayURLAsset:[self.URLAsset copy] URL:nil atPosition:self.initialPosition withSegments:self.segments targetSegment:self.initialTargetSegment userInfo:self.userInfo completionHandler:^{
            [self play];
        }];
    }
}

- (void)pause
{
    // Won't do anything if called after playback has ended
    [self.player pause];
}

- (void)stop
{
    [self stopWithUserInfo:nil];
}

- (void)seekToPosition:(SRGPosition *)position withCompletionHandler:(void (^)(BOOL))completionHandler
{
    [self seekToPosition:position withTargetSegment:nil completionHandler:completionHandler];
}

- (void)reset
{
    // Save previous state information
    NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
    if (self.contentURL) {
        userInfo[SRGMediaPlayerPreviousContentURLKey] = self.contentURL;
    }
    if (self.URLAsset) {
        userInfo[SRGMediaPlayerPreviousURLAssetKey] = self.URLAsset;
    }
    if (self.userInfo) {
        userInfo[SRGMediaPlayerPreviousUserInfoKey] = self.userInfo;
    }
    
    // Reset input values (so that any state change notification reflects this new state)
    self.contentURL = nil;
    self.URLAsset = nil;
    self.segments = nil;
    self.userInfo = nil;
    
    self.initialTargetSegment = nil;
    self.initialPosition = nil;
    
    [self stopWithUserInfo:[userInfo copy]];
}

#pragma mark Playback (convenience methods)

- (void)prepareToPlayURL:(NSURL *)URL withCompletionHandler:(void (^)(void))completionHandler
{
    [self prepareToPlayURL:URL atPosition:nil withSegments:nil userInfo:nil completionHandler:completionHandler];
}

- (void)prepareToPlayURLAsset:(AVURLAsset *)URLAsset withCompletionHandler:(void (^)(void))completionHandler
{
    [self prepareToPlayURLAsset:URLAsset atPosition:nil withSegments:nil userInfo:nil completionHandler:completionHandler];
}

- (void)playURL:(NSURL *)URL atPosition:(SRGPosition *)position withSegments:(NSArray<id<SRGSegment>> *)segments userInfo:(NSDictionary *)userInfo
{
    [self prepareToPlayURL:URL atPosition:position withSegments:segments userInfo:userInfo completionHandler:^{
        [self play];
    }];
}

- (void)playURLAsset:(AVURLAsset *)URLAsset atPosition:(SRGPosition *)position withSegments:(NSArray<id<SRGSegment>> *)segments userInfo:(NSDictionary *)userInfo
{
    [self prepareToPlayURLAsset:URLAsset atPosition:position withSegments:segments userInfo:userInfo completionHandler:^{
        [self play];
    }];
}

- (void)playURL:(NSURL *)URL
{
    [self playURL:URL atPosition:nil withSegments:nil userInfo:nil];
}

- (void)playURLAsset:(AVURLAsset *)URLAsset
{
    [self playURLAsset:URLAsset atPosition:nil withSegments:nil userInfo:nil];
}

- (void)togglePlayPause
{
    if (self.player && self.player.rate == 1.f) {
        [self pause];
    }
    else {
        [self play];
    }
}

#pragma mark Segment playback

- (void)prepareToPlayURL:(NSURL *)URL
                 atIndex:(NSInteger)index
                position:(SRGPosition *)position
              inSegments:(NSArray<id<SRGSegment>> *)segments
            withUserInfo:(NSDictionary *)userInfo
       completionHandler:(void (^)(void))completionHandler
{
    id<SRGSegment> targetSegment = (index >= 0 && index < segments.count) ? segments[index] : nil;
    [self prepareToPlayURLAsset:nil URL:URL atPosition:position withSegments:segments targetSegment:targetSegment userInfo:userInfo completionHandler:completionHandler];
}

- (void)prepareToPlayURLAsset:(AVURLAsset *)URLAsset
                      atIndex:(NSInteger)index
                     position:(SRGPosition *)position
                   inSegments:(NSArray<id<SRGSegment>> *)segments
                 withUserInfo:(NSDictionary *)userInfo
            completionHandler:(void (^)(void))completionHandler
{
    id<SRGSegment> targetSegment = (index >= 0 && index < segments.count) ? segments[index] : nil;
    [self prepareToPlayURLAsset:URLAsset URL:nil atPosition:position withSegments:segments targetSegment:targetSegment userInfo:userInfo completionHandler:completionHandler];
}

- (void)playURL:(NSURL *)URL
        atIndex:(NSInteger)index
       position:(SRGPosition *)position
     inSegments:(NSArray<id<SRGSegment>> *)segments
   withUserInfo:(NSDictionary *)userInfo
{
    [self prepareToPlayURL:URL atIndex:index position:position inSegments:segments withUserInfo:userInfo completionHandler:^{
        [self play];
    }];
}

- (void)playURLAsset:(AVURLAsset *)URLAsset
             atIndex:(NSInteger)index
            position:(SRGPosition *)position
          inSegments:(NSArray<id<SRGSegment>> *)segments
        withUserInfo:(NSDictionary *)userInfo
{
    [self prepareToPlayURLAsset:URLAsset atIndex:index position:position inSegments:segments withUserInfo:userInfo completionHandler:^{
        [self play];
    }];
}

- (void)seekToPosition:(SRGPosition *)position inSegmentAtIndex:(NSInteger)index withCompletionHandler:(void (^)(BOOL))completionHandler
{
    if (index < 0 || index >= self.segments.count) {
        return;
    }
    
    [self seekToPosition:position inSegment:self.segments[index] withCompletionHandler:completionHandler];
}

- (void)seekToPosition:(SRGPosition *)position inSegment:(id<SRGSegment>)segment withCompletionHandler:(void (^)(BOOL))completionHandler
{
    if (! [self.segments containsObject:segment]) {
        return;
    }
    
    [self seekToPosition:position withTargetSegment:segment completionHandler:completionHandler];
}

- (id<SRGSegment>)selectedSegment
{
    return _selected ? self.currentSegment : nil;
}

#pragma mark Playback (internal). Time parameters are ignored when valid segments are provided

- (void)prepareToPlayURLAsset:(AVURLAsset *)URLAsset
                          URL:(NSURL *)URL
                   atPosition:(SRGPosition *)position
                 withSegments:(NSArray<id<SRGSegment>> *)segments
                targetSegment:(id<SRGSegment>)targetSegment
                     userInfo:(NSDictionary *)userInfo
            completionHandler:(void (^)(void))completionHandler
{
    NSAssert(URLAsset || URL, @"A URL asset or URL must be provided");
    NSAssert(! targetSegment || [segments containsObject:targetSegment], @"Segment must be valid");
    
    if (! position) {
        position = SRGPosition.defaultPosition;
    }
    
    if (URLAsset) {
        URL = URLAsset.URL;
    }
    else {
        URLAsset = [AVURLAsset assetWithURL:URL];
    }
    
    @weakify(self)
    [URLAsset loadValuesAsynchronouslyForKeys:@[ @keypath(URLAsset.availableMediaCharacteristicsWithMediaSelectionOptions) ] completionHandler:^{
        @strongify(self)
        
        if ([URLAsset statusOfValueForKey:@keypath(URLAsset.availableMediaCharacteristicsWithMediaSelectionOptions) error:NULL] == AVKeyValueStatusLoaded) {
            self.availableAudioTrackLocalizations = [self availableTrackLocalizationsForAsset:URLAsset withMediaCharacteristic:AVMediaCharacteristicAudible];
            self.availableSubtitleLocalizations = [self availableTrackLocalizationsForAsset:URLAsset withMediaCharacteristic:AVMediaCharacteristicLegible];
            
            if (self.preferredSubtitleLocalization) {
                [self applySubtitleLocalization:self.preferredSubtitleLocalization];
            }
            
            [self updateTracks];
        }
    }];
    
    SRGMediaPlayerLogDebug(@"Controller", @"Playing %@", URL);
    
    [self reset];
    
    _timeRange = kCMTimeRangeInvalid;
    
    self.contentURL = URL;
    self.URLAsset = URLAsset;
    
    self.segments = segments;
    self.userInfo = userInfo;
    self.targetSegment = targetSegment;
    
    // Save initial values for restart after a stop
    self.initialTargetSegment = targetSegment;
    self.initialPosition = position;
    
    // Values used at startup and nilled afterwards
    self.startPosition = position;
    self.startCompletionHandler = completionHandler;
    
    // Hide the view until playback starts to avoid briefly displaying the frame which the player was loaded into first
    // (default playback position). Hide the internal view since visibility of the media player view can be controlled
    // by clients.
    self.view.playbackViewHidden = YES;
    
    AVPlayerItem *playerItem = [AVPlayerItem playerItemWithAsset:URLAsset];
    self.player = [AVPlayer playerWithPlayerItem:playerItem];
    
    // Notify the state change last. If clients repond to the preparing state change notification, the state need to
    // be fully consistent first.
    [self setPlaybackState:SRGMediaPlayerPlaybackStatePreparing withUserInfo:nil];
}

- (void)seekToPosition:(SRGPosition *)position withTargetSegment:(id<SRGSegment>)targetSegment completionHandler:(void (^)(BOOL))completionHandler
{
    NSAssert(! targetSegment || [self.segments containsObject:targetSegment], @"Segment must be valid");
    
    if (! position) {
        position = SRGPosition.defaultPosition;
    }
    
    if (self.player.currentItem.status != AVPlayerItemStatusReadyToPlay) {
        return;
    }
    
    self.targetSegment = targetSegment;
    
    // If a segment is targeted, interpret the position as relative, and add a small offset so that playback is guaranteed
    // to start within the segment.
    if (targetSegment) {
        position = SRGMediaPlayerControllerOffset(position, CMTimeAdd(targetSegment.srg_timeRange.start, CMTimeMakeWithSeconds(SRGSegmentSeekOffsetInSeconds, NSEC_PER_SEC)));
    }
    
    CMTimeRange timeRange = targetSegment ? targetSegment.srg_timeRange : self.timeRange;
    SRGPosition *seekPosition = SRGMediaPlayerControllerPositionInTimeRange(position, timeRange);
    
    // Trap attempts to seek to blocked segments early. We cannot only rely on playback time observers to detect a blocked segment
    // for direct seeks, otherwise blocked segment detection would occur after the segment has been entered, which is too late
    id<SRGSegment> segment = targetSegment ?: [self segmentForTime:seekPosition.time];
    if (! segment || ! segment.srg_blocked) {
        [self setPlaybackState:SRGMediaPlayerPlaybackStateSeeking withUserInfo:nil];
        
        [NSNotificationCenter.defaultCenter postNotificationName:SRGMediaPlayerSeekNotification
                                                          object:self
                                                        userInfo:@{ SRGMediaPlayerSeekTimeKey : [NSValue valueWithCMTime:seekPosition.time],
                                                                    SRGMediaPlayerLastPlaybackTimeKey : [NSValue valueWithCMTime:self.player.currentTime] }];
        
        // Only store the origin in case of multiple seeks, but update the target
        if (CMTIME_IS_INDEFINITE(self.seekStartTime)) {
            self.seekStartTime = self.player.currentTime;
        }
        self.seekTargetTime = seekPosition.time;
        
        // Starting with iOS 11, there is no guarantee that the last seek succeeds (there was no formal documentation for this
        // behavior on iOS 10 and below, but this was generally working). Starting with iOS 11, the following is unreliable,
        // as the state might not be updated if the last seek gets cancelled. This is especially the case if multiple seeks
        // are made in sequence (with some small delay between them), the last seek occuring at the end of the stream.
        //
        // To be able to reset the state no matter the last seek finished, we use a special category method which keeps count
        // of the count of seek requests still pending.
        [self.player srg_countedSeekToTime:seekPosition.time toleranceBefore:seekPosition.toleranceBefore toleranceAfter:seekPosition.toleranceAfter completionHandler:^(BOOL finished, NSInteger pendingSeekCount) {
            if (pendingSeekCount == 0) {
                [self setPlaybackState:(self.player.rate == 0.f) ? SRGMediaPlayerPlaybackStatePaused : SRGMediaPlayerPlaybackStatePlaying withUserInfo:nil];
                
                self.seekStartTime = kCMTimeIndefinite;
                self.seekTargetTime = kCMTimeIndefinite;
            }
            completionHandler ? completionHandler(finished) : nil;
        }];
    }
    else {
        [self skipBlockedSegment:segment withCompletionHandler:completionHandler];
    }
}

- (void)stopWithUserInfo:(NSDictionary *)userInfo
{
    if (self.pictureInPictureController.isPictureInPictureActive) {
        [self.pictureInPictureController stopPictureInPicture];
    }
    
    NSMutableDictionary *fullUserInfo = [userInfo mutableCopy] ?: [NSMutableDictionary dictionary];
    
    // Only reset if needed (this would otherwise lazily instantiate the view again and create potential issues)
    if (self.player) {
        [self.player.currentItem.asset cancelLoading];
        
        fullUserInfo[SRGMediaPlayerLastPlaybackTimeKey] = [NSValue valueWithCMTime:self.player.currentTime];
        fullUserInfo[SRGMediaPlayerPreviousTimeRangeKey] = [NSValue valueWithCMTimeRange:self.timeRange];
        fullUserInfo[SRGMediaPlayerPreviousMediaTypeKey] = @(self.mediaType);
        fullUserInfo[SRGMediaPlayerPreviousStreamTypeKey] = @(self.streamType);
        if (_selected) {
            fullUserInfo[SRGMediaPlayerPreviousSelectedSegmentKey] = self.currentSegment;
        }
        self.player = nil;
    }
    
    _timeRange = kCMTimeRangeInvalid;
    _selected = NO;
    
    self.previousSegment = nil;
    self.targetSegment = nil;
    self.currentSegment = nil;
    
    self.startPosition = nil;
    self.startCompletionHandler = nil;
    
    self.presentationSizeValue = nil;
    
    self.seekStartTime = kCMTimeIndefinite;
    self.seekTargetTime = kCMTimeIndefinite;
    
    self.lastPlaybackTime = kCMTimeIndefinite;
    self.lastStallDetectionDate = nil;
    
    self.availableAudioTrackLocalizations = nil;
    self.availableSubtitleLocalizations = nil;
    
    self.audioTrackOption = nil;
    self.subtitleOption = nil;
    
    self.audioTrackLocalization = nil;
    self.subtitleLocalization = nil;
    
    self.pictureInPictureController = nil;
    
    // Emit the notification once all state has been reset
    [self setPlaybackState:SRGMediaPlayerPlaybackStateIdle withUserInfo:[fullUserInfo copy]];
}

#pragma mark Configuration

- (void)reloadPlayerConfiguration
{
    if (self.player) {
        self.playerConfigurationBlock ? self.playerConfigurationBlock(self.player) : nil;
    }
}

#pragma mark Segments

- (void)updateSegmentStatusForPlaybackState:(SRGMediaPlayerPlaybackState)playbackState
                      previousPlaybackState:(SRGMediaPlayerPlaybackState)previousPlaybackState
                                       time:(CMTime)time
{
    if (CMTIME_IS_INVALID(time)) {
        return;
    }
    
    // Only update when relevant
    if (playbackState != SRGMediaPlayerPlaybackStatePaused && playbackState != SRGMediaPlayerPlaybackStatePlaying) {
        return;
    }
    
    if (self.targetSegment) {
        [self processTransitionToSegment:self.targetSegment selected:YES interrupted:YES];
        self.targetSegment = nil;
    }
    else {
        id<SRGSegment> segment = [self segmentForTime:time];
        BOOL interrupted = (previousPlaybackState == SRGMediaPlayerPlaybackStateSeeking);
        [self processTransitionToSegment:segment selected:NO interrupted:interrupted];
    }
}

// Emit correct notifications for transitions (selected = NO for normal playback, YES if the segment has been selected)
// and seek over blocked segments. interrupted is set to NO if playback
- (void)processTransitionToSegment:(id<SRGSegment>)segment selected:(BOOL)selected interrupted:(BOOL)interrupted
{
    // No segment transition. Nothing to do
    if (segment == self.previousSegment && ! selected) {
        return;
    }
    
    CMTime lastPlaybackTime = CMTIME_IS_INDEFINITE(self.seekStartTime) ? self.player.currentTime : self.seekStartTime;
    
    if (self.previousSegment && ! self.previousSegment.srg_blocked) {
        self.currentSegment = nil;
        
        NSMutableDictionary *userInfo = [@{ SRGMediaPlayerSegmentKey : self.previousSegment,
                                            SRGMediaPlayerSelectionKey : @(selected),
                                            SRGMediaPlayerSelectedKey : @(_selected),
                                            SRGMediaPlayerInterruptionKey : @(interrupted),
                                            SRGMediaPlayerLastPlaybackTimeKey : [NSValue valueWithCMTime:lastPlaybackTime] } mutableCopy];
        if (! segment.srg_blocked) {
            userInfo[SRGMediaPlayerNextSegmentKey] = segment;
        }
        [NSNotificationCenter.defaultCenter postNotificationName:SRGMediaPlayerSegmentDidEndNotification
                                                          object:self
                                                        userInfo:[userInfo copy]];
        _selected = NO;
        
        SRGMediaPlayerLogDebug(@"Controller", @"Segment did end with info %@", userInfo);
    }
    
    if (segment) {
        if (! segment.srg_blocked) {
            _selected = selected;
            
            self.currentSegment = segment;
            
            NSMutableDictionary *userInfo = [@{ SRGMediaPlayerSegmentKey : segment,
                                                SRGMediaPlayerSelectionKey : @(_selected),
                                                SRGMediaPlayerSelectedKey : @(_selected),
                                                SRGMediaPlayerLastPlaybackTimeKey : [NSValue valueWithCMTime:lastPlaybackTime] } mutableCopy];
            if (self.previousSegment && ! self.previousSegment.srg_blocked) {
                userInfo[SRGMediaPlayerPreviousSegmentKey] = self.previousSegment;
            }
            [NSNotificationCenter.defaultCenter postNotificationName:SRGMediaPlayerSegmentDidStartNotification
                                                              object:self
                                                            userInfo:[userInfo copy]];
            
            SRGMediaPlayerLogDebug(@"Controller", @"Segment did start with info %@", userInfo);
        }
        else {
            [self skipBlockedSegment:segment withCompletionHandler:nil];
        }
    }
    
    self.previousSegment = segment;
}

- (id<SRGSegment>)segmentForTime:(CMTime)time
{
    if (CMTIME_IS_INVALID(time)) {
        return nil;
    }
    
    __block id<SRGSegment> locatedSegment = nil;
    [self.segments enumerateObjectsUsingBlock:^(id<SRGSegment>  _Nonnull segment, NSUInteger idx, BOOL * _Nonnull stop) {
        if (CMTimeRangeContainsTime(segment.srg_timeRange, time)) {
            locatedSegment = segment;
            *stop = YES;
        }
    }];
    return locatedSegment;
}

// No tolerance parameters here. When skipping blocked segments, we want to resume sharply at segment end
- (void)skipBlockedSegment:(id<SRGSegment>)segment withCompletionHandler:(void (^)(BOOL finished))completionHandler
{
    NSAssert(segment.srg_blocked, @"Expect a blocked segment");
    
    NSValue *lastPlaybackTimeValue = [NSValue valueWithCMTime:self.player.currentTime];
    [NSNotificationCenter.defaultCenter postNotificationName:SRGMediaPlayerWillSkipBlockedSegmentNotification
                                                      object:self
                                                    userInfo:@{ SRGMediaPlayerSegmentKey : segment,
                                                                SRGMediaPlayerLastPlaybackTimeKey : lastPlaybackTimeValue }];
    
    SRGMediaPlayerLogDebug(@"Controller", @"Segment %@ will be skipped", segment);
    
    // Seek precisely just after the end of the segment to avoid reentering the blocked segment when playback resumes (which
    // would trigger skips recursively)
    SRGPosition *segmentEndPosition = [SRGPosition positionAtTime:CMTimeRangeGetEnd(segment.srg_timeRange)];
    [self seekToPosition:SRGMediaPlayerControllerOffset(segmentEndPosition, CMTimeMakeWithSeconds(SRGSegmentSeekOffsetInSeconds, NSEC_PER_SEC)) withCompletionHandler:^(BOOL finished) {
        // Do not check the finished boolean. We want to emit the notification even if the seek is interrupted by another
        // one (e.g. due to a contiguous blocked segment being skipped). Emit the notification after the completion handler
        // so that consecutive notifications are received in the correct order
        [NSNotificationCenter.defaultCenter postNotificationName:SRGMediaPlayerDidSkipBlockedSegmentNotification
                                                          object:self
                                                        userInfo:@{ SRGMediaPlayerSegmentKey : segment,
                                                                    SRGMediaPlayerLastPlaybackTimeKey : lastPlaybackTimeValue}];
        
        SRGMediaPlayerLogDebug(@"Controller", @"Segment %@ was skipped", segment);
        
        completionHandler ? completionHandler(finished) : nil;
    }];
}

#pragma mark Current player track information

- (AVMediaSelectionOption *)selectedTrackOptionForMediaCharacteristic:(AVMediaCharacteristic)characteristic
{
    AVPlayerItem *playerItem = self.player.currentItem;
    AVAsset *asset = playerItem.asset;
    
    if ([asset statusOfValueForKey:@keypath(asset.availableMediaCharacteristicsWithMediaSelectionOptions) error:NULL] != AVKeyValueStatusLoaded) {
        return nil;
    }
    
    AVMediaSelectionGroup *group = [asset mediaSelectionGroupForMediaCharacteristic:characteristic];
    return [playerItem selectedMediaOptionInMediaSelectionGroup:group];
}

- (void)updateTracks
{
    AVMediaSelectionOption *audioTrackOption = [self selectedTrackOptionForMediaCharacteristic:AVMediaCharacteristicAudible];
    if ((audioTrackOption || self.audioTrackOption) && ! [audioTrackOption isEqual:self.audioTrackOption]) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
        if (self.audioTrackOption) {
            userInfo[SRGMediaPlayerPreviousTrackKey] = self.audioTrackOption;
        }
        if (audioTrackOption) {
            userInfo[SRGMediaPlayerTrackKey] = audioTrackOption;
        }
        
        self.audioTrackOption = audioTrackOption;
        self.audioTrackLocalization = [audioTrackOption.locale objectForKey:NSLocaleLanguageCode];
        
        [NSNotificationCenter.defaultCenter postNotificationName:SRGMediaPlayerAudioTrackDidChangeNotification
                                                          object:self
                                                        userInfo:[userInfo copy]];
    }
    
    AVMediaSelectionOption *subtitleOption = [self selectedTrackOptionForMediaCharacteristic:AVMediaCharacteristicLegible];
    if ((subtitleOption || self.subtitleOption) && ! [subtitleOption isEqual:self.subtitleOption]) {
        NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
        if (self.subtitleOption) {
            userInfo[SRGMediaPlayerPreviousTrackKey] = self.subtitleOption;
        }
        if (subtitleOption) {
            userInfo[SRGMediaPlayerTrackKey] = subtitleOption;
        }
        
        self.subtitleOption = subtitleOption;
        self.subtitleLocalization = [subtitleOption.locale objectForKey:NSLocaleLanguageCode];
        
        [NSNotificationCenter.defaultCenter postNotificationName:SRGMediaPlayerSubtitleTrackDidChangeNotification
                                                          object:self
                                                        userInfo:[userInfo copy]];
    }
}

#pragma mark Asset track information extraction

- (NSArray<NSString *> *)availableTrackLocalizationsForAsset:(AVAsset *)asset withMediaCharacteristic:(AVMediaCharacteristic)characteristic
{
    if ([asset statusOfValueForKey:@keypath(asset.availableMediaCharacteristicsWithMediaSelectionOptions) error:NULL] != AVKeyValueStatusLoaded) {
        return @[];
    }
    
    NSMutableSet<NSString *> *localizations = [NSMutableSet set];
    
    AVMediaSelectionGroup *group = [asset mediaSelectionGroupForMediaCharacteristic:characteristic];
    NSArray<AVMediaSelectionOption *> *options = [AVMediaSelectionGroup mediaSelectionOptionsFromArray:group.options withoutMediaCharacteristics:@[AVMediaCharacteristicContainsOnlyForcedSubtitles]];
    for (AVMediaSelectionOption *option in options) {
        NSString *languageCode = [option.locale objectForKey:NSLocaleLanguageCode];
        [localizations addObject:languageCode];
    }
    
    return [localizations.allObjects sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
}

#pragma mark Audio tracks

- (void)setPreferredAudioTrackLocalization:(NSString *)preferredAudioTrackLocalization
{
    _preferredAudioTrackLocalization = preferredAudioTrackLocalization;
    
    [self applyAudioTrackLocalization:preferredAudioTrackLocalization];
}

- (void)applyAudioTrackLocalization:(NSString *)audioTrackLocalization
{
    AVPlayerItem *playerItem = self.player.currentItem;
    AVAsset *asset = playerItem.asset;
    
    if ([asset statusOfValueForKey:@keypath(asset.availableMediaCharacteristicsWithMediaSelectionOptions) error:NULL] != AVKeyValueStatusLoaded) {
        return;
    }
    
    AVMediaSelectionGroup *audioGroup = [asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicAudible];
    
    if (! audioTrackLocalization || [audioTrackLocalization isEqualToString:SRGMediaPlayerLocalizationAutomatic]) {
        [playerItem selectMediaOptionAutomaticallyInMediaSelectionGroup:audioGroup];
    }
    else if ([audioTrackLocalization isEqualToString:SRGMediaPlayerLocalizationDisabled]) {
        [playerItem selectMediaOption:nil inMediaSelectionGroup:audioGroup];
    }
    else {
        NSArray<AVMediaSelectionOption *> *audioOptions = [AVMediaSelectionGroup playableMediaSelectionOptionsFromArray:audioGroup.options];
        NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(AVMediaSelectionOption * _Nullable option, NSDictionary<NSString *,id> * _Nullable bindings) {
            return [audioTrackLocalization isEqualToString:[option.locale objectForKey:NSLocaleLanguageCode]];
        }];
        AVMediaSelectionOption *audioOption = [audioOptions filteredArrayUsingPredicate:predicate].firstObject;
        if (audioOption) {
            [playerItem selectMediaOption:audioOption inMediaSelectionGroup:audioGroup];
        }
        else {
            [playerItem selectMediaOptionAutomaticallyInMediaSelectionGroup:audioGroup];
        }
    }
}

#pragma mark Subtitles

- (void)setPreferredSubtitleLocalization:(NSString *)preferredSubtitleLocalization
{
    _preferredSubtitleLocalization = preferredSubtitleLocalization;
    
    [self applySubtitleLocalization:preferredSubtitleLocalization];
}

- (void)applySubtitleLocalization:(NSString *)subtitleLocalization
{
    AVPlayerItem *playerItem = self.player.currentItem;
    AVAsset *asset = playerItem.asset;
    
    if ([asset statusOfValueForKey:@keypath(asset.availableMediaCharacteristicsWithMediaSelectionOptions) error:NULL] != AVKeyValueStatusLoaded) {
        return;
    }
    
    AVMediaSelectionGroup *subtitleGroup = [asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible];
    
    void (^applySubtitleLocalization)(NSString *) = ^(NSString *subtitleLocalization) {
        if (subtitleLocalization) {
            NSArray<AVMediaSelectionOption *> *subtitleOptions = [AVMediaSelectionGroup mediaSelectionOptionsFromArray:subtitleGroup.options withoutMediaCharacteristics:@[AVMediaCharacteristicContainsOnlyForcedSubtitles]];
            NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(AVMediaSelectionOption * _Nullable option, NSDictionary<NSString *,id> * _Nullable bindings) {
                return [subtitleLocalization isEqualToString:[option.locale objectForKey:NSLocaleLanguageCode]];
            }];
            AVMediaSelectionOption *subtitleOption = [subtitleOptions filteredArrayUsingPredicate:predicate].firstObject;
            if (subtitleOption) {
                [playerItem selectMediaOption:subtitleOption inMediaSelectionGroup:subtitleGroup];
                return;
            }
        }
        
        // Use automatic behavior instead
        [playerItem selectMediaOptionAutomaticallyInMediaSelectionGroup:subtitleGroup];
    };
    
    // Revert to default behavior as obtained from MediaAccessibility settings
    if (! subtitleLocalization) {
        MACaptionAppearanceDisplayType displayType = MACaptionAppearanceGetDisplayType(kMACaptionAppearanceDomainUser);
        if (displayType == kMACaptionAppearanceDisplayTypeForcedOnly) {
            [playerItem selectMediaOption:nil inMediaSelectionGroup:subtitleGroup];
        }
        else if (displayType == kMACaptionAppearanceDisplayTypeAlwaysOn) {
            NSArray<NSString *> *selectedLanguages = (__bridge NSArray<NSString *> *)(MACaptionAppearanceCopySelectedLanguages(kMACaptionAppearanceDomainUser));
            applySubtitleLocalization(selectedLanguages.firstObject);
        }
        else {
            [playerItem selectMediaOptionAutomaticallyInMediaSelectionGroup:subtitleGroup];
        };
    }
    else if ([subtitleLocalization isEqualToString:SRGMediaPlayerLocalizationDisabled]) {
        [playerItem selectMediaOption:nil inMediaSelectionGroup:subtitleGroup];
    }
    else if ([subtitleLocalization isEqualToString:SRGMediaPlayerLocalizationAutomatic]) {
        [playerItem selectMediaOptionAutomaticallyInMediaSelectionGroup:subtitleGroup];
    }
    else {
        applySubtitleLocalization(subtitleLocalization);
    }
}

#pragma mark Time observers

- (void)registerTimeObserversForPlayer:(AVPlayer *)player
{
    for (SRGPeriodicTimeObserver *playbackBlockRegistration in [self.periodicTimeObservers allValues]) {
        [playbackBlockRegistration attachToMediaPlayer:player];
    }
    
    @weakify(self)
    self.playerPeriodicTimeObserver = [player addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.1, NSEC_PER_SEC) queue:NULL usingBlock:^(CMTime time) {
        @strongify(self)
        if (self.playerLayer.readyForDisplay) {
            if (self.pictureInPictureController.playerLayer != self.playerLayer) {
                self.pictureInPictureController = [[AVPictureInPictureController alloc] initWithPlayerLayer:self.playerLayer];
                self.pictureInPictureControllerCreationBlock ? self.pictureInPictureControllerCreationBlock(self.pictureInPictureController) : nil;
            }
        }
        else {
            self.pictureInPictureController = nil;
        }
        
        [self updateSegmentStatusForPlaybackState:self.playbackState previousPlaybackState:self.playbackState time:time];
    }];
    
    self.controllerPeriodicTimeObserver = [self addPeriodicTimeObserverForInterval:CMTimeMakeWithSeconds(0.1, NSEC_PER_SEC) queue:NULL usingBlock:^(CMTime time) {
        @strongify(self)
        [self updateTracks];
    }];
}

- (void)unregisterTimeObserversForPlayer:(AVPlayer *)player
{
    [player removeTimeObserver:self.playerPeriodicTimeObserver];
    self.playerPeriodicTimeObserver = nil;
    
    [self removePeriodicTimeObserver:self.controllerPeriodicTimeObserver];
    
    for (SRGPeriodicTimeObserver *periodicTimeObserver in [self.periodicTimeObservers allValues]) {
        [periodicTimeObserver detachFromMediaPlayer];
    }
}

- (id)addPeriodicTimeObserverForInterval:(CMTime)interval queue:(dispatch_queue_t)queue usingBlock:(void (^)(CMTime time))block
{
    if (! block) {
        return nil;
    }
    
    NSString *identifier = NSUUID.UUID.UUIDString;
    SRGPeriodicTimeObserver *periodicTimeObserver = [self periodicTimeObserverForInterval:interval queue:queue];
    [periodicTimeObserver setBlock:block forIdentifier:identifier];
    
    if (self.player) {
        [periodicTimeObserver attachToMediaPlayer:self.player];
    }
    
    // Return the opaque identifier
    return identifier;
}

- (void)removePeriodicTimeObserver:(id)observer
{
    if (! observer) {
        return;
    }
    
    for (NSString *key in self.periodicTimeObservers.allKeys) {
        SRGPeriodicTimeObserver *periodicTimeObserver = self.periodicTimeObservers[key];
        if (! [periodicTimeObserver hasBlockWithIdentifier:observer]) {
            continue;
        }
        
        [periodicTimeObserver removeBlockWithIdentifier:observer];
        
        // Remove the periodic time observer if not used anymore
        if (periodicTimeObserver.registrationCount == 0) {
            [self.periodicTimeObservers removeObjectForKey:key];
            return;
        }
    }
}

- (SRGPeriodicTimeObserver *)periodicTimeObserverForInterval:(CMTime)interval queue:(dispatch_queue_t)queue
{
    NSString *key = [NSString stringWithFormat:@"%@-%@-%@-%@-%p", @(interval.value), @(interval.timescale), @(interval.flags), @(interval.epoch), queue];
    SRGPeriodicTimeObserver *periodicTimeObserver = self.periodicTimeObservers[key];
    
    if (! periodicTimeObserver) {
        periodicTimeObserver = [[SRGPeriodicTimeObserver alloc] initWithInterval:interval queue:queue];
        self.periodicTimeObservers[key] = periodicTimeObserver;
    }
    
    return periodicTimeObserver;
}

#pragma mark Notifications

- (void)srg_mediaPlayerController_playerItemDidPlayToEndTime:(NSNotification *)notification
{
    [self setPlaybackState:SRGMediaPlayerPlaybackStateEnded withUserInfo:nil];
}

- (void)srg_mediaPlayerController_playerItemFailedToPlayToEndTime:(NSNotification *)notification
{
    [self stopWithUserInfo:nil];
    
    NSError *error = SRGMediaPlayerControllerError(notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey]);
    [NSNotificationCenter.defaultCenter postNotificationName:SRGMediaPlayerPlaybackDidFailNotification
                                                      object:self
                                                    userInfo:@{ SRGMediaPlayerErrorKey: error }];
    
    SRGMediaPlayerLogDebug(@"Controller", @"Playback did fail with error: %@", error);
}

#pragma mark KVO

+ (BOOL)automaticallyNotifiesObserversForKey:(NSString *)key
{
    if ([key isEqualToString:@keypath(SRGMediaPlayerController.new, playbackState)]) {
        return NO;
    }
    else {
        return [super automaticallyNotifiesObserversForKey:key];
    }
}

#pragma mark Description

- (NSString *)description
{
    CMTimeRange timeRange = self.timeRange;
    return [NSString stringWithFormat:@"<%@: %p; playbackState = %@; mediaType = %@; streamType = %@; live = %@; "
            "URLAsset = %@; segments = %@; userInfo = %@; minimumDVRWindowLength = %@; liveTolerance = %@; "
            "timeRange = (%@, %@); currentTime = %@>",
            self.class,
            self,
            SRGMediaPlayerControllerNameForPlaybackState(self.playbackState),
            SRGMediaPlayerControllerNameForMediaType(self.mediaType),
            SRGMediaPlayerControllerNameForStreamType(self.streamType),
            self.live ? @"YES" : @"NO",
            self.URLAsset,
            self.segments,
            self.userInfo,
            @(self.minimumDVRWindowLength),
            @(self.liveTolerance),
            @(CMTimeGetSeconds(timeRange.start)),
            @(CMTimeGetSeconds(CMTimeRangeGetEnd(timeRange))),
            @(CMTimeGetSeconds(self.currentTime))];
}

@end

#pragma mark Functions

static NSError *SRGMediaPlayerControllerError(NSError *underlyingError)
{
    NSCParameterAssert(underlyingError);
    return [NSError errorWithDomain:SRGMediaPlayerErrorDomain code:SRGMediaPlayerErrorPlayback userInfo:@{ NSLocalizedDescriptionKey: SRGMediaPlayerLocalizedString(@"The media cannot be played", @"Error message when the media cannot be played due to a technical error."),
                                                                                                           NSUnderlyingErrorKey: underlyingError }];
}

static NSString *SRGMediaPlayerControllerNameForPlaybackState(SRGMediaPlayerPlaybackState playbackState)
{
    static NSDictionary<NSNumber *, NSString *> *s_names;
    static dispatch_once_t s_onceToken;
    dispatch_once(&s_onceToken, ^{
        s_names = @{ @(SRGMediaPlayerPlaybackStateIdle) : @"idle",
                     @(SRGMediaPlayerPlaybackStatePreparing) : @"preparing",
                     @(SRGMediaPlayerPlaybackStatePlaying) : @"playing",
                     @(SRGMediaPlayerPlaybackStateSeeking) : @"seeking",
                     @(SRGMediaPlayerPlaybackStatePaused) : @"paused",
                     @(SRGMediaPlayerPlaybackStateStalled) : @"stalled",
                     @(SRGMediaPlayerPlaybackStateEnded) : @"ended" };
    });
    return s_names[@(playbackState)] ?: @"unknown";
}

static NSString *SRGMediaPlayerControllerNameForMediaType(SRGMediaPlayerMediaType mediaType)
{
    static NSDictionary<NSNumber *, NSString *> *s_names;
    static dispatch_once_t s_onceToken;
    dispatch_once(&s_onceToken, ^{
        s_names = @{ @(SRGMediaPlayerMediaTypeVideo) : @"video",
                     @(SRGMediaPlayerMediaTypeAudio) : @"audio" };
    });
    return s_names[@(mediaType)] ?: @"unknown";
}

static NSString *SRGMediaPlayerControllerNameForStreamType(SRGMediaPlayerStreamType streamType)
{
    static NSDictionary<NSNumber *, NSString *> *s_names;
    static dispatch_once_t s_onceToken;
    dispatch_once(&s_onceToken, ^{
        s_names = @{ @(SRGMediaPlayerStreamTypeOnDemand) : @"on-demand",
                     @(SRGMediaPlayerStreamTypeLive) : @"live",
                     @(SRGMediaPlayerStreamTypeDVR) : @"DVR" };
    });
    return s_names[@(streamType)] ?: @"unknown";
}

// Add an offset to a position
static SRGPosition *SRGMediaPlayerControllerOffset(SRGPosition *position, CMTime offset)
{
    return [SRGPosition positionWithTime:CMTimeAdd(position.time, offset) toleranceBefore:position.toleranceBefore toleranceAfter:position.toleranceAfter];
}

// Adjust position tolerance settings so that the position is guaranteed to fall within the specified time range. If the time itself
// is outside the specified range, it is fixed to the nearest end.
static SRGPosition *SRGMediaPlayerControllerPositionInTimeRange(SRGPosition *position, CMTimeRange timeRange)
{
    if (SRG_CMTIMERANGE_IS_NOT_EMPTY(timeRange)) {
        CMTime toleranceBefore = CMTimeMaximum(CMTimeMinimum(position.toleranceBefore, CMTimeSubtract(position.time, timeRange.start)), kCMTimeZero);
        CMTime toleranceAfter = CMTimeMaximum(CMTimeMinimum(position.toleranceAfter, CMTimeSubtract(CMTimeRangeGetEnd(timeRange), position.time)), kCMTimeZero);
        CMTime time = CMTimeMaximum(CMTimeMinimum(position.time, CMTimeRangeGetEnd(timeRange)), timeRange.start);
        return [SRGPosition positionWithTime:time toleranceBefore:toleranceBefore toleranceAfter:toleranceAfter];
    }
    else {
        return position;
    }
}
