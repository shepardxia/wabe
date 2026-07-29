#include "include/wabe_sensor.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>
#include <pthread.h>
#include <stdatomic.h>
#include <string.h>

// ---- SPU wake / sleep (registry property writes on AppleSPUHIDDriver, unprivileged) ----

static int setDriverProps(int reporting, int power, int interval_us) {
	io_iterator_t it = 0;
	if (IOServiceGetMatchingServices(kIOMainPortDefault,
			IOServiceMatching("AppleSPUHIDDriver"), &it) != KERN_SUCCESS)
		return 0;
	struct { const char *key; int32_t val; } props[] = {
		{"SensorPropertyReportingState", reporting},
		{"SensorPropertyPowerState", power},
		{"ReportInterval", interval_us},
	};
	int n = 0;
	io_service_t svc;
	while ((svc = IOIteratorNext(it))) {
		int ok = 1;
		for (int i = 0; i < 3; i++) {
			CFStringRef k = CFStringCreateWithCString(NULL, props[i].key, kCFStringEncodingUTF8);
			CFNumberRef v = CFNumberCreate(NULL, kCFNumberSInt32Type, &props[i].val);
			if (IORegistryEntrySetCFProperty(svc, k, v) != KERN_SUCCESS) ok = 0;
			CFRelease(k);
			CFRelease(v);
		}
		if (ok) n++;
		IOObjectRelease(svc);
	}
	IOObjectRelease(it);
	return n;
}

static int lastWakeInterval = 1000;

int ws_wake(int interval_us) {
	lastWakeInterval = interval_us;
	return setDriverProps(1, 1, interval_us);
}
int ws_sleep(void) { return setDriverProps(0, 0, 0); }

// ---- SPSC rings, one per sensor. Producer = HID callback thread, consumer = Swift. ----

#define RING_CAP 8192  // power of two; ~10 s of headroom at 795 Hz

typedef struct {
	ws_sample buf[RING_CAP];
	_Atomic size_t head, tail;  // head = next write, tail = next read
} ring;

static ring rings[2];  // 0 = accel, 1 = gyro

static void ring_push(ring *r, ws_sample s) {
	size_t h = atomic_load_explicit(&r->head, memory_order_relaxed);
	size_t t = atomic_load_explicit(&r->tail, memory_order_acquire);
	if (h - t >= RING_CAP) return;  // full: drop newest; consumer is wedged anyway
	r->buf[h & (RING_CAP - 1)] = s;
	atomic_store_explicit(&r->head, h + 1, memory_order_release);
}

static size_t ring_drain(ring *r, ws_sample *out, size_t max) {
	size_t t = atomic_load_explicit(&r->tail, memory_order_relaxed);
	size_t h = atomic_load_explicit(&r->head, memory_order_acquire);
	size_t n = h - t;
	if (n > max) n = max;
	for (size_t i = 0; i < n; i++) out[i] = r->buf[(t + i) & (RING_CAP - 1)];
	atomic_store_explicit(&r->tail, t + n, memory_order_release);
	return n;
}

size_t ws_read_accel(ws_sample *out, size_t max) { return ring_drain(&rings[0], out, max); }
size_t ws_read_gyro(ws_sample *out, size_t max) { return ring_drain(&rings[1], out, max); }

// ---- reader thread ----

static double mono_now(void) {
	return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9;
}

static float axis(const uint8_t *r, int off) {
	int32_t v = (int32_t)((uint32_t)r[off] | ((uint32_t)r[off + 1] << 8) |
	                      ((uint32_t)r[off + 2] << 16) | ((uint32_t)r[off + 3] << 24));
	return (float)(v / 65536.0);
}

static uint8_t cbBuf[2][256];

static void onReport(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                     uint32_t reportID, uint8_t *report, CFIndex length) {
	if (length < 18) return;
	ws_sample s = {mono_now(), axis(report, 6), axis(report, 10), axis(report, 14)};
	ring_push(&rings[(long)ctx], s);
}

static long numProp(IOHIDDeviceRef d, CFStringRef key) {
	CFTypeRef v = IOHIDDeviceGetProperty(d, key);
	long out = -1;
	if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &out);
	return out;
}

