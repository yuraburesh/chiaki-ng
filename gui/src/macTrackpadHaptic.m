#import <AppKit/AppKit.h>
#import "macTrackpadHaptic.h"

void macTrackpadHapticTick(int strong)
{
    @autoreleasepool {
        [[NSHapticFeedbackManager defaultPerformer]
            performFeedbackPattern:(strong ? NSHapticFeedbackPatternLevelChange : NSHapticFeedbackPatternGeneric)
                   performanceTime:NSHapticFeedbackPerformanceTimeNow];
    }
}
