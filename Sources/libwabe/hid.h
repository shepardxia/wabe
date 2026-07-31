#ifndef WABE_HID_H
#define WABE_HID_H

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/hid/IOHIDManager.h>

// A numeric device property, or -1 when absent.
long wabe_hid_num_prop(IOHIDDeviceRef d, CFStringRef key);

// The device advertising (page, usage), as its primary collection or in its usage-pairs array.
// Borrowed reference: the manager keeps ownership.
IOHIDDeviceRef wabe_hid_find(IOHIDManagerRef mgr, long page, long usage);

#endif
