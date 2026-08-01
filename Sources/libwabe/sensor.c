#include "wabe_sensor.h"
#include "hid.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>
#include <pthread.h>
#include <stdatomic.h>
#include <math.h>
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


int ws_wake(int interval_us) {
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

#define PROBE_MAX 48

static int axisOffsets[3] = {6, 10, 14};  // documented layout; only used once gravity confirms it
static _Atomic int layoutKnown;
static _Atomic int probing;
static _Atomic int probeCount;
static uint8_t probeBuf[PROBE_MAX][64];
static CFIndex probeLen[PROBE_MAX];

static void onReport(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                     uint32_t reportID, uint8_t *report, CFIndex length) {
	if (atomic_load(&probing)) {
		int i = atomic_fetch_add(&probeCount, 1);
		if (i < PROBE_MAX) {
			CFIndex n = length > (CFIndex)sizeof(probeBuf[0]) ? (CFIndex)sizeof(probeBuf[0]) : length;
			memcpy(probeBuf[i], report, (size_t)n);
			probeLen[i] = n;
		}
		return;
	}
	if (length < axisOffsets[2] + 4) return;
	ws_sample s = {mono_now(), axis(report, axisOffsets[0]), axis(report, axisOffsets[1]),
	               axis(report, axisOffsets[2])};
	ring_push(&rings[(long)ctx], s);
}

// Pick the offset triple whose accelerometer magnitude sits closest to 1 g across the probe
// window. Wrong layouts land orders of magnitude off, so the accept band is wide.
static int discoverLayout(void) {
	int n = atomic_load(&probeCount);
	if (n > PROBE_MAX) n = PROBE_MAX;
	if (n < 4) return -1;

	int best = -1;
	double bestErr = 1e9;
	for (int off = 2; off + 12 <= 60; off += 2) {
		double sum = 0;
		int used = 0;
		for (int i = 0; i < n; i++) {
			if (probeLen[i] < off + 12) continue;
			double x = axis(probeBuf[i], off), y = axis(probeBuf[i], off + 4),
			       z = axis(probeBuf[i], off + 8);
			sum += sqrt(x * x + y * y + z * z);
			used++;
		}
		if (used < 4) continue;
		double mean = sum / used;
		if (mean < 0.25 || mean > 4.0) continue;  // not an acceleration in g
		double err = fabs(mean - 1.0);
		if (err < bestErr) {
			bestErr = err;
			best = off;
		}
	}
	if (best < 0) return -1;
	axisOffsets[0] = best;
	axisOffsets[1] = best + 4;
	axisOffsets[2] = best + 8;
	atomic_store(&layoutKnown, 1);
	fprintf(stderr, "ws: report layout axes at %d/%d/%d%s\n", best, best + 4, best + 8,
	        best == 6 ? "" : " (differs from the documented layout)");
	return 0;
}

int ws_layout_known(void) { return atomic_load(&layoutKnown); }

static pthread_t readerThread;
static CFRunLoopRef readerLoop;
static _Atomic int running;

static int openVerified(long usage, long ringIdx, int probe) {
	for (int attempt = 1; attempt <= 3; attempt++) {
		IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
		IOHIDManagerSetDeviceMatching(mgr, NULL);
		IOHIDDeviceRef d = wabe_hid_find(mgr, 0xFF00, usage);
		if (!d || IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
			CFRelease(mgr);
			usleep(50000);
			continue;
		}
		IOHIDDeviceRegisterInputReportCallback(d, cbBuf[ringIdx], sizeof(cbBuf[ringIdx]),
			onReport, (void *)ringIdx);
		IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

		size_t before = atomic_load(&rings[ringIdx].head);
		if (probe) {
			atomic_store(&probeCount, 0);
			atomic_store(&probing, 1);
		}
		double deadline = mono_now() + 0.25;
		while (mono_now() < deadline)
			CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, false);
		int flowed = probe ? atomic_load(&probeCount) > 0
		                   : atomic_load(&rings[ringIdx].head) != before;
		if (probe) {
			if (flowed && discoverLayout() != 0)
				fprintf(stderr, "ws: no byte offset yields a 1 g magnitude; layout unrecognised\n");
			atomic_store(&probing, 0);
		}
		if (flowed) {
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
	// Accel first and with probing on: gravity is the only reference that can confirm the
	// report layout, and the gyro shares it.
	if (openVerified(3, 0, 1) == 0) mask |= 1;
	if (openVerified(9, 1, 0) == 0) mask |= 2;
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
