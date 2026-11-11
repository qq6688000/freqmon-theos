// FreqMon 1.0.16 - IOReport real frequency reading (based on mactop's verified logic)
// 关键：直接从 IOReport 的 CPU Complex Performance States / GPU Performance States
// 读当前频率，状态名含数字则直接用，否则用 IORegistry voltage-states 频率表。
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

#define DUMPPATH "/var/mobile/Library/Logs/freqmon-dump.log"

// ===== 日志（统一写 dump 文件）=====
static __attribute__((unused)) void dump_line(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    FILE *f = fopen(DUMPPATH, "a");
    if (f) { vfprintf(f, fmt, ap); fputc('\n', f); fclose(f); }
    va_end(ap);
}
static __attribute__((unused)) void dump_ns(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen(DUMPPATH, "a");
    if (f) { fwrite([s UTF8String], 1, [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding], f); fputc('\n', f); fclose(f); }
}
static void dlog(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    FILE *f = fopen(DUMPPATH, "a");
    if (f) { vfprintf(f, fmt, ap); fputc('\n', f); fclose(f); }
    va_end(ap);
}
static void dlog_ns(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    FILE *f = fopen(DUMPPATH, "a");
    if (f) { fwrite([s UTF8String], 1, [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding], f); fputc('\n', f); fclose(f); }
}

// ===== IOReport 动态加载 =====
typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;
static void *s_iolib = NULL;
static CFDictionaryRef (*s_CopyChannelsInGroup)(CFStringRef, CFStringRef, uint64_t, uint64_t, uint64_t) = NULL;
static IOReportSubscriptionRef (*s_CreateSubscription)(void *, CFMutableDictionaryRef, CFDictionaryRef *, uint64_t, void *) = NULL;
static CFDictionaryRef (*s_CreateSamples)(IOReportSubscriptionRef, CFDictionaryRef, void *) = NULL;
static CFDictionaryRef (*s_CreateSamplesDelta)(CFDictionaryRef, CFDictionaryRef, void *) = NULL;
static int64_t (*s_SimpleGetIntegerValue)(CFDictionaryRef, int32_t) = NULL;
static int32_t (*s_StateGetCount)(CFDictionaryRef) = NULL;
static CFStringRef (*s_StateGetNameForIndex)(CFDictionaryRef, int32_t) = NULL;
static int64_t (*s_StateGetResidency)(CFDictionaryRef, int32_t) = NULL;
static CFStringRef (*s_ChannelGetGroup)(CFDictionaryRef) = NULL;
static CFStringRef (*s_ChannelGetSubGroup)(CFDictionaryRef) = NULL;
static CFStringRef (*s_ChannelGetChannelName)(CFDictionaryRef) = NULL;
static void (*s_MergeChannels)(CFDictionaryRef, CFDictionaryRef, void *) = NULL;

static IOReportSubscriptionRef g_sub = NULL;
static CFMutableDictionaryRef g_channels = NULL;
static int g_ioreportOk = 0;

