// Enumerate every HID device on the SPU (sensor processing unit) transport and try to open each one
// unprivileged, so we can see which sensors are actually reachable without root.
#include <IOKit/hid/IOHIDManager.h>
#include <stdio.h>

static long numProp(IOHIDDeviceRef d, CFStringRef key) {
	CFTypeRef v = IOHIDDeviceGetProperty(d, key);
	long out = -1;
	if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &out);
	return out;
}

static void strProp(IOHIDDeviceRef d, CFStringRef key, char *buf, size_t len) {
	buf[0] = 0;
	CFTypeRef v = IOHIDDeviceGetProperty(d, key);
	if (v && CFGetTypeID(v) == CFStringGetTypeID())
		CFStringGetCString(v, buf, len, kCFStringEncodingUTF8);
}

int main(void) {
	IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
	IOHIDManagerSetDeviceMatching(mgr, NULL); // everything

	IOReturn mopen = IOHIDManagerOpen(mgr, kIOHIDOptionsTypeNone);
	printf("IOHIDManagerOpen = 0x%08x\n\n", mopen);

	CFSetRef devices = IOHIDManagerCopyDevices(mgr);
	CFIndex n = devices ? CFSetGetCount(devices) : 0;
	printf("total HID devices: %ld\n\n", (long)n);
	if (n == 0) return 1;

	IOHIDDeviceRef *devs = malloc(sizeof(IOHIDDeviceRef) * n);
	CFSetGetValues(devices, (const void **)devs);

	for (CFIndex i = 0; i < n; i++) {
		IOHIDDeviceRef d = devs[i];
		char transport[64], product[128];
		strProp(d, CFSTR(kIOHIDTransportKey), transport, sizeof(transport));
		strProp(d, CFSTR(kIOHIDProductKey), product, sizeof(product));

		// Only care about the on-SoC sensors.
		if (strcmp(transport, "SPU") != 0) continue;

		long page = numProp(d, CFSTR(kIOHIDPrimaryUsagePageKey));
		long usage = numProp(d, CFSTR(kIOHIDPrimaryUsageKey));
		printf("SPU device: product=\"%s\" usagePage=0x%02lx usage=0x%02lx\n",
			product, page, usage);

		IOReturn dopen = IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone);
		printf("  IOHIDDeviceOpen = 0x%08x %s\n", dopen,
			dopen == kIOReturnSuccess ? "(OK)" : "(denied)");
		if (dopen != kIOReturnSuccess) continue;

		CFArrayRef els = IOHIDDeviceCopyMatchingElements(d, NULL, kIOHIDOptionsTypeNone);
		CFIndex ne = els ? CFArrayGetCount(els) : 0;
		printf("  elements=%ld, readable values:\n", (long)ne);
		for (CFIndex j = 0; j < ne; j++) {
			IOHIDElementRef el = (IOHIDElementRef)CFArrayGetValueAtIndex(els, j);
			if (IOHIDElementGetUsagePage(el) == 0) continue; // padding
			IOHIDValueRef v = NULL;
			if (IOHIDDeviceGetValue(d, el, &v) == kIOReturnSuccess && v)
				printf("    usage=0x%03x report=%u value=%ld\n", IOHIDElementGetUsage(el),
					IOHIDElementGetReportID(el), (long)IOHIDValueGetIntegerValue(v));
		}
		// Sweep feature reports; sensor data on these devices tends to live here.
		for (int rid = 1; rid <= 6; rid++) {
			uint8_t buf[64] = {0};
			CFIndex len = sizeof(buf);
			if (IOHIDDeviceGetReport(d, kIOHIDReportTypeFeature, rid, buf, &len) != kIOReturnSuccess)
				continue;
			printf("    feature[%d] len=%ld:", rid, (long)len);
			for (CFIndex k = 0; k < len && k < 20; k++) printf(" %02x", buf[k]);
			printf("\n");
		}
		printf("\n");
	}
	return 0;
}
