//
//  OALAudioSession.m
//  ObjectAL
//
//  Created by Karl Stenerud on 10-12-19.
//
//  Copyright (c) 2009 Karl Stenerud. All rights reserved.
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall remain in place
// in this source code.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
//
// Attribution is not required, but appreciated :)
//

#import "OALAudioSession.h"
#import <AudioToolbox/AudioToolbox.h>
#import "ObjectALMacros.h"
#import "ARCSafe_MemMgmt.h"
#import "OALNotifications.h"


#define kMaxSessionActivationRetries 40
#define kMinTimeIntervalBetweenResets 1.0

#pragma mark -
#pragma mark Private Methods

SYNTHESIZE_SINGLETON_FOR_CLASS_PROTOTYPE(OALAudioSession);


#if defined(__IPHONE_OS_VERSION_MAX_ALLOWED)

/** \cond */
/**
 * (INTERNAL USE) Private methods for OALAudioSupport. 
 */
@interface OALAudioSession (Private)

/** (INTERNAL USE) Update settings to be compatible with the current audio session category.
 */
- (void) updateFromAudioSessionCategory;

/** (INTERNAL USE) Update the audio session category to be compatible with the current settings.
 */
- (void) updateFromFlags;

/** (INTERNAL USE) Called by SuspendHandler.
 */
- (void) setSuspended:(bool) value;

/** (INTERNAL USE) Called when an audio error is signalled via
 * notification.
 */
- (void) onAudioError:(NSNotification*) notification;

@end
/** \endcond */


@implementation OALAudioSession

#pragma mark Object Management

SYNTHESIZE_SINGLETON_FOR_CLASS(OALAudioSession);

- (id) init
{
	if(nil != (self = [super init]))
	{
		OAL_LOG_DEBUG(@"%@: Init", self);

		suspendHandler = [[OALSuspendHandler alloc] initWithTarget:self selector:@selector(setSuspended:)];

		// Set up defaults
		allowIpod = YES;
		ipodDucking = NO;
		useHardwareIfAvailable = YES;
		honorSilentSwitch = YES;
		[self updateFromFlags];

#if OBJECTAL_CFG_RESET_AUDIO_SESSION_ON_ERROR
		[[NSNotificationCenter defaultCenter] addObserver:self
												 selector:@selector(onAudioError:)
													 name:OALAudioErrorNotification object:nil];
#endif

		lastResetTime = [[NSDate alloc] init];
		// Activate the audio session.
		self.audioSessionActive = YES;
	}
	return self;
}

- (void) dealloc
{
	OAL_LOG_DEBUG(@"%@: Dealloc", self);

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    NSError* error;
    if(![[AVAudioSession sharedInstance] setActive:NO error:&error])
    {
        OAL_LOG_ERROR(@"Could not deactivate audio session: %@", error);
    }
	
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	as_release(lastResetTime);	
	as_release(audioSessionCategory);
	as_release(suspendHandler);
	as_superdealloc();
}


#pragma mark Properties

- (NSString*) audioSessionCategory
{
    return audioSessionCategory;
}

- (void) setAudioSessionCategory:(NSString*) value
{
	OPTIONALLY_SYNCHRONIZED(self)
	{
        as_autorelease_noref(audioSessionCategory);
		audioSessionCategory = as_retain(value);
		[self updateFromAudioSessionCategory];
		[self setAudioMode];
	}	
}

- (bool) allowIpod
{
    return allowIpod;
}

- (void) setAllowIpod:(bool) value
{
	OPTIONALLY_SYNCHRONIZED(self)
	{
		allowIpod = value;
		[self updateFromFlags];
		[self setAudioMode];
	}
}

- (bool) ipodDucking
{
    return ipodDucking;
}

- (void) setIpodDucking:(bool) value
{
	OPTIONALLY_SYNCHRONIZED(self)
	{
		ipodDucking = value;
		[self updateFromFlags];
		[self setAudioMode];
	}
}

- (bool) useHardwareIfAvailable
{
    return useHardwareIfAvailable;
}

- (void) setUseHardwareIfAvailable:(bool) value
{
	OPTIONALLY_SYNCHRONIZED(self)
	{
		useHardwareIfAvailable = value;
		[self updateFromFlags];
		[self setAudioMode];
	}
}

- (bool) honorSilentSwitch
{
    return honorSilentSwitch;
}

- (void) setHonorSilentSwitch:(bool) value
{
	OPTIONALLY_SYNCHRONIZED(self)
	{
		honorSilentSwitch = value;
		[self updateFromFlags];
		[self setAudioMode];
	}
}


