//
//  brwm_application.m
//  brwm
//
//  Created by bedtime on 7/19/25.
//

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#import <QuartzCore/QuartzCore.h>
#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <libproc.h>

#import "log.h"

@interface BRPlaceHolderRoot : NSObject
@end

@implementation BRPlaceHolderRoot
@end

char* format_executable_name_as_identifier(pid_t pid, NSUInteger windowNumber) {
    char *executableName = NULL;
    char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
     
    int ret = proc_pidpath(pid, pathbuf, sizeof(pathbuf));
    if (ret > 0) {
        char *basename_ptr = strrchr(pathbuf, '/');
        if (basename_ptr) {
            executableName = basename_ptr + 1;
        } else {
            executableName = pathbuf;
        }
    }
     
    if (!executableName || strlen(executableName) == 0) {
        executableName = "unknown_app";
    }
     
    size_t len = strlen(executableName);
    char *result = malloc(len * 2 + 48);
    if (!result) return NULL;
    
    char *dst = result;
    
    strcpy(dst, "brwm.handle.");
    dst += 12;
    
    if (executableName[0] >= '0' && executableName[0] <= '9') {
        strcpy(dst, "app_");
        dst += 4;
    }

    for (const char *src = executableName; *src; src++) {
        char c = *src;
        if (c >= 'A' && c <= 'Z') {
            c = c + 32;
        }
        if (c == ' ') {
            c = '_';
        }
        if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {
            *dst++ = c;
        }
    }
    
    sprintf(dst, "_%lu", (unsigned long)windowNumber);
    
    if (strncmp(result, "brwm.handle._", 13) == 0) {
        sprintf(result, "brwm.handle.unknown_app_%lu", (unsigned long)windowNumber);
    }
    
    return result;
}


@interface NSWindow (Connection)
@end

static NSMutableDictionary *windowConnections = nil;
static NSMutableSet *animatingWindows = nil;

@implementation NSWindow (Connection)

+ (void)load {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        windowConnections = [[NSMutableDictionary alloc] init];

        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(windowDidBecomeVisible:)
                                                     name:NSWindowDidUpdateNotification
                                                   object:nil];
    });
}

+ (void)windowDidBecomeVisible:(NSNotification *)notification {
    NSWindow *window = notification.object;

    // Ensure it's not a system or internal window (no title, not on-screen, or missing delegate)
    if (!window || ![window isKindOfClass:[NSWindow class]] || !window.delegate) {
        return;
    }

    // Skip AppKit internal windows or already connected ones
    if (![window isVisible] || !window.title || [self connectionNameForWindow:window]) {
        return;
    }

    // Ensure windowNumber is valid (non-zero)
    if ([window windowNumber] == 0) {
        return;
    }

    [window setupConnection];
}

- (void)animateToFrame:(NSRect)targetFrame {
    @synchronized(animatingWindows) {
        if ([animatingWindows containsObject:self]) {
            return; // Already animating — skip
        }
        [animatingWindows addObject:self];
    }

    NSTimeInterval duration = 0.1;

    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
        context.duration = duration;
        context.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [[self animator] setFrame:targetFrame display:NO];
    } completionHandler:^{
        @synchronized(animatingWindows) {
            [animatingWindows removeObject:self];
        }
    }];
}

- (void)removeTitleBarButtons {
    NSButton *closeButton = [self standardWindowButton:NSWindowCloseButton];
    NSButton *minimizeButton = [self standardWindowButton:NSWindowMiniaturizeButton];
    NSButton *zoomButton = [self standardWindowButton:NSWindowZoomButton];

    [closeButton removeFromSuperview];
    [minimizeButton removeFromSuperview];
    [zoomButton removeFromSuperview];
}

- (void)setupConnection {
    @synchronized(windowConnections) {
        NSUInteger window_number = [self windowNumber];
        char *identifier = format_executable_name_as_identifier(getpid(), window_number);
        NSString *connectionName = @(identifier);
        free(identifier); // Clean up allocated memory
        
        // Create connection with this window as root object
        NSConnection *connection = [[NSConnection alloc] init];
        [connection setRootObject:self];
        
        // Register the connection
        if ([connection registerName:connectionName]) {
            // Store connection reference
            windowConnections[@((NSUInteger)self)] = @{
                @"connection": connection,
                @"name": connectionName,
                @"windowNumber": @(window_number)
            };
            
            BRLog(@"Window connection established: %@ for window: %@",
                  connectionName, self.title ?: @"Untitled");
            
            // Set up window close notification to clean up connection
            [[NSNotificationCenter defaultCenter] addObserver:[NSWindow class]
                                                     selector:@selector(windowWillClose:)
                                                         name:NSWindowWillCloseNotification
                                                       object:self];
        } else {
            BRLog(@"Failed to register connection: %@", connectionName);
        }
    }
}

+ (void)windowWillClose:(NSNotification *)notification {
    NSWindow *window = notification.object;
    [window removeConnection];
}
 
- (void)removeConnection {
    @synchronized(windowConnections) {
        NSNumber *windowKey = @((NSUInteger)self);
        NSDictionary *connectionInfo = windowConnections[windowKey];
        
        if (connectionInfo) {
            NSConnection *connection = connectionInfo[@"connection"];
            NSString *connectionName = connectionInfo[@"name"];
             
            BRLog(@"Window connection removed: %@", connectionName);
            [connection setRootObject:[[BRPlaceHolderRoot alloc] init]];
            
            // Delay actual invalidation by 1 second, to prevent crashes inside
            // our server proc. here the dock might not have seen the window
            // disappear yet.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [connection invalidate];
                [windowConnections removeObjectForKey:windowKey];
            });
        }
        
        // Remove notification observer
        [[NSNotificationCenter defaultCenter] removeObserver:[NSWindow class]
                                                        name:NSWindowWillCloseNotification
                                                      object:self];
    }
}


// Helper methods
+ (NSString *)connectionNameForWindow:(NSWindow *)window {
    @synchronized(windowConnections) {
        NSNumber *windowKey = @((NSUInteger)window);
        NSDictionary *connectionInfo = windowConnections[windowKey];
        return connectionInfo[@"name"];
    }
}

+ (NSArray *)allActiveConnectionNames {
    @synchronized(windowConnections) {
        NSMutableArray *names = [NSMutableArray array];
        for (NSDictionary *info in windowConnections.allValues) {
            [names addObject:info[@"name"]];
        }
        return [names copy];
    }
}

+ (NSUInteger)windowNumberForWindow:(NSWindow *)window {
    @synchronized(windowConnections) {
        NSNumber *windowKey = @((NSUInteger)window);
        NSDictionary *connectionInfo = windowConnections[windowKey];
        return [connectionInfo[@"windowNumber"] unsignedIntegerValue];
    }
}

@end

#pragma clang diagnostic pop
