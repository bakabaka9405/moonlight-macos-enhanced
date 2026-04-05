#import "AwdlAuthorizationHelper.h"
#import "AwdlPrivilegedHelperProtocol.h"

#import <ServiceManagement/ServiceManagement.h>
#import <Security/Authorization.h>
#import <Security/AuthorizationTags.h>
#import <Security/SecCode.h>
#import <Security/SecBase.h>

@implementation MLAwdlAuthorizationHelper

static AuthorizationRef MLAwdlAuthorizationRef = NULL;
static BOOL MLAwdlAuthorizationPrepared = NO;
static NSXPCConnection *MLAwdlPrivilegedHelperConnection = nil;
static NSString * const MLAwdlPrivilegedHelperSuffix = @".AwdlPrivilegedHelper";
static NSTimeInterval const MLAwdlPrivilegedHelperTimeout = 5.0;

+ (NSString *)helperLabel {
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    if (bundleIdentifier.length == 0) {
        return [@"std.skyhua.MoonlightMac" stringByAppendingString:MLAwdlPrivilegedHelperSuffix];
    }
    return [bundleIdentifier stringByAppendingString:MLAwdlPrivilegedHelperSuffix];
}

+ (NSString *)messageForStatus:(OSStatus)status fallback:(NSString *)fallback {
    CFStringRef message = SecCopyErrorMessageString(status, NULL);
    if (message != NULL) {
        return CFBridgingRelease(message);
    }
    return fallback;
}

+ (BOOL)ensureAuthorizationRef:(NSString * _Nullable * _Nullable)errorMessage {
    if (MLAwdlAuthorizationRef != NULL) {
        return YES;
    }

    OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment, kAuthorizationFlagDefaults, &MLAwdlAuthorizationRef);
    if (status == errAuthorizationSuccess && MLAwdlAuthorizationRef != NULL) {
        MLAwdlAuthorizationPrepared = NO;
        return YES;
    }

    if (errorMessage != NULL) {
        *errorMessage = [self messageForStatus:status fallback:[NSString stringWithFormat:@"Authorization failed (%d).", (int)status]];
    }
    MLAwdlAuthorizationRef = NULL;
    return NO;
}

+ (void)invalidateConnection {
    if (MLAwdlPrivilegedHelperConnection != nil) {
        [MLAwdlPrivilegedHelperConnection invalidate];
        MLAwdlPrivilegedHelperConnection = nil;
    }
}

+ (NSXPCConnection *)helperConnection {
    if (MLAwdlPrivilegedHelperConnection != nil) {
        return MLAwdlPrivilegedHelperConnection;
    }

    NSXPCConnection *connection = [[NSXPCConnection alloc] initWithMachServiceName:[self helperLabel]
                                                                           options:NSXPCConnectionPrivileged];
    connection.remoteObjectInterface = [NSXPCInterface interfaceWithProtocol:@protocol(MLAwdlPrivilegedHelperProtocol)];
    connection.invalidationHandler = ^{
        @synchronized (self) {
            if (MLAwdlPrivilegedHelperConnection == connection) {
                MLAwdlPrivilegedHelperConnection = nil;
            }
        }
    };
    connection.interruptionHandler = ^{
        @synchronized (self) {
            if (MLAwdlPrivilegedHelperConnection == connection) {
                MLAwdlPrivilegedHelperConnection = nil;
            }
        }
    };
    [connection resume];
    MLAwdlPrivilegedHelperConnection = connection;
    return connection;
}

+ (BOOL)queryHelperInstalledWithErrorMessage:(NSString * _Nullable * _Nullable)errorMessage {
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block BOOL helperPresent = NO;
    __block NSString *message = @"";

    NSXPCConnection *connection = [self helperConnection];
    id<MLAwdlPrivilegedHelperProtocol> proxy =
        [connection synchronousRemoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
            message = proxyError.localizedDescription ?: @"Unable to contact the AWDL privileged helper.";
            dispatch_semaphore_signal(semaphore);
        }];

    [proxy queryAwdlStateWithReply:^(BOOL present, BOOL up, NSString *stderrText) {
        helperPresent = YES;
        message = stderrText ?: @"";
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MLAwdlPrivilegedHelperTimeout * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
        [self invalidateConnection];
        if (errorMessage != NULL) {
            *errorMessage = @"Timed out while contacting the AWDL privileged helper.";
        }
        return NO;
    }

    if (!helperPresent) {
        [self invalidateConnection];
        if (errorMessage != NULL) {
            *errorMessage = message.length > 0 ? message : @"Unable to contact the AWDL privileged helper.";
        }
        return NO;
    }

    return YES;
}

+ (BOOL)privilegedHelperInstalled {
    return [self queryHelperInstalledWithErrorMessage:nil];
}

