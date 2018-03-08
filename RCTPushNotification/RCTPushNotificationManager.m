//
//  RCTPushNotificationManager.m
//  RCTPushNotificationManager
//
//  Created by Yu Hei Dapper Apps on 8/3/18.
//  Copyright © 2018 Yu Hei Dapper Apps. All rights reserved.
//

#import "RCTPushNotificationManager.h"

#import <UserNotifications/UserNotifications.h>

#import <React/RCTBridge.h>
#import <React/RCTConvert.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTUtils.h>

NSString *const RCTRemoteNotificationReceived = @"RemoteNotificationReceived";

static NSString *const kLocalNotificationReceived = @"LocalNotificationReceived";
static NSString *const kRemoteNotificationsRegistered = @"RemoteNotificationsRegistered";
static NSString *const kRemoteNotificationRegistrationFailed = @"RemoteNotificationRegistrationFailed";

static NSString *const kErrorUnableToRequestPermissions = @"E_UNABLE_TO_REQUEST_PERMISSIONS";

#if !TARGET_OS_TV
@implementation RCTConvert (UNAuthorizationOptions)

+ (UNAuthorizationOptions)UNAuthorizationOptions:(id)permissions
{
    UNAuthorizationOptions options = UNAuthorizationOptionNone;
    if (permissions) {
        if ([RCTConvert BOOL:permissions[@"alert"]]) {
            options |= UNAuthorizationOptionAlert;
        }
        if ([RCTConvert BOOL:permissions[@"badge"]]) {
            options |= UNAuthorizationOptionBadge;
        }
        if ([RCTConvert BOOL:permissions[@"sound"]]) {
            options |= UNAuthorizationOptionSound;
        }
    } else {
        options = UNAuthorizationOptionAlert|UNAuthorizationOptionBadge|UNAuthorizationOptionSound;
    }
    return options;
}

@end

@implementation RCTConvert (NSDateComponents)

RCT_ENUM_CONVERTER(NSCalendarUnit,
                   (@{
                      @"year": @(NSCalendarUnitYear),
                      @"month": @(NSCalendarUnitMonth),
                      @"week": @(NSCalendarUnitWeekOfYear),
                      @"day": @(NSCalendarUnitDay),
                      @"hour": @(NSCalendarUnitHour),
                      @"minute": @(NSCalendarUnitMinute)
                      }),
                   0,
                   integerValue)

+ (NSDateComponents *)NSDateComponents:(id)json
{
    NSDate *date = [RCTConvert NSDate:json];
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    return [calendar components:NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay|NSCalendarUnitHour|NSCalendarUnitMinute|NSCalendarUnitMinute|NSCalendarUnitNanosecond fromDate:date];
}

+ (NSDateComponents *)NSDateComponents:(id)json date:(id)date
{
    NSDate *d = [RCTConvert NSDate:date];
    NSCalendarUnit units = [RCTConvert NSCalendarUnit:json];
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    return [calendar components:units fromDate:d];
}

@end

Boolean pushNotificationManagerIsReady = false;
UNNotification *initialNotification = NULL;

@interface RCTPushNotificationManager ()
@property (nonatomic, strong) NSMutableDictionary *remoteNotificationCallbacks;

@end

@implementation RCTConvert (UNNotificationRequest)

