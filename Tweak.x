#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/host_info.h>
#import <mach/mach_host.h>
#include <IOKit/IOKitLib.h>
#include <stdarg.h>

#define LOGPATH "/var/mobile/Library/Logs/freqmon.log"
#define DUMPPATH "/var/mobile/Library/Logs/freqmon-dump.log"

static void dlog(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    FILE *f = fopen(LOGPATH, "a");
    if (f) { vfprintf(f, fmt, ap); fputc('\n', f); fclose(f); }
    va_end(ap);
}
static void dump_line(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    FILE *f = fopen(DUMPPATH, "a");
    if (f) { vfprintf(f, fmt, ap); fputc('\n', f); fclose(f); }
    va_end(ap);
}
static void ensure_dump_started(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    FILE *f = fopen(DUMPPATH, "w");
    if (f) fclose(f);
    dlog("freqmon loaded, dumping discovery info...");
}

// ================= CPU usage (%) =================
static double cpu_usage(void) {
    static natural_t prev_total = 0, prev_idle = 0;
    static int inited = 0;
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &count) != KERN_SUCCESS) return 0;
    natural_t total = info.cpu_ticks[0] + info.cpu_ticks[1] + info.cpu_ticks[2] + info.cpu_ticks[3];
    natural_t idle = info.cpu_ticks[3];
    if (!inited) { prev_total = total; prev_idle = idle; inited = 1; return 0; }
    double dtotal = (double)(total - prev_total), didle = (double)(idle - prev_idle);
    prev_total = total; prev_idle = idle;
    if (dtotal <= 0) return 0;
    return (dtotal - didle) / dtotal * 100.0;
}

// ================= GPU utilization (%) =================
static double __attribute__((unused)) gpu_util(void) {
    io_iterator_t iter = 0;
    CFMutableDictionaryRef match = IOServiceMatching("AGXAccelerator");
    if (IOServiceGetMatchingServices(0, match, &iter) != KERN_SUCCESS) return -1;
    io_object_t entry;
    double val = -1;
    while ((entry = IOIteratorNext(iter))) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            CFDictionaryRef stats = CFDictionaryGetValue(props, CFSTR("PerformanceStatistics"));
            if (stats && CFGetTypeID(stats) == CFDictionaryGetTypeID()) {
                CFNumberRef n = CFDictionaryGetValue(stats, CFSTR("Device Utilization %"));
                if (n && CFGetTypeID(n) == CFNumberGetTypeID()) {
                    double v; if (CFNumberGetValue(n, kCFNumberDoubleType, &v)) { val = v; }
                }
            }
            CFRelease(props);
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iter);
    return val;
}

// ================= IOReport (dlopen, best effort) =================
typedef struct io_report_subscribe_s *io_report_subscribe_t;
typedef struct io_report_state_s *io_report_state_t;
typedef void *(*fn_IOReportCreateSubscription)(mach_port_t, CFDictionaryRef, CFDictionaryRef *, const char *, uint64_t, uint64_t, uint64_t);
typedef io_report_state_t (*fn_IOReportCreateSamples)(io_report_subscribe_t, io_report_state_t, uint64_t *);
typedef void (*fn_IOReportFreeSamples)(io_report_state_t);
typedef CFArrayRef (*fn_IOReportCopyAllChannels)(CFDictionaryRef);

static void *g_ioReport = NULL;
static fn_IOReportCreateSubscription g_createSub = NULL;
static fn_IOReportCreateSamples g_createSamples = NULL;
static fn_IOReportFreeSamples g_freeSamples = NULL;
static fn_IOReportCopyAllChannels g_copyAllChannels = NULL;

static void ioreport_init(void) {
    if (g_ioReport) return;
    g_ioReport = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW);
    if (!g_ioReport) return;
    g_createSub = (fn_IOReportCreateSubscription)dlsym(g_ioReport, "IOReportCreateSubscription");
    g_createSamples = (fn_IOReportCreateSamples)dlsym(g_ioReport, "IOReportCreateSamples");
    g_freeSamples = (fn_IOReportFreeSamples)dlsym(g_ioReport, "IOReportFreeSamples");
    g_copyAllChannels = (fn_IOReportCopyAllChannels)dlsym(g_ioReport, "IOReportCopyAllChannels");
}

