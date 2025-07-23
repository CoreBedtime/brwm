//
//  brwm_core.m
//  brwm
//
//  Created by bedtime on 7/19/25.
//

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <libproc.h>
#import <CoreGraphics/CoreGraphics.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <signal.h>

#import "log.h"

extern id GetSpaces(void);
extern void brwm_set_window_frame(uint32_t window_id, CGFloat x, CGFloat y, CGFloat width, CGFloat height);
extern CFMutableArrayRef collect_tileable_windows(uint64_t space_id);

extern int SLSMainConnectionID(void);
extern uint64_t SLSGetActiveSpace(int cid);

static CGFloat g_screen_width = 1440;
static CGFloat g_screen_height = 900;
static JSGlobalContextRef g_js_context = NULL;

@protocol DockSpaces
- (BOOL)switchToNextSpace:(BOOL)arg;
- (BOOL)switchToPreviousSpace:(BOOL)arg;
@end


JSValueRef _WindowArrayToJSArray(CFArrayRef array, JSContextRef ctx) {
    if (!array || !ctx) return JSValueMakeUndefined(ctx);

    CFIndex count = CFArrayGetCount(array);
    JSValueRef* jsValues = malloc(sizeof(JSValueRef) * count);

    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(array, i);

        CFNumberRef cf_wid = CFDictionaryGetValue(dict, CFSTR("wid"));
        CFNumberRef cf_pid = CFDictionaryGetValue(dict, CFSTR("pid"));

        int wid = 0, pid = 0;
        if (cf_wid) CFNumberGetValue(cf_wid, kCFNumberIntType, &wid);
        if (cf_pid) CFNumberGetValue(cf_pid, kCFNumberIntType, &pid);

        JSObjectRef jsObj = JSObjectMake(ctx, NULL, NULL);
        JSStringRef widKey = JSStringCreateWithUTF8CString("wid");
        JSStringRef pidKey = JSStringCreateWithUTF8CString("pid");

        JSObjectSetProperty(ctx, jsObj, widKey, JSValueMakeNumber(ctx, wid), kJSPropertyAttributeNone, NULL);
        JSObjectSetProperty(ctx, jsObj, pidKey, JSValueMakeNumber(ctx, pid), kJSPropertyAttributeNone, NULL);

        JSStringRelease(widKey);
        JSStringRelease(pidKey);

        jsValues[i] = jsObj;
    }

    JSObjectRef jsArray = JSObjectMakeArray(ctx, count, jsValues, NULL);
    free(jsValues);
    return jsArray;
}

static void initialize_screen_dimensions(void) {
    CGDirectDisplayID display = CGMainDisplayID();
    g_screen_width = CGDisplayPixelsWide(display);
    g_screen_height = CGDisplayPixelsHigh(display);
    BRLog(@"[BRWM] Screen initialized: %.0fx%.0f", g_screen_width, g_screen_height);
}

static void setup_signal_handlers(void) {
    signal(SIGABRT, SIG_IGN);
}

JSValueRef brwm_set_window_frame_js(JSContextRef ctx,
                                    JSObjectRef function,
                                    JSObjectRef thisObject,
                                    size_t argumentCount,
                                    const JSValueRef arguments[],
                                    JSValueRef* exception) {
    if (argumentCount < 5) {
        *exception = JSValueMakeString(ctx, JSStringCreateWithUTF8CString("setWindowFrame requires 5 arguments: windowId, x, y, width, height"));
        return JSValueMakeUndefined(ctx);
    }
    if (!JSValueIsNumber(ctx, arguments[0]) || !JSValueIsNumber(ctx, arguments[1]) ||
        !JSValueIsNumber(ctx, arguments[2]) || !JSValueIsNumber(ctx, arguments[3]) ||
        !JSValueIsNumber(ctx, arguments[4])) {
        *exception = JSValueMakeString(ctx, JSStringCreateWithUTF8CString("All arguments to setWindowFrame must be numbers"));
        return JSValueMakeUndefined(ctx);
    }

    uint32_t window_id = (uint32_t)JSValueToNumber(ctx, arguments[0], NULL);
    double x = JSValueToNumber(ctx, arguments[1], NULL);
    double y = JSValueToNumber(ctx, arguments[2], NULL);
    double width = JSValueToNumber(ctx, arguments[3], NULL);
    double height = JSValueToNumber(ctx, arguments[4], NULL);

    brwm_set_window_frame(window_id, x, y, width, height);

    return JSValueMakeUndefined(ctx); // Or return success status
}

JSValueRef brwm_get_windows_js(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef* exception) {
    // Optionally get space_id from arguments[0] if provided, otherwise use active space
    uint64_t current_space = SLSGetActiveSpace(SLSMainConnectionID());
    CFMutableArrayRef windows_cf = collect_tileable_windows(current_space);

    if (!windows_cf) {
        // Return empty array or throw JS exception
        *exception = JSValueMakeString(ctx, JSStringCreateWithUTF8CString("Failed to collect windows"));
        return JSValueMakeUndefined(ctx);
    }

    JSObjectRef jsArray = _WindowArrayToJSArray((CFArrayRef)windows_cf, ctx);
    CFRelease(windows_cf);
    return jsArray;
}

JSValueRef brwm_get_screen_size_js(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef* exception) {
    // Create a JS object { width: ..., height: ... }
    JSObjectRef sizeObj = JSObjectMake(ctx, NULL, NULL);
    JSStringRef widthKey = JSStringCreateWithUTF8CString("width");
    JSStringRef heightKey = JSStringCreateWithUTF8CString("height");

    JSObjectSetProperty(ctx, sizeObj, widthKey, JSValueMakeNumber(ctx, g_screen_width), kJSPropertyAttributeNone, NULL);
    JSObjectSetProperty(ctx, sizeObj, heightKey, JSValueMakeNumber(ctx, g_screen_height), kJSPropertyAttributeNone, NULL);

    JSStringRelease(widthKey);
    JSStringRelease(heightKey);
    return sizeObj;
}

