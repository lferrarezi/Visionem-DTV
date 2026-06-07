#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>

#define SIANO_VENDOR_ID 0x187f
#define SIANO_PRODUCT_ID 0x0202

static int cf_number_to_u32(CFTypeRef value, uint32_t *out) {
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) {
        return 0;
    }

    int number = 0;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberIntType, &number)) {
        return 0;
    }

    *out = (uint32_t)number;
    return 1;
}

static void print_cf_string(const char *label, CFTypeRef value) {
    char buffer[256];

    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        printf("  %s: <missing>\n", label);
        return;
    }

    if (CFStringGetCString((CFStringRef)value, buffer, sizeof(buffer), kCFStringEncodingUTF8)) {
        printf("  %s: %s\n", label, buffer);
    } else {
        printf("  %s: <unprintable>\n", label);
    }
}

static void inspect_device(io_registry_entry_t service, int *matched_count) {
    CFMutableDictionaryRef props = NULL;
    kern_return_t kr = IORegistryEntryCreateCFProperties(
        service,
        &props,
        kCFAllocatorDefault,
        kNilOptions
    );

    if (kr != KERN_SUCCESS || !props) {
        return;
    }

    uint32_t vendor_id = 0;
    uint32_t product_id = 0;
    uint32_t location_id = 0;
    uint32_t usb_address = 0;
    uint32_t device_speed = 0;

    CFTypeRef vendor_ref = CFDictionaryGetValue(props, CFSTR("idVendor"));
    CFTypeRef product_ref = CFDictionaryGetValue(props, CFSTR("idProduct"));

    if (!cf_number_to_u32(vendor_ref, &vendor_id) ||
        !cf_number_to_u32(product_ref, &product_id)) {
        CFRelease(props);
        return;
    }

    if (vendor_id == SIANO_VENDOR_ID && product_id == SIANO_PRODUCT_ID) {
        (*matched_count)++;
        cf_number_to_u32(CFDictionaryGetValue(props, CFSTR("locationID")), &location_id);
        cf_number_to_u32(CFDictionaryGetValue(props, CFSTR("USB Address")), &usb_address);
        cf_number_to_u32(CFDictionaryGetValue(props, CFSTR("Device Speed")), &device_speed);

        printf("Matched Siano MDTV receiver\n");
        printf("  VID:PID: %04x:%04x\n", vendor_id, product_id);
        printf("  locationID: 0x%08x\n", location_id);
        printf("  USB Address: %u\n", usb_address);
        printf("  Device Speed: %u\n", device_speed);
        print_cf_string("USB Product Name", CFDictionaryGetValue(props, CFSTR("USB Product Name")));
        print_cf_string("USB Vendor Name", CFDictionaryGetValue(props, CFSTR("USB Vendor Name")));
        print_cf_string("Product String", CFDictionaryGetValue(props, CFSTR("kUSBProductString")));
        print_cf_string("Vendor String", CFDictionaryGetValue(props, CFSTR("kUSBVendorString")));
    }

    CFRelease(props);
}

int main(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    if (!matching) {
        fprintf(stderr, "Failed to create IOUSBHostDevice matching dictionary\n");
        return 2;
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "IOServiceGetMatchingServices failed: 0x%x\n", kr);
        return 2;
    }

    int matched_count = 0;
    io_registry_entry_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        inspect_device(service, &matched_count);
        IOObjectRelease(service);
    }

    IOObjectRelease(iterator);

    if (matched_count == 0) {
        printf("No Siano MDTV receiver found for VID:PID %04x:%04x\n", SIANO_VENDOR_ID, SIANO_PRODUCT_ID);
        return 1;
    }

    return 0;
}

