#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>

NS_ASSUME_NONNULL_BEGIN

void EeveeSBInvokeSeekDouble(id target, SEL selector, double argument);
NSString *EeveeJBRootPath(NSString *path);

// Audio recording API
void EeveeStartAudioRecording(NSString *outputPath);
void EeveeStopAudioRecording(void);
BOOL EeveeIsAudioRecording(void);

NS_ASSUME_NONNULL_END
