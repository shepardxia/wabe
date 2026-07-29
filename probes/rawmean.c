// Mean raw accel vector (chip frame) over N seconds. For the physical axis-mapping test:
// hold the machine in a known orientation, read which chip axis gravity lands on.
#include <IOKit/hid/IOHIDManager.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static double sum[3];
static long count;
static uint8_t buf[4096];

static float axis(const uint8_t *r, int off) {
	int32_t v = (int32_t)((uint32_t)r[off] | ((uint32_t)r[off + 1] << 8) |
	                      ((uint32_t)r[off + 2] << 16) | ((uint32_t)r[off + 3] << 24));
	return (float)(v / 65536.0);
}

static void onReport(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                     uint32_t reportID, uint8_t *report, CFIndex length) {
	if (length < 18) return;
	sum[0] += axis(report, 6);
	sum[1] += axis(report, 10);
	sum[2] += axis(report, 14);
	count++;
}

static long numProp(IOHIDDeviceRef d, CFStringRef key) {
	CFTypeRef v = IOHIDDeviceGetProperty(d, key);
	long out = -1;
	if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &out);
	return out;
}

int main(int argc, char **argv) {
	double sec = argc > 1 ? atof(argv[1]) : 5.0;
	IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
	IOHIDManagerSetDeviceMatching(mgr, NULL);
	CFSetRef devices = IOHIDManagerCopyDevices(mgr);
	CFIndex n = devices ? CFSetGetCount(devices) : 0;
	IOHIDDeviceRef *devs = malloc(sizeof(IOHIDDeviceRef) * n);
	CFSetGetValues(devices, (const void **)devs);
	for (CFIndex i = 0; i < n; i++) {
		if (numProp(devs[i], CFSTR(kIOHIDPrimaryUsagePageKey)) != 0xFF00) continue;
		if (numProp(devs[i], CFSTR(kIOHIDPrimaryUsageKey)) != 3) continue;
		if (IOHIDDeviceOpen(devs[i], kIOHIDOptionsTypeNone) != kIOReturnSuccess) continue;
		IOHIDDeviceRegisterInputReportCallback(devs[i], buf, sizeof(buf), onReport, NULL);
		IOHIDDeviceScheduleWithRunLoop(devs[i], CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
		break;
	}
	CFRunLoopRunInMode(kCFRunLoopDefaultMode, sec, false);
	if (!count) { fprintf(stderr, "no samples (sensors asleep?)\n"); return 1; }
	printf("chip accel mean over %.0fs (%ld samples): x=%+7.4f  y=%+7.4f  z=%+7.4f\n",
		sec, count, sum[0] / count, sum[1] / count, sum[2] / count);
	return 0;
}
