// Finding an SPU HID device. Shared by the IMU reader and the lid poll, which are otherwise
// unrelated: they want different devices, different report types, and different lifetimes.
#include "hid.h"

#include <stdlib.h>

long wabe_hid_num_prop(IOHIDDeviceRef d, CFStringRef key) {
	CFTypeRef v = IOHIDDeviceGetProperty(d, key);
	long out = -1;
	if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &out);
	return out;
}

// A device may expose the usage we want as its primary collection or as one of several pairs.
// Matching only the primary is what makes hardcoded lookups miss on machines that enumerate
// differently, so check the pairs array too.
static int has_usage_pair(IOHIDDeviceRef d, long page, long usage) {
	CFArrayRef pairs = IOHIDDeviceGetProperty(d, CFSTR(kIOHIDDeviceUsagePairsKey));
	if (!pairs || CFGetTypeID(pairs) != CFArrayGetTypeID()) return 0;
	for (CFIndex i = 0; i < CFArrayGetCount(pairs); i++) {
		CFDictionaryRef p = CFArrayGetValueAtIndex(pairs, i);
		if (!p || CFGetTypeID(p) != CFDictionaryGetTypeID()) continue;
		long pg = -1, us = -1;
		CFNumberRef a = CFDictionaryGetValue(p, CFSTR(kIOHIDDeviceUsagePageKey));
		CFNumberRef b = CFDictionaryGetValue(p, CFSTR(kIOHIDDeviceUsageKey));
		if (a) CFNumberGetValue(a, kCFNumberLongType, &pg);
		if (b) CFNumberGetValue(b, kCFNumberLongType, &us);
		if (pg == page && us == usage) return 1;
	}
	return 0;
}

IOHIDDeviceRef wabe_hid_find(IOHIDManagerRef mgr, long page, long usage) {
	CFSetRef devices = IOHIDManagerCopyDevices(mgr);
	CFIndex n = devices ? CFSetGetCount(devices) : 0;
	if (!n) return NULL;
	IOHIDDeviceRef *devs = malloc(sizeof(IOHIDDeviceRef) * n);
	CFSetGetValues(devices, (const void **)devs);
	IOHIDDeviceRef found = NULL;
	for (CFIndex i = 0; i < n && !found; i++) {
		if (wabe_hid_num_prop(devs[i], CFSTR(kIOHIDPrimaryUsagePageKey)) == page &&
		    wabe_hid_num_prop(devs[i], CFSTR(kIOHIDPrimaryUsageKey)) == usage)
			found = devs[i];
	}
	for (CFIndex i = 0; i < n && !found; i++)
		if (has_usage_pair(devs[i], page, usage)) found = devs[i];
	free(devs);
	CFRelease(devices);
	return found;  // borrowed; manager keeps ownership
}
