// Which lid-angle access paths does this machine answer on?
//
// libwabe walks the same table (Sources/libwabe/lid_reports.h) and takes the first plausible
// entry. Run this on any MacBook to see what yours offers; the output is what a compatibility
// report should contain.
//
//   clang -O2 -o lidpaths lidpaths.c ../Sources/libwabe/hid.c \
//       -framework IOKit -framework CoreFoundation
#include "../Sources/libwabe/hid.h"
#include "../Sources/libwabe/lid_reports.h"

#include <stdio.h>

int main(void) {
	IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
	IOHIDManagerSetDeviceMatching(mgr, NULL);
	// The library's own lookup, not a copy of it: this probe exists to report what libwabe would
	// find, which it can only do honestly by asking the same question the same way.
	IOHIDDeviceRef lid = wabe_hid_find(mgr, 0x20, 0x8A);
	if (!lid) {
		printf("no lid angle sensor on this machine (usage page 0x20, usage 0x8A)\n");
		return 1;
	}
	printf("lid sensor found: vendor 0x%lx product 0x%lx\n",
	       wabe_hid_num_prop(lid, CFSTR(kIOHIDVendorIDKey)), wabe_hid_num_prop(lid, CFSTR(kIOHIDProductIDKey)));
	if (IOHIDDeviceOpen(lid, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
		printf("open failed\n");
		return 1;
	}

	for (size_t i = 0; i < WABE_LID_REPORT_COUNT; i++) {
		const wabe_lid_report *c = &wabe_lid_reports[i];
		uint8_t buf[16] = {0};
		CFIndex len = sizeof(buf);
		IOReturn r = IOHIDDeviceGetReport(lid, c->type, c->id, buf, &len);
		if (r != kIOReturnSuccess) {
			printf("  %-25s no answer (0x%x)\n", c->name, r);
			continue;
		}
		double deg = (double)(buf[1] | (buf[2] << 8)) * c->scale;
		printf("  %-25s %zd bytes -> %.2f deg%s\n", c->name, (ssize_t)len, deg,
		       wabe_lid_plausible(deg) ? "" : "  (implausible, would be rejected)");
	}
	return 0;
}
