#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <mach/mach.h>
#import <mach/host_info.h>
#import <mach/mach_host.h>
#include <IOKit/IOKitLib.h>
#include <stdarg.h>

#define LOGPATH "/var/mobile/Library/Logs/freqmon.log"

static void dlog(const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    FILE *f = fopen(LOGPATH, "a");
    if (f) { vfprintf(f, fmt, ap); fputc('\n', f); fclose(f); }
    va_end(ap);
}

// ================= CPU usage (%) =================
static double cpu_usage(void) {
    static host_cpu_load_info_data_t prev = {0};
    static int inited = 0;
    host_cpu_load_info_data_t info;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&info, &count) != KERN_SUCCESS) return 0;
    if (!inited) { prev = info; inited = 1; return 0; }
    unsigned long long user = info.cpu_ticks[CPU_STATE_USER] - prev.cpu_ticks[CPU_STATE_USER];
    unsigned long long sys  = info.cpu_ticks[CPU_STATE_SYSTEM] - prev.cpu_ticks[CPU_STATE_SYSTEM];
    unsigned long long idle = info.cpu_ticks[CPU_STATE_IDLE] - prev.cpu_ticks[CPU_STATE_IDLE];
    unsigned long long nice = info.cpu_ticks[CPU_STATE_NICE] - prev.cpu_ticks[CPU_STATE_NICE];
    unsigned long long total = user + sys + idle + nice;
    prev = info;
    if (total == 0) return 0;
    return (double)(user + sys + nice) / total * 100.0;
}

// ================= GPU utilization (%) =================
static double gpu_util(void) {
    @try {
        io_iterator_t iter = 0;
        CFMutableDictionaryRef match = IOServiceMatching("AGXAccelerator");
        if (!match) return -1;
        if (IOServiceGetMatchingServices(0, match, &iter) != KERN_SUCCESS) return -1;
        io_object_t entry = IOIteratorNext(iter);
        if (!entry) { IOObjectRelease(iter); return -1; }
        CFMutableDictionaryRef props = NULL;
        double util = -1;
        if (IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            NSDictionary *d = (__bridge NSDictionary *)props;
            id v = [d objectForKey:@"PerformanceStatistics"];
            if (v && [v isKindOfClass:[NSDictionary class]]) {
                id du = [v objectForKey:@"Device Utilization %"];
                if (du && [du respondsToSelector:@selector(integerValue)]) util = (double)[du integerValue];
            }
            CFRelease(props);
        }
        IOObjectRelease(entry);
        IOObjectRelease(iter);
        return util;
    } @catch (NSException *e) {
        dlog("gpu_util exception: %@", e);
        return -1;
    }
}

// ================= CPU frequency (MHz) =================
// Read voltage-states from IORegistry AppleARMIODevice — gives available frequency table
// For current frequency, use PerformanceStates from AppleCLPC
static int s_maxCpuFreq = 0;  // max CPU freq in MHz

static void init_cpu_freq(void) {
    @try {
        io_iterator_t iter = 0;
        CFMutableDictionaryRef match = IOServiceMatching("AppleARMIODevice");
        if (!match) return;
        if (IOServiceGetMatchingServices(0, match, &iter) != KERN_SUCCESS) return;
        io_object_t entry; int maxFreq = 0;
        while ((entry = IOIteratorNext(iter))) {
            CFMutableDictionaryRef props = NULL;
            if (IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
                NSDictionary *d = (__bridge NSDictionary *)props;
                // voltage-states is an NSData containing uint32 freq/voltage pairs
                id vs = [d objectForKey:@"voltage-states"];
                if (vs && [vs isKindOfClass:[NSData class]]) {
                    NSData *data = vs;
                    const uint32_t *p = (const uint32_t *)data.bytes;
                    NSUInteger cnt = data.length / sizeof(uint32_t);
                    // pairs: (freq_kHz, voltage) — or (freq_MHz, voltage) depending on device
                    for (NSUInteger i = 0; i + 1 < cnt; i += 2) {
                        int freq = (int)p[i];
                        if (freq > maxFreq && freq < 100000) maxFreq = freq; // sanity: <100GHz
                    }
                }
                id vs5 = [d objectForKey:@"voltage-states5"];
                if (vs5 && [vs5 isKindOfClass:[NSData class]]) {
                    NSData *data = vs5;
                    const uint32_t *p = (const uint32_t *)data.bytes;
                    NSUInteger cnt = data.length / sizeof(uint32_t);
                    for (NSUInteger i = 0; i + 1 < cnt; i += 2) {
                        int freq = (int)p[i];
                        if (freq > maxFreq && freq < 100000) maxFreq = freq;
                    }
                }
                CFRelease(props);
            }
            IOObjectRelease(entry);
        }
        IOObjectRelease(iter);
        // A16 iPhone 15 Pro Max: P-core max ~3464 MHz, E-core ~2016 MHz
        // voltage-states freq is in kHz on newer devices, MHz on older
        if (maxFreq > 100000) maxFreq /= 1000; // kHz -> MHz
        s_maxCpuFreq = maxFreq;
        dlog("init_cpu_freq: maxFreq=%d MHz", maxFreq);
    } @catch (NSException *e) {
        dlog("init_cpu_freq exception: %@", e);
    }
}