+ (UNNotificationRequest *)UNNotificationRequest:(id)json
{
    NSDictionary<NSString *, id> *details = [self NSDictionary:json];
    BOOL isSilent = [RCTConvert BOOL:details[@"isSilent"]];
    UNCalendarNotificationTrigger* trigger = nil;
    
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = [RCTConvert NSString:details[@"alertTitle"]];
    content.body = [RCTConvert NSString:details[@"alertBody"]];
    if (details[@"repeatInterval"] && [RCTConvert NSDate:details[@"fireDate"]]) {
        NSLog(@"Date components: %@", [RCTConvert NSDateComponents:details[@"repeatInterval"] date:details[@"fireDate"]]);
        trigger = [UNCalendarNotificationTrigger triggerWithDateMatchingComponents:[RCTConvert NSDateComponents:details[@"repeatInterval"] date:details[@"fireDate"]] repeats:YES];
    } else if ([RCTConvert NSDate:details[@"fireDate"]]) {
        trigger = [UNCalendarNotificationTrigger triggerWithDateMatchingComponents:[RCTConvert NSDateComponents:details[@"fireDate"]] repeats:NO];
    }
    content.categoryIdentifier = [RCTConvert NSString:details[@"category"]];
    content.userInfo = [RCTConvert NSDictionary:details[@"userInfo"]];
    if (details[@"applicationIconBadgeNumber"]) {
        content.badge = @([RCTConvert NSInteger:details[@"applicationIconBadgeNumber"]]);
    }
    if (!isSilent) {
        NSString *soundName = [RCTConvert NSString:details[@"soundName"]];
        content.sound = soundName ? [UNNotificationSound soundNamed:soundName] : [UNNotificationSound defaultSound];
    }
    return [UNNotificationRequest requestWithIdentifier:details[@"identifier"]?details[@"identifier"]:@"defaultLocalNotification" content:content trigger:trigger];
}

@end
#endif //TARGET_OS_TV

@implementation RCTPushNotificationManager {
    RCTPromiseResolveBlock _requestPermissionsResolveBlock;
}

#if !TARGET_OS_TV

static NSDictionary *RCTFormatLocalNotification(UNNotificationRequest *request)
{
    NSMutableDictionary *formattedLocalNotification = [NSMutableDictionary dictionary];
    if (request.trigger && [request.trigger respondsToSelector:@selector(nextTriggerDate)]) {
        NSDate *date = [request.trigger performSelector:@selector(nextTriggerDate)];
        NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
        [formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"];
        NSString *fireDateString = [formatter stringFromDate:date];
        formattedLocalNotification[@"fireDate"] = fireDateString;
    }
    formattedLocalNotification[@"alertAction"] = RCTNullIfNil(NULL);
    formattedLocalNotification[@"alertBody"] = RCTNilIfNull(request.content.body);
    formattedLocalNotification[@"applicationIconBadgeNumber"] = RCTNilIfNull(request.content.badge);
    formattedLocalNotification[@"category"] = RCTNullIfNil(request.content.categoryIdentifier);
    formattedLocalNotification[@"soundName"] = RCTNullIfNil(NULL);
    formattedLocalNotification[@"userInfo"] = RCTNullIfNil(RCTJSONClean(request.content.userInfo));
    formattedLocalNotification[@"remote"] = @NO;
    return formattedLocalNotification;
}

static NSDictionary *RCTFormatUNNotification(UNNotification *notification)
{
    NSMutableDictionary *formattedNotification = [NSMutableDictionary dictionary];
    UNNotificationContent *content = notification.request.content;
    
    formattedNotification[@"identifier"] = notification.request.identifier;
    
    if (notification.date) {
        NSDateFormatter *formatter = [NSDateFormatter new];
        [formatter setDateFormat:@"yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"];
        NSString *dateString = [formatter stringFromDate:notification.date];
        formattedNotification[@"date"] = dateString;
    }
    
    formattedNotification[@"title"] = RCTNullIfNil(content.title);
    formattedNotification[@"body"] = RCTNullIfNil(content.body);
    formattedNotification[@"category"] = RCTNullIfNil(content.categoryIdentifier);
    formattedNotification[@"thread-id"] = RCTNullIfNil(content.threadIdentifier);
    formattedNotification[@"userInfo"] = RCTNullIfNil(RCTJSONClean(content.userInfo));
    
    return formattedNotification;
}

#endif //TARGET_OS_TV

RCT_EXPORT_MODULE()

- (instancetype)init {
    self = [super init];
    if (self) {
        pushNotificationManagerIsReady = true;
    }
    return self;
}

- (dispatch_queue_t)methodQueue
{
    return dispatch_get_main_queue();
}

#if !TARGET_OS_TV
- (void)startObserving
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleLocalNotificationReceived:)
                                                 name:kLocalNotificationReceived
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleRemoteNotificationReceived:)
                                                 name:RCTRemoteNotificationReceived
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleRemoteNotificationsRegistered:)
                                                 name:kRemoteNotificationsRegistered
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(handleRemoteNotificationRegistrationError:)
                                                 name:kRemoteNotificationRegistrationFailed
                                               object:nil];
}

