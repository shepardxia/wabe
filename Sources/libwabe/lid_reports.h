// The lid angle is reachable by more than one HID report, and which ones a machine answers on
// varies. This table is the single list of what to try, finest first: libwabe walks it to pick
// an access path, and probes/lidpaths.c walks the same one so its compatibility output always
// describes what the library will actually do.
//
// Header-only and dependency-free on purpose, so the probe still builds with a bare
// `clang -O2 -o lidpaths lidpaths.c -framework IOKit -framework CoreFoundation`.
#ifndef WABE_LID_REPORTS_H
#define WABE_LID_REPORTS_H

#include <IOKit/hid/IOHIDManager.h>

typedef struct {
    IOHIDReportType type;
    uint32_t id;
    double scale;      // degrees per count
    const char *name;
} wabe_lid_report;

static const wabe_lid_report wabe_lid_reports[] = {
    {kIOHIDReportTypeInput, 7, 0.01, "input report 7 (0.01 deg)"},
    {kIOHIDReportTypeInput, 1, 1.0, "input report 1 (1 deg)"},
    {kIOHIDReportTypeFeature, 1, 1.0, "feature report 1 (1 deg)"},
};

#define WABE_LID_REPORT_COUNT (sizeof(wabe_lid_reports) / sizeof(wabe_lid_reports[0]))

// A lid angle is bounded well under 180 degrees. This is what rejects a report that exists but
// carries something else.
static inline int wabe_lid_plausible(double deg) { return deg > 0.0 && deg <= 180.0; }

#endif
