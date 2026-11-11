#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach/mach_host.h>
#import <mach/host_info.h>
#import <IOKit/IOKitLib.h>
#import <CoreFoundation/CoreFoundation.h>

#define DUMPPATH "/var/mobile/Library/Logs/freqmon-dump.log"

// ===== 日志 =====
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

// ===== IOReport 频率读取 —— AppleOverclock 方案：IORegistry 读 IOReportChannels 属性 =====
// 不调用 libIOReport 函数（避免崩溃），直接从 IORegistry 节点读 IOReportChannels / IOReportChannelStateNames
static double s_cpuFreq = 0, s_gpuFreq = 0;
static int g_ioreportOk = 0;
static int g_freqTried = 0;

// ===== 频率表（从 IORegistry voltage-states 加载）=====
#define MAX_FREQS 64
static uint32_t g_ecpu_freqs[MAX_FREQS]; static int g_ecpu_freq_count = 0;
static uint32_t g_pcpu_freqs[MAX_FREQS]; static int g_pcpu_freq_count = 0;
static uint32_t g_gpu_freqs[MAX_FREQS];  static int g_gpu_freq_count = 0;

static __attribute__((unused)) int cfStrEq(CFStringRef s, const char *c) {
    if (!s || !c) return 0;
    return CFStringCompare(s, CFStringCreateWithCString(NULL, c, kCFStringEncodingUTF8), 0) == kCFCompareEqualTo;
}
static __attribute__((unused)) int cfStrHas(CFStringRef s, const char *sub) {
    if (!s || !sub) return 0;
    char buf[128] = {0};
    if (!CFStringGetCString(s, buf, sizeof(buf), kCFStringEncodingUTF8)) return 0;
    return strstr(buf, sub) != NULL;
}

// 解析 voltage-states 二进制（每项8字节，前4字节频率）→ MHz 表
static __attribute__((unused)) void parseFreqData(CFDataRef data, uint32_t *outFreqs, int *outCount) {
    if (!data) return;
    CFIndex len = CFDataGetLength(data);
    const uint8_t *bytes = CFDataGetBytePtr(data);
    int totalEntries = (int)(len / 8);
    *outCount = 0;
    for (int i = 0; i < totalEntries; i++) {
        uint32_t freq = 0;
        memcpy(&freq, bytes + (i * 8), 4);
        uint32_t freqMHz = 0;
        if (freq >= 100000000) freqMHz = freq / 1000000;      // Hz
        else if (freq >= 100000) freqMHz = freq / 1000;       // kHz
        if (freqMHz > 0 && *outCount < MAX_FREQS) outFreqs[(*outCount)++] = freqMHz;
    }
}

