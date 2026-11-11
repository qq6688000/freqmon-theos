// IOReport functions (loaded via dlopen from /usr/lib/libIOReport.dylib)
#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>

typedef CFArrayRef (*IOReportCopyAllChannels_t)(void);
typedef CFDictionaryRef (*IOReportCreateSubscription_t)(mach_port_t, CFDictionaryRef, CFDictionaryRef*, const char*, uint64_t, ...);
typedef CFDictionaryRef (*IOReportCreateSamples_t)(CFDictionaryRef, CFDictionaryRef, ...);
typedef CFDictionaryRef (*IOReportCreateSamplesDelta_t)(CFDictionaryRef, CFDictionaryRef);

static void *s_iolib = NULL;
static IOReportCopyAllChannels_t s_copyAllChannels = NULL;
static IOReportCreateSubscription_t s_createSubscription = NULL;
static IOReportCreateSamples_t s_createSamples = NULL;

static int ioreport_init(void) {
    if (s_iolib) return 1;
    s_iolib = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY | RTLD_LOCAL);
    if (!s_iolib) return 0;
    s_copyAllChannels = (IOReportCopyAllChannels_t)dlsym(s_iolib, "IOReportCopyAllChannels");
    s_createSubscription = (IOReportCreateSubscription_t)dlsym(s_iolib, "IOReportCreateSubscription");
    s_createSamples = (IOReportCreateSamples_t)dlsym(s_iolib, "IOReportCreateSamples");
    return (s_copyAllChannels && s_createSubscription && s_createSamples) ? 1 : 0;
}
