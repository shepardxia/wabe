// Open the SPU accelerometer (0xFF00 usage 3) and gyroscope (0xFF00 usage 9) and stream input
// reports. Needs root. Doubles as (a) a wire-format check -- mean |accel| should read ~1g while the
// machine sits still -- and (b) a steady ~100Hz subscriber for the power measurement.
//
// Format per prior reverse engineering: x/y/z are int32 LE at byte offsets 6/10/14, scale 1/65536.
// Usage: imu100 <seconds> [--quiet]
#include <IOKit/hid/IOHIDManager.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ACCEL 0
#define GYRO 1
#define RBUF 256

static uint8_t buffers[2][RBUF];
static const char *names[2] = {"accel", "gyro"};
static long counts[2];
static double sumMag[2], firstSeen[2];
static int quiet;
static int printed[2];

static double now(void) {
	return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9;
}

static double axis(const uint8_t *r, int off) {
	int32_t v = (int32_t)((uint32_t)r[off] | ((uint32_t)r[off + 1] << 8) |
	                      ((uint32_t)r[off + 2] << 16) | ((uint32_t)r[off + 3] << 24));
	return v / 65536.0;
}

static void onReport(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                     uint32_t reportID, uint8_t *report, CFIndex length) {
	long which = (long)ctx;
	if (counts[which] == 0) firstSeen[which] = now();
	counts[which]++;

	if (length < 18) return;
	double x = axis(report, 6), y = axis(report, 10), z = axis(report, 14);
	sumMag[which] += sqrt(x * x + y * y + z * z);

	if (!quiet && printed[which] < 3) {
		printed[which]++;
		printf("  %s sample: x=%+8.4f y=%+8.4f z=%+8.4f  |v|=%.4f  (len=%ld)\n",
			names[which], x, y, z, sqrt(x * x + y * y + z * z), (long)length);
	}
}

static long numProp(IOHIDDeviceRef d, CFStringRef key) {
	CFTypeRef v = IOHIDDeviceGetProperty(d, key);
	long out = -1;
	if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &out);
	return out;
}

int main(int argc, char **argv) {
	double seconds = argc > 1 ? atof(argv[1]) : 5.0;
	quiet = (argc > 2 && strcmp(argv[2], "--quiet") == 0);

	IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
	IOHIDManagerSetDeviceMatching(mgr, NULL);
	CFSetRef devices = IOHIDManagerCopyDevices(mgr);
	CFIndex n = devices ? CFSetGetCount(devices) : 0;
	if (n == 0) { fprintf(stderr, "no HID devices\n"); return 1; }
	IOHIDDeviceRef *devs = malloc(sizeof(IOHIDDeviceRef) * n);
	CFSetGetValues(devices, (const void **)devs);

	int opened = 0;
	for (CFIndex i = 0; i < n; i++) {
		IOHIDDeviceRef d = devs[i];
		if (numProp(d, CFSTR(kIOHIDPrimaryUsagePageKey)) != 0xFF00) continue;
		long usage = numProp(d, CFSTR(kIOHIDPrimaryUsageKey));
		long which = usage == 3 ? ACCEL : (usage == 9 ? GYRO : -1);
		if (which < 0) continue;

		IOReturn r = IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone);
		if (!quiet) printf("%s (usage %ld): IOHIDDeviceOpen = 0x%08x\n", names[which], usage, r);
		if (r != kIOReturnSuccess) continue;

		IOHIDDeviceRegisterInputReportCallback(d, buffers[which], RBUF, onReport, (void *)which);
		IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
		opened++;
	}
	if (opened == 0) { fprintf(stderr, "opened nothing (need root?)\n"); return 1; }

	if (!quiet) printf("streaming %.1fs...\n", seconds);
	double t0 = now();
	CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
	double elapsed = now() - t0;

	printf("\n=== %.1fs elapsed ===\n", elapsed);
	for (int i = 0; i < 2; i++) {
		if (counts[i] == 0) { printf("  %-5s : no reports\n", names[i]); continue; }
		printf("  %-5s : %ld reports, %.1f Hz, mean |v| = %.4f %s\n", names[i], counts[i],
			counts[i] / elapsed, sumMag[i] / counts[i], i == ACCEL ? "g" : "deg/s");
	}
	return 0;
}