static int ioreport_init(void) {
    if (g_ioreportOk) return 1;
    s_iolib = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!s_iolib) { dlog("ioreport: dlopen failed"); return 0; }
    s_CopyChannelsInGroup = dlsym(s_iolib, "IOReportCopyChannelsInGroup");
    s_CreateSubscription = dlsym(s_iolib, "IOReportCreateSubscription");
    s_CreateSamples = dlsym(s_iolib, "IOReportCreateSamples");
    s_CreateSamplesDelta = dlsym(s_iolib, "IOReportCreateSamplesDelta");
    s_SimpleGetIntegerValue = dlsym(s_iolib, "IOReportSimpleGetIntegerValue");
    s_StateGetCount = dlsym(s_iolib, "IOReportStateGetCount");
    s_StateGetNameForIndex = dlsym(s_iolib, "IOReportStateGetNameForIndex");
    s_StateGetResidency = dlsym(s_iolib, "IOReportStateGetResidency");
    s_ChannelGetGroup = dlsym(s_iolib, "IOReportChannelGetGroup");
    s_ChannelGetSubGroup = dlsym(s_iolib, "IOReportChannelGetSubGroup");
    s_ChannelGetChannelName = dlsym(s_iolib, "IOReportChannelGetChannelName");
    s_MergeChannels = dlsym(s_iolib, "IOReportMergeChannels");
    if (!s_CopyChannelsInGroup || !s_CreateSubscription || !s_CreateSamples ||
        !s_CreateSamplesDelta || !s_SimpleGetIntegerValue || !s_StateGetCount ||
        !s_StateGetNameForIndex || !s_StateGetResidency) {
        dlog("ioreport: missing symbols");
        return 0;
    }
    @try {
        // 订阅 CPU Stats + GPU Stats 组（含所有频率/性能状态通道）
        CFDictionaryRef cpuChan = s_CopyChannelsInGroup(CFSTR("CPU Stats"), NULL, 0, 0, 0);
        CFDictionaryRef gpuChan = s_CopyChannelsInGroup(CFSTR("GPU Stats"), NULL, 0, 0, 0);
        CFDictionaryRef base = cpuChan ? cpuChan : gpuChan;
        if (!base) { dlog("ioreport: no CPU/GPU channels"); return 0; }
        if (gpuChan) { s_MergeChannels(base, gpuChan, NULL); CFRelease(gpuChan); }
        CFIndex size = CFDictionaryGetCount(base);
        g_channels = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, size, base);
        CFRelease(base);
        if (!g_channels) { dlog("ioreport: mutable copy failed"); return 0; }
        CFDictionaryRef subsystem = NULL;
        g_sub = s_CreateSubscription(NULL, g_channels, &subsystem, 0, NULL);
        if (!g_sub) { dlog("ioreport: subscription failed"); CFRelease(g_channels); g_channels=NULL; return 0; }
        dlog("ioreport: subscription ok, channels=%ld", (long)CFDictionaryGetCount(g_channels));
        g_ioreportOk = 1;
    } @catch (NSException *e) {
        dlog_ns(@"ioreport init exception: %@", e);
        return 0;
    }
    return 1;
}

// 从状态名字符串提取频率 MHz（"600MHz"->600, "V3"->-1 需查表, "3500"->3500）
static double freqFromStateName(const char *name) {
    if (!name) return -1;
    if (name[0] == 'V') return -1; // V# 需要频率表
    // 找第一个数字
    const char *p = name;
    while (*p && !isdigit(*p)) p++;
    if (*p) return atof(p);
    return -1;
}

// 从 IORegistry AppleARMIODevice voltage-states 加载频率表（Hz->MHz）
#define MAX_FREQS 64
static int g_ecpu_freqs[MAX_FREQS], g_ecpu_freq_count = 0;
static int g_pcpu_freqs[MAX_FREQS], g_pcpu_freq_count = 0;

static void load_freq_tables(void) {
    if (g_ecpu_freq_count > 0) return;
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(0, IOServiceMatching("AppleARMIODevice"), &iter) != KERN_SUCCESS) return;
    io_object_t entry;
    while ((entry = IOIteratorNext(iter)) != 0) {
        CFMutableDictionaryRef props = NULL;
        if (IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) != KERN_SUCCESS || !props) {
            IOObjectRelease(entry); continue;
        }
        NSDictionary *d = CFBridgingRelease(props);
        NSString *name = d[@"name"];
        // voltage-states / voltage-states1 是 CFData，每 8 字节一个频率（Hz）
        for (NSString *key in @[@"voltage-states", @"voltage-states1", @"voltage-states2"]) {
            NSData *data = d[key];
            if (![data isKindOfClass:[NSData class]]) continue;
            const uint8_t *bytes = [data bytes];
            int len = (int)[data length] / 8;
            if (len > MAX_FREQS) len = MAX_FREQS;
            int *freqs = nil; int *cnt = nil;
            if ([name containsString:@"ecpu"] || [name containsString:@"E"] || [name containsString:@"cpu0"]) {
                freqs = g_ecpu_freqs; cnt = &g_ecpu_freq_count;
            } else if ([name containsString:@"pcpu"] || [name containsString:@"P"] || [name containsString:@"cpu1"]) {
                freqs = g_pcpu_freqs; cnt = &g_pcpu_freq_count;
            }
            if (!freqs) continue;
            for (int i = 0; i < len; i++) {
                uint32_t freqHz = 0;
                memcpy(&freqHz, bytes + (i * 8), 4);
                if (freqHz > 100000000) freqs[(*cnt)++] = freqHz / 1000000;
                else if (freqHz > 100000) freqs[(*cnt)++] = freqHz / 1000;
            }
        }
        IOObjectRelease(entry);
    }
    IOObjectRelease(iter);
    dlog("freq tables: ecpu=%d pcpu=%d", g_ecpu_freq_count, g_pcpu_freq_count);
}

