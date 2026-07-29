// Two experiments:
//  1. LAS declares an Output element (usage 0x544, boolean) and two input reports that read zero,
//     one of which is a 0.01-degree lid angle. Try writing 1 to it and see if they wake up.
//  2. The accel/gyro devices declare 22-byte input reports but never push. Try polling them with a
//     synchronous input GetReport instead of waiting on the callback.
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

static void dumpInputReports(IOHIDDeviceRef d, const char *tag, int maxID) {
	for (int rid = 0; rid <= maxID; rid++) {
		uint8_t buf[128] = {0};
		CFIndex len = sizeof(buf);
		IOReturn r = IOHIDDeviceGetReport(d, kIOHIDReportTypeInput, rid, buf, &len);
		if (r != kIOReturnSuccess) continue;
		printf("    %s input[%d] len=%2ld:", tag, rid, (long)len);
		for (CFIndex k = 0; k < len && k < 24; k++) printf(" %02x", buf[k]);
		printf("\n");
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
		int isLAS = (page == 0x20 && usage == 0x8A);
		int isIMU = (page == 0xFF00 && (usage == 3 || usage == 9));
		if (!isLAS && !isIMU) continue;

		printf("\n==== page=0x%02lx usage=0x%02lx ====\n", page, usage);
		if (IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
			printf("  open failed\n");
			continue;
		}

		if (isIMU) {
			printf("  polling input reports (no enable register exists here):\n");
			dumpInputReports(d, "imu", 4);
			continue;
		}

		printf("  BEFORE enable:\n");
		dumpInputReports(d, "las", 8);

		// Output report 6 carries the single boolean at usage 0x544.
		uint8_t on[2] = {6, 1};
		IOReturn w = IOHIDDeviceSetReport(d, kIOHIDReportTypeOutput, 6, on, sizeof(on));
		printf("  SetReport(output, id=6, value=1) = 0x%08x %s\n", w,
			w == kIOReturnSuccess ? "(ok)" : "(failed)");

		printf("  AFTER enable:\n");
		dumpInputReports(d, "las", 8);
	}
	return 0;
}
