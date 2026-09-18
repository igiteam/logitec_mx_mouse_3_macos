#import <Foundation/Foundation.h>

@interface MXKeysManager : NSObject
@property (nonatomic, assign) BOOL running;
- (void)start;
- (void)stop;
- (void)switchToChannelDirect:(int)channel;
@property (nonatomic, assign, readonly) BOOL deviceConnected;
@property (nonatomic, strong, readonly) NSString *deviceName;
@property (nonatomic, assign, readonly) int batteryLevel;
@property (nonatomic, strong, readonly) NSString *batteryLevelString;
@end