// ===== 实时采样：读 CPU/GPU 频率（MHz）=====
static double s_cpuFreq = 0, s_gpuFreq = 0;

static void sample_frequencies(void) {
    if (!g_ioreportOk) return;
    @try {
        CFDictionaryRef s1 = s_CreateSamples(g_sub, g_channels, NULL);
        if (!s1) return;
        usleep(200000); // 200ms 采样间隔
        CFDictionaryRef s2 = s_CreateSamples(g_sub, g_channels, NULL);
        if (!s2) { CFRelease(s1); return; }
        CFDictionaryRef delta = s_CreateSamplesDelta(s1, s2, NULL);
        CFRelease(s1); CFRelease(s2);
        if (!delta) return;
        CFArrayRef arr = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
        CFIndex cnt = arr ? CFArrayGetCount(arr) : 0;
        double ecpuF = 0, pcpuF = 0, gpuF = 0;
        int ecpuA = 0, pcpuA = 0, gpuA = 0;
        for (CFIndex i = 0; i < cnt; i++) {
            CFDictionaryRef ch = (CFDictionaryRef)CFArrayGetValueAtIndex(arr, i);
            if (!ch) continue;
            CFStringRef grpRef = s_ChannelGetGroup(ch);
            CFStringRef subRef = s_ChannelGetSubGroup(ch);
            CFStringRef nameRef = s_ChannelGetChannelName(ch);
            if (!grpRef || !nameRef) continue;
            char grp[64]={0}, sub[64]={0}, chn[128]={0};
            CFStringGetCString(grpRef, grp, sizeof(grp), kCFStringEncodingUTF8);
            if (subRef) CFStringGetCString(subRef, sub, sizeof(sub), kCFStringEncodingUTF8);
            CFStringGetCString(nameRef, chn, sizeof(chn), kCFStringEncodingUTF8);
            if (strcmp(grp, "CPU Stats") == 0 && strstr(sub, "Performance States")) {
                int isE = strstr(chn, "ECPU") != NULL;
                int isP = strstr(chn, "PCPU") != NULL;
                if (!isE && !isP) continue;
                int32_t sc = s_StateGetCount(ch);
                int64_t act = 0;
                double wf = 0;
                for (int32_t s = 0; s < sc; s++) {
                    int64_t res = s_StateGetResidency(ch, s);
                    CFStringRef sn = s_StateGetNameForIndex(ch, s);
                    char nm[64]={0};
                    if (sn) { CFStringGetCString(sn, nm, sizeof(nm), kCFStringEncodingUTF8); }
                    if (strcmp(nm, "OFF") && strcmp(nm, "IDLE") && strcmp(nm, "DOWN")) {
                        act += res;
                        double f = freqFromStateName(nm);
                        if (f > 0) wf += f * res;
                    }
                }
                if (act > 0 && wf > 0) {
                    double avg = wf / act;
                    if (isE) { ecpuF = avg; ecpuA = 1; }
                    if (isP) { pcpuF = avg; pcpuA = 1; }
                }
            } else if (strcmp(grp, "GPU Stats") == 0 && strstr(sub, "Performance States")) {
                int32_t sc = s_StateGetCount(ch);
                int64_t act = 0;
                double wf = 0;
                for (int32_t s = 0; s < sc; s++) {
                    int64_t res = s_StateGetResidency(ch, s);
                    CFStringRef sn = s_StateGetNameForIndex(ch, s);
                    char nm[64]={0};
                    if (sn) { CFStringGetCString(sn, nm, sizeof(nm), kCFStringEncodingUTF8); }
                    if (strcmp(nm, "OFF") && strcmp(nm, "IDLE") && strcmp(nm, "DOWN")) {
                        act += res;
                        double f = freqFromStateName(nm);
                        if (f > 0) wf += f * res;
                    }
                }
                if (act > 0 && wf > 0) { gpuF = wf / act; gpuA = 1; }
            }
        }
        CFRelease(delta);
        if (ecpuA || pcpuA) s_cpuFreq = (ecpuA ? ecpuF : pcpuF);
        if (gpuA) s_gpuFreq = gpuF;
    } @catch (NSException *e) {
        dlog_ns(@"sample exception: %@", e);
    }
}