- (void)stopObserving
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (NSArray<NSString *> *)supportedEvents
{
    return @[@"localNotificationReceived",
             @"remoteNotificationReceived",
             @"remoteNotificationsRegistered",
             @"remoteNotificationRegistrationError"];
}

+ (void)didRegisterForRemoteNotificationsWithDeviceToken:(NSData *)deviceToken
{
    NSMutableString *hexString = [NSMutableString string];
    NSUInteger deviceTokenLength = deviceToken.length;
    const unsigned char *bytes = deviceToken.bytes;
    for (NSUInteger i = 0; i < deviceTokenLength; i++) {
        [hexString appendFormat:@"%02x", bytes[i]];
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:kRemoteNotificationsRegistered
                                                        object:self
                                                      userInfo:@{@"deviceToken" : [hexString copy]}];
}

+ (void)didFailToRegisterForRemoteNotificationsWithError:(NSError *)error
{
    [[NSNotificationCenter defaultCenter] postNotificationName:kRemoteNotificationRegistrationFailed
                                                        object:self
                                                      userInfo:@{@"error": error}];
}

+ (void)willPresentNotification:(UNNotification *)notification withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completionHandler
{
    [self handleNotification:notification];
    completionHandler(UNNotificationPresentationOptionAlert|UNNotificationPresentationOptionSound);
}

+ (void)didReceiveNotification:(UNNotification *)notification withCompletionHandler:(void (^)(void))completionHandler
{
    [self handleNotification:notification];
    completionHandler();
}

+ (void)handleNotification:(UNNotification *)notification
{
    if (!pushNotificationManagerIsReady) {
        initialNotification = notification;
        return;
    }
    
    if ([notification.request.trigger isKindOfClass:[UNPushNotificationTrigger class]]) {
        NSDictionary *userInfo = @{@"notification": notification.request.content.userInfo};
        [[NSNotificationCenter defaultCenter] postNotificationName:RCTRemoteNotificationReceived
                                                            object:self
                                                          userInfo:userInfo];
    } else {
        [[NSNotificationCenter defaultCenter] postNotificationName:kLocalNotificationReceived
                                                            object:self
                                                          userInfo:RCTFormatLocalNotification(notification.request)];
        [[UNUserNotificationCenter currentNotificationCenter] getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> * _Nonnull requests) {
            [requests enumerateObjectsUsingBlock:^(UNNotificationRequest * _Nonnull obj, NSUInteger idx, BOOL * _Nonnull stop) {
                NSLog(@"Request: %@", obj);
                if ([obj.trigger respondsToSelector:@selector(nextTriggerDate)]) {
                    NSLog(@"Next trigger: %@", [    obj.trigger performSelector:@selector(nextTriggerDate)]);
                }
            }];
        }];
    }
}

+ (void)didReceiveRemoteNotification:(NSDictionary *)notification
{
    NSDictionary *userInfo = @{@"notification": notification};
    [[NSNotificationCenter defaultCenter] postNotificationName:RCTRemoteNotificationReceived
                                                        object:self
                                                      userInfo:userInfo];
}

+ (void)didReceiveRemoteNotification:(NSDictionary *)notification
              fetchCompletionHandler:(RCTRemoteNotificationCallback)completionHandler
{
    NSDictionary *userInfo = @{@"notification": notification, @"completionHandler": completionHandler};
    [[NSNotificationCenter defaultCenter] postNotificationName:RCTRemoteNotificationReceived
                                                        object:self
                                                      userInfo:userInfo];
}

- (void)handleLocalNotificationReceived:(NSNotification *)notification
{
    [self sendEventWithName:@"localNotificationReceived" body:notification.userInfo];
}

- (void)handleRemoteNotificationReceived:(NSNotification *)notification
{
    NSMutableDictionary *remoteNotification = [NSMutableDictionary dictionaryWithDictionary:notification.userInfo[@"notification"]];
    RCTRemoteNotificationCallback completionHandler = notification.userInfo[@"completionHandler"];
    NSString *notificationId = [[NSUUID UUID] UUIDString];
    remoteNotification[@"notificationId"] = notificationId;
    remoteNotification[@"remote"] = @YES;
    if (completionHandler) {
        if (!self.remoteNotificationCallbacks) {
            // Lazy initialization
            self.remoteNotificationCallbacks = [NSMutableDictionary dictionary];
        }
        self.remoteNotificationCallbacks[notificationId] = completionHandler;
    }
    
    [self sendEventWithName:@"remoteNotificationReceived" body:remoteNotification];
}

