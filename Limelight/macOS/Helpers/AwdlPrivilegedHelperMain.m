#import <Foundation/Foundation.h>
#import <Security/Security.h>

#import "AwdlPrivilegedHelperProtocol.h"

static NSString * const MLAwdlPrivilegedHelperFallbackLabel = @"std.skyhua.MoonlightMac.AwdlPrivilegedHelper";

static NSString *MLAwdlPrivilegedHelperServiceLabel(void) {
    NSString *bundleIdentifier = [[NSBundle mainBundle] bundleIdentifier];
    return bundleIdentifier.length > 0 ? bundleIdentifier : MLAwdlPrivilegedHelperFallbackLabel;
}

@interface MLAwdlPrivilegedHelperService : NSObject <NSXPCListenerDelegate, MLAwdlPrivilegedHelperProtocol>
@end

@implementation MLAwdlPrivilegedHelperService

- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)newConnection {
    if (![self isConnectionAuthorized:newConnection]) {
        return NO;
    }

    newConnection.exportedInterface = [NSXPCInterface interfaceWithProtocol:@protocol(MLAwdlPrivilegedHelperProtocol)];
    newConnection.exportedObject = self;
    [newConnection resume];
    return YES;
}

- (void)queryAwdlStateWithReply:(void (^)(BOOL present, BOOL up, NSString *stderrText))reply {
    NSString *stdoutText = @"";
    NSString *stderrText = @"";
    int status = [self runTask:@"/sbin/ifconfig" arguments:@[@"awdl0"] stdout:&stdoutText stderr:&stderrText];
    if (status != 0) {
        reply(NO, NO, stderrText ?: @"");
        return;
    }

    BOOL isUp = [self outputRepresentsUpState:stdoutText];
    reply(YES, isUp, stderrText ?: @"");
}

- (void)runIfconfigArgument:(NSString *)argument
                  withReply:(void (^)(BOOL success, NSString *message))reply {
    if (!([argument isEqualToString:@"up"] || [argument isEqualToString:@"down"])) {
        reply(NO, @"Unsupported AWDL command.");
        return;
    }

    NSString *stdoutText = @"";
    NSString *stderrText = @"";
    int status = [self runTask:@"/sbin/ifconfig"
                     arguments:@[@"awdl0", argument]
                        stdout:&stdoutText
                        stderr:&stderrText];
    if (status == 0) {
        reply(YES, @"");
        return;
    }

    NSString *message = stderrText.length > 0 ? stderrText : stdoutText;
    if (message.length == 0) {
        message = [NSString stringWithFormat:@"ifconfig awdl0 %@ failed with status %d.", argument, status];
    }
    reply(NO, message);
}

- (BOOL)isConnectionAuthorized:(NSXPCConnection *)connection {
    NSArray<NSString *> *requirements = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"SMAuthorizedClients"];
    if (requirements.count == 0) {
        return NO;
    }

    NSDictionary *attributes = @{
        (__bridge NSString *)kSecGuestAttributePid: @(connection.processIdentifier)
    };

    SecCodeRef guestCode = NULL;
    OSStatus guestStatus = SecCodeCopyGuestWithAttributes(
        NULL,
        (__bridge CFDictionaryRef)attributes,
        kSecCSDefaultFlags,
        &guestCode
    );
    if (guestStatus != errSecSuccess || guestCode == NULL) {
        if (guestCode != NULL) {
            CFRelease(guestCode);
        }
        return NO;
    }

    BOOL authorized = NO;
    for (NSString *requirementString in requirements) {
        SecRequirementRef requirement = NULL;
        OSStatus requirementStatus = SecRequirementCreateWithString(
            (__bridge CFStringRef)requirementString,
            kSecCSDefaultFlags,
            &requirement
        );
        if (requirementStatus == errSecSuccess && requirement != NULL) {
            OSStatus validityStatus = SecCodeCheckValidity(guestCode, kSecCSDefaultFlags, requirement);
            CFRelease(requirement);
            if (validityStatus == errSecSuccess) {
                authorized = YES;
                break;
            }
        }
    }

    CFRelease(guestCode);
    return authorized;
}

- (int)runTask:(NSString *)launchPath
      arguments:(NSArray<NSString *> *)arguments
         stdout:(NSString * _Nullable * _Nullable)stdoutText
         stderr:(NSString * _Nullable * _Nullable)stderrText {
    NSPipe *stdoutPipe = [NSPipe pipe];
    NSPipe *stderrPipe = [NSPipe pipe];

    NSTask *task = [[NSTask alloc] init];
    task.launchPath = launchPath;
    task.arguments = arguments;
    task.standardOutput = stdoutPipe;
    task.standardError = stderrPipe;

    @try {
        [task launch];
        [task waitUntilExit];
    } @catch (NSException *exception) {
        if (stdoutText != NULL) {
            *stdoutText = @"";
        }
        if (stderrText != NULL) {
            *stderrText = exception.reason ?: @"Task launch failed.";
        }
        return -1;
    }

    NSData *stdoutData = [[stdoutPipe fileHandleForReading] readDataToEndOfFile];
    NSData *stderrData = [[stderrPipe fileHandleForReading] readDataToEndOfFile];

    if (stdoutText != NULL) {
        *stdoutText = [[NSString alloc] initWithData:stdoutData encoding:NSUTF8StringEncoding] ?: @"";
    }
    if (stderrText != NULL) {
        *stderrText = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"";
    }

    return task.terminationStatus;
}

- (BOOL)outputRepresentsUpState:(NSString *)stdoutText {
    NSRange open = [stdoutText rangeOfString:@"<"];
    NSRange close = [stdoutText rangeOfString:@">"];
    if (open.location != NSNotFound &&
        close.location != NSNotFound &&
        open.location < close.location) {
        NSUInteger start = NSMaxRange(open);
        NSString *flagsString = [stdoutText substringWithRange:NSMakeRange(start, close.location - start)];
        NSArray<NSString *> *flags = [flagsString componentsSeparatedByString:@","];
        return [flags containsObject:@"UP"];
    }
    return [stdoutText containsString:@"UP"];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        MLAwdlPrivilegedHelperService *delegate = [[MLAwdlPrivilegedHelperService alloc] init];
        NSXPCListener *listener = [[NSXPCListener alloc] initWithMachServiceName:MLAwdlPrivilegedHelperServiceLabel()];
        listener.delegate = delegate;
        [listener resume];
        [[NSRunLoop currentRunLoop] run];
    }
    return EXIT_FAILURE;
}
