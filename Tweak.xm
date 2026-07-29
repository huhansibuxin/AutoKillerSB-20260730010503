#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <dispatch/dispatch.h>
#import <signal.h>

// ---- FBProcess / FBProcessManager ----
@interface FBProcess : NSObject
@property (readonly) int pid;
@property (readonly, copy) NSString *bundleIdentifier;
@property (readonly, copy) NSString *executablePath;
@end

@interface FBProcessState : NSObject
@property (readonly, getter=isRunning) BOOL running;
@property (readonly, getter=isForeground) BOOL foreground;
@end

@interface FBProcessManager : NSObject
+ (instancetype)sharedInstance;
- (FBProcess *)processForPID:(int)pid;
- (FBProcess *)processForProcessIdentity:(id)identity;
- (NSArray<FBProcess *> *)allProcesses;
@end

// ---- log ----
static NSString *_logPath;

static void _sb_log(NSString *msg) {
    if (!_logPath) {
        NSString *doc = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        _logPath = [doc stringByAppendingPathComponent:@"autokiller-sb.log"];
    }
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
        [NSDateFormatter localizedStringFromDate:[NSDate date]
            dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle], msg];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:_logPath];
    if (!fh) {
        [line writeToFile:_logPath atomically:NO encoding:NSUTF8StringEncoding error:nil];
    } else {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// ---- state ----
static int _alipayPid = 0;
static dispatch_source_t _killTimer;
static const uint64_t kBgDelaySec = 60;

static void _startTimer(void) {
    if (_killTimer) return;
    _sb_log([NSString stringWithFormat:@"starting %llus timer for PID %d", kBgDelaySec, _alipayPid]);

    _killTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    dispatch_source_set_timer(_killTimer,
        dispatch_time(DISPATCH_TIME_NOW, kBgDelaySec * NSEC_PER_SEC),
        DISPATCH_TIME_FOREVER, 0);
    dispatch_source_set_event_handler(_killTimer, ^{
        _sb_log([NSString stringWithFormat:@"timer fired, killing PID %d", _alipayPid]);
        if (_alipayPid > 0) {
            kill(_alipayPid, SIGKILL);
        }
        _killTimer = nil;
    });
    dispatch_resume(_killTimer);
}

static void _cancelTimer(void) {
    if (!_killTimer) return;
    _sb_log(@"cancelling timer");
    dispatch_source_cancel(_killTimer);
    _killTimer = nil;
}

static void _cleanup(void) {
    _cancelTimer();
    _alipayPid = 0;
}

// ---- hook FBProcessManager ----
%hook FBProcessManager

- (void)_noteProcess:(FBProcess *)process stateDidChangeFromState:(FBProcessState *)fromState toState:(FBProcessState *)toState {
    %orig;

    if (!process) return;

    NSString *bid = process.bundleIdentifier;
    if (!bid) bid = process.executablePath;

    if (![bid isEqualToString:@"com.alipay.iphoneclient"]) return;

    int pid = process.pid;
    BOOL wasFg = fromState.isForeground;
    BOOL isFg  = toState.isForeground;
    BOOL wasRunning = fromState.isRunning;
    BOOL isRunning  = toState.isRunning;

    _sb_log([NSString stringWithFormat:@"alipay PID=%d: fg %d→%d  running %d→%d",
        pid, wasFg, isFg, wasRunning, isRunning]);

    // process died / no longer running
    if (wasRunning && !isRunning) {
        _sb_log([NSString stringWithFormat:@"alipay PID %d exited", pid]);
        if (pid == _alipayPid) _cleanup();
        return;
    }

    // newly spawned, ignore if already tracking
    if (!wasRunning && isRunning) {
        _sb_log([NSString stringWithFormat:@"alipay PID %d spawned", pid]);
        if (_alipayPid != 0 && _alipayPid != pid) {
            // old PID gone, switch
            _cleanup();
        }
        _alipayPid = pid;
        if (!isFg) {
            // launched into background (push/location/etc)
            _sb_log(@"background launch detected");
            _startTimer();
        }
        return;
    }

    // foreground → background
    if (wasFg && !isFg && isRunning) {
        _sb_log(@"alipay entered background");
        _alipayPid = pid;
        _startTimer();
        return;
    }

    // background → foreground
    if (!wasFg && isFg && isRunning) {
        _sb_log(@"alipay entered foreground");
        if (pid == _alipayPid) _cancelTimer();
        _alipayPid = pid;
        return;
    }

    // alipay still running, still background, but we might have missed the transition
    if (!isFg && isRunning && _alipayPid == 0) {
        _sb_log(@"alipay in background without timer, starting");
        _alipayPid = pid;
        _startTimer();
    }
}

%end

%ctor {
    _sb_log(@"injected into SpringBoard");
}
