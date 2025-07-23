//
//  window.m
//  brwm
//
//  Created by bedtime on 7/23/25.
//

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <libproc.h>
#import <CoreGraphics/CoreGraphics.h>

#import "log.h"

@interface BRPlaceHolderRoot : NSObject
@end

@interface NSWindow (Connection)
- (void)animateToFrame:(NSRect)targetFrame;
- (void)removeTitleBarButtons;
@end

extern char *format_executable_name_as_identifier(pid_t pid, NSUInteger windowNumber);

extern int SLSMainConnectionID(void);
extern uint64_t SLSGetActiveSpace(int cid);
extern CGError SLSGetWindowOwner(int cid, uint32_t wid, int* out_cid);
extern CGError SLSConnectionGetPID(int cid, pid_t *pid);
extern CFArrayRef SLSCopyWindowsWithOptionsAndTags(int cid, uint32_t owner, CFArrayRef spaces, uint32_t options, uint64_t *set_tags, uint64_t *clear_tags);
extern CFTypeRef SLSWindowQueryWindows(int cid, CFArrayRef windows, uint32_t options);
extern CFTypeRef SLSWindowQueryResultCopyWindows(CFTypeRef window_query);
extern int SLSWindowIteratorGetCount(CFTypeRef iterator);
extern bool SLSWindowIteratorAdvance(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetParentID(CFTypeRef iterator);
extern uint32_t SLSWindowIteratorGetWindowID(CFTypeRef iterator);
extern uint64_t SLSWindowIteratorGetTags(CFTypeRef iterator);
extern uint64_t SLSWindowIteratorGetAttributes(CFTypeRef iterator);

static bool is_window_suitable_for_tiling(CFTypeRef iterator) {
    uint64_t tags = SLSWindowIteratorGetTags(iterator);
    uint64_t attributes = SLSWindowIteratorGetAttributes(iterator);
    uint32_t parent_wid = SLSWindowIteratorGetParentID(iterator);
    
    return ((parent_wid == 0) &&
            ((attributes & 0x2) || (tags & 0x400000000000000)) &&
            (((tags & 0x1)) || ((tags & 0x2) && (tags & 0x80000000))));
}
 
static CFArrayRef create_number_array(void *values, size_t size, int count, CFNumberType type) {
    CFNumberRef temp[count];
    
    for (int i = 0; i < count; ++i) {
        temp[i] = CFNumberCreate(NULL, type, ((char *)values) + (size * i));
    }
    
    CFArrayRef result = CFArrayCreate(NULL, (const void **)temp, count, &kCFTypeArrayCallBacks);
    
    for (int i = 0; i < count; ++i) {
        CFRelease(temp[i]);
    }
    
    return result;
}

static CFComparisonResult compare_windows_by_id(const void *val1, const void *val2, void *context) {
    CFDictionaryRef dict1 = (CFDictionaryRef)val1;
    CFDictionaryRef dict2 = (CFDictionaryRef)val2;
    
    CFNumberRef wid1 = CFDictionaryGetValue(dict1, CFSTR("wid"));
    CFNumberRef wid2 = CFDictionaryGetValue(dict2, CFSTR("wid"));
    
    int int_wid1 = 0, int_wid2 = 0;
    CFNumberGetValue(wid1, kCFNumberIntType, &int_wid1);
    CFNumberGetValue(wid2, kCFNumberIntType, &int_wid2);
    
    if (int_wid1 < int_wid2) return kCFCompareLessThan;
    if (int_wid1 > int_wid2) return kCFCompareGreaterThan;
    return kCFCompareEqualTo;
}

// MARK: - Window Collection
CFMutableArrayRef collect_tileable_windows(uint64_t space_id) {
    int connection = SLSMainConnectionID();
    CFMutableArrayRef suitable_windows = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    
    CFArrayRef space_list = create_number_array(&space_id, sizeof(uint64_t), 1, kCFNumberSInt64Type);
    
    uint64_t set_tags = 1;
    uint64_t clear_tags = 0;
    CFArrayRef window_list = SLSCopyWindowsWithOptionsAndTags(connection, 0, space_list, 0x2, &set_tags, &clear_tags);
    
    if (window_list) {
        CFTypeRef query = SLSWindowQueryWindows(connection, window_list, 0x0);
        if (query) {
            CFTypeRef iterator = SLSWindowQueryResultCopyWindows(query);
            if (iterator) {
                while (SLSWindowIteratorAdvance(iterator)) {
                    if (is_window_suitable_for_tiling(iterator)) {
                        uint32_t wid = SLSWindowIteratorGetWindowID(iterator);
                        int wid_cid = 0;
                        SLSGetWindowOwner(connection, wid, &wid_cid);
                        
                        pid_t pid = 0;
                        SLSConnectionGetPID(wid_cid, &pid);
                        
                        CFMutableDictionaryRef win_info = CFDictionaryCreateMutable(NULL, 0,
                                                                                   &kCFTypeDictionaryKeyCallBacks,
                                                                                   &kCFTypeDictionaryValueCallBacks);
                        CFNumberRef cf_wid = CFNumberCreate(NULL, kCFNumberIntType, &wid);
                        CFNumberRef cf_pid = CFNumberCreate(NULL, kCFNumberIntType, &pid);
                        
                        CFDictionarySetValue(win_info, CFSTR("wid"), cf_wid);
                        CFDictionarySetValue(win_info, CFSTR("pid"), cf_pid);
                        
                        CFArrayAppendValue(suitable_windows, win_info);
                        
                        CFRelease(cf_wid);
                        CFRelease(cf_pid);
                        CFRelease(win_info);
                    }
                }
                CFRelease(iterator);
            }
            CFRelease(query);
        }
        CFRelease(window_list);
    }
    
    CFRelease(space_list);
    
    // Sort windows by ID for consistent ordering
    CFArraySortValues(suitable_windows,
                      CFRangeMake(0, CFArrayGetCount(suitable_windows)),
                      compare_windows_by_id,
                      NULL);
    
    return suitable_windows;
}

// MARK: - Connection Management
static BOOL is_connection_valid(NSConnection *conn) {
    if (!conn || !conn.isValid) return NO;
    
    @try {
        id root = [conn rootProxy];
        return root != nil;
    } @catch (NSException *exception) {
        BRLog(@"[BRWM] Connection validation failed: %@", exception.reason);
        return NO;
    }
}
#define kConnectionTimeout 0.25

static id get_window_proxy(NSConnection *conn) {
    if (!conn) return nil;
    
    @try {
        conn.replyTimeout = kConnectionTimeout;
        conn.requestTimeout = kConnectionTimeout;
        
        id root = [conn rootProxy];
        if (!root) return nil;
        
        if ([root respondsToSelector:@selector(isKindOfClass:)]) {
            @try {
                if ([root isKindOfClass:[BRPlaceHolderRoot class]]) return nil;
                if (![root isKindOfClass:[NSWindow class]]) return nil;
            } @catch (NSException *exception) {
                BRLog(@"[BRWM] Class check failed: %@", exception.reason);
                return nil;
            }
        } else {
            return nil;
        }
        
        return root;
        
    } @catch (NSException *exception) {
        BRLog(@"[BRWM] Proxy retrieval failed: %@", exception.reason);
        return nil;
    }
}

NSMutableDictionary<NSString *, NSConnection *> *connection_cache = nil;
void brwm_set_window_frame(uint32_t window_id, CGFloat x, CGFloat y, CGFloat width, CGFloat height) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        connection_cache = [[NSMutableDictionary alloc] init];
    });

    int connection = SLSMainConnectionID();
    int wid_cid = 0;
    if (SLSGetWindowOwner(connection, window_id, &wid_cid) != kCGErrorSuccess) {
        BRLog(@"[BRWM] Failed to get owner for window ID %u", window_id);
        return;
    }

    pid_t pid = 0;
    if (SLSConnectionGetPID(wid_cid, &pid) != kCGErrorSuccess) {
        BRLog(@"[BRWM] Failed to get PID for window ID %u", window_id);
        return;
    }

    char *identifier_cstr = format_executable_name_as_identifier(pid, window_id);
    if (!identifier_cstr) {
        BRLog(@"[BRWM] Failed to format identifier for window ID %u", window_id);
        return;
    }

    NSString *identifier = [NSString stringWithUTF8String:identifier_cstr];
    free(identifier_cstr);

    NSConnection *conn = connection_cache[identifier];
    if (!conn || ![conn isValid]) {
        conn = [NSConnection connectionWithRegisteredName:identifier host:nil];
        if (!conn || ![conn isValid]) {
            BRLog(@"[BRWM] Failed to connect to window %@ (ID %u)", identifier, window_id);
            return;
        }
        connection_cache[identifier] = conn;
    }

    id proxy = get_window_proxy(conn);
    if (!proxy) {
        BRLog(@"[BRWM] Failed to get proxy for window %@ (ID %u)", identifier, window_id);
        return;
    }

    NSRect target_frame = NSMakeRect(x, y, width, height);
    @try {
        [proxy animateToFrame:target_frame];
    } @catch (NSException *e) {
        BRLog(@"[BRWM] Exception setting frame for window %@ (ID %u): %@", identifier, window_id, e.reason);
    }
}

#pragma clang diagnostic pop