JSValueRef brwm_space_js(JSContextRef ctx,
                                        JSObjectRef function,
                                        JSObjectRef thisObject,
                                        size_t argumentCount,
                                        const JSValueRef arguments[],
                                        JSValueRef *exception) {
    id spaces_ptr = GetSpaces();
    NSArray *spaces = [spaces_ptr performSelector:NSSelectorFromString(@"displays")];
    BRLog(@"%s", spaces.description.UTF8String);
    
    size_t count = [spaces count];
    JSValueRef* jsValues = malloc(sizeof(JSValueRef) * count);

    for (NSUInteger i = 0; i < count; i++) {
        id item = [spaces objectAtIndex:i];
        NSString *desc = [item description];
        JSStringRef jsStr = JSStringCreateWithCFString((__bridge CFStringRef)desc);
        jsValues[i] = JSValueMakeString(ctx, jsStr);
        JSStringRelease(jsStr);
    }

    JSObjectRef jsArray = JSObjectMakeArray(ctx, count, jsValues, exception);
    free(jsValues);
    return jsArray;
}

JSValueRef brwm_sleep_js(JSContextRef ctx,
                         JSObjectRef function,
                         JSObjectRef thisObject,
                         size_t argumentCount,
                         const JSValueRef arguments[],
                         JSValueRef* exception) {
    if (argumentCount < 1 || !JSValueIsNumber(ctx, arguments[0])) {
        *exception = JSValueMakeString(ctx, JSStringCreateWithUTF8CString("sleep(ms) requires 1 numeric argument (milliseconds)"));
        return JSValueMakeUndefined(ctx);
    }

    double milliseconds = JSValueToNumber(ctx, arguments[0], NULL);
    if (milliseconds < 0) milliseconds = 0;

    useconds_t microseconds = (useconds_t)(milliseconds * 1000);
    usleep(microseconds);

    return JSValueMakeUndefined(ctx);
}

static void setup_javascript_context(void) {
    g_js_context = JSGlobalContextCreate(NULL);
    if (!g_js_context) {
        BRLog(@"[BRWM] Failed to create JavaScript context");
        return;
    }

    JSObjectRef global = JSContextGetGlobalObject(g_js_context);

    struct {
        const char *name;
        JSObjectCallAsFunctionCallback func;
    } bindings[] = {
        { "getWindows",      brwm_get_windows_js },
        { "getScreenSize",   brwm_get_screen_size_js },
        { "setWindowFrame",  brwm_set_window_frame_js },
        { "sleep", brwm_sleep_js },
        { "pokeSpace",      brwm_space_js },
    };

    for (int i = 0; i < sizeof(bindings) / sizeof(*bindings); i++) {
        JSStringRef jsName = JSStringCreateWithUTF8CString(bindings[i].name);
        JSObjectRef jsFunc = JSObjectMakeFunctionWithCallback(g_js_context, jsName, bindings[i].func);
        JSObjectSetProperty(g_js_context, global, jsName, jsFunc, kJSPropertyAttributeNone, NULL);
        JSStringRelease(jsName);
    }

    BRLog(@"[BRWM] JavaScript context initialized and API exposed.");
}

static void load_and_run_javascript_config(NSString *configPath) {
    if (!g_js_context) {
        g_js_context = JSGlobalContextCreate(NULL);
        setup_javascript_context();
    }
    
    NSError *error = nil;
    NSString *scriptContent = [NSString stringWithContentsOfFile:configPath encoding:NSUTF8StringEncoding error:&error];
    if (error || !scriptContent) {
        BRLog(@"[BRWM] Failed to load JavaScript config from %@: %@", configPath, error.localizedDescription);
        return;
    }

    JSStringRef scriptJS = JSStringCreateWithCFString((__bridge CFStringRef)scriptContent);
    JSValueRef jsException = NULL;
    JSValueRef result = JSEvaluateScript(g_js_context, scriptJS, NULL, NULL, 0, &jsException);

    if (jsException) {
        // Convert JS exception to string and log
        JSStringRef exceptionString = JSValueToStringCopy(g_js_context, jsException, NULL);
        size_t maxSize = JSStringGetMaximumUTF8CStringSize(exceptionString);
        char *buffer = (char *)malloc(maxSize);
        if (buffer) {
            JSStringGetUTF8CString(exceptionString, buffer, maxSize);
            BRLog(@"[BRWM] JavaScript error: %@", [NSString stringWithUTF8String:buffer]);
            free(buffer);
        }
        JSStringRelease(exceptionString);
    } else {
        BRLog(@"[BRWM] JavaScript config loaded and executed successfully.");
        // Optionally handle the result if needed
    }

    JSStringRelease(scriptJS);
}

// MARK: - Initialization
static void initialize_window_manager(void) {
    char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(getpid(), pathbuf, sizeof(pathbuf)) <= 0) {
        return;
    }
    
    const char *basename = strrchr(pathbuf, '/');
    const char *executable = basename ? basename + 1 : pathbuf;
    
    if (strcmp(executable, "Dock") != 0) {
        return;
    }
    
    BRLog(@"[BRWM] Initializing window manager in Dock process");
    
    setup_signal_handlers();
    initialize_screen_dimensions();
    load_and_run_javascript_config(@"/Users/bedtime/Developer/brwm/p8.js");
}
 
__attribute__((constructor))
static void brwm_constructor(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        initialize_window_manager();
    });
}