#pragma mark Internal Use

- (BOOL) _otherAudioPlaying
{
    return ((AVAudioSession*)[AVAudioSession sharedInstance]).otherAudioPlaying;
}

- (void) setAudioCategory:(NSString*) audioCategory
{
	NSError* error;
	if(![[AVAudioSession sharedInstance] setCategory:audioCategory error:&error])
	{
		OAL_LOG_ERROR(@"Failed to set audio category: %@", error);
	}
}

- (void) updateFromAudioSessionCategory
{
	if([AVAudioSessionCategoryAmbient isEqualToString:audioSessionCategory])
	{
		honorSilentSwitch = YES;
		allowIpod = YES;
	}
	else if([AVAudioSessionCategorySoloAmbient isEqualToString:audioSessionCategory])
	{
		honorSilentSwitch = YES;
		allowIpod = NO;
	}
	else if([AVAudioSessionCategoryPlayback isEqualToString:audioSessionCategory])
	{
		honorSilentSwitch = NO;
	}
	else if([AVAudioSessionCategoryRecord isEqualToString:audioSessionCategory])
	{
		honorSilentSwitch = NO;
		allowIpod = NO;
		ipodDucking = NO;
	}
	else if([AVAudioSessionCategoryPlayAndRecord isEqualToString:audioSessionCategory])
	{
		honorSilentSwitch = NO;
		allowIpod = NO;
		ipodDucking = NO;
	}
	else
	{
		OAL_LOG_WARNING(@"%@: Unrecognized audio session category", audioSessionCategory);
	}
	
}

- (void) updateFromFlags
{
	as_release(audioSessionCategory);
	if(honorSilentSwitch)
	{
		if(allowIpod)
		{
			audioSessionCategory = as_retain(AVAudioSessionCategoryAmbient);
		}
		else
		{
			audioSessionCategory = as_retain(AVAudioSessionCategorySoloAmbient);
		}
	}
	else
	{
		audioSessionCategory = as_retain(AVAudioSessionCategoryPlayback);
	}
}

- (void) setAudioMode
{
	// Simulator doesn't support setting the audio session category.
#if !TARGET_IPHONE_SIMULATOR
	
	NSString* actualCategory = audioSessionCategory;
	
	// Mixing uses software decoding and mixes with other apps.
	bool mixing = allowIpod;
	
	// Ducking causes other app audio to lower in volume while this session is active.
	bool ducking = ipodDucking;
	
	// If the hardware is available and we want it, take it.
	if(mixing && useHardwareIfAvailable && !self._otherAudioPlaying)
	{
		mixing = NO;
	}
	
	// Handle special case where useHardwareIfAvailable caused us to take the hardware.
	if(!mixing && [AVAudioSessionCategoryAmbient isEqualToString:audioSessionCategory])
	{
		actualCategory = AVAudioSessionCategorySoloAmbient;
	}
	
	[self setAudioCategory:actualCategory];
	
	if(!mixing)
	{
		// Setting OtherMixableAudioShouldDuck clears MixWithOthers.
		[self setIntProperty:kAudioSessionProperty_OtherMixableAudioShouldDuck value:ducking];
	}
	
	if(!ducking)
	{
		// Setting MixWithOthers clears OtherMixableAudioShouldDuck.
		[self setIntProperty:kAudioSessionProperty_OverrideCategoryMixWithOthers value:mixing];
	}
	
#endif /* !TARGET_IPHONE_SIMULATOR */
}

- (bool) audioSessionActive
{
    return audioSessionActive;
}

/** Work around for iOS4 bug that causes the session to not activate on the first few attempts
 * in certain situations.
 */ 
- (void) activateAudioSession
{
	NSError* error;
	for(int try = 1; try <= kMaxSessionActivationRetries; try++)
	{
		if([[AVAudioSession sharedInstance] setActive:YES error:&error])
		{
			audioSessionActive = YES;
			return;
		}
		OAL_LOG_ERROR(@"Could not activate audio session after %d tries: %@", try, error);
		[NSThread sleepForTimeInterval:0.2];
	}
	OAL_LOG_ERROR(@"Failed to activate the audio session");
}

- (void) setAudioSessionActive:(bool) value
{
	OPTIONALLY_SYNCHRONIZED(self)
	{
		if(value != audioSessionActive)
		{
			if(value)
			{
				OAL_LOG_DEBUG(@"Activate audio session");
				[self setAudioMode];
				[self activateAudioSession];
			}
			else
			{
				OAL_LOG_DEBUG(@"Deactivate audio session");
				NSError* error;
				if(![[AVAudioSession sharedInstance] setActive:NO error:&error])
				{
					OAL_LOG_ERROR(@"Could not deactivate audio session: %@", error);
				}
				else
				{
					audioSessionActive = NO;
				}
				
			}
		}
	}
}

