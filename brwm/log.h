//
//  log.h
//  brwm
//
//  Created by bedtime on 7/23/25.
//

#define BRLog(fmt, ...) do { \
    NSString *logStr = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
    NSString *logPath = @"/tmp/brwm.log"; \
    NSFileHandle *fileHandle = [NSFileHandle fileHandleForWritingAtPath:logPath]; \
    if (!fileHandle) { \
        [logStr writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil]; \
    } else { \
        [fileHandle seekToEndOfFile]; \
        [fileHandle writeData:[[logStr stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]]; \
        [fileHandle closeFile]; \
    } \
} while(0)
