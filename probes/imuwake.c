// Wake the SPU sensor drivers (root: sets registry properties on AppleSPUHIDDriver), then stream
// accel/gyro to confirm they report. Split from imu100 so we can test whether the wake persists for
// later unprivileged readers -- which decides whether a pose daemon needs to hold root or only needs
// it once at setup.
// Usage: imuwake [--wake-only] [seconds]
#include <IOKit/IOKitLib.h>
#include <IOKit/hid/IOHIDManager.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int wakeSPUDrivers(void) {
	CFMutableDictionaryRef match = IOServiceMatching("AppleSPUHIDDriver");
	io_iterator_t it = 0;
	if (IOServiceGetMatchingServices(kIOMainPortDefault, match, &it) != KERN_SUCCESS) {
		printf("IOServiceGetMatchingServices failed\n");
		return 0;
	}

	const char *keys[] = {"SensorPropertyReportingState", "SensorPropertyPowerState", "ReportInterval"};
	int32_t vals[] = {1, 1, 1000};

	int nsvc = 0;
	io_service_t svc;
	while ((svc = IOIteratorNext(it))) {
		nsvc++;
		for (int i = 0; i < 3; i++) {
			CFStringRef k = CFStringCreateWithCString(NULL, keys[i], kCFStringEncodingUTF8);
			CFNumberRef v = CFNumberCreate(NULL, kCFNumberSInt32Type, &vals[i]);
			kern_return_t r = IORegistryEntrySetCFProperty(svc, k, v);
			printf("  svc%d %-30s = %d -> 0x%08x %s\n", nsvc, keys[i], vals[i], r,
				r == KERN_SUCCESS ? "(ok)" : "(FAILED)");
			CFRelease(k);
			CFRelease(v);
		}
		IOObjectRelease(svc);
	}
	IOObjectRelease(it);
	printf("  matched %d AppleSPUHIDDriver service(s)\n", nsvc);
	return nsvc;
}

#define ACCEL 0
#define GYRO 1
static uint8_t buffers[2][4096];
static const char *names[2] = {"accel", "gyro"};
static long counts[2];
static double sumMag[2];
static int printed[2];

static double axis(const uint8_t *r, int off) {
	int32_t v = (int32_t)((uint32_t)r[off] | ((uint32_t)r[off + 1] << 8) |
	                      ((uint32_t)r[off + 2] << 16) | ((uint32_t)r[off + 3] << 24));
	return v / 65536.0;
}

static void onReport(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                     uint32_t reportID, uint8_t *report, CFIndex length) {
	long w = (long)ctx;
	counts[w]++;
	if (length < 18) return;
	double x = axis(report, 6), y = axis(report, 10), z = axis(report, 14);
	double mag = sqrt(x * x + y * y + z * z);
	sumMag[w] += mag;
	if (printed[w] < 3) {
		printed[w]++;
		printf("  %s: x=%+8.4f y=%+8.4f z=%+8.4f |v|=%.4f (len=%ld)\n",
			names[w], x, y, z, mag, (long)length);
	}
}

static long numProp(IOHIDDeviceRef d, CFStringRef key) {
	CFTypeRef v = IOHIDDeviceGetProperty(d, key);
	long out = -1;
	if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &out);
	return out;
}

int main(int argc, char **argv) {
	int wakeOnly = 0, argi = 1;
	if (argc > argi && strcmp(argv[argi], "--wake-only") == 0) { wakeOnly = 1; argi++; }
	double seconds = argc > argi ? atof(argv[argi]) : 5.0;

	printf("=== waking SPU drivers (uid=%d) ===\n", geteuid());
	wakeSPUDrivers();
	if (wakeOnly) { printf("wake-only, exiting\n"); return 0; }

	printf("=== streaming %.1fs ===\n", seconds);
	IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
	IOHIDManagerSetDeviceMatching(mgr, NULL);
	CFSetRef devices = IOHIDManagerCopyDevices(mgr);
	CFIndex n = devices ? CFSetGetCount(devices) : 0;
	IOHIDDeviceRef *devs = malloc(sizeof(IOHIDDeviceRef) * n);
	CFSetGetValues(devices, (const void **)devs);

	for (CFIndex i = 0; i < n; i++) {
		IOHIDDeviceRef d = devs[i];
		if (numProp(d, CFSTR(kIOHIDPrimaryUsagePageKey)) != 0xFF00) continue;
		long u = numProp(d, CFSTR(kIOHIDPrimaryUsageKey));
		long w = u == 3 ? ACCEL : (u == 9 ? GYRO : -1);
		if (w < 0) continue;
		if (IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) != kIOReturnSuccess) continue;
		IOHIDDeviceRegisterInputReportCallback(d, buffers[w], sizeof(buffers[w]), onReport, (void *)w);
		IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
	}
	CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);

	printf("\n=== result ===\n");
	for (int i = 0; i < 2; i++) {
		if (!counts[i]) { printf("  %-5s : NO REPORTS\n", names[i]); continue; }
		printf("  %-5s : %ld reports, %.1f Hz, mean |v| = %.4f %s\n", names[i], counts[i],
			counts[i] / seconds, sumMag[i] / counts[i], i == ACCEL ? "g" : "deg/s");
	}
	return 0;
}
