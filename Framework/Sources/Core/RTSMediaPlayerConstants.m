//
//  Copyright (c) SRG. All rights reserved.
//
//  License information is available from the LICENSE file.
//

#import "RTSMediaPlayerConstants.h"

NSTimeInterval const RTSMediaLiveDefaultTolerance = 30.;                // same tolerance as built-in iOS player

NSString * const RTSMediaPlayerPlaybackStateDidChangeNotification = @"RTSMediaPlayerPlaybackStateDidChangeNotification";
NSString * const RTSMediaPlayerPreviousPlaybackStateUserInfoKey = @"RTSMediaPlayerPreviousPlaybackState";

NSString * const RTSMediaPlayerPlaybackDidFailNotification = @"RTSMediaPlayerPlaybackDidFailNotification";
NSString * const RTSMediaPlayerPlaybackDidFailErrorUserInfoKey = @"RTSMediaPlayerPlaybackError";

NSString * const RTSMediaPlayerPictureInPictureStateChangeNotification = @"RTSMediaPlayerPictureInPictureStateChangeNotification";