// Discovery: dump all IOReport channel names + all relevant IORegistry props (incl. children)
static __attribute__((unused)) void run_discovery(void) {
    ensure_dump_started();
    ioreport_init();
    if (g_copyAllChannels) {
        CFArrayRef chans = g_copyAllChannels(NULL);
        if (chans) {
            CFIndex cnt = CFArrayGetCount(chans);
            dump_line("=== IOReport channels: %ld ===", (long)cnt);
            for (CFIndex i = 0; i < cnt; i++) {
                CFDictionaryRef ch = (CFDictionaryRef)CFArrayGetValueAtIndex(chans, i);
                if (!ch || CFGetTypeID(ch) != CFDictionaryGetTypeID()) continue;
                CFStringRef name = (CFStringRef)CFDictionaryGetValue(ch, CFSTR("ChannelName"));
                CFStringRef group = (CFStringRef)CFDictionaryGetValue(ch, CFSTR("Group"));
                CFStringRef unit = (CFStringRef)CFDictionaryGetValue(ch, CFSTR("Unit"));
                char nb[160] = {0}, gb[160] = {0}, ub[160] = {0};
                if (name) CFStringGetCString(name, nb, sizeof(nb), kCFStringEncodingUTF8);
                if (group) CFStringGetCString(group, gb, sizeof(gb), kCFStringEncodingUTF8);
                if (unit) CFStringGetCString(unit, ub, sizeof(ub), kCFStringEncodingUTF8);
                dump_line("ch[%ld] group=%s name=%s unit=%s", (long)i, gb, nb, ub);
            }
            CFRelease(chans);
        } else dump_line("IOReportCopyAllChannels returned NULL");
    } else dump_line("no IOReportCopyAllChannels");

    const char *classes[] = {"AGXAccelerator", "AppleARMIODevice", "AppleCLPC", "AppleARMPE", "AppleGPU", "IOGPU", "AppleH8", "AppleH7", "AppleSoc", NULL};
    for (int i = 0; classes[i]; i++) {
        io_iterator_t iter = 0;
        if (IOServiceGetMatchingServices(0, IOServiceMatching(classes[i]), &iter) != KERN_SUCCESS) continue;
        io_object_t entry; int n = 0;
        while ((entry = IOIteratorNext(iter)) && n < 3) {
            CFMutableDictionaryRef props = NULL;
            if (IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
                CFStringRef desc = CFCopyDescription(props);
                if (desc) {
                    char buf[4096];
                    if (CFStringGetCString(desc, buf, sizeof(buf), kCFStringEncodingUTF8))
                        dump_line("[%s #%d] %s", classes[i], n, buf);
                    CFRelease(desc);
                }
                CFRelease(props);
            }
            io_iterator_t cit = 0;
            IORegistryEntryGetChildIterator(entry, "IOService", &cit);
            if (cit) {
                io_object_t c; int cn = 0;
                while ((c = IOIteratorNext(cit)) && cn < 4) {
                    CFMutableDictionaryRef cp = NULL;
                    if (IORegistryEntryCreateCFProperties(c, &cp, kCFAllocatorDefault, 0) == KERN_SUCCESS && cp) {
                        CFStringRef cd = CFCopyDescription(cp);
                        if (cd) {
                            char b[2048];
                            if (CFStringGetCString(cd, b, sizeof(b), kCFStringEncodingUTF8))
                                dump_line("  [%s #%d] child#%d: %s", classes[i], n, cn, b);
                            CFRelease(cd);
                        }
                        CFRelease(cp);
                    }
                    IOObjectRelease(c); cn++;
                }
                IOObjectRelease(cit);
            }
            IOObjectRelease(entry); n++;
        }
        IOObjectRelease(iter);
    }
    dump_line("=== discovery done ===");
}

// ================= Floating window =================
static UIWindow *g_window;
static UILabel *g_label;

static void tick(void);