// ===== CPU 利用率 =====
static double cpu_usage(void) {
    static int64_t prevUser=0, prevSys=0, prevIdle=0, prevNice=0;
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &count) != KERN_SUCCESS) return 0;
    int64_t user = info.cpu_ticks[CPU_STATE_USER];
    int64_t sys  = info.cpu_ticks[CPU_STATE_SYSTEM];
    int64_t idle = info.cpu_ticks[CPU_STATE_IDLE];
    int64_t nice = info.cpu_ticks[CPU_STATE_NICE];
    if (prevUser==0 && prevSys==0 && prevIdle==0) {
        prevUser=user; prevSys=sys; prevIdle=idle; prevNice=nice; return 0;
    }
    int64_t dUser=user-prevUser, dSys=sys-prevSys, dIdle=idle-prevIdle, dNice=nice-prevNice;
    prevUser=user; prevSys=sys; prevIdle=idle; prevNice=nice;
    int64_t total = dUser + dSys + dIdle + dNice;
    if (total <= 0) return 0;
    return (double)(dUser + dSys + dNice) / (double)total * 100.0;
}

// ===== 心电图波形 =====
#define MAX_POINTS 120
static float g_cpuHistory[MAX_POINTS], g_gpuHistory[MAX_POINTS], g_freqHistory[MAX_POINTS];
static int g_histCount = 0;

static void push_history(float cpu, float gpu, float freq) {
    if (g_histCount < MAX_POINTS) {
        g_cpuHistory[g_histCount] = cpu;
        g_gpuHistory[g_histCount] = gpu;
        g_freqHistory[g_histCount] = freq;
        g_histCount++;
    } else {
        memmove(g_cpuHistory, g_cpuHistory+1, sizeof(float)*(MAX_POINTS-1));
        memmove(g_gpuHistory, g_gpuHistory+1, sizeof(float)*(MAX_POINTS-1));
        memmove(g_freqHistory, g_freqHistory+1, sizeof(float)*(MAX_POINTS-1));
        g_cpuHistory[MAX_POINTS-1] = cpu;
        g_gpuHistory[MAX_POINTS-1] = gpu;
        g_freqHistory[MAX_POINTS-1] = freq;
    }
}

// ===== 悬浮窗 =====
@interface FreqMonPanel : UIView @end
@implementation FreqMonPanel
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    // 背景
    CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.75].CGColor);
    CGContextFillRect(ctx, rect);
    // 网格
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.12].CGColor);
    CGContextSetLineWidth(ctx, 0.5);
    for (CGFloat x = 0; x < rect.size.width; x += 24) {
        CGContextMoveToPoint(ctx, x, 0); CGContextAddLineToPoint(ctx, x, rect.size.height);
    }
    for (CGFloat y = 0; y < rect.size.height; y += 24) {
        CGContextMoveToPoint(ctx, 0, y); CGContextAddLineToPoint(ctx, rect.size.width, y);
    }
    CGContextStrokePath(ctx);
    // CPU 波形（绿色）
    [self drawWave:ctx color:[UIColor colorWithRed:0.2 green:1.0 blue:0.4 alpha:1.0]
           data:g_cpuHistory count:g_histCount max:100.0];
    // GPU 波形（青色）
    [self drawWave:ctx color:[UIColor colorWithRed:0.2 green:0.8 blue:1.0 alpha:0.8]
           data:g_gpuHistory count:g_histCount max:100.0];
    // 频率波形（黄色，归一化到 0-4000MHz）
    [self drawWave:ctx color:[UIColor colorWithRed:1.0 green:0.9 blue:0.2 alpha:0.7]
           data:g_freqHistory count:g_histCount max:4000.0];
}
- (void)drawWave:(CGContextRef)ctx color:(UIColor*)color data:(float*)data count:(int)count max:(float)max {
    if (count < 2) return;
    CGContextSetStrokeColorWithColor(ctx, color.CGColor);
    CGContextSetLineWidth(ctx, 2.0);
    CGContextSetShadowWithColor(ctx, CGSizeMake(0,0), 4, color.CGColor);
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGContextBeginPath(ctx);
    for (int i = 0; i < count; i++) {
        CGFloat x = (CGFloat)i / (MAX_POINTS - 1) * w;
        CGFloat v = data[i] / max;
        if (v > 1) v = 1;
        CGFloat y = h - v * h * 0.9 - h * 0.05;
        if (i == 0) CGContextMoveToPoint(ctx, x, y);
        else CGContextAddLineToPoint(ctx, x, y);
    }
    CGContextStrokePath(ctx);
    CGContextSetShadowWithColor(ctx, CGSizeZero, 0, NULL);
}
@end

