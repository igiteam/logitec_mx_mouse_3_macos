#import <Foundation/Foundation.h>

@interface Grace3PlayManager : NSObject
@property (nonatomic, assign) BOOL running;
- (void)start;
- (void)stop;
@property (nonatomic, assign, readonly) BOOL deviceConnected;
@property (nonatomic, strong, readonly) NSString *deviceName;
@property (nonatomic, assign, readonly) int batteryLevel;
@property (nonatomic, strong, readonly) NSString *batteryString;
- (void)switchToChannelDirect:(int)channel;
@end