- (void) onAudioError:(NSNotification*) notification
{
    #pragma unused(notification)

#if OBJECTAL_CFG_RESET_AUDIO_SESSION_ON_ERROR
	if(self.suspended)
	{
		OAL_LOG_WARNING(@"Received audio error notification, but session is suspended. Doing nothing.");
		return;
	}

	OPTIONALLY_SYNCHRONIZED(self)
	{
		NSTimeInterval timeSinceLastReset = [[NSDate date] timeIntervalSinceDate:lastResetTime];
		if(timeSinceLastReset > kMinTimeIntervalBetweenResets && !handlingErrorNotification)
		{
            handlingErrorNotification = TRUE;
            
			OAL_LOG_WARNING(@"Received audio error notification. Resetting audio session.");
			self.manuallySuspended = YES;
			self.manuallySuspended = NO;
			as_release(lastResetTime);
			lastResetTime = [[NSDate alloc] init];
		
            handlingErrorNotification = FALSE;
        }
		else
		{
            if(!handlingErrorNotification)
            {
                OAL_LOG_WARNING(@"Received audio error notification, but last reset was %f seconds ago. Doing nothing.", timeSinceLastReset);
            }
		}
	}
#endif
}

#pragma mark Suspend Handler

- (void) addSuspendListener:(id<OALSuspendListener>) listener
{
	[suspendHandler addSuspendListener:listener];
}

- (void) removeSuspendListener:(id<OALSuspendListener>) listener
{
	[suspendHandler removeSuspendListener:listener];
}

- (bool) manuallySuspended
{
	return suspendHandler.manuallySuspended;
}

- (void) setManuallySuspended:(bool) value
{
	suspendHandler.manuallySuspended = value;
}

- (bool) interrupted
{
	return suspendHandler.interrupted;
}

- (void) setInterrupted:(bool) value
{
	suspendHandler.interrupted = value;
}

- (bool) suspended
{
	return suspendHandler.suspended;
}

- (void) setSuspended:(bool) value
{
	OAL_LOG_DEBUG(@"setSuspended %d", value);
	if(value)
	{
		audioSessionWasActive = self.audioSessionActive;
		self.audioSessionActive = NO;
	}
	else
	{
		if(audioSessionWasActive)
		{
			self.audioSessionActive = YES;
		}
	}
}


@end

#else

@implementation OALAudioSession

#pragma mark Object Management

SYNTHESIZE_SINGLETON_FOR_CLASS(OALAudioSession);

- (id) init
{
	if(nil != (self = [super init]))
	{
		suspendHandler = [[OALSuspendHandler alloc] initWithTarget:self selector:@selector(setSuspended:)];

		// Set up defaults
		allowIpod = NO;
		ipodDucking = NO;
		useHardwareIfAvailable = YES;
		honorSilentSwitch = NO;

		self.audioSessionActive = YES;
	}
	return self;
}

- (void) dealloc
{
	as_release(lastResetTime);
	as_release(audioSessionCategory);
	as_release(suspendHandler);
	as_superdealloc();
}

#pragma mark Properties

@synthesize audioSessionCategory;
@synthesize audioSessionActive;
@synthesize allowIpod;
@synthesize ipodDucking;
@synthesize useHardwareIfAvailable;
@synthesize honorSilentSwitch;

#pragma mark Suspend Handler

- (void) addSuspendListener:(id<OALSuspendListener>) listener
{
	[suspendHandler addSuspendListener:listener];
}

- (void) removeSuspendListener:(id<OALSuspendListener>) listener
{
	[suspendHandler removeSuspendListener:listener];
}

- (bool) manuallySuspended
{
	return suspendHandler.manuallySuspended;
}

- (void) setManuallySuspended:(bool) value
{
	suspendHandler.manuallySuspended = value;
}

- (bool) interrupted
{
    return false;
}

- (void) setInterrupted:(__unused bool) value
{
}

- (bool) suspended
{
	return suspendHandler.suspended;
}

- (void) setSuspended:(bool) value
{
	OAL_LOG_DEBUG(@"setSuspended %d", value);
	if(value)
	{
		audioSessionWasActive = self.audioSessionActive;
		self.audioSessionActive = NO;
	}
	else
	{
		if(audioSessionWasActive)
		{
			self.audioSessionActive = YES;
		}
	}
}

@end

#endif
