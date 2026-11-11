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

// ================= IORegistry helpers =================
static NSDictionary *ioPropsForClass(NSString *className) {
    @try {
        io_iterator_t iter = 0;
        CFMutableDictionaryRef match = IOServiceMatching(className.UTF8String);
        if (!match) return nil;
        if (IOServiceGetMatchingServices(0, match, &iter) != KERN_SUCCESS) return nil;
        io_object_t entry = IOIteratorNext(iter);
        if (!entry) { IOObjectRelease(iter); return nil; }
        CFMutableDictionaryRef props = NULL;
        NSDictionary *result = nil;
        if (IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            result = [(__bridge NSDictionary *)props copy];
            CFRelease(props);
        }
        IOObjectRelease(entry);
        IOObjectRelease(iter);
        return result;
    } @catch (NSException *e) { return nil; }
}

static NSDictionary *ioPropsForService(NSString *className) {
    // Get first matching service (singular)
    @try {
        CFMutableDictionaryRef match = IOServiceMatching(className.UTF8String);
        if (!match) return nil;
        io_service_t svc = IOServiceGetMatchingService(0, match);
        if (!svc) return nil;
        CFMutableDictionaryRef props = NULL;
        NSDictionary *result = nil;
        if (IORegistryEntryCreateCFProperties(svc, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS && props) {
            result = [(__bridge NSDictionary *)props copy];
            CFRelease(props);
        }
        IOObjectRelease(svc);
        return result;
    } @catch (NSException *e) { return nil; }
}

// ================= Data readers =================
static double s_gpuUtil = -1;
static double s_gpuFreq = 0;
static int s_maxCpuFreq = 0;
static double s_battCurrent = 0;
static double s_battTemp = 0;
static int s_battPercent = 0;

static void readGpuData(void) {
    @try {
        NSDictionary *d = ioPropsForClass(@"AGXAccelerator");
        if (!d) return;
        NSDictionary *ps = [d objectForKey:@"PerformanceStatistics"];
        if (!ps) return;
        id du = [ps objectForKey:@"Device Utilization %"];
        if (du && [du respondsToSelector:@selector(integerValue)]) s_gpuUtil = (double)[du integerValue];
        // GPU frequency: try various keys
        for (NSString *k in @[@"GPU Clock", @"gpuClock", @"Freq", @"frequency", @"GPU Frequency (MHz)", @"GpuCoreClock"]) {
            id v = [ps objectForKey:k];
            if (v && [v respondsToSelector:@selector(integerValue)]) { s_gpuFreq = (double)[v integerValue]; break; }
        }
    } @catch (NSException *e) {}
}

static void initCpuFreq(void) {
    @try {
        NSDictionary *d = ioPropsForClass(@"AppleARMIODevice");
        if (!d) return;
        NSData *vs = [d objectForKey:@"voltage-states"];
        if (vs) {
            const uint32_t *p = (const uint32_t *)vs.bytes;
            NSUInteger cnt = vs.length / sizeof(uint32_t);
            int maxF = 0;
            for (NSUInteger i = 0; i + 1 < cnt; i += 2) {
                int freq = (int)p[i];
                if (freq > maxF && freq < 100000) maxF = freq;
            }
            if (maxF > 100000) maxF /= 1000;
            s_maxCpuFreq = maxF;
        }
    } @catch (NSException *e) {}
    dlog("initCpuFreq max=%d", s_maxCpuFreq);
}

static void readBattery(void) {
    @try {
        NSDictionary *d = ioPropsForService(@"AppleSmartBattery");
        if (!d) return;
        id cur = [d objectForKey:@"Amperage"];
        if (cur && [cur respondsToSelector:@selector(integerValue)]) s_battCurrent = (double)[cur integerValue] / 1000.0;
        id tmp = [d objectForKey:@"Temperature"];
        if (tmp && [tmp respondsToSelector:@selector(integerValue)]) s_battTemp = (double)[tmp integerValue] / 100.0;
        id cap = [d objectForKey:@"CurrentCapacity"];
        id mx = [d objectForKey:@"MaxCapacity"];
        if (cap && mx && [mx integerValue] > 0) s_battPercent = (int)([cap integerValue] * 100 / [mx integerValue]);
    } @catch (NSException *e) {}
}

// ================= ECG Waveform View =================
@interface FreqMonView : UIView {
    CAShapeLayer *_gridLayer;
    CAShapeLayer *_cpuWave;
    CAShapeLayer *_gpuWave;
    NSMutableArray *_cpuHist;
    NSMutableArray *_gpuHist;
    UILabel *_line1;
    UILabel *_line2;
    UILabel *_line3;
    UILabel *_line4;
}
@property (nonatomic, assign) NSInteger maxSamples;
@end

@implementation FreqMonView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.02 alpha:0.82];
        self.layer.cornerRadius = 10;
        self.layer.masksToBounds = YES;
        self.layer.borderColor = [UIColor colorWithWhite:0.2 alpha:0.5].CGColor;
        self.layer.borderWidth = 0.5;
        _maxSamples = 80;
        _cpuHist = [NSMutableArray arrayWithCapacity:80];
        _gpuHist = [NSMutableArray arrayWithCapacity:80];
        
        CGFloat w = frame.size.width;
        
        // Text lines (top area)
        CGFloat ty = 6;
        _line1 = [[UILabel alloc] initWithFrame:CGRectMake(8, ty, w-16, 14)];
        _line1.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
        _line1.textColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.3 alpha:1.0];
        _line1.text = @"CPU --- MHz  --%";
        [self addSubview:_line1]; ty += 15;
        
        _line2 = [[UILabel alloc] initWithFrame:CGRectMake(8, ty, w-16, 14)];
        _line2.font = [UIFont systemFontOfSize:10 weight:UIFontWeightBold];
        _line2.textColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:1.0];
        _line2.text = @"GPU --- MHz  --%";
        [self addSubview:_line2]; ty += 15;
        
        // Waveform area
        CGFloat waveTop = ty + 2;
        CGFloat waveH = 70;
        
        _gridLayer = [CAShapeLayer layer];
        _gridLayer.strokeColor = [UIColor colorWithWhite:0.12 alpha:0.6].CGColor;
        _gridLayer.fillColor = [UIColor clearColor].CGColor;
        _gridLayer.lineWidth = 0.5;
        [self.layer addSublayer:_gridLayer];
        
        _cpuWave = [CAShapeLayer layer];
        _cpuWave.strokeColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.3 alpha:0.95].CGColor;
        _cpuWave.fillColor = [UIColor clearColor].CGColor;
        _cpuWave.lineWidth = 1.5;
        _cpuWave.shadowColor = [UIColor colorWithRed:0.2 green:1.0 blue:0.3 alpha:0.6].CGColor;
        _cpuWave.shadowRadius = 2;
        _cpuWave.shadowOpacity = 0.8;
        _cpuWave.shadowOffset = CGSizeZero;
        [self.layer addSublayer:_cpuWave];
        
        _gpuWave = [CAShapeLayer layer];
        _gpuWave.strokeColor = [UIColor colorWithRed:0.3 green:0.8 blue:1.0 alpha:0.8].CGColor;
        _gpuWave.fillColor = [UIColor clearColor].CGColor;
        _gpuWave.lineWidth = 1.2;
        [self.layer addSublayer:_gpuWave];
        
        // Draw grid
        UIBezierPath *grid = [UIBezierPath bezierPath];
        for (int i = 1; i < 4; i++) {
            CGFloat y = waveTop + waveH * i / 4.0;
            [grid moveToPoint:CGPointMake(0, y)];
            [grid addLineToPoint:CGPointMake(w, y)];
        }
        for (int i = 1; i < 6; i++) {
            CGFloat x = w * i / 6.0;
            [grid moveToPoint:CGPointMake(x, waveTop)];
            [grid addLineToPoint:CGPointMake(x, waveTop + waveH)];
        }
        _gridLayer.path = grid.CGPath;
        
        // Save wave frame
        objc_setAssociatedObject(self, "waveTop", @(waveTop), OBJC_ASSOCIATION_RETAIN);
        objc_setAssociatedObject(self, "waveH", @(waveH), OBJC_ASSOCIATION_RETAIN);
        
        // Bottom info lines
        ty = waveTop + waveH + 4;
        _line3 = [[UILabel alloc] initWithFrame:CGRectMake(8, ty, w-16, 12)];
        _line3.font = [UIFont systemFontOfSize:9 weight:UIFontWeightMedium];
        _line3.textColor = [UIColor colorWithWhite:0.7 alpha:1.0];
        _line3.text = @"--.-°C  --mA  --%";
        [self addSubview:_line3]; ty += 13;
        
        _line4 = [[UILabel alloc] initWithFrame:CGRectMake(8, ty, w-16, 12)];
        _line4.font = [UIFont systemFontOfSize:8 weight:UIFontWeightRegular];
        _line4.textColor = [UIColor colorWithWhite:0.5 alpha:0.8];
        _line4.text = @"A16 • iPhone15,3";
        [self addSubview:_line4];
    }
    return self;
}