- (void)handleRemoteNotificationsRegistered:(NSNotification *)notification
{
    [self sendEventWithName:@"remoteNotificationsRegistered" body:notification.userInfo];
}

- (void)handleRemoteNotificationRegistrationError:(NSNotification *)notification
{
    NSError *error = notification.userInfo[@"error"];
    NSDictionary *errorDetails = @{
                                   @"message": error.localizedDescription,
                                   @"code": @(error.code),
                                   @"details": error.userInfo,
                                   };
    [self sendEventWithName:@"remoteNotificationRegistrationError" body:errorDetails];
}

RCT_EXPORT_METHOD(onFinishRemoteNotification:(NSString *)notificationId fetchResult:(UIBackgroundFetchResult)result) {
    RCTRemoteNotificationCallback completionHandler = self.remoteNotificationCallbacks[notificationId];
    if (!completionHandler) {
        RCTLogError(@"There is no completion handler with notification id: %@", notificationId);
        return;
    }
    completionHandler(result);
    [self.remoteNotificationCallbacks removeObjectForKey:notificationId];
}

/**
 * Update the application icon badge number on the home screen
 */
RCT_EXPORT_METHOD(setApplicationIconBadgeNumber:(NSInteger)number)
{
    RCTSharedApplication().applicationIconBadgeNumber = number;
}

/**
 * Get the current application icon badge number on the home screen
 */
RCT_EXPORT_METHOD(getApplicationIconBadgeNumber:(RCTResponseSenderBlock)callback)
{
    callback(@[@(RCTSharedApplication().applicationIconBadgeNumber)]);
}

RCT_EXPORT_METHOD(requestPermissions:(NSDictionary *)permissions
                  resolver:(RCTPromiseResolveBlock)resolve
                  rejecter:(RCTPromiseRejectBlock)reject)
{
    if (RCTRunningInAppExtension()) {
        reject(kErrorUnableToRequestPermissions, nil, RCTErrorWithMessage(@"Requesting push notifications is currently unavailable in an app extension"));
        return;
    }
    
    if (_requestPermissionsResolveBlock != nil) {
        RCTLogError(@"Cannot call requestPermissions twice before the first has returned.");
        return;
    }
    
    // Add a listener to make sure that startObserving has been called
    [self addListener:@"remoteNotificationsRegistered"];
    _requestPermissionsResolveBlock = resolve;
    
    [[UNUserNotificationCenter currentNotificationCenter] requestAuthorizationWithOptions:[RCTConvert UNAuthorizationOptions:permissions] completionHandler:^(BOOL granted, NSError * _Nullable error) {
        if (error) {
            reject(kErrorUnableToRequestPermissions, nil, error);
        } else if (granted) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [RCTSharedApplication() registerForRemoteNotifications];
            });
            [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
                NSDictionary *notificationTypes = @{
                                                    @"alert": @(settings.alertSetting == UNNotificationSettingEnabled),
                                                    @"sound": @(settings.soundSetting == UNNotificationSettingEnabled),
                                                    @"badge": @(settings.badgeSetting == UNNotificationSettingEnabled),
                                                    };
                
                _requestPermissionsResolveBlock(notificationTypes);
                // Clean up listener added in requestPermissions
                [self removeListeners:1];
                _requestPermissionsResolveBlock = nil;
            }];
        }
    }];
}

RCT_EXPORT_METHOD(abandonPermissions)
{
    [RCTSharedApplication() unregisterForRemoteNotifications];
}

RCT_EXPORT_METHOD(checkPermissions:(RCTResponseSenderBlock)callback)
{
    if (RCTRunningInAppExtension()) {
        callback(@[@{@"alert": @NO, @"badge": @NO, @"sound": @NO}]);
        return;
    }
    
    [[UNUserNotificationCenter currentNotificationCenter] getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings * _Nonnull settings) {
        callback(@[@{
                        @"alert": @(settings.alertSetting == UNNotificationSettingEnabled),
                        @"sound": @(settings.soundSetting == UNNotificationSettingEnabled),
                        @"badge": @(settings.badgeSetting == UNNotificationSettingEnabled),
                        }]);
    }];
}