// Estimate current CPU frequency from utilization (if we can't read actual)
static double cpu_freq_mhz(void) {
    // Without IOReport, estimate from load: idle=min, busy=max
    double cpu = cpu_usage();
    if (s_maxCpuFreq == 0) return 0;
    // E-core min ~600 MHz, P-core max ~s_maxCpuFreq
    double minFreq = 600;
    double freq = minFreq + (s_maxCpuFreq - minFreq) * (cpu / 100.0);
    return freq;
}

// ================= ECG Waveform Chart View =================
@interface FreqMonChartView : UIView {
    CAShapeLayer *_gridLayer;
    CAShapeLayer *_cpuLayer;
    CAShapeLayer *_gpuLayer;
    CAShapeLayer *_freqLayer;
    NSMutableArray *_cpuHist;
    NSMutableArray *_gpuHist;
    NSMutableArray *_freqHist;
    UILabel *_label;
}
@property (nonatomic, assign) NSInteger maxSamples;
@end

@implementation FreqMonChartView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.7];
        self.layer.cornerRadius = 8;
        self.layer.masksToBounds = YES;
        _maxSamples = 120;
        _cpuHist = [NSMutableArray arrayWithCapacity:120];
        _gpuHist = [NSMutableArray arrayWithCapacity:120];
        _freqHist = [NSMutableArray arrayWithCapacity:120];
        
        // Grid layer
        _gridLayer = [CAShapeLayer layer];
        _gridLayer.strokeColor = [UIColor colorWithWhite:0.15 alpha:0.5].CGColor;
        _gridLayer.fillColor = [UIColor clearColor].CGColor;
        _gridLayer.lineWidth = 0.5;
        [self.layer addSublayer:_gridLayer];
        
        // CPU trace (green, glowing)
        _cpuLayer = [CAShapeLayer layer];
        _cpuLayer.strokeColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.3 alpha:0.95].CGColor;
        _cpuLayer.fillColor = [UIColor clearColor].CGColor;
        _cpuLayer.lineWidth = 1.5;
        _cpuLayer.shadowColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.3 alpha:0.8].CGColor;
        _cpuLayer.shadowRadius = 3;
        _cpuLayer.shadowOpacity = 0.8;
        _cpuLayer.shadowOffset = CGSizeZero;
        [self.layer addSublayer:_cpuLayer];
        
        // GPU trace (cyan)
        _gpuLayer = [CAShapeLayer layer];
        _gpuLayer.strokeColor = [UIColor colorWithRed:0.3 green:0.7 blue:1.0 alpha:0.8].CGColor;
        _gpuLayer.fillColor = [UIColor clearColor].CGColor;
        _gpuLayer.lineWidth = 1.2;
        [self.layer addSublayer:_gpuLayer];
        
        // Freq trace (yellow)
        _freqLayer = [CAShapeLayer layer];
        _freqLayer.strokeColor = [UIColor colorWithRed:1.0 green:0.85 blue:0.2 alpha:0.7].CGColor;
        _freqLayer.fillColor = [UIColor clearColor].CGColor;
        _freqLayer.lineWidth = 1.0;
        [self.layer addSublayer:_freqLayer];
        
        // Text label (top-left)
        _label = [[UILabel alloc] initWithFrame:CGRectMake(6, 2, frame.size.width - 8, 14)];
        _label.font = [UIFont systemFontOfSize:9 weight:UIFontWeightBold];
        _label.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.3 alpha:1.0];
        _label.numberOfLines = 1;
        _label.adjustsFontSizeToFitWidth = YES;
        _label.text = @"FreqMon";
        [self addSubview:_label];
        
        [self drawGrid];
    }
    return self;
}

- (void)drawGrid {
    UIBezierPath *grid = [UIBezierPath bezierPath];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    // Horizontal lines (4 divisions)
    for (int i = 1; i < 4; i++) {
        CGFloat y = h * i / 4.0;
        [grid moveToPoint:CGPointMake(0, y)];
        [grid addLineToPoint:CGPointMake(w, y)];
    }
    // Vertical lines (8 divisions)
    for (int i = 1; i < 8; i++) {
        CGFloat x = w * i / 8.0;
        [grid moveToPoint:CGPointMake(x, 0)];
        [grid addLineToPoint:CGPointMake(x, h)];
    }
    _gridLayer.path = grid.CGPath;
}