- (void)addSampleCPU:(double)cpu gpu:(double)gpu {
    [_cpuHist addObject:@(cpu)];
    [_gpuHist addObject:@(gpu)];
    while (_cpuHist.count > _maxSamples) [_cpuHist removeObjectAtIndex:0];
    while (_gpuHist.count > _maxSamples) [_gpuHist removeObjectAtIndex:0];
    
    NSNumber *wtObj = objc_getAssociatedObject(self, "waveTop");
    NSNumber *whObj = objc_getAssociatedObject(self, "waveH");
    CGFloat waveTop = [wtObj floatValue];
    CGFloat waveH = [whObj floatValue];
    CGFloat w = self.bounds.size.width;
    NSInteger n = _cpuHist.count;
    if (n < 2) return;
    CGFloat dx = w / (CGFloat)_maxSamples;
    
    // CPU wave
    {
        UIBezierPath *p = [UIBezierPath bezierPath];
        for (NSInteger i = 0; i < n; i++) {
            CGFloat x = (i + (_maxSamples - n)) * dx;
            CGFloat v = [_cpuHist[i] floatValue] / 100.0;
            CGFloat y = waveTop + waveH - v * waveH;
            if (i == 0) [p moveToPoint:CGPointMake(x, y)];
            else [p addLineToPoint:CGPointMake(x, y)];
        }
        _cpuWave.path = p.CGPath;
    }
    // GPU wave
    {
        UIBezierPath *p = [UIBezierPath bezierPath];
        for (NSInteger i = 0; i < n; i++) {
            CGFloat x = (i + (_maxSamples - n)) * dx;
            CGFloat v = [_gpuHist[i] floatValue];
            if (v < 0) v = 0; if (v > 100) v = 100;
            v /= 100.0;
            CGFloat y = waveTop + waveH - v * waveH;
            if (i == 0) [p moveToPoint:CGPointMake(x, y)];
            else [p addLineToPoint:CGPointMake(x, y)];
        }
        _gpuWave.path = p.CGPath;
    }
}