RCT_EXPORT_METHOD(presentLocalNotification:(UNNotificationRequest *)request)
{
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
}

RCT_EXPORT_METHOD(scheduleLocalNotification:(UNNotificationRequest *)request)
{
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:request withCompletionHandler:nil];
}

RCT_EXPORT_METHOD(cancelAllLocalNotifications)
{
    [[UNUserNotificationCenter currentNotificationCenter] removeAllPendingNotificationRequests];
}

RCT_EXPORT_METHOD(cancelLocalNotifications:(NSDictionary<NSString *, id> *)userInfo)
{
    [[UNUserNotificationCenter currentNotificationCenter] getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> * _Nonnull requests) {
        NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
        for (UNNotificationRequest *request in requests) {
            __block BOOL matchesAll = YES;
            NSDictionary<NSString *, id> *notificationInfo = request.content.userInfo;
            [userInfo enumerateKeysAndObjectsUsingBlock:^(NSString *key, id obj, BOOL *stop) {
                if (![notificationInfo[key] isEqual:obj]) {
                    matchesAll = NO;
                    *stop = YES;
                }
            }];
            if (matchesAll) {
                [identifiers addObject:request.identifier];
            }
        }
        if (identifiers.count > 0) {
            [[UNUserNotificationCenter currentNotificationCenter] removePendingNotificationRequestsWithIdentifiers:identifiers];
        }
    }];
}

RCT_EXPORT_METHOD(getInitialNotification:(RCTPromiseResolveBlock)resolve
                  reject:(__unused RCTPromiseRejectBlock)reject)
{
    if (initialNotification) {
        if ([initialNotification.request.trigger isKindOfClass:[UNPushNotificationTrigger class]]) {
            NSMutableDictionary<NSString *, id> *userInfo = initialNotification.request.content.userInfo.mutableCopy;
            userInfo[@"remote"] = @YES;
            resolve(userInfo);
        } else {
            resolve(RCTFormatLocalNotification(initialNotification.request));
        }
    } else {
        resolve((id)kCFNull);
    }
}

RCT_EXPORT_METHOD(getScheduledLocalNotifications:(RCTResponseSenderBlock)callback)
{
    [[UNUserNotificationCenter currentNotificationCenter] getPendingNotificationRequestsWithCompletionHandler:^(NSArray<UNNotificationRequest *> * _Nonnull requests) {
        NSMutableArray<NSDictionary *> *formattedScheduledLocalNotifications = [NSMutableArray new];
        for (UNNotificationRequest *request in requests) {
            [formattedScheduledLocalNotifications addObject:RCTFormatLocalNotification(request)];
        }
        callback(@[formattedScheduledLocalNotifications]);
    }];
}

RCT_EXPORT_METHOD(removeAllDeliveredNotifications)
{
    if ([UNUserNotificationCenter class]) {
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        [center removeAllDeliveredNotifications];
    }
}

RCT_EXPORT_METHOD(removeDeliveredNotifications:(NSArray<NSString *> *)identifiers)
{
    if ([UNUserNotificationCenter class]) {
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        [center removeDeliveredNotificationsWithIdentifiers:identifiers];
    }
}

RCT_EXPORT_METHOD(getDeliveredNotifications:(RCTResponseSenderBlock)callback)
{
    if ([UNUserNotificationCenter class]) {
        UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
        [center getDeliveredNotificationsWithCompletionHandler:^(NSArray<UNNotification *> *_Nonnull notifications) {
            NSMutableArray<NSDictionary *> *formattedNotifications = [NSMutableArray new];
            
            for (UNNotification *notification in notifications) {
                [formattedNotifications addObject:RCTFormatUNNotification(notification)];
            }
            callback(@[formattedNotifications]);
        }];
    }
}

#else //TARGET_OS_TV

- (NSArray<NSString *> *)supportedEvents
{
    return @[];
}

#endif //TARGET_OS_TV

@end