// ---- 选 scene：iOS 13+ 的窗口必须绑定 UIWindowScene，否则在 SpringBoard 里不显示 ----
static __weak UIWindowScene *g_cachedScene = nil;
static UIWindowScene *pick_scene(void) {
    if (g_cachedScene) return g_cachedScene;
    @try {
        UIWindowScene *any = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            if (!any) any = (UIWindowScene *)sc;
            if (sc.activationState == UISceneActivationStateForegroundActive)
                return (UIWindowScene *)sc;
        }
        if (any) return any;
    } @catch (__unused NSException *e) {}
    return nil;
}

static void create_window(void) {
    if (g_window) return;
    @autoreleasepool {
        UIWindowScene *scene = pick_scene();
        if (scene) g_cachedScene = scene;

        UIWindow *win = nil;
        if (scene) {
            @try {
                win = ((id(*)(id, SEL, id))objc_msgSend)([UIWindow alloc],
                        NSSelectorFromString(@"initWithWindowScene:"), scene);
            } @catch (NSException *e) { win = nil; }
        }
        if (!win) win = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
        if (!win.windowScene && scene) {
            SEL s2 = NSSelectorFromString(@"_setWindowScene:");
            if ([win respondsToSelector:s2]) ((void(*)(id, SEL, id))objc_msgSend)(win, s2, scene);
        }

        win.frame = [[UIScreen mainScreen] bounds];
        win.windowLevel = 5000.0;              // 高但绝不当 key window
        win.backgroundColor = [UIColor clearColor];
        win.rootViewController = nil;          // 避免接管 SpringBoard 的 key 追踪
        win.userInteractionEnabled = NO;       // 悬浮层不吃触摸
        win.hidden = NO;                       // 直接显示，不 makeKeyAndVisible（会死锁主线程！）
        g_window = win;

        UIView *bg = [[UIView alloc] initWithFrame:CGRectMake(8, 60, 150, 84)];
        bg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        bg.layer.cornerRadius = 10;
        bg.layer.masksToBounds = YES;
        [win addSubview:bg];

        g_label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 150, 84)];
        g_label.textAlignment = NSTextAlignmentCenter;
        g_label.numberOfLines = 5;
        g_label.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        g_label.textColor = [UIColor colorWithRed:0.4 green:1.0 blue:0.5 alpha:1.0];
        g_label.text = @"FreqMon OK\nCPU --%\nGPU --%";
        [bg addSubview:g_label];

        dlog("window created: scene=%@ level=%.0f visible=%d",
             scene ? @"yes" : @"NIL", (double)win.windowLevel, (int)(!win.hidden));

        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { tick(); }];
    }
}

static void tick(void) {
    @autoreleasepool {
        double cpu = cpu_usage();
        // GPU 暂时禁用（IOKit 调用可能导致崩溃，后续再启用）
        NSString *txt = [NSString stringWithFormat:@"CPU %4.0f%%\n%ld cores",
            cpu, (long)[[NSProcessInfo processInfo] processorCount]];
        g_label.text = txt;
    }
}

// ================= Entry =================
__attribute__((constructor))
static void freqmon_ctor(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) bid = [[NSProcessInfo processInfo] processName];
        dlog("constructor ran in %@ (pid %d)", bid ? bid : @"(unknown)", getpid());
        // 在 SpringBoard 里 mainBundle 可能是 UIKit，所以放宽判定：
        // 只要进程是 SpringBoard（按进程名）或 bundle id 匹配就继续
        NSString *pname = [[NSProcessInfo processInfo] processName];
        BOOL isSB = [bid isEqualToString:@"com.apple.springboard"]
                 || [pname isEqualToString:@"SpringBoard"]
                 || [bid isEqualToString:@"com.apple.UIKit"];
        dlog("isSB=%d bid=%@ pname=%@", (int)isSB, bid, pname);
        if (isSB) {
            // 先只做窗口创建，discovery 暂时禁用（IOKit 调用可能导致 SpringBoard 崩溃）
            // dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            //     @autoreleasepool { run_discovery(); }
            // });
            static int tries = 0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (g_window) return;
                create_window();
                if (!g_window && tries++ < 40) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (g_window) return;
                        create_window();
                    });
                }
            });
        }
    }
}
