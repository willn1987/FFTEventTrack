//
//  FFAppDelegate+FFSwizzle.m
//  FFTwoBaboons
//
//  Created by huangqun on 2018/3/27.
//  Copyright © 2018年 finupgroup. All rights reserved.
//

#import "FFAppDelegate+FFSwizzle.h"
#import "FFLocationManager.h"

static void *const KAppLaunchTime = (void *) &KAppLaunchTime;
static void *const KBackgroundTaskIdentifier = (void *) &KBackgroundTaskIdentifier;

@interface FFAppDelegate ()

@property (nonatomic, strong) NSDate *appLaunchTime;    /**< APP启动时的时间 */
@property(nonatomic, unsafe_unretained) UIBackgroundTaskIdentifier backgroundTaskIdentifier;    /**< 后台任务标记 */

@end

@implementation FFAppDelegate (FFSwizzle)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        SEL originalSelector = @selector(application:didFinishLaunchingWithOptions:);
        SEL swizzledSelector = @selector(swizzled_application:didFinishLaunchingWithOptions:);
        [FFSwizzleUtils swizzlingInClass:[self class] originalSelector:originalSelector swizzledSelector:swizzledSelector];

        originalSelector = @selector(applicationWillEnterForeground:);
        swizzledSelector = @selector(swizzled_applicationWillEnterForeground:);
        [FFSwizzleUtils swizzlingInClass:[self class] originalSelector:originalSelector swizzledSelector:swizzledSelector];

        originalSelector = @selector(applicationDidEnterBackground:);
        swizzledSelector = @selector(swizzled_applicationDidEnterBackground:);
        [FFSwizzleUtils swizzlingInClass:[self class] originalSelector:originalSelector swizzledSelector:swizzledSelector];
    });
}

// 程序冷启动
- (void)swizzled_application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSLog(@"swizzled  程序启动");
    [self swizzled_application:application didFinishLaunchingWithOptions:launchOptions];
    if ([FFConfigManager isVersionRelease]) {
        [[FFLocationManager sharedInstance] updateWithBlock:^(CLLocation *geoPoint, NSError *error) {

        }];
    }

    // 程序启动 数据打点
    [self applicationStartOrEnterForeground];
}

// 程序热启动
- (void)swizzled_applicationWillEnterForeground:(UIApplication *)application {
    NSLog(@"swizzled  程序进入前台");
    [self swizzled_applicationWillEnterForeground:application];
    
    // 程序切入前台 数据打点
    [self applicationStartOrEnterForeground];
    
    // 结束后台任务
    [self endBackgroundTask];
}

// 程序进入后台
- (void)swizzled_applicationDidEnterBackground:(UIApplication *)application {
    NSLog(@"swizzled  程序进入后台");
    [self swizzled_applicationDidEnterBackground:application];

    // 标记一个后台任务开始 默认600S
    @weakify(self);
    self.backgroundTaskIdentifier = [application beginBackgroundTaskWithExpirationHandler:^(void) {
        @strongify(self);
        // 当应用程序留给后台的时间快要到结束时（应用程序留给后台执行的时间是有限的）， 这个Block块将被执行
        // 我们需要在次Block块中执行一些清理工作。
        // 如果清理工作失败了，那么将导致程序挂掉

        // 清理工作需要在主线程中用同步的方式来进行
        [self endBackgroundTask];
    }];

    // 上传所以埋点日志
    [self submitAllLogsWhenEnterBackground];
}

#pragma mark -
#pragma mark - 增加APP启动时间属性
- (void)setAppLaunchTime:(NSDate *)appLaunchTime {
    objc_setAssociatedObject(self, KAppLaunchTime, appLaunchTime, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSDate *)appLaunchTime {
    return objc_getAssociatedObject(self, KAppLaunchTime);
}

#pragma mark -
#pragma mark - 增加后台任务标记属性
- (void)setBackgroundTaskIdentifier:(UIBackgroundTaskIdentifier)backgroundTaskIdentifier {
    objc_setAssociatedObject(self, KBackgroundTaskIdentifier, @(backgroundTaskIdentifier), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (UIBackgroundTaskIdentifier)backgroundTaskIdentifier {
    return [objc_getAssociatedObject(self, KBackgroundTaskIdentifier) integerValue];
}

#pragma mark -
#pragma mark - 应用程序启动或者进入前台时添加埋点
- (void)applicationStartOrEnterForeground {
    self.appLaunchTime = [NSDate date];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 添加进入前台的埋点
        [FFAnalyticsManager sensorAnalyticsStart];
        [FFAnalyticsManager  sensorAnalyticTrackEvent:KEventTypeAppEnterForeground];
        [FFTrackDataManager addEventTrackData:[FFTrackDataUtil eventTrackData:@{KEventKeyEventType: KEventTypeAppEnterForeground}]];
        
        if (![self hasLaunched]) {
            // 第一次安装
            [FFAnalyticsManager sensorAnalyticTrackEvent:KEventTypeAppFisrtLaunch];
            [FFTrackDataManager addEventTrackData:[FFTrackDataUtil eventTrackData:@{KEventKeyEventType: KEventTypeAppFisrtLaunch}]];
        }
        
        //进入前台 上传本地和已有埋点数据
        [FFTrackDataManager uploadLocalEventTrackData];
    });
}

#pragma mark -
#pragma mark - 程序进入后台时上传埋点所有日志
- (void)submitAllLogsWhenEnterBackground {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 添加进入后台时的埋点
        double timeInterval = [[NSDate date] timeIntervalSinceDate:self.appLaunchTime];
        NSString *timeIntervalString = [NSString stringWithFormat:@"%0.0f", timeInterval * 1000];
        NSDictionary *dic = @{KEventKeyEventType: KEventTypeAppEnterBackground,
                              @"exitType": @"1",
                              @"length": timeIntervalString
                              };
        [FFAnalyticsManager  sensorAnalyticTrackEvent:KEventTypeAppEnterBackground withProperties:dic];
        [FFTrackDataManager addEventTrackData:[FFTrackDataUtil eventTrackData:dic]];
        
        // 上传已有的埋点数据
        @weakify(self);
        [FFTrackDataManager uploadEventTrackData:^(BOOL success, NSString *msg) {
            @strongify(self)
            if (!success) {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                    // 进入后台时存储本地统计数据 （上传失败时将数据缓存到本地）
                    [FFTrackDataManager saveLocalEventTrackData];
                });
            }
            // 结束后台任务
            [self endBackgroundTask];
        }];
    });
}

#pragma mark -
#pragma mark - 结束后台任务
- (void)endBackgroundTask {
    // 判断任务标记是否为未结束 如果有后台任务则将其结束
    if (self.backgroundTaskIdentifier != UIBackgroundTaskInvalid) {
        @weakify(self);
        dispatch_async(dispatch_get_main_queue(), ^(void) {
            @strongify(self);
            //标记指定的后台任务完成
            [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTaskIdentifier];
            //将后台任务设置为结束(销毁后台任务)
            self.backgroundTaskIdentifier = UIBackgroundTaskInvalid;
        });
    }
}

#pragma mark -
#pragma mark - 是否第一次安装
- (BOOL)hasLaunched {
    NSString *version = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    NSUserDefaults *userDefaults = [NSUserDefaults standardUserDefaults];
    if (![[userDefaults objectForKey:@"CFBundleShortVersion"] isEqualToString:version]) {
        [userDefaults setObject:version forKey:@"CFBundleShortVersion"];
        return NO;
    } else {
        return YES;
    }
    return YES;
}

@end
