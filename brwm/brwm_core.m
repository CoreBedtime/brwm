//
//  brwm_core.m
//  brwm
//
//  Created by bedtime on 7/19/25.
//

#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <libproc.h>
#import <CoreGraphics/CoreGraphics.h>
#import <JavaScriptCore/JavaScriptCore.h>
#import <Carbon/Carbon.h> 
#import <signal.h>

#import "log.h"

@interface BRKeyBind : NSObject
@property CGKeyCode keyCode;
@property CGEventFlags requiredFlags;
@property JSValueRef jsFunction;
@end
extern id GetSpaces(void);
extern void brwm_set_window_frame(uint32_t window_id, CGFloat x, CGFloat y, CGFloat width, CGFloat height);
extern CFMutableArrayRef collect_tileable_windows(uint64_t space_id);
extern CGDirectDisplayID CurrentDisplayId(void);

extern bool setup_tap_backend(void);

extern int SLSMainConnectionID(void);
extern uint64_t SLSGetActiveSpace(int cid);
extern CFStringRef SLSCopyManagedDisplayForSpace(int cid, uint64_t sid);
extern void SLSShowSpaces(int cid, CFArrayRef space_list);
extern void SLSHideSpaces(int cid, CFArrayRef space_list);
extern void SLSManagedDisplaySetCurrentSpace(int cid, CFStringRef display_ref, uint64_t sid);

extern NSArray<BRKeyBind *> *gKeyBindings;

static CGFloat g_screen_width = 1440;
static CGFloat g_screen_height = 900;

JSGlobalContextRef g_js_context = NULL;

@protocol DockSpaces
- (BOOL)switchToUserSpace:(int32_t)spid;
- (int32_t)spid;
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

JSValueRef brwm_space_id_list_js(JSContextRef ctx,
                        JSObjectRef function,
                        JSObjectRef thisObject,
                        size_t argumentCount,
                        const JSValueRef arguments[],
                        JSValueRef *exception) {
    id spaces_ptr = GetSpaces();
    if (!spaces_ptr) {
        return JSValueMakeUndefined(ctx);
    }
     
    NSArray *userSpaces = [spaces_ptr performSelector:NSSelectorFromString(@"currentSpaces")];
    if (![userSpaces isKindOfClass:[NSArray class]]) {
        return JSValueMakeUndefined(ctx);
    }

    size_t count = userSpaces.count;
    JSValueRef *values = (JSValueRef *)malloc(sizeof(JSValueRef) * count);

    for (NSUInteger i = 0; i < count; i++) {
        id space = userSpaces[i];
        if ([space respondsToSelector:@selector(spid)]) {
            int32_t spid =  [space spid];
            values[i] = JSValueMakeNumber(ctx, (double)spid);
        } else {
            values[i] = JSValueMakeUndefined(ctx);
        }
    }

    JSObjectRef jsArray = JSObjectMakeArray(ctx, count, values, exception);
    free(values);

    return jsArray;
}

