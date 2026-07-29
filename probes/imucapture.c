// Capture raw input reports from every openable SPU HID device for a fixed window.
// Emits one line per report: "<page> <usage> <reportID> <hex bytes>". Pair two runs taken at
// different physical orientations and diff them to find which bytes encode orientation.
// Usage: imucapture <seconds>
#include <IOKit/hid/IOHIDManager.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define MAXDEV 16
#define RBUF 512

static uint8_t buffers[MAXDEV][RBUF];
static long devPage[MAXDEV], devUsage[MAXDEV];

static void onReport(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                     uint32_t reportID, uint8_t *report, CFIndex length) {
	long idx = (long)ctx;
	printf("0x%02lx 0x%02lx %u", devPage[idx], devUsage[idx], reportID);
	for (CFIndex i = 0; i < length; i++) printf(" %02x", report[i]);
	printf("\n");
}

static long numProp(IOHIDDeviceRef d, CFStringRef key) {
	CFTypeRef v = IOHIDDeviceGetProperty(d, key);
	long out = -1;
	if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &out);
	return out;
}

int main(int argc, char **argv) {
	double seconds = argc > 1 ? atof(argv[1]) : 5.0;

	IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
	IOHIDManagerSetDeviceMatching(mgr, NULL);
	CFSetRef devices = IOHIDManagerCopyDevices(mgr);
	CFIndex n = devices ? CFSetGetCount(devices) : 0;
	if (n == 0) { fprintf(stderr, "no devices\n"); return 1; }

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
		if (IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) != kIOReturnSuccess) continue;

		devPage[hooked] = numProp(d, CFSTR(kIOHIDPrimaryUsagePageKey));
		devUsage[hooked] = numProp(d, CFSTR(kIOHIDPrimaryUsageKey));
		IOHIDDeviceRegisterInputReportCallback(d, buffers[hooked], RBUF, onReport,
			(void *)(long)hooked);
		IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
		hooked++;
	}
	fprintf(stderr, "capturing %d SPU devices for %.1fs...\n", hooked, seconds);
	CFRunLoopRunInMode(kCFRunLoopDefaultMode, seconds, false);
	fprintf(stderr, "done\n");
	return 0;
}
