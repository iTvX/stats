#import <CoreFoundation/CoreFoundation.h>

// Returns immutable raw channel values. The private IOReport declarations
// stay in the implementation and are not exported by Kit's Swift module.
CFArrayRef _Nullable StatsCopyEnergySample(void) CF_RETURNS_RETAINED;
