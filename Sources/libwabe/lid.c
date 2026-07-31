// Lid angle, polled synchronously with GetReport on its own device handle. Which report answers
// differs across machines and some have no encoder at all, so the access path is probed once
// from the table in lid_reports.h and cached. Shares nothing with the IMU but device lookup.
#include "wabe_sensor.h"
#include "hid.h"
#include "lid_reports.h"

static IOHIDDeviceRef lidDev;
static IOHIDManagerRef lidMgr;
static int lidProbed;
static uint32_t lidReportID;
static IOHIDReportType lidReportType;
static double lidScale;

// Read one candidate; returns the angle, or -1 if it did not answer plausibly.
static double lidTry(IOHIDReportType type, uint32_t id, double scale) {
	uint8_t buf[16] = {0};
	CFIndex len = sizeof(buf);
	if (IOHIDDeviceGetReport(lidDev, type, id, buf, &len) != kIOReturnSuccess || len < 3)
		return -1.0;
	double deg = (double)(buf[1] | (buf[2] << 8)) * scale;
	return wabe_lid_plausible(deg) ? deg : -1.0;
}

double ws_lid_deg(void) {
	if (!lidProbed) {
		lidProbed = 1;  // one attempt: a machine without the sensor must not retry forever
		lidMgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
		IOHIDManagerSetDeviceMatching(lidMgr, NULL);
		lidDev = wabe_hid_find(lidMgr, 0x20, 0x8A);
		if (!lidDev || IOHIDDeviceOpen(lidDev, kIOHIDOptionsTypeNone) != kIOReturnSuccess) {
			lidDev = NULL;
			return -1.0;
		}
		for (size_t i = 0; i < WABE_LID_REPORT_COUNT; i++) {
			const wabe_lid_report *c = &wabe_lid_reports[i];
			double deg = lidTry(c->type, c->id, c->scale);
			if (deg >= 0) {
				lidReportType = c->type;
				lidReportID = c->id;
				lidScale = c->scale;
				return deg;
			}
		}
		lidDev = NULL;  // device present but no candidate answered
		return -1.0;
	}
	if (!lidDev)
		return -1.0;
	return lidTry(lidReportType, lidReportID, lidScale);
}

double ws_lid_resolution(void) {
	if (!lidProbed)
		(void)ws_lid_deg();
	return lidDev ? lidScale : 0.0;
}

