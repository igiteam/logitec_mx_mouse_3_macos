#import <Foundation/Foundation.h>

@interface MXFlowManager : NSObject
@property (nonatomic, assign) BOOL running;
- (void)start;
- (void)stop;
@property (nonatomic, assign, readonly) int batteryLevel;
@property (nonatomic, strong, readonly) NSString *batteryString;
@property (nonatomic, assign, readonly) BOOL deviceReady;
@property (nonatomic, assign, readonly) int myChannel;   // auto-detected
- (void)switchToChannelDirect:(int)channel;
@end