static IOHIDDeviceRef findSPU(IOHIDManagerRef mgr, long page, long usage) {
	CFSetRef devices = IOHIDManagerCopyDevices(mgr);
	CFIndex n = devices ? CFSetGetCount(devices) : 0;
	if (!n) return NULL;
	IOHIDDeviceRef *devs = malloc(sizeof(IOHIDDeviceRef) * n);
	CFSetGetValues(devices, (const void **)devs);
	IOHIDDeviceRef found = NULL;
	for (CFIndex i = 0; i < n && !found; i++) {
		if (numProp(devs[i], CFSTR(kIOHIDPrimaryUsagePageKey)) == page &&
		    numProp(devs[i], CFSTR(kIOHIDPrimaryUsageKey)) == usage)
			found = devs[i];
	}
	free(devs);
	CFRelease(devices);
	return found;  // borrowed; manager keeps ownership
}

static pthread_t readerThread;
static CFRunLoopRef readerLoop;
static _Atomic int running;

// The accel stream fails to start on a large fraction of opens, and neither in-process reopen,
// driver ReportingState bounces, nor seize-open ever revived a stuck instance past attempt 2
// (measured; see NOTES.md "accel stream stall"). Retry with a fresh IOHIDManager a few times,
// then report dead — the caller re-execs the process, which reliably rerolls the stall.
static int openVerified(long usage, long ringIdx) {
	for (int attempt = 1; attempt <= 3; attempt++) {
		IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
		IOHIDManagerSetDeviceMatching(mgr, NULL);
		IOHIDDeviceRef d = findSPU(mgr, 0xFF00, usage);
		if (!d || IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
			CFRelease(mgr);
			usleep(50000);
			continue;
		}
		IOHIDDeviceRegisterInputReportCallback(d, cbBuf[ringIdx], sizeof(cbBuf[ringIdx]),
			onReport, (void *)ringIdx);
		IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

		size_t before = atomic_load(&rings[ringIdx].head);
		double deadline = mono_now() + 0.25;
		while (mono_now() < deadline)
			CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
		if (atomic_load(&rings[ringIdx].head) != before) {
			if (attempt > 1)
				fprintf(stderr, "ws: usage %ld streaming after %d attempts\n", usage, attempt);
			return 0;
		}
		IOHIDDeviceUnscheduleFromRunLoop(d, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
		IOHIDDeviceRegisterInputReportCallback(d, cbBuf[ringIdx], sizeof(cbBuf[ringIdx]), NULL, NULL);
		IOHIDDeviceClose(d, kIOHIDOptionsTypeNone);
		CFRelease(mgr);
		usleep(50000);
	}
	fprintf(stderr, "ws: usage %ld DEAD after 3 attempts\n", usage);
	return -1;
}

static _Atomic int openedMask;

int ws_opened_mask(void) { return atomic_load(&openedMask); }

static void *readerMain(void *arg) {
	int mask = 0;
	if (openVerified(3, 0) == 0) mask |= 1;  // accel
	if (openVerified(9, 1) == 0) mask |= 2;  // gyro
	atomic_store(&openedMask, mask);
	if (!mask) {
		atomic_store(&running, -1);
		return NULL;
	}

	readerLoop = CFRunLoopGetCurrent();
	atomic_store(&running, 1);
	while (atomic_load(&running) == 1)
		CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.25, false);
	return NULL;
}

int ws_start(void) {
	atomic_store(&running, 0);
	if (pthread_create(&readerThread, NULL, readerMain, NULL) != 0) return -1;
	while (atomic_load(&running) == 0) usleep(1000);
	return atomic_load(&running) == 1 ? 0 : -1;
}

void ws_stop(void) {
	if (atomic_load(&running) != 1) return;
	atomic_store(&running, 2);
	if (readerLoop) CFRunLoopWakeUp(readerLoop);
	pthread_join(readerThread, NULL);
}

// ---- lid angle: synchronous GetReport poll, own device handle ----

static IOHIDDeviceRef lidDev;
static IOHIDManagerRef lidMgr;

double ws_lid_deg(void) {
	if (!lidDev) {
		lidMgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
		IOHIDManagerSetDeviceMatching(lidMgr, NULL);
		lidDev = findSPU(lidMgr, 0x20, 0x8A);
		if (!lidDev || IOHIDDeviceOpen(lidDev, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
			lidDev = NULL;
			return -1.0;
		}
	}
	uint8_t buf[8] = {0};
	CFIndex len = sizeof(buf);
	if (IOHIDDeviceGetReport(lidDev, kIOHIDReportTypeInput, 7, buf, &len) != kIOReturnSuccess ||
	    len < 3)
		return -1.0;
	return (double)(buf[1] | (buf[2] << 8)) / 100.0;
}
