//
//  Copyright (c) SRG SSR. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SRGPlayer : AVPlayer

@property (nonatomic, readonly, getter=isSeeking) BOOL seeking;

/**
 *  Attempt to play the media immediately if possible (iOS 10 and greater), otherwise normally.
 */
- (void)playImmediatelyIfPossible;

@end

NS_ASSUME_NONNULL_END
