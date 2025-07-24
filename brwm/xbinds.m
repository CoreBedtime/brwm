//
//  keybinds.m
//  brwm
//
//  Created by bedtime on 7/23/25.
//

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <JavaScriptCore/JavaScriptCore.h>

#import "log.h"

@interface BRKeyBind : NSObject
@property CGKeyCode keyCode;
@property CGEventFlags requiredFlags;
@property JSValueRef jsFunction;
@end

@implementation BRKeyBind
// shut up linker
@end

CFMachPortRef gEventTap = NULL;
CFRunLoopSourceRef gRunLoopSource = NULL;
NSArray<BRKeyBind *> *gKeyBindings = nil;

extern JSGlobalContextRef g_js_context;

// Function to execute a keybinding's JavaScript function
void execute_keybinding_function(JSValueRef jsFunction) {
    if (!g_js_context || !jsFunction || JSValueIsUndefined(g_js_context, jsFunction)) {
        BRLog(@"[BRWM] Invalid JavaScript function for keybinding");
        return;
    }
    
    JSValueRef exception = NULL;
    JSObjectRef functionObj = JSValueToObject(g_js_context, jsFunction, &exception);
    
    if (exception) {
        BRLog(@"[BRWM] Error converting keybinding function to object");
        return;
    }
    
    JSValueRef result = JSObjectCallAsFunction(g_js_context, functionObj, NULL, 0, NULL, &exception);
    
    if (exception) {
        JSStringRef exceptionString = JSValueToStringCopy(g_js_context, exception, NULL);
        size_t maxSize = JSStringGetMaximumUTF8CStringSize(exceptionString);
        char *buffer = (char *)malloc(maxSize);
        if (buffer) {
            JSStringGetUTF8CString(exceptionString, buffer, maxSize);
            BRLog(@"[BRWM] Keybinding JavaScript error: %@", [NSString stringWithUTF8String:buffer]);
            free(buffer);
        }
        JSStringRelease(exceptionString);
    }
}

CGEventRef EventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *userInfo) {
    if (!g_js_context) {
        return event;
    }
    
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        BRLog(@"[!] Event Tap Disabled (type %d). Re-enabling...", type);
        if (gEventTap != NULL) {
            CGEventTapEnable(gEventTap, true);
            BRLog(@"[+] Event Tap Re-enabled.");
        }
        return event; // Pass the event along
    }

    // We are only interested in key down events for triggering actions
    if (type != kCGEventKeyDown) {
        return event; // Pass the event along
    }

    CGKeyCode keyCode = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    // Get flags *without* device-dependent bits, which can vary (like caps lock state)
    CGEventFlags flags = CGEventGetFlags(event) & 0xffff0000;

    bool consumeEvent = false;

    BRLog(@"[BRWM] Checking keybindings for keyCode=%d, flags=0x%x (total bindings: %lu)",
          keyCode, (unsigned int)flags, (unsigned long)gKeyBindings.count);

    for (BRKeyBind * binding in gKeyBindings) {
        if (keyCode == binding.keyCode) {
            // Check if all required modifier flags are present
            if ((flags & binding.requiredFlags) == binding.requiredFlags) {
                BRLog(@"[+] Matched keybinding: keyCode=%d, flags=0x%x", keyCode, (unsigned int)binding.requiredFlags);
                
                // Execute the JavaScript function directly
                execute_keybinding_function(binding.jsFunction);
                
                consumeEvent = true;
                break;
            } else {
                BRLog(@"[BRWM] Key matched but modifiers didn't: required=0x%x, actual=0x%x",
                      (unsigned int)binding.requiredFlags, (unsigned int)flags);
            }
        }
    }
    
    if (!consumeEvent) {
        BRLog(@"[BRWM] No matching keybinding found for keyCode=%d, flags=0x%x", keyCode, (unsigned int)flags);
    }
    
    return consumeEvent ? NULL : event;
}

bool setup_tap_backend(void) {
    // Define which events we want to tap (only key down needed for bindings)
    // Add kCGEventFlagsChanged if you need to react to modifier key presses alone.
    CGEventMask eventMask = CGEventMaskBit(kCGEventKeyDown); // | CGEventMaskBit(kCGEventFlagsChanged);

    // Create the event tap
    gEventTap = CGEventTapCreate(kCGHIDEventTap,           // Tap HID system events
                                 kCGHeadInsertEventTap,    // Insert before other taps
                                 kCGEventTapOptionDefault, // Default behavior (listen-only is kCGEventTapOptionListenOnly)
                                 eventMask,                // Mask of events to tap
                                 EventTapCallback,         // Callback function
                                 NULL);                    // User info pointer (not used here)

    if (!gEventTap) {
        BRLog(@"[!] FATAL: Failed to create event tap. Check permissions and system integrity.");
        // This could be due to permissions issues not caught by AXIsProcessTrusted,
        // or other system-level problems.
        return false;
    }

    // Create a run loop source for the event tap
    gRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gEventTap, 0);
    if (!gRunLoopSource) {
        BRLog(@"[!] FATAL: Failed to create run loop source for event tap.");
        CFRelease(gEventTap);
        gEventTap = NULL;
        return false;
    }

    // Add the source to the current run loop (main thread's run loop)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), gRunLoopSource, kCFRunLoopCommonModes);

    // Enable the event tap
    CGEventTapEnable(gEventTap, true);
    BRLog(@"[+] Event Tap enabled successfully.");

    return true;
}