// 从 IORegistry AppleARMIODevice pmgr/clpc 加载频率表
static __attribute__((unused)) void load_freq_tables(void) {
    if (g_ecpu_freq_count > 0 && g_pcpu_freq_count > 0 && g_gpu_freq_count > 0) return;
    io_iterator_t iter = 0;
    if (IOServiceGetMatchingServices(0, IOServiceMatching("AppleARMIODevice"), &iter) != KERN_SUCCESS) return;
    io_object_t entry;
    while ((entry = IOIteratorNext(iter)) != 0) {
        io_name_t name;
        IORegistryEntryGetName(entry, name);
        if (strcmp(name, "pmgr") == 0 || strcmp(name, "clpc") == 0) {
            CFMutableDictionaryRef props = NULL;
            if (IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS) {
                CFDataRef eData = (CFDataRef)CFDictionaryGetValue(props, CFSTR("voltage-states1"));
                if (!eData) eData = (CFDataRef)CFDictionaryGetValue(props, CFSTR("voltage-states1-sram"));
                if (eData && g_ecpu_freq_count == 0) parseFreqData(eData, g_ecpu_freqs, &g_ecpu_freq_count);
                CFDataRef pData = (CFDataRef)CFDictionaryGetValue(props, CFSTR("voltage-states5"));
                if (!pData) pData = (CFDataRef)CFDictionaryGetValue(props, CFSTR("voltage-states5-sram"));
                if (pData && g_pcpu_freq_count == 0) parseFreqData(pData, g_pcpu_freqs, &g_pcpu_freq_count);
                // GPU: 遍历所有 voltage-states*，选最大的
                CFIndex cnt = CFDictionaryGetCount(props);
                const void *keys[128]; const void *vals[128];
                if (cnt <= 128) {
                    CFDictionaryGetKeysAndValues(props, keys, vals);
                    for (CFIndex i = 0; i < cnt; i++) {
                        CFStringRef key = (CFStringRef)keys[i];
                        char kn[128] = {0};
                        if (CFStringGetCString(key, kn, sizeof(kn), kCFStringEncodingUTF8) && strstr(kn, "voltage-states")) {
                            CFDataRef data = (CFDataRef)vals[i];
                            uint32_t tmp[MAX_FREQS]; int tc = 0;
                            parseFreqData(data, tmp, &tc);
                            if (tc > g_gpu_freq_count && tc > 0) {
                                memcpy(g_gpu_freqs, tmp, tc * sizeof(uint32_t));
                                g_gpu_freq_count = tc;
                            }
                        }
                    }
                }
                CFRelease(props);
            }
        }
        IOObjectRelease(entry);
        if (g_ecpu_freq_count > 0 && g_pcpu_freq_count > 0) break;
    }
    IOObjectRelease(iter);
    dlog("freq tables: E=%d P=%d GPU=%d", g_ecpu_freq_count, g_pcpu_freq_count, g_gpu_freq_count);
}

// ===== 从 IORegistry 读 IOReportChannels 属性，解析频率通道 =====
// AppleOverclock 方式：匹配 IOReport 服务 → 读 IOReportChannels 数组，
// 每个 channel 有 IOReportGroupName/IOReportSubGroupName/IOReportChannelStateNames
static void ioreport_init(void) {
    if (g_ioreportOk || g_freqTried) return;
    g_freqTried = 1;
    @try {
        // 找含 IOReportChannels 属性的服务（用匹配字典遍历所有 IORegistry 服务太慢，
        // 用 IOServiceGetMatchingServices 遍历 IOReport 相关类）
        // A16: 走 IOServiceGetMatchingServices(NULL) 匹配所有，检查属性
        io_iterator_t iter = 0;
        kern_return_t kr = IOServiceGetMatchingServices(0, IOServiceMatching("IOReport"), &iter);
        // 若上面失败，尝试遍历 AGXAccelerator / pmgr / clpc
        if (kr != KERN_SUCCESS || !iter) {
            kr = IOServiceGetMatchingServices(0, IOServiceMatching("AppleARMIODevice"), &iter);
        }
        if (kr != KERN_SUCCESS || !iter) {
            dlog("ioreport: no matching service");
            return;
        }
        io_object_t entry;
        while ((entry = IOIteratorNext(iter)) != 0) {
            CFMutableDictionaryRef props = NULL;
            if (IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
                CFArrayRef chans = (CFArrayRef)CFDictionaryGetValue(props, CFSTR("IOReportChannels"));
                if (chans && CFGetTypeID(chans) == CFArrayGetTypeID()) {
                    CFIndex cnt = CFArrayGetCount(chans);
                    dlog("ioreport: found IOReportChannels count=%ld", (long)cnt);
                    for (CFIndex i = 0; i < cnt; i++) {
                        CFDictionaryRef ch = (CFDictionaryRef)CFArrayGetValueAtIndex(chans, i);
                        if (!ch || CFGetTypeID(ch) != CFDictionaryGetTypeID()) continue;
                        CFStringRef grp = (CFStringRef)CFDictionaryGetValue(ch, CFSTR("IOReportGroupName"));
                        CFStringRef sub = (CFStringRef)CFDictionaryGetValue(ch, CFSTR("IOReportSubGroupName"));
                        CFStringRef stateNames = (CFStringRef)CFDictionaryGetValue(ch, CFSTR("IOReportChannelStateNames"));
                        if (!grp || !sub) continue;
                        char gbuf[64]={0}, sbuf[64]={0};
                        CFStringGetCString(grp, gbuf, sizeof(gbuf), kCFStringEncodingUTF8);
                        CFStringGetCString(sub, sbuf, sizeof(sbuf), kCFStringEncodingUTF8);
                        // CPU Complex Performance States
                        if (strstr(gbuf,"CPU") && strstr(sbuf,"Complex Performance States")) {
                            dlog("  CPU freq channel: %s/%s stateNames=%s", gbuf, sbuf, stateNames ? "yes" : "no");
                        }
                        if (strstr(gbuf,"GPU") && strstr(sbuf,"GPU Performance States")) {
                            dlog("  GPU freq channel: %s/%s stateNames=%s", gbuf, sbuf, stateNames ? "yes" : "no");
                        }
                    }
                }
                CFRelease(props);
            }
            IOObjectRelease(entry);
        }
        IOObjectRelease(iter);
        g_ioreportOk = 1;
    } @catch (NSException *e) {
        dlog_ns(@"ioreport init exception: %@", e);
    }
}

