// Open every vendor-defined SPU HID device and listen for async input reports for a few seconds.
// Streaming sensors push data this way rather than answering feature reads, so this is the access
// pattern that would actually surface accelerometer/gyro samples if they are reachable unprivileged.
#include <IOKit/hid/IOHIDManager.h>
#include <stdio.h>
#include <string.h>

#define MAXDEV 16
#define RBUF 256

static uint8_t buffers[MAXDEV][RBUF];
static int reportCount[MAXDEV];
static long devPage[MAXDEV], devUsage[MAXDEV];

static void onReport(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                     uint32_t reportID, uint8_t *report, CFIndex length) {
	long idx = (long)ctx;
	reportCount[idx]++;
	if (reportCount[idx] > 3) return; // a few samples per device is enough to see the shape
	printf("  [page=0x%02lx usage=0x%02lx] input report id=%u len=%ld:",
		devPage[idx], devUsage[idx], reportID, (long)length);
	for (CFIndex i = 0; i < length && i < 24; i++) printf(" %02x", report[i]);
	printf("\n");
	fflush(stdout);
}

static long numProp(IOHIDDeviceRef d, CFStringRef key) {
	CFTypeRef v = IOHIDDeviceGetProperty(d, key);
	long out = -1;
	if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &out);
	return out;
}

int main(void) {
	IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
	IOHIDManagerSetDeviceMatching(mgr, NULL);
	CFSetRef devices = IOHIDManagerCopyDevices(mgr);
	CFIndex n = devices ? CFSetGetCount(devices) : 0;
	if (n == 0) { printf("no devices\n"); return 1; }

	IOHIDDeviceRef *devs = malloc(sizeof(IOHIDDeviceRef) * n);
	CFSetGetValues(devices, (const void **)devs);

	int hooked = 0;
	for (CFIndex i = 0; i < n && hooked < MAXDEV; i++) {
		IOHIDDeviceRef d = devs[i];
		char transport[64] = {0};
		CFTypeRef t = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDTransportKey));
		if (t && CFGetTypeID(t) == CFStringGetTypeID())
			CFStringGetCString(t, transport, sizeof(transport), kCFStringEncodingUTF8);
		if (strcmp(transport, "SPU") != 0) continue;

		long page = numProp(d, CFSTR(kIOHIDPrimaryUsagePageKey));
		long usage = numProp(d, CFSTR(kIOHIDPrimaryUsageKey));
		if (IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) != kIOReturnSuccess) continue;

		devPage[hooked] = page;
		devUsage[hooked] = usage;
		IOHIDDeviceRegisterInputReportCallback(d, buffers[hooked], RBUF, onReport,
			(void *)(long)hooked);
		IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
		printf("listening: page=0x%02lx usage=0x%02lx\n", page, usage);
		hooked++;
	}
	printf("\nhooked %d SPU devices, listening 4s...\n\n", hooked);
	fflush(stdout);

	CFRunLoopRunInMode(kCFRunLoopDefaultMode, 4.0, false);

	printf("\n=== report counts ===\n");
	for (int i = 0; i < hooked; i++)
		printf("  page=0x%02lx usage=0x%02lx -> %d reports\n", devPage[i], devUsage[i], reportCount[i]);
	return 0;
}