+ (BOOL)blessHelperWithLabel:(NSString *)label errorMessage:(NSString * _Nullable * _Nullable)errorMessage {
    if (![self ensureAuthorizationRef:errorMessage]) {
        return NO;
    }

    CFErrorRef blessError = NULL;
    Boolean blessed = SMJobBless(kSMDomainSystemLaunchd,
                                 (__bridge CFStringRef)label,
                                 MLAwdlAuthorizationRef,
                                 &blessError);
    if (blessed) {
        return YES;
    }

    if (errorMessage != NULL) {
        if (blessError != NULL) {
            *errorMessage = [(__bridge NSError *)blessError localizedDescription] ?: @"Failed to install the AWDL privileged helper.";
        } else {
            *errorMessage = @"Failed to install the AWDL privileged helper.";
        }
    }
    if (blessError != NULL) {
        CFRelease(blessError);
    }
    return NO;
}

+ (BOOL)prepareSessionWithPrompt:(NSString *)prompt
                    errorMessage:(NSString * _Nullable * _Nullable)errorMessage {
    NSString *connectionError = nil;
    if ([self queryHelperInstalledWithErrorMessage:&connectionError]) {
        return YES;
    }

    if (MLAwdlAuthorizationPrepared) {
        NSString *postBlessError = nil;
        if ([self queryHelperInstalledWithErrorMessage:&postBlessError]) {
            return YES;
        }
    }

    if (![self ensureAuthorizationRef:errorMessage]) {
        return NO;
    }

    AuthorizationItem rightItem = {
        .name = kSMRightBlessPrivilegedHelper,
        .valueLength = 0,
        .value = NULL,
        .flags = 0,
    };
    AuthorizationRights rights = {
        .count = 1,
        .items = &rightItem,
    };

    const char *promptCString = prompt.UTF8String ?: "";
    AuthorizationItem envItems[] = {
        {
            .name = kAuthorizationEnvironmentPrompt,
            .valueLength = strlen(promptCString),
            .value = (void *)promptCString,
            .flags = 0,
        },
        {
            .name = kAuthorizationEnvironmentShared,
            .valueLength = 0,
            .value = NULL,
            .flags = 0,
        },
    };
    AuthorizationEnvironment environment = {
        .count = sizeof(envItems) / sizeof(envItems[0]),
        .items = envItems,
    };

    AuthorizationFlags flags = kAuthorizationFlagExtendRights | kAuthorizationFlagInteractionAllowed | kAuthorizationFlagPreAuthorize;
    OSStatus status = AuthorizationCopyRights(MLAwdlAuthorizationRef, &rights, &environment, flags, NULL);
    if (status != errAuthorizationSuccess) {
        MLAwdlAuthorizationPrepared = NO;
        if (errorMessage != NULL) {
            *errorMessage = [self messageForStatus:status fallback:[NSString stringWithFormat:@"Authorization failed (%d).", (int)status]];
        }
        return NO;
    }

    MLAwdlAuthorizationPrepared = YES;
    if (![self blessHelperWithLabel:[self helperLabel] errorMessage:errorMessage]) {
        return NO;
    }

    [self invalidateConnection];
    NSString *postBlessError = nil;
    if ([self queryHelperInstalledWithErrorMessage:&postBlessError]) {
        return YES;
    }

    if (errorMessage != NULL) {
        *errorMessage = postBlessError.length > 0 ? postBlessError : @"The AWDL privileged helper was installed but did not start correctly.";
    }
    return NO;
}

+ (BOOL)runIfconfigArgument:(NSString *)argument
                     prompt:(NSString *)prompt
               errorMessage:(NSString * _Nullable * _Nullable)errorMessage {
    if (![self prepareSessionWithPrompt:prompt errorMessage:errorMessage]) {
        return NO;
    }

    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    __block BOOL success = NO;
    __block NSString *message = @"";

    NSXPCConnection *connection = [self helperConnection];
    id<MLAwdlPrivilegedHelperProtocol> proxy =
        [connection synchronousRemoteObjectProxyWithErrorHandler:^(NSError *proxyError) {
            message = proxyError.localizedDescription ?: @"Unable to contact the AWDL privileged helper.";
            dispatch_semaphore_signal(semaphore);
        }];

    [proxy runIfconfigArgument:argument withReply:^(BOOL helperSuccess, NSString *helperMessage) {
        success = helperSuccess;
        message = helperMessage ?: @"";
        dispatch_semaphore_signal(semaphore);
    }];

    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MLAwdlPrivilegedHelperTimeout * NSEC_PER_SEC));
    if (dispatch_semaphore_wait(semaphore, timeout) != 0) {
        [self invalidateConnection];
        if (errorMessage != NULL) {
            *errorMessage = @"Timed out while waiting for the AWDL privileged helper.";
        }
        return NO;
    }

    if (!success) {
        [self invalidateConnection];
        if (errorMessage != NULL) {
            *errorMessage = message.length > 0 ? message : @"The AWDL privileged helper command failed.";
        }
        return NO;
    }

    return YES;
}

+ (void)invalidateSession {
    [self invalidateConnection];
    if (MLAwdlAuthorizationRef != NULL) {
        AuthorizationFree(MLAwdlAuthorizationRef, kAuthorizationFlagDestroyRights);
        MLAwdlAuthorizationRef = NULL;
    }
    MLAwdlAuthorizationPrepared = NO;
}

@end
