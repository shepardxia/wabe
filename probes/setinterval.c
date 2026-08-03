// Set AppleSPUHIDDriver sensor properties and report per-property return codes, which is how we
// know a non-root process may change them. ReportInterval is the only real rate lever.
//
// Usage: setinterval <interval_us> [reporting_state] [power_state]
//   interval_us 0 with states 0 puts the sensors back to sleep.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int main(int argc, char **argv) {
	int32_t interval = argc > 1 ? atoi(argv[1]) : 1000;
	int32_t reporting = argc > 2 ? atoi(argv[2]) : 1;
	int32_t power = argc > 3 ? atoi(argv[3]) : 1;

	printf("uid=%d  setting ReportInterval=%d ReportingState=%d PowerState=%d\n",
		geteuid(), interval, reporting, power);

	io_iterator_t it = 0;
	if (IOServiceGetMatchingServices(kIOMainPortDefault,
			IOServiceMatching("AppleSPUHIDDriver"), &it) != KERN_SUCCESS) {
		fprintf(stderr, "IOServiceGetMatchingServices failed\n");
		return 1;
	}

	struct { const char *key; int32_t val; } props[] = {
		{"SensorPropertyReportingState", reporting},
		{"SensorPropertyPowerState", power},
		{"ReportInterval", interval},
	};

	int n = 0;
	io_service_t svc;
	while ((svc = IOIteratorNext(it))) {
		n++;
		printf("  service %d:", n);
		for (int i = 0; i < 3; i++) {
			CFStringRef k = CFStringCreateWithCString(NULL, props[i].key, kCFStringEncodingUTF8);
			CFNumberRef v = CFNumberCreate(NULL, kCFNumberSInt32Type, &props[i].val);
			kern_return_t r = IORegistryEntrySetCFProperty(svc, k, v);
			printf("  %s=0x%08x", props[i].key + 14, r); // trim "SensorProperty"
			CFRelease(k);
			CFRelease(v);
		}
		printf("\n");
		IOObjectRelease(svc);
	}
	IOObjectRelease(it);
	printf("  %d service(s). 0x00000000 = ok, 0xe00002c1 = not permitted\n", n);
	return 0;
}
