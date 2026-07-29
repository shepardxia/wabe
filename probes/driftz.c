// Measure yaw drift on the SPU gyro: estimate bias over a calibration window, then integrate the
// bias-corrected z rate and report how far heading walks. This is the number that decides whether
// relative-only heading is usable at a given session length, and whether an EKF with explicit bias
// states earns its complexity over a plain complementary filter.
//
// Machine must sit still for the whole run. Assumes the driver is already woken.
// Usage: driftz [calib_seconds] [run_seconds]
#include <IOKit/hid/IOHIDManager.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

static double calibSec = 5.0, runSec = 60.0;
static double t0;
static long nCalib, nRun;
static double biasSum[3], heading[3], lastT;
static double bias[3];
static int calibrated;
static double peak[3];
static uint8_t buf[4096];

static double now(void) {
	return (double)clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9;
}

static double axis(const uint8_t *r, int off) {
	int32_t v = (int32_t)((uint32_t)r[off] | ((uint32_t)r[off + 1] << 8) |
	                      ((uint32_t)r[off + 2] << 16) | ((uint32_t)r[off + 3] << 24));
	return v / 65536.0;
}

static void onReport(void *ctx, IOReturn result, void *sender, IOHIDReportType type,
                     uint32_t reportID, uint8_t *report, CFIndex length) {
	if (length < 18) return;
	double t = now() - t0;
	double r[3] = {axis(report, 6), axis(report, 10), axis(report, 14)};

	if (t < calibSec) {
		for (int i = 0; i < 3; i++) biasSum[i] += r[i];
		nCalib++;
		lastT = t;
		return;
	}
	if (!calibrated) {
		calibrated = 1;
		for (int i = 0; i < 3; i++) bias[i] = nCalib ? biasSum[i] / nCalib : 0.0;
		printf("bias over %.0fs / %ld samples: x=%+.5f y=%+.5f z=%+.5f deg/s\n",
			calibSec, nCalib, bias[0], bias[1], bias[2]);
		printf("\n   t(s)    yaw(deg)   pitch(deg)   roll(deg)\n");
		lastT = t;
		return;
	}

	double dt = t - lastT;
	lastT = t;
	if (dt <= 0 || dt > 0.5) return;
	nRun++;
	for (int i = 0; i < 3; i++) {
		heading[i] += (r[i] - bias[i]) * dt;
		if (fabs(heading[i]) > fabs(peak[i])) peak[i] = heading[i];
	}

	static double nextPrint = 0;
	if (t - calibSec >= nextPrint) {
		printf("  %5.0f   %+9.3f   %+9.3f   %+9.3f\n",
			t - calibSec, heading[2], heading[1], heading[0]);
		nextPrint += 10.0;
	}
}

static long numProp(IOHIDDeviceRef d, CFStringRef key) {
	CFTypeRef v = IOHIDDeviceGetProperty(d, key);
	long out = -1;
	if (v && CFGetTypeID(v) == CFNumberGetTypeID()) CFNumberGetValue(v, kCFNumberLongType, &out);
	return out;
}

int main(int argc, char **argv) {
	if (argc > 1) calibSec = atof(argv[1]);
	if (argc > 2) runSec = atof(argv[2]);

	IOHIDManagerRef mgr = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
	IOHIDManagerSetDeviceMatching(mgr, NULL);
	CFSetRef devices = IOHIDManagerCopyDevices(mgr);
	CFIndex n = devices ? CFSetGetCount(devices) : 0;
	IOHIDDeviceRef *devs = malloc(sizeof(IOHIDDeviceRef) * n);
	CFSetGetValues(devices, (const void **)devs);

	int found = 0;
	for (CFIndex i = 0; i < n; i++) {
		IOHIDDeviceRef d = devs[i];
		if (numProp(d, CFSTR(kIOHIDPrimaryUsagePageKey)) != 0xFF00) continue;
		if (numProp(d, CFSTR(kIOHIDPrimaryUsageKey)) != 9) continue; // gyro
		if (IOHIDDeviceOpen(d, kIOHIDOptionsTypeNone) != kIOReturnSuccess) continue;
		IOHIDDeviceRegisterInputReportCallback(d, buf, sizeof(buf), onReport, NULL);
		IOHIDDeviceScheduleWithRunLoop(d, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);
		found = 1;
		break;
	}
	if (!found) { fprintf(stderr, "gyro not found/openable\n"); return 1; }

	printf("calibrating %.0fs, then integrating %.0fs. Do not touch the machine.\n", calibSec, runSec);
	t0 = now();
	CFRunLoopRunInMode(kCFRunLoopDefaultMode, calibSec + runSec, false);

	if (!nRun) { fprintf(stderr, "no samples in run phase\n"); return 1; }
	printf("\n=== drift over %.0fs (%ld samples) ===\n", runSec, nRun);
	const char *nm[3] = {"roll(x)", "pitch(y)", "yaw(z)"};
	int order[3] = {2, 1, 0};
	for (int k = 0; k < 3; k++) {
		int i = order[k];
		printf("  %-9s final=%+8.3f deg   peak=%+8.3f deg   rate=%+7.4f deg/s = %+6.2f deg/min\n",
			nm[i], heading[i], peak[i], heading[i] / runSec, heading[i] / runSec * 60.0);
	}
	return 0;
}
