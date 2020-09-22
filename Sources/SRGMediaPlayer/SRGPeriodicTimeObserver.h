//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

@import AVFoundation;
@import Foundation;

NS_ASSUME_NONNULL_BEGIN

/**
 *  A periodic time observer calls one or several blocks during playback of an associated player. This class works
 *  exactly like time observers associated with an `AVPlayer`, with two differences:
 *    - Seekable time range updates are reported as well.
 *    - Blocks with identical periodicity are executed together.
 */
@interface SRGPeriodicTimeObserver : NSObject

/**
 *  Create a periodic time observer. Does nothing until attached to a player.
 *
 *  @param interval     The interval at which the block must be executed.
 *  @param queue	   The serial queue onto which block should be enqueued (main queue if `NULL`).
 */
- (instancetype)initWithInterval:(CMTime)interval queue:(nullable dispatch_queue_t)queue NS_DESIGNATED_INITIALIZER;

/**
 *  Register a block for a given identifier. If a block with the same identifier has already been registered, it
 *  is simply replaced.
 *
 *  @param block            The block to register (mandatory).
 *  @param identifier The identifier to which the block must be associated.
 */
- (void)setBlock:(void (^)(CMTime time))block forIdentifier:(NSString *)identifier;

/**
 *  The number of block registrations.
 */
@property (nonatomic) NSUInteger registrationCount;

/**
 *  Return `YES` iff the periodic time observer has a block registered for the specified identifier.
 *
 *  @param identifier The identifier to look for.
 *
 *  @return `YES` iff found.
 */
- (BOOL)hasBlockWithIdentifier:(id)identifier;

/**
 *  Unregister the block matching the provided identifier (does nothing if the identifier is not found).
 *
 *  @param identifier The identifier for which a block must be discarded (mandatory).
 */
- (void)removeBlockWithIdentifier:(id)identifier;

/**
 *  The time interval at which the observer executes all associated blocks.
 */
@property (nonatomic, readonly) CMTime interval;

/**
 *  The player to which the time observer has been attached, `nil` if none.
 */
@property (nonatomic, readonly, weak, nullable) AVPlayer *player;

/**
 *  Attach to a player. If a previous association existed, it will be removed first.
 */
- (void)attachToMediaPlayer:(AVPlayer *)player;

/**
 *  Detach the time observer from the associated player, if any.
 */
- (void)detachFromMediaPlayer;

@end

@interface SRGPeriodicTimeObserver (Unavailable)

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