- (void)updateText:(NSString *)l1 gpu:(NSString *)l2 info:(NSString *)l3 {
    _line1.text = l1;
    _line2.text = l2;
    _line3.text = l3;
}

@end

// ================= Window =================
static UIWindow *g_window;
static FreqMonView *g_view;
static __weak UIWindowScene *g_cachedScene;

static UIWindowScene *pick_scene(void) {
    if (g_cachedScene) return g_cachedScene;
    @try {
        UIWindowScene *any = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            if (!any) any = (UIWindowScene *)sc;
            if (sc.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)sc;
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
        
        CGRect vf = CGRectMake(8, 55, 230, 175);
        g_view = [[FreqMonView alloc] initWithFrame:vf];
        g_view.userInteractionEnabled = NO;
        [win addSubview:g_view];
        
        dlog("window+card created scene=%@", scene ? @"yes" : @"NIL");
        
        // Init frequency table + battery in background
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_BACKGROUND, 0), ^{
            @autoreleasepool { initCpuFreq(); readBattery(); }
        });
        
        [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) {
            @autoreleasepool {
                double cpu = cpu_usage();
                double gpu = s_gpuUtil;
                // Refresh GPU data periodically (lighter than every tick)
                static int gpuTick = 0;
                if (++gpuTick % 4 == 0) { readGpuData(); readBattery(); }
                
                double cpuFreq = 0;
                if (s_maxCpuFreq > 0) {
                    double minF = 600;
                    cpuFreq = minF + (s_maxCpuFreq - minF) * (cpu / 100.0);
                }
                
                [g_view addSampleCPU:cpu gpu:(gpu < 0 ? 0 : gpu)];
                
                NSString *l1 = [NSString stringWithFormat:@"CPU %.0f MHz  %.0f%%", cpuFreq, cpu];
                NSString *l2 = [NSString stringWithFormat:@"GPU %.0f MHz  %.0f%%", s_gpuFreq, (gpu < 0 ? 0 : gpu)];
                NSString *l3 = [NSString stringWithFormat:@"%.1f°C  %.0fmA  %d%%", s_battTemp, s_battCurrent, s_battPercent];
                [g_view updateText:l1 gpu:l2 info:l3];
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
