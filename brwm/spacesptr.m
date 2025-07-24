//
//  spaces.m
//  brwm
//
//  Created by bedtime on 7/23/25.
//
//  This file aggressively hooks NSObject's +alloc method to intercept the
//  allocation of the Dock.Spaces Swift class instance (and maybe other objects).
//
//  Use this with caution and only when you have no safer alternative.
//

#import <libproc.h>
#import <objc/runtime.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

#import "log.h"

// Global storage for the captured instance
static id gDockSpacesInstance = nil;

id GetSpaces(void) {
    return gDockSpacesInstance;
}

__attribute__((constructor))
static void hook_NSObject_init_for_spaces(void) {
    // Ensure this only runs inside the Dock process
    char pathbuf[PROC_PIDPATHINFO_MAXSIZE];
    if (proc_pidpath(getpid(), pathbuf, sizeof(pathbuf)) <= 0) {
        return;
    }
    
    const char *basename = strrchr(pathbuf, '/');
    const char *executable = basename ? basename + 1 : pathbuf;
    if (strcmp(executable, "Dock") != 0) {
        return;
    }
    
    Class nsObjectClass = [NSObject class];
    SEL initSel = @selector(init);
    Method origInitMethod = class_getInstanceMethod(nsObjectClass, initSel);
    IMP origInitIMP = method_getImplementation(origInitMethod);

    id (*origInitFunc)(id, SEL) = (id (*)(id, SEL))origInitIMP;

    IMP newInitIMP = imp_implementationWithBlock(^id(id self, SEL _cmd) {
        // If already captured, just call original
        if (gDockSpacesInstance) {
            return origInitFunc(self, _cmd);
        }

        const char *className = class_getName(object_getClass(self));
        if (strcmp(className, "Dock.Spaces") == 0 ||
            strcmp(className, "Spaces") == 0) {
            BRLog(@"[BRWM] Captured instance: %s.", className);
            id instance = origInitFunc(self, _cmd);
            gDockSpacesInstance = instance;
            return instance;
        }

        return origInitFunc(self, _cmd);
    });

    method_setImplementation(origInitMethod, newInitIMP);
}