// 从状态名提取频率 MHz
static __attribute__((unused)) int freqFromStateName(const char *name) {
    if (!name || !name[0]) return 0;
    const char *p = name;
    while (*p && !isdigit(*p)) p++;
    if (*p) return atoi(p);
    return 0;
}

// 采样：IORegistry 读当前状态（无 libIOReport 函数调用，安全）
static void ioreport_sample(void) {
    // AppleOverclock 通过 IORegistry 属性实时读；这里保留 CPU/GPU 利用率已有。
    // 频率状态名已由 ioreport_init 读到（后续版本直接用 stateNames + CurrentStates）
}

// ===== CPU 利用率（host_statistics）=====
static double cpu_usage(void) {
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &count) != KERN_SUCCESS)
        return 0;
    unsigned long total = info.cpu_ticks[CPU_STATE_USER] + info.cpu_ticks[CPU_STATE_SYSTEM] +
                          info.cpu_ticks[CPU_STATE_NICE] + info.cpu_ticks[CPU_STATE_IDLE];
    if (total == 0) return 0;
    return 100.0 * (double)(total - info.cpu_ticks[CPU_STATE_IDLE]) / (double)total;
}

// ===== GPU 利用率（IORegistry AGXAccelerator PerformanceStatistics）=====
static double gpu_util(void) {
    double util = 0;
    @try {
        io_iterator_t iter = 0;
        if (IOServiceGetMatchingServices(0, IOServiceMatching("AGXAccelerator"), &iter) == KERN_SUCCESS) {
            io_object_t entry;
            while ((entry = IOIteratorNext(iter)) != 0) {
                CFMutableDictionaryRef props = NULL;
                if (IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS) {
                    CFDictionaryRef ps = (CFDictionaryRef)CFDictionaryGetValue(props, CFSTR("PerformanceStatistics"));
                    if (ps) {
                        NSDictionary *d = (__bridge NSDictionary *)ps;
                        id v = [d objectForKey:@"Device Utilization %"];
                        if (v) util = [v doubleValue];
                    }
                    CFRelease(props);
                }
                IOObjectRelease(entry);
                if (util > 0) break;
            }
            IOObjectRelease(iter);
        }
    } @catch (NSException *e) {}
    return util;
}