- (void)addSampleCPU:(double)cpu gpu:(double)gpu freq:(double)freq {
    [_cpuHist addObject:@(cpu)];
    [_gpuHist addObject:@(gpu)];
    [_freqHist addObject:@(freq)];
    while (_cpuHist.count > _maxSamples) [_cpuHist removeObjectAtIndex:0];
    while (_gpuHist.count > _maxSamples) [_gpuHist removeObjectAtIndex:0];
    while (_freqHist.count > _maxSamples) [_freqHist removeObjectAtIndex:0];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self drawGrid];
    CGFloat w = self.bounds.size.width;
    CGFloat h = self.bounds.size.height;
    CGFloat chartH = h - 16; // leave 16px at top for label
    CGFloat top = 16;
    NSInteger n = _cpuHist.count;
    if (n < 2) return;
    
    CGFloat dx = w / (CGFloat)_maxSamples;
    
    // CPU line (0-100%)
    {
        UIBezierPath *p = [UIBezierPath bezierPath];
        for (NSInteger i = 0; i < n; i++) {
            CGFloat x = (i + (_maxSamples - n)) * dx;
            CGFloat v = [_cpuHist[i] floatValue] / 100.0;
            CGFloat y = top + chartH - v * chartH;
            if (i == 0) [p moveToPoint:CGPointMake(x, y)];
            else [p addLineToPoint:CGPointMake(x, y)];
        }
        _cpuLayer.path = p.CGPath;
    }
    // GPU line (0-100%)
    {
        UIBezierPath *p = [UIBezierPath bezierPath];
        for (NSInteger i = 0; i < n; i++) {
            CGFloat x = (i + (_maxSamples - n)) * dx;
            CGFloat v = [_gpuHist[i] floatValue];
            if (v < 0) v = 0; if (v > 100) v = 100;
            v /= 100.0;
            CGFloat y = top + chartH - v * chartH;
            if (i == 0) [p moveToPoint:CGPointMake(x, y)];
            else [p addLineToPoint:CGPointMake(x, y)];
        }
        _gpuLayer.path = p.CGPath;
    }
    // Freq line (0 - maxFreq MHz, normalized to 0-1)
    {
        UIBezierPath *p = [UIBezierPath bezierPath];
        double maxF = s_maxCpuFreq > 0 ? s_maxCpuFreq : 3500;
        for (NSInteger i = 0; i < n; i++) {
            CGFloat x = (i + (_maxSamples - n)) * dx;
            CGFloat v = [_freqHist[i] floatValue] / maxF;
            if (v < 0) v = 0; if (v > 1) v = 1;
            CGFloat y = top + chartH - v * chartH;
            if (i == 0) [p moveToPoint:CGPointMake(x, y)];
            else [p addLineToPoint:CGPointMake(x, y)];
        }
        _freqLayer.path = p.CGPath;
    }
}

- (void)updateLabel:(NSString *)text { _label.text = text; }

@end

// ================= Window & main loop =================
static UIWindow *g_window;
static FreqMonChartView *g_chart;
static __weak UIWindowScene *g_cachedScene;

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
        win.windowLevel = 5000.0;
        win.backgroundColor = [UIColor clearColor];
        win.rootViewController = nil;
        win.userInteractionEnabled = NO;
        win.hidden = NO;
        g_window = win;
        
        // Chart view: 200x100 at top-left, below status bar
        CGRect chartFrame = CGRectMake(8, 55, 220, 90);
        g_chart = [[FreqMonChartView alloc] initWithFrame:chartFrame];
        g_chart.userInteractionEnabled = NO;
        [win addSubview:g_chart];
        
        dlog("window+chart created scene=%@", scene ? @"yes" : @"NIL");
        
        [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:YES block:^(NSTimer *t) {
            @autoreleasepool {
                double cpu = cpu_usage();
                double gpu = gpu_util();
                double freq = cpu_freq_mhz();
                [g_chart addSampleCPU:cpu gpu:gpu freq:freq];
                [g_chart updateLabel:[NSString stringWithFormat:@"CPU %.0f%% GPU %.0f%%  %.0fMHz",
                    cpu, (gpu < 0 ? 0 : gpu), freq]];
            }
        }];
    }
}

// ================= Entry =================
__attribute__((constructor))
static void freqmon_ctor(void) {
    @autoreleasepool {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid) bid = [[NSProcessInfo processInfo] processName];
        NSString *pname = [[NSProcessInfo processInfo] processName];
        BOOL isSB = [bid isEqualToString:@"com.apple.springboard"]
                 || [pname isEqualToString:@"SpringBoard"]
                 || [bid isEqualToString:@"com.apple.UIKit"];
        dlog("ctor: bid=%@ pname=%@ isSB=%d", bid, pname, (int)isSB);
        if (isSB) {
            // Init frequency table (safe, wrapped in @try)
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
                @autoreleasepool { init_cpu_freq(); }
            });
            static int tries = 0;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (g_window) return;
                create_window();
                if (!g_window && tries++ < 40) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)),
                                   dispatch_get_main_queue(), ^{
                        if (!g_window) create_window();
                    });
                }
            });
        }
    }
}
