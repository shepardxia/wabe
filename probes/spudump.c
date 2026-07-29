// Dump what each SPU HID device actually declares: report descriptor bytes, element tree, and any
// readable feature reports. Point is to find out why 0xFF00 usage 3/9 stay silent on M4 -- whether
// they declare input reports at all, and whether there is a control/enable report to write.
#include <IOKit/hid/IOHIDManager.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static long numProp(IOHIDDeviceRef d, CFStringRef key) {
	CFTypeRef v = IOHIDDeviceGetProperty(d, key);
	long out = -1;
	if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &out);
	return out;
}

static const char *typeName(IOHIDElementType t) {
	switch (t) {
		case kIOHIDElementTypeInput_Misc: return "Input_Misc";
		case kIOHIDElementTypeInput_Button: return "Input_Button";
		case kIOHIDElementTypeInput_Axis: return "Input_Axis";
		case kIOHIDElementTypeInput_ScanCodes: return "Input_Scan";
		case kIOHIDElementTypeInput_NULL: return "Input_NULL";
		case kIOHIDElementTypeOutput: return "Output";
		case kIOHIDElementTypeFeature: return "Feature";
		case kIOHIDElementTypeCollection: return "Collection";
		default: return "?";
	}
}

int main(void) {
	IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
	IOHIDManagerSetDeviceMatching(mgr, NULL);
	CFSetRef devices = IOHIDManagerCopyDevices(mgr);
	CFIndex n = devices ? CFSetGetCount(devices) : 0;
	IOHIDDeviceRef *devs = malloc(sizeof(IOHIDDeviceRef) * n);
	CFSetGetValues(devices, (const void **)devs);

	for (CFIndex i = 0; i < n; i++) {
		IOHIDDeviceRef d = devs[i];
		char transport[64] = {0};
		CFTypeRef t = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDTransportKey));
		if (t && CFGetTypeID(t) == CFStringGetTypeID())
			CFStringGetCString(t, transport, sizeof(transport), kCFStringEncodingUTF8);
		if (strcmp(transport, "SPU") != 0) continue;

		long page = numProp(d, CFSTR(kIOHIDPrimaryUsagePageKey));
		long usage = numProp(d, CFSTR(kIOHIDPrimaryUsageKey));
		printf("\n======== SPU page=0x%02lx usage=0x%02lx  (vid=0x%04lx pid=0x%04lx) ========\n",
			page, usage, numProp(d, CFSTR(kIOHIDVendorIDKey)), numProp(d, CFSTR(kIOHIDProductIDKey)));

		CFTypeRef desc = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDReportDescriptorKey));
		if (desc && CFGetTypeID(desc) == CFDataGetTypeID()) {
			const uint8_t *b = CFDataGetBytePtr(desc);
			CFIndex len = CFDataGetLength(desc);
			printf("report descriptor (%ld bytes):\n ", (long)len);
			for (CFIndex k = 0; k < len; k++) {
				printf(" %02x", b[k]);
				if ((k + 1) % 16 == 0) printf("\n ");
			}
			printf("\n");
		} else {
			printf("report descriptor: unavailable\n");
		}

		printf("max report sizes: in=%ld out=%ld feature=%ld\n",
			numProp(d, CFSTR(kIOHIDMaxInputReportSizeKey)),
			numProp(d, CFSTR(kIOHIDMaxOutputReportSizeKey)),
			numProp(d, CFSTR(kIOHIDMaxFeatureReportSizeKey)));

		if (IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
			printf("open failed\n");
			continue;
		}
		CFArrayRef els = IOHIDDeviceCopyMatchingElements(d, NULL, kIOHIDOptionsTypeNone);
		CFIndex ne = els ? CFArrayGetCount(els) : 0;
		printf("elements (%ld):\n", (long)ne);
		for (CFIndex j = 0; j < ne; j++) {
			IOHIDElementRef el = (IOHIDElementRef)CFArrayGetValueAtIndex(els, j);
			printf("  %-12s page=0x%02x usage=0x%03x reportID=%u size=%u count=%u min=%ld max=%ld\n",
				typeName(IOHIDElementGetType(el)), IOHIDElementGetUsagePage(el),
				IOHIDElementGetUsage(el), IOHIDElementGetReportID(el),
				IOHIDElementGetReportSize(el), IOHIDElementGetReportCount(el),
				(long)IOHIDElementGetLogicalMin(el), (long)IOHIDElementGetLogicalMax(el));
		}
	}
	return 0;
}