// ===== ECG 波形视图 =====
#define SAMPLE_CAP 120
#define MAX_TRACES 3
@interface FreqMonChartView : UIView
@end
@implementation FreqMonChartView {
    double _cpuHist[SAMPLE_CAP]; int _cpuLen;
    double _gpuHist[SAMPLE_CAP]; int _gpuLen;
    double _freqHist[SAMPLE_CAP]; int _freqLen;
    UILabel *_statusLabel;
    CAShapeLayer *_cpuLine, *_gpuLine, *_freqLine;
}
- (id)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.88];
        self.layer.cornerRadius = 10;
        self.layer.borderWidth = 0.5;
        self.layer.borderColor = [UIColor colorWithWhite:0.3 alpha:0.6].CGColor;
        self.layer.masksToBounds = YES;
        _cpuLen = _gpuLen = _freqLen = 0;
        _statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(6, 2, frame.size.width - 12, 40)];
        _statusLabel.font = [UIFont monospacedDigitSystemFontOfSize:10 weight:UIFontWeightMedium];
        _statusLabel.textColor = [UIColor colorWithRed:0.3 green:1.0 blue:0.5 alpha:1];
        _statusLabel.numberOfLines = 3;
        _statusLabel.adjustsFontSizeToFitWidth = YES;
        [self addSubview:_statusLabel];
        // CPU (green glow)
        _cpuLine = [CAShapeLayer layer];
        _cpuLine.strokeColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:1].CGColor;
        _cpuLine.fillColor = nil; _cpuLine.lineWidth = 1.8;
        _cpuLine.shadowColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:0.8].CGColor;
        _cpuLine.shadowRadius = 4; _cpuLine.shadowOpacity = 0.9;
        [self.layer addSublayer:_cpuLine];
        // GPU (cyan)
        _gpuLine = [CAShapeLayer layer];
        _gpuLine.strokeColor = [UIColor colorWithRed:0.3 green:0.9 blue:1.0 alpha:1].CGColor;
        _gpuLine.fillColor = nil; _gpuLine.lineWidth = 1.4;
        [self.layer addSublayer:_gpuLine];
        // freq (yellow)
        _freqLine = [CAShapeLayer layer];
        _freqLine.strokeColor = [UIColor colorWithRed:1.0 green:0.9 blue:0.3 alpha:1].CGColor;
        _freqLine.fillColor = nil; _freqLine.lineWidth = 1.2;
        [self.layer addSublayer:_freqLine];
    }
    return self;
}
- (void)pushSample:(double)cpu gpu:(double)gpu freq:(double)freq {
    if (_cpuLen < SAMPLE_CAP) _cpuHist[_cpuLen++] = cpu; else memmove(_cpuHist, _cpuHist+1, (SAMPLE_CAP-1)*8), _cpuHist[SAMPLE_CAP-1] = cpu;
    if (_gpuLen < SAMPLE_CAP) _gpuHist[_gpuLen++] = gpu; else memmove(_gpuHist, _gpuHist+1, (SAMPLE_CAP-1)*8), _gpuHist[SAMPLE_CAP-1] = gpu;
    if (_freqLen < SAMPLE_CAP) _freqHist[_freqLen++] = freq; else memmove(_freqHist, _freqHist+1, (SAMPLE_CAP-1)*8), _freqHist[SAMPLE_CAP-1] = freq;
    [self setNeedsDisplay];
}
- (void)updateStatus:(NSString *)s { _statusLabel.text = s; }
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    // grid
    CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1.0 alpha:0.07].CGColor);
    CGContextSetLineWidth(ctx, 0.5);
    CGFloat w = rect.size.width, h = rect.size.height;
    for (int i = 1; i < 8; i++) { CGFloat x = w * i / 8; CGContextMoveToPoint(ctx, x, 40); CGContextAddLineToPoint(ctx, x, h); }
    for (int i = 1; i < 6; i++) { CGFloat y = 40 + (h - 40) * i / 6; CGContextMoveToPoint(ctx, 0, y); CGContextAddLineToPoint(ctx, w, y); }
    CGContextStrokePath(ctx);
    [self drawLine:ctx hist:_cpuHist len:_cpuLen max:110 color:[UIColor colorWithRed:0.2 green:1.0 blue:0.5 alpha:1] rect:rect offset:0];
    [self drawLine:ctx hist:_gpuHist len:_gpuLen max:110 color:[UIColor colorWithRed:0.3 green:0.9 blue:1.0 alpha:1] rect:rect offset:0.33];
    [self drawLine:ctx hist:_freqHist len:_freqLen max:4000 color:[UIColor colorWithRed:1.0 green:0.9 blue:0.3 alpha:1] rect:rect offset:0.66];
}
- (void)drawLine:(CGContextRef)ctx hist:(double*)h len:(int)len max:(double)max color:(UIColor*)color rect:(CGRect)rect offset:(CGFloat)off {
    if (len < 2) return;
    CGFloat w = rect.size.width, hh = rect.size.height;
    CGFloat top = 40 + (hh - 40) * off;
    CGFloat hgt = (hh - 40) * 0.30;
    CGContextSetStrokeColorWithColor(ctx, color.CGColor);
    CGContextSetLineWidth(ctx, 1.6);
    CGContextBeginPath(ctx);
    for (int i = 0; i < len; i++) {
        double v = h[i]; if (v < 0) v = 0; if (v > max) v = max;
        CGFloat x = w * (len - 1 - i) / (SAMPLE_CAP - 1);
        CGFloat y = top + hgt - hgt * (v / max);
        if (i == 0) CGContextMoveToPoint(ctx, x, y); else CGContextAddLineToPoint(ctx, x, y);
    }
    CGContextStrokePath(ctx);
}
@end

