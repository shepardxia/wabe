// Probe the MacBook lid angle sensor (undocumented HID device, usagePage 0x20 / usage 0x8A).
// Dumps every element value plus a raw feature report so we can see what actually carries the angle.
#include <IOKit/hid/IOHIDManager.h>
#include <errno.h>
#include <stdio.h>

// Can we read an angle a helper daemon dropped outside our container? This is the fallback path
// for the sandboxed screen saver, so test it in the same process that tests direct HID access.
static void tryFileRead(const char *path) {
	FILE *f = fopen(path, "r");
	if (!f) { printf("fopen(%s) FAILED (errno=%d)\n", path, errno); return; }
	int angle = -1;
	printf("fopen(%s) ok, read angle=%s\n", path, fscanf(f, "%d", &angle) == 1 ? "yes" : "no");
	if (angle >= 0) printf("  angle from file = %d deg\n", angle);
	fclose(f);
}

int main(void) {
	tryFileRead("/tmp/lidangle");

	IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);

	int usagePage = 0x20, usage = 0x8A;
	CFNumberRef pageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usagePage);
	CFNumberRef usageNum = CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &usage);
	CFStringRef keys[] = {CFSTR(kIOHIDDeviceUsagePageKey), CFSTR(kIOHIDDeviceUsageKey)};
	CFTypeRef vals[] = {pageNum, usageNum};
	CFDictionaryRef match = CFDictionaryCreate(kCFAllocatorDefault, (const void **)keys,
		(const void **)vals, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
	IOHIDManagerSetDeviceMatching(mgr, match);

	IOReturn open = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
	printf("IOHIDManagerOpen = 0x%08x %s\n", open, open == kIOReturnSuccess ? "(ok)" : "(FAILED)");
	if (open != kIOReturnSuccess) return 1;

	CFSetRef devices = IOHIDManagerCopyDevices(mgr);
	CFIndex n = devices ? CFSetGetCount(devices) : 0;
	printf("matched devices: %ld\n", (long)n);
	if (n == 0) return 1;

	IOHIDDeviceRef dev;
	CFSetGetValues(devices, (const void **)&dev);

	IOReturn dopen = IOHIDDeviceOpen(dev, kIOHIDOptionsTypeNone);
	printf("IOHIDDeviceOpen  = 0x%08x %s\n", dopen, dopen == kIOReturnSuccess ? "(ok)" : "(FAILED)");

	CFArrayRef elements = IOHIDDeviceCopyMatchingElements(dev, NULL, kIOHIDOptionsTypeNone);
	printf("elements: %ld\n", elements ? (long)CFArrayGetCount(elements) : 0);
	for (CFIndex i = 0; elements && i < CFArrayGetCount(elements); i++) {
		IOHIDElementRef el = (IOHIDElementRef)CFArrayGetValueAtIndex(elements, i);
		IOHIDValueRef v = NULL;
		IOReturn r = IOHIDDeviceGetValue(dev, el, &v);
		printf("  el[%ld] page=0x%02x usage=0x%02x type=%d report=%u getValue=0x%08x",
			(long)i, IOHIDElementGetUsagePage(el), IOHIDElementGetUsage(el),
			IOHIDElementGetType(el), IOHIDElementGetReportID(el), r);
		if (r == kIOReturnSuccess && v) printf(" value=%ld", (long)IOHIDValueGetIntegerValue(v));
		printf("\n");
	}

	// Feature report 1 is where the reverse-engineered implementations read the angle from.
	uint8_t report[8] = {0};
	CFIndex len = sizeof(report);
	IOReturn r = IOHIDDeviceGetReport(dev, kIOHIDReportTypeFeature, 1, report, &len);
	printf("feature report 1 = 0x%08x len=%ld bytes:", r, (long)len);
	for (CFIndex i = 0; i < len; i++) printf(" %02x", report[i]);
	printf("\n");
	if (r == kIOReturnSuccess && len >= 3)
		printf("angle (int16 LE @ offset 1) = %d deg\n", (int16_t)(report[1] | (report[2] << 8)));

	return 0;
}
