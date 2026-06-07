#include <libusb.h>
#include <stdint.h>
#include <stdio.h>

#define SIANO_VENDOR_ID 0x187f
#define SIANO_PRODUCT_ID 0x0202

static const char *endpoint_direction(uint8_t address) {
    return (address & LIBUSB_ENDPOINT_IN) ? "IN" : "OUT";
}

static const char *transfer_type(uint8_t attributes) {
    switch (attributes & LIBUSB_TRANSFER_TYPE_MASK) {
    case LIBUSB_TRANSFER_TYPE_CONTROL:
        return "control";
    case LIBUSB_TRANSFER_TYPE_ISOCHRONOUS:
        return "isochronous";
    case LIBUSB_TRANSFER_TYPE_BULK:
        return "bulk";
    case LIBUSB_TRANSFER_TYPE_INTERRUPT:
        return "interrupt";
    default:
        return "unknown";
    }
}

static void print_string_descriptor(libusb_device_handle *handle, const char *label, uint8_t index) {
    unsigned char buffer[256];

    if (index == 0) {
        printf("  %s: <missing>\n", label);
        return;
    }

    int rc = libusb_get_string_descriptor_ascii(handle, index, buffer, sizeof(buffer));
    if (rc < 0) {
        printf("  %s: <error %s>\n", label, libusb_error_name(rc));
        return;
    }

    printf("  %s: %s\n", label, buffer);
}

static void print_config_descriptor(const struct libusb_config_descriptor *config) {
    printf("  Configuration value: %u\n", config->bConfigurationValue);
    printf("  Interfaces: %u\n", config->bNumInterfaces);
    printf("  Attributes: 0x%02x\n", config->bmAttributes);
    printf("  Max power: %u mA\n", config->MaxPower * 2);

    for (uint8_t i = 0; i < config->bNumInterfaces; i++) {
        const struct libusb_interface *interface = &config->interface[i];
        printf("  Interface %u alt settings: %d\n", i, interface->num_altsetting);

        for (int a = 0; a < interface->num_altsetting; a++) {
            const struct libusb_interface_descriptor *alt = &interface->altsetting[a];
            printf("    Alt %d: number=%u class=0x%02x subclass=0x%02x protocol=0x%02x endpoints=%u\n",
                   a,
                   alt->bInterfaceNumber,
                   alt->bInterfaceClass,
                   alt->bInterfaceSubClass,
                   alt->bInterfaceProtocol,
                   alt->bNumEndpoints);

            for (uint8_t e = 0; e < alt->bNumEndpoints; e++) {
                const struct libusb_endpoint_descriptor *ep = &alt->endpoint[e];
                printf("      Endpoint 0x%02x %s type=%s maxPacket=%u interval=%u\n",
                       ep->bEndpointAddress,
                       endpoint_direction(ep->bEndpointAddress),
                       transfer_type(ep->bmAttributes),
                       ep->wMaxPacketSize,
                       ep->bInterval);
            }
        }
    }
}

int main(void) {
    libusb_context *ctx = NULL;
    int rc = libusb_init(&ctx);
    if (rc < 0) {
        fprintf(stderr, "libusb_init failed: %s\n", libusb_error_name(rc));
        return 2;
    }

    libusb_device **devices = NULL;
    ssize_t count = libusb_get_device_list(ctx, &devices);
    if (count < 0) {
        fprintf(stderr, "libusb_get_device_list failed: %s\n", libusb_error_name((int)count));
        libusb_exit(ctx);
        return 2;
    }

    int matched = 0;
    for (ssize_t i = 0; i < count; i++) {
        libusb_device *device = devices[i];
        struct libusb_device_descriptor desc;
        rc = libusb_get_device_descriptor(device, &desc);
        if (rc < 0) {
            continue;
        }

        if (desc.idVendor != SIANO_VENDOR_ID || desc.idProduct != SIANO_PRODUCT_ID) {
            continue;
        }

        matched++;
        printf("Matched Siano MDTV receiver via libusb\n");
        printf("  Bus: %u\n", libusb_get_bus_number(device));
        printf("  Address: %u\n", libusb_get_device_address(device));
        printf("  VID:PID: %04x:%04x\n", desc.idVendor, desc.idProduct);
        printf("  USB release: %x.%02x\n", desc.bcdUSB >> 8, desc.bcdUSB & 0xff);
        printf("  Device release: %x.%02x\n", desc.bcdDevice >> 8, desc.bcdDevice & 0xff);
        printf("  Class/Subclass/Protocol: 0x%02x/0x%02x/0x%02x\n",
               desc.bDeviceClass,
               desc.bDeviceSubClass,
               desc.bDeviceProtocol);
        printf("  Configurations: %u\n", desc.bNumConfigurations);

        libusb_device_handle *handle = NULL;
        rc = libusb_open(device, &handle);
        if (rc < 0) {
            printf("  Open: <error %s>\n", libusb_error_name(rc));
        } else {
            printf("  Open: ok\n");
            print_string_descriptor(handle, "Manufacturer", desc.iManufacturer);
            print_string_descriptor(handle, "Product", desc.iProduct);
            print_string_descriptor(handle, "Serial", desc.iSerialNumber);
        }

        for (uint8_t c = 0; c < desc.bNumConfigurations; c++) {
            struct libusb_config_descriptor *config = NULL;
            rc = libusb_get_config_descriptor(device, c, &config);
            if (rc < 0) {
                printf("  Configuration %u: <error %s>\n", c, libusb_error_name(rc));
                continue;
            }

            printf("  Configuration index: %u\n", c);
            print_config_descriptor(config);
            libusb_free_config_descriptor(config);
        }

        if (handle) {
            libusb_close(handle);
        }
    }

    libusb_free_device_list(devices, 1);
    libusb_exit(ctx);

    if (!matched) {
        printf("No Siano MDTV receiver found for VID:PID %04x:%04x\n", SIANO_VENDOR_ID, SIANO_PRODUCT_ID);
        return 1;
    }

    return 0;
}