// ===== 全局 =====
static UIWindow *g_window = nil;
static FreqMonChartView *g_chart = nil;
static NSTimer *g_timer = nil;

static UIWindowScene *pick_scene(void) {
    @try {
        NSArray *scenes = UIApplication.sharedApplication.connectedScenes.allObjects;
        for (UIWindowScene *sc in scenes)
            if (sc.activationState == UISceneActivationStateForegroundActive) return sc;
        for (UIWindowScene *sc in scenes) if (sc.activationState != UISceneActivationStateUnattached) return sc;
        if (scenes.count) return scenes.firstObject;
    } @catch (NSException *e) {}
    return nil;
}

static void create_window(void) {
    if (g_window) return;
    UIWindowScene *scene = pick_scene();
    if (!scene) return;
    CGRect f = CGRectMake(6, 60, 190, 150);
    g_window = [[UIWindow alloc] initWithWindowScene:scene];
    g_window.frame = f;
    g_window.windowLevel = 5000;
    g_window.backgroundColor = [UIColor clearColor];
    g_window.hidden = NO;
    g_window.userInteractionEnabled = NO;
    g_chart = [[FreqMonChartView alloc] initWithFrame:f];
    [g_window addSubview:g_chart];
    [g_window makeKeyAndVisible]; // NOTE: window is non-interactive; makeKeyAndVisible ok because userInteractionEnabled=NO
    dlog_ns(@"window created scene=%@", scene ? @"yes" : @"NIL");
}

static void tick(void) {
    @autoreleasepool {
        double cpu = cpu_usage();
        double gpu = gpu_util();
        ioreport_sample();
        if (g_chart) {
            [g_chart pushSample:cpu gpu:gpu freq:s_cpuFreq];
            NSString *txt = [NSString stringWithFormat:@"CPU %.0f%% %.0fMHz\nGPU %.0f%% %.0fMHz", cpu, s_cpuFreq, gpu, s_gpuFreq];
            [g_chart updateStatus:txt];
        }
    }
}

__attribute__((constructor))
static void freqmon_ctor(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
        NSString *pname = [[NSProcessInfo processInfo] processName] ?: @"";
        BOOL isSB = [bid isEqualToString:@"com.apple.springboard"] || [pname isEqualToString:@"SpringBoard"];
        dlog_ns(@"ctor: bid=%@ pname=%@ isSB=%d", bid, pname, (int)isSB);
        if (!isSB) return;
        static int tries = 0;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!g_window) create_window();
            if (tries < 40 && !g_window) { tries++; dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (!g_window) create_window(); }); }
            if (!g_timer) {
                ioreport_init();
                g_timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:[NSBlockOperation blockOperationWithBlock:^{ tick(); }] selector:@selector(main) userInfo:nil repeats:YES];
            }
        });
    }
}