JSValueRef brwm_space_js(JSContextRef ctx,
                        JSObjectRef function,
                        JSObjectRef thisObject,
                        size_t argumentCount,
                        const JSValueRef arguments[],
                        JSValueRef *exception) {
    id spaces_ptr = GetSpaces();
    if (!spaces_ptr) {
        return JSValueMakeUndefined(ctx);
    }
     
    int32_t spid = 0;
     
    if (argumentCount > 0) {
        spid = JSValueToInt32(ctx, arguments[0], NULL);
    }
    [spaces_ptr switchToUserSpace:spid];
    return JSValueMakeUndefined(ctx);
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

JSValueRef brwm_add_keybind_js(JSContextRef ctx,
                               JSObjectRef function,
                               JSObjectRef thisObject,
                               size_t argumentCount,
                               const JSValueRef arguments[],
                               JSValueRef* exception) {
    if (argumentCount < 3) {
        *exception = JSValueMakeString(ctx, JSStringCreateWithUTF8CString("addKeybind requires 3 arguments: keyCode, modifiers, function"));
        return JSValueMakeUndefined(ctx);
    }
    
    if (!JSValueIsNumber(ctx, arguments[0]) || !JSValueIsNumber(ctx, arguments[1]) || !JSValueIsObject(ctx, arguments[2])) {
        *exception = JSValueMakeString(ctx, JSStringCreateWithUTF8CString("addKeybind arguments must be: number, number, function"));
        return JSValueMakeUndefined(ctx);
    }
    
    // Check if the third argument is actually a function
    JSObjectRef functionObj = JSValueToObject(ctx, arguments[2], exception);
    if (*exception) {
        return JSValueMakeUndefined(ctx);
    }
    
    if (!JSObjectIsFunction(ctx, functionObj)) {
        *exception = JSValueMakeString(ctx, JSStringCreateWithUTF8CString("Third argument must be a JavaScript function"));
        return JSValueMakeUndefined(ctx);
    }

    CGKeyCode keyCode = (CGKeyCode)JSValueToNumber(ctx, arguments[0], NULL);
    CGEventFlags modifiers = (CGEventFlags)JSValueToNumber(ctx, arguments[1], NULL);
    
    JSStringRef jsFuncName = JSValueToStringCopy(ctx, arguments[2], NULL);
    size_t maxSize = JSStringGetMaximumUTF8CStringSize(jsFuncName);
    char *buffer = malloc(maxSize);
    if (!buffer) {
        JSStringRelease(jsFuncName);
        *exception = JSValueMakeString(ctx, JSStringCreateWithUTF8CString("Memory allocation failed"));
        return JSValueMakeUndefined(ctx);
    }
    
    JSStringGetUTF8CString(jsFuncName, buffer, maxSize);
    NSString *functionName = [NSString stringWithUTF8String:buffer];
    free(buffer);
    JSStringRelease(jsFuncName);
    
    // Create the KeyBinding struct
    BRKeyBind * binding = [[BRKeyBind alloc] init];
    binding.keyCode = keyCode;
    binding.requiredFlags = modifiers;
    
    JSValueProtect(ctx, arguments[2]);
    binding.jsFunction = arguments[2];
    
    if (gKeyBindings == nil) {
        gKeyBindings = @[binding];
    } else {
        NSMutableArray *mutableBindings = [gKeyBindings mutableCopy];
        [mutableBindings addObject:binding];
        gKeyBindings = [mutableBindings copy];
    }
    
    BRLog(@"[BRWM] Added keybinding: keyCode=%d, modifiers=0x%x, function=%@", keyCode, (unsigned int)modifiers, functionName);
    
    return JSValueMakeUndefined(ctx);
}

NSDictionary<NSString *, NSNumber *> *GetKeycodeMap() {
    static NSDictionary<NSString *, NSNumber *> *map = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        map = @{
            @"a": @(kVK_ANSI_A), @"b": @(kVK_ANSI_B), @"c": @(kVK_ANSI_C),
            @"d": @(kVK_ANSI_D), @"e": @(kVK_ANSI_E), @"f": @(kVK_ANSI_F),
            @"g": @(kVK_ANSI_G), @"h": @(kVK_ANSI_H), @"i": @(kVK_ANSI_I),
            @"j": @(kVK_ANSI_J), @"k": @(kVK_ANSI_K), @"l": @(kVK_ANSI_L),
            @"m": @(kVK_ANSI_M), @"n": @(kVK_ANSI_N), @"o": @(kVK_ANSI_O),
            @"p": @(kVK_ANSI_P), @"q": @(kVK_ANSI_Q), @"r": @(kVK_ANSI_R),
            @"s": @(kVK_ANSI_S), @"t": @(kVK_ANSI_T), @"u": @(kVK_ANSI_U),
            @"v": @(kVK_ANSI_V), @"w": @(kVK_ANSI_W), @"x": @(kVK_ANSI_X),
            @"y": @(kVK_ANSI_Y), @"z": @(kVK_ANSI_Z),
            @"0": @(kVK_ANSI_0), @"1": @(kVK_ANSI_1), @"2": @(kVK_ANSI_2),
            @"3": @(kVK_ANSI_3), @"4": @(kVK_ANSI_4), @"5": @(kVK_ANSI_5),
            @"6": @(kVK_ANSI_6), @"7": @(kVK_ANSI_7), @"8": @(kVK_ANSI_8),
            @"9": @(kVK_ANSI_9),
            @"`": @(kVK_ANSI_Grave), @"-": @(kVK_ANSI_Minus), @"=": @(kVK_ANSI_Equal),
            @"[": @(kVK_ANSI_LeftBracket), @"]": @(kVK_ANSI_RightBracket),
            @"\\": @(kVK_ANSI_Backslash), @";": @(kVK_ANSI_Semicolon),
            @"'": @(kVK_ANSI_Quote), @",": @(kVK_ANSI_Comma), @".": @(kVK_ANSI_Period),
            @"/": @(kVK_ANSI_Slash),
            // Add other keys if needed (e.g., Space, Tab, Enter)
            @"space": @(kVK_Space),
            @"tab": @(kVK_Tab),
            @"enter": @(kVK_Return), // Or kVK_ANSI_KeypadEnter
            @"escape": @(kVK_Escape),
        };
    });
    return map;
}

JSValueRef brwm_get_key_constants_js(JSContextRef ctx, JSObjectRef function, JSObjectRef thisObject, size_t argumentCount, const JSValueRef arguments[], JSValueRef* exception) {
    JSObjectRef constants = JSObjectMake(ctx, NULL, NULL);
    
    // Use the keycode map
    NSDictionary *keyMap = GetKeycodeMap();
    for (NSString *key in keyMap) {
        NSNumber *value = keyMap[key];
        JSStringRef jsKey = JSStringCreateWithCFString((__bridge CFStringRef)key.uppercaseString);
        JSObjectSetProperty(ctx, constants, jsKey, JSValueMakeNumber(ctx, value.intValue), kJSPropertyAttributeNone, NULL);
        JSStringRelease(jsKey);
    }
    
    // Modifiers
    JSObjectRef mod = JSObjectMake(ctx, NULL, NULL);
    struct { const char *name; CGEventFlags flag; } mods[] = {
        {"CMD", kCGEventFlagMaskCommand}, {"SHIFT", kCGEventFlagMaskShift},
        {"ALT", kCGEventFlagMaskAlternate}, {"CTRL", kCGEventFlagMaskControl}
    };
    
    for (int i = 0; i < sizeof(mods)/sizeof(*mods); i++) {
        JSStringRef name = JSStringCreateWithUTF8CString(mods[i].name);
        JSObjectSetProperty(ctx, mod, name, JSValueMakeNumber(ctx, mods[i].flag), kJSPropertyAttributeNone, NULL);
        JSStringRelease(name);
    }
    
    JSStringRef modKey = JSStringCreateWithUTF8CString("MOD");
    JSObjectSetProperty(ctx, constants, modKey, mod, kJSPropertyAttributeNone, NULL);
    JSStringRelease(modKey);
    
    return constants;
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
        { "traverseSpace",      brwm_space_js },
        { "spaceList",      brwm_space_id_list_js },
        { "addKeybind",      brwm_add_keybind_js },
        { "getKeyConstants",      brwm_get_key_constants_js },
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
    
    dispatch_async(dispatch_get_main_queue(), ^{
        setup_tap_backend();
    });
    
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