static UIWindow *g_window;
static UILabel *g_label;
static FreqMonPanel *g_panel;

static void tick(void);

static UIWindowScene *pick_scene(void) {
    @try {
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)sc;
            if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        }
        for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)sc;
        }
    } @catch (NSException *e) {}
    return nil;
}

static void create_window(void) {
    if (g_window) return;
    @autoreleasepool {
        UIWindowScene *scene = pick_scene();
        if (!scene) { dlog("create_window: no scene yet"); return; }
        UIWindow *w = [[UIWindow alloc] initWithWindowScene:scene];
        w.frame = CGRectMake(8, 60, 170, 150);
        w.windowLevel = UIWindowLevelStatusBar + 100;
        w.backgroundColor = [UIColor clearColor];
        w.userInteractionEnabled = NO;
        w.hidden = NO;
        // 用 UIViewController 承载视图，避免 window 的 rootViewController 为空导致不显示
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view.backgroundColor = [UIColor clearColor];
        w.rootViewController = vc;
        // 面板
        FreqMonPanel *panel = [[FreqMonPanel alloc] initWithFrame:CGRectMake(0, 0, 170, 150)];
        panel.backgroundColor = [UIColor clearColor];
        [vc.view addSubview:panel];
        g_panel = panel;
        // 顶部标签
        g_label = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 170, 34)];
        g_label.textAlignment = NSTextAlignmentCenter;
        g_label.numberOfLines = 2;
        g_label.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
        g_label.textColor = [UIColor whiteColor];
        g_label.text = @"CPU --  GPU --";
        [vc.view addSubview:g_label];
        g_window = w;
        dlog("window created scene=%@", scene ? @"yes" : @"NIL");
        // 启动定时器
        [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) { tick(); }];
    }
}

static void tick(void) {
    @autoreleasepool {
        double cpu = cpu_usage();
        sample_frequencies();
        push_history((float)cpu, (float)s_cpuFreq, (float)s_gpuFreq);
        int freqMhz = (int)s_cpuFreq;
        int gpuMhz = (int)s_gpuFreq;
        g_label.text = [NSString stringWithFormat:@"CPU %3.0f%%  %dMHz\nGPU %dMHz", cpu, freqMhz, gpuMhz];
        [g_panel setNeedsDisplay];
    }
}

__attribute__((constructor))
static void freqmon_ctor(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) bid = [[NSProcessInfo processInfo] processName];
        NSString *pname = [[NSProcessInfo processInfo] processName];
        BOOL isSB = [bid isEqualToString:@"com.apple.springboard"]
                 || [pname isEqualToString:@"SpringBoard"]
                 || [bid isEqualToString:@"com.apple.UIKit"];
        dlog_ns(@"ctor: bid=%@ pname=%@ isSB=%d", bid, pname, (int)isSB);
        if (isSB) {
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                @autoreleasepool {
                    load_freq_tables();
                    ioreport_init();
                }
            });
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
