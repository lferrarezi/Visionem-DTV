#include "smsusb_transport.h"

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

static void usage(const char *argv0) {
    fprintf(stderr, "Usage: %s probe|version|usb-state|usb-reset|firmware-path|firmware-load <path>|init-isdbt|init-isdbt-bda|prepare-reception|tune-isdbt <frequency_hz>|stats-isdbt <frequency_hz>|stats-isdbt-ex <frequency_hz>|channels-br|channels-br-extended|scan-br|scan-br-extended|diag-br <canal_fisico> [seconds_per_trial] [csv_path]|debug-channel-br <canal_fisico> [seconds_per_mode]|pid-list-br <canal_fisico>|stream-kick-br <canal_fisico> [enable-ts,data-pump,raw-capture,data:req:res:value,header:req:res]|watch-br <canal_fisico> [seconds] [out.ts]|debug-read <frequency_hz> <seconds>|capture-isdbt <frequency_hz> <seconds> <out.ts>|watch-isdbt <frequency_hz> <seconds> <out.ts>\n", argv0);
}

#define BR_SCAN_MIN_CHANNEL 1
#define BR_SCAN_MAX_CHANNEL 59
#define BR_SCAN_EXTENDED_MAX_CHANNEL 69

static void close_device_preserving_error(smsusb_device_t *device, char *error, unsigned long error_len);

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

static void copy_cf_string(CFTypeRef value, char *buffer, size_t buffer_len) {
    if (!buffer || buffer_len == 0) {
        return;
    }
    snprintf(buffer, buffer_len, "<missing>");
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) {
        return;
    }
    CFStringGetCString((CFStringRef)value, buffer, buffer_len, kCFStringEncodingUTF8);
}

static int usb_state_command(void) {
    CFMutableDictionaryRef matching = IOServiceMatching("IOUSBHostDevice");
    if (!matching) {
        fprintf(stderr, "usb-state failed: IOUSBHostDevice matching unavailable\n");
        return 2;
    }

    io_iterator_t iterator = IO_OBJECT_NULL;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "usb-state failed: IOServiceGetMatchingServices 0x%x\n", kr);
        return 2;
    }

    int md_tv_count = 0;
    int mxt_count = 0;
    printf("siano-tv usb-state\n");
    io_registry_entry_t service;
    while ((service = IOIteratorNext(iterator)) != IO_OBJECT_NULL) {
        CFMutableDictionaryRef props = NULL;
        kr = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, kNilOptions);
        IOObjectRelease(service);
        if (kr != KERN_SUCCESS || !props) {
            continue;
        }

        uint32_t vendor_id = 0;
        uint32_t product_id = 0;
        uint32_t location_id = 0;
        uint32_t usb_address = 0;
        cf_number_to_u32(CFDictionaryGetValue(props, CFSTR("idVendor")), &vendor_id);
        cf_number_to_u32(CFDictionaryGetValue(props, CFSTR("idProduct")), &product_id);
        cf_number_to_u32(CFDictionaryGetValue(props, CFSTR("locationID")), &location_id);
        cf_number_to_u32(CFDictionaryGetValue(props, CFSTR("USB Address")), &usb_address);

        char product[256];
        char owner[256];
        copy_cf_string(CFDictionaryGetValue(props, CFSTR("USB Product Name")), product, sizeof(product));
        copy_cf_string(CFDictionaryGetValue(props, CFSTR("UsbExclusiveOwner")), owner, sizeof(owner));

        if (vendor_id == SMSUSB_VENDOR_ID && product_id == SMSUSB_PRODUCT_ID) {
            md_tv_count++;
            printf("  mdtv: present vidpid=%04x:%04x location=0x%08x address=%u product=\"%s\" owner=\"%s\"\n",
                   vendor_id,
                   product_id,
                   location_id,
                   usb_address,
                   product,
                   owner);
        } else if (vendor_id == 0xaaaa && product_id == 0x8816) {
            mxt_count++;
            printf("  mxt: present vidpid=%04x:%04x location=0x%08x address=%u product=\"%s\"\n",
                   vendor_id,
                   product_id,
                   location_id,
                   usb_address,
                   product);
        }
        CFRelease(props);
    }
    IOObjectRelease(iterator);

    printf("  summary: mdtv=%d mxt=%d\n", md_tv_count, mxt_count);
    return md_tv_count > 0 ? 0 : 1;
}

static int probe_command(void) {
    smsusb_device_t device;
    char error[256];

    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "probe failed: %s\n", error);
        return 1;
    }

    printf("siano-tv probe\n");
    printf("  open: ok\n");
    printf("  claimed interface: %u\n", device.info.interface_number);
    printf("  endpoint in: 0x%02x\n", device.info.endpoint_in);
    printf("  endpoint out: 0x%02x\n", device.info.endpoint_out);
    printf("  endpoint max packet: %u\n", device.info.endpoint_max_packet);

    rc = smsusb_close(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "close failed: %s\n", error);
        return 1;
    }

    printf("  close: ok\n");
    return 0;
}

static int version_command(void) {
    smsusb_device_t device;
    sms_version_res_t version;
    char error[256];

    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "version failed: %s\n", error);
        return 1;
    }

    rc = smsusb_get_version(&device, &version, 3000, error, sizeof(error));
    if (rc != 0) {
        close_device_preserving_error(&device, error, sizeof(error));
        fprintf(stderr, "version failed: %s\n", error);
        return 1;
    }

    printf("siano-tv version\n");
    printf("  chip model: 0x%04x\n", version.chip_model);
    printf("  step: %u\n", version.step);
    printf("  metal fix: %u\n", version.metal_fix);
    printf("  firmware id: %u\n", version.firmware_id);
    printf("  supported protocols: 0x%02x\n", version.supported_protocols);
    printf("  firmware version: %u.%u.%u.%u\n",
           version.version_major,
           version.version_minor,
           version.version_patch,
           version.version_field_patch);
    printf("  rom version: %u.%u.%u.%u\n",
           version.rom_ver_major,
           version.rom_ver_minor,
           version.rom_ver_patch,
           version.rom_ver_field_patch);

    rc = smsusb_close(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "close failed: %s\n", error);
        return 1;
    }

    return 0;
}

static int usb_reset_command(void) {
    smsusb_device_t device;
    char error[256];

    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "usb-reset failed: %s\n", error);
        return 1;
    }

    rc = smsusb_reset(&device, error, sizeof(error));
    close_device_preserving_error(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "usb-reset failed: %s\n", error);
        return 1;
    }

    printf("siano-tv usb-reset\n");
    printf("  reset: ok\n");
    return 0;
}

static unsigned char *read_file(const char *path, size_t *size_out) {
    FILE *file = fopen(path, "rb");
    if (!file) {
        return NULL;
    }

    if (fseek(file, 0, SEEK_END) != 0) {
        fclose(file);
        return NULL;
    }
    long size = ftell(file);
    if (size < 0) {
        fclose(file);
        return NULL;
    }
    rewind(file);

    unsigned char *buffer = malloc((size_t)size);
    if (!buffer) {
        fclose(file);
        return NULL;
    }

    size_t read_count = fread(buffer, 1, (size_t)size, file);
    fclose(file);

    if (read_count != (size_t)size) {
        free(buffer);
        return NULL;
    }

    *size_out = (size_t)size;
    return buffer;
}

static int ensure_parent_directory(const char *path) {
    char buffer[1024];
    snprintf(buffer, sizeof(buffer), "%s", path);

    char *last_slash = strrchr(buffer, '/');
    if (!last_slash) {
        return 0;
    }
    if (last_slash == buffer) {
        return 0;
    }
    *last_slash = '\0';

    for (char *p = buffer + 1; *p; p++) {
        if (*p != '/') {
            continue;
        }
        *p = '\0';
        mkdir(buffer, 0755);
        *p = '/';
    }
    mkdir(buffer, 0755);
    return 0;
}

static FILE *open_output_file(const char *path) {
    ensure_parent_directory(path);
    return fopen(path, "wb");
}

static void close_device_preserving_error(smsusb_device_t *device, char *error, unsigned long error_len) {
    char original[256];
    snprintf(original, sizeof(original), "%s", error ? error : "");
    smsusb_close(device, error, error_len);
    if (error && error_len > 0 && original[0]) {
        snprintf(error, error_len, "%s", original);
    }
}

static const char *find_isdbt_firmware(void) {
    const char *override = getenv("SIANO_TV_FIRMWARE");
    if (override && access(override, R_OK) == 0) {
        return override;
    }

    const char *paths[] = {
        "firmware/isdbt_nova_12mhz_b0_official_2010.inp",
        "/Library/Application Support/Siano TV Digital/firmware/isdbt_nova_12mhz_b0_official_2010.inp",
        "firmware/isdbt_nova_12mhz_b0.inp",
        "/Library/Application Support/Siano TV Digital/firmware/isdbt_nova_12mhz_b0.inp",
        "/usr/local/share/siano-tv/firmware/isdbt_nova_12mhz_b0.inp",
        "/Users/lferrarezi/Downloads/Infinito PenTV/Mini_PENTV_USB/Linux/isdbt_nova_12mhz_b0.inp",
    };

    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        if (access(paths[i], R_OK) == 0) {
            return paths[i];
        }
    }

    static char home_path[512];
    const char *home = getenv("HOME");
    if (home) {
        int written = snprintf(
            home_path,
            sizeof(home_path),
            "%s/.local/share/siano-tv/firmware/isdbt_nova_12mhz_b0.inp",
            home
        );
        if (written > 0 && (size_t)written < sizeof(home_path) && access(home_path, R_OK) == 0) {
            return home_path;
        }
    }

    return NULL;
}

static int firmware_path_command(void) {
    const char *path = find_isdbt_firmware();
    if (!path) {
        fprintf(stderr, "firmware-path failed: ISDB-T firmware not found\n");
        return 1;
    }
    printf("siano-tv firmware-path\n");
    printf("  %s\n", path);
    return 0;
}

static uint32_t selected_isdbt_mode(void) {
    const char *mode = getenv("SIANO_TV_MODE");
    if (mode && strcmp(mode, "isdbt-bda") == 0) {
        return SMS_DEVICE_MODE_ISDBT_BDA;
    }
    return SMS_DEVICE_MODE_ISDBT;
}

static const char *device_mode_name(uint32_t mode) {
    return mode == SMS_DEVICE_MODE_ISDBT_BDA ? "ISDB-T BDA" : "ISDB-T";
}

static uint8_t env_u8_or_default(const char *name, uint8_t fallback) {
    const char *value = getenv(name);
    if (!value || !*value) {
        return fallback;
    }
    char *end = NULL;
    unsigned long parsed = strtoul(value, &end, 0);
    if (end == value || *end != '\0' || parsed > 255) {
        return fallback;
    }
    return (uint8_t)parsed;
}

static int env_flag_enabled(const char *name) {
    const char *value = getenv(name);
    return value && (strcmp(value, "1") == 0 || strcmp(value, "true") == 0 || strcmp(value, "yes") == 0);
}

static int ensure_isdbt_ready_mode(smsusb_device_t *device, uint32_t mode, char *error, unsigned long error_len) {
    sms_version_res_t version;
    int rc = smsusb_get_version(device, &version, 3000, error, error_len);
    if (rc != 0) {
        return -1;
    }

    if (version.firmware_id == 255) {
        const char *firmware_path = find_isdbt_firmware();
        if (!firmware_path) {
            snprintf(error, error_len, "ISDB-T firmware not found");
            return -1;
        }

        size_t firmware_size = 0;
        unsigned char *firmware = read_file(firmware_path, &firmware_size);
        if (!firmware) {
            snprintf(error, error_len, "could not read firmware %s", firmware_path);
            return -1;
        }

        rc = smsusb_load_firmware(device, firmware, firmware_size, error, error_len);
        free(firmware);
        if (rc != 0) {
            return -1;
        }

        sleep(1);
    }

    rc = smsusb_init_device_mode(device, mode, error, error_len);
    if (rc != 0) {
        return -1;
    }

    return smsusb_set_max_tx_msg_len(device, 15792, error, error_len);
}

static int ensure_isdbt_ready(smsusb_device_t *device, char *error, unsigned long error_len) {
    return ensure_isdbt_ready_mode(device, selected_isdbt_mode(), error, error_len);
}

static void prepare_reception_best_effort(smsusb_device_t *device) {
    char local_error[256];
    int rc = smsusb_set_max_tx_msg_len(device, 15792, local_error, sizeof(local_error));
    printf("  prepare max-tx-msg-len 15792: %s%s%s\n",
           rc == 0 ? "ok" : "erro",
           rc == 0 ? "" : " ",
           rc == 0 ? "" : local_error);

    rc = smsusb_receive_1seg_through_fullseg(device, local_error, sizeof(local_error));
    printf("  prepare 1seg-through-fullseg: %s%s%s\n",
           rc == 0 ? "ok" : "erro",
           rc == 0 ? "" : " ",
           rc == 0 ? "" : local_error);

    rc = smsusb_receive_vhf_via_vhf_input(device, local_error, sizeof(local_error));
    printf("  prepare vhf-via-vhf-input: %s%s%s\n",
           rc == 0 ? "ok" : "erro",
           rc == 0 ? "" : " ",
           rc == 0 ? "" : local_error);
    fflush(stdout);
}

static void prepare_reception_experimental_if_enabled(smsusb_device_t *device) {
    const char *enabled = getenv("SIANO_TV_EXPERIMENTAL_PREP");
    if (enabled && strcmp(enabled, "1") == 0) {
        prepare_reception_best_effort(device);
    }
}

static int prepare_reception_command(void) {
    smsusb_device_t device;
    char error[256];
    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "prepare-reception failed: %s\n", error);
        return 1;
    }

    rc = ensure_isdbt_ready(&device, error, sizeof(error));
    if (rc != 0) {
        close_device_preserving_error(&device, error, sizeof(error));
        fprintf(stderr, "prepare-reception failed: %s\n", error);
        return 1;
    }

    printf("siano-tv prepare-reception\n");
    prepare_reception_best_effort(&device);
    smsusb_close(&device, error, sizeof(error));
    return 0;
}

static int firmware_load_command(const char *path) {
    size_t firmware_size = 0;
    unsigned char *firmware = read_file(path, &firmware_size);
    if (!firmware) {
        fprintf(stderr, "firmware-load failed: could not read %s\n", path);
        return 1;
    }

    smsusb_device_t device;
    char error[256];

    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        free(firmware);
        fprintf(stderr, "firmware-load failed: %s\n", error);
        return 1;
    }

    printf("siano-tv firmware-load\n");
    printf("  file: %s\n", path);
    printf("  size: %lu bytes\n", (unsigned long)firmware_size);

    rc = smsusb_load_firmware(&device, firmware, firmware_size, error, sizeof(error));
    free(firmware);

    if (rc != 0) {
        close_device_preserving_error(&device, error, sizeof(error));
        fprintf(stderr, "firmware-load failed: %s\n", error);
        return 1;
    }

    rc = smsusb_close(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "close failed: %s\n", error);
        return 1;
    }

    printf("  load: ok\n");
    return 0;
}

static int tune_isdbt_command(const char *frequency_text) {
    char *end = NULL;
    unsigned long frequency = strtoul(frequency_text, &end, 10);
    if (!end || *end != '\0' || frequency == 0 || frequency > 1000000000UL) {
        fprintf(stderr, "tune-isdbt failed: invalid frequency %s\n", frequency_text);
        return 2;
    }

    smsusb_device_t device;
    char error[256];

    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "tune-isdbt failed: %s\n", error);
        return 1;
    }

    rc = ensure_isdbt_ready(&device, error, sizeof(error));
    if (rc != 0) {
        close_device_preserving_error(&device, error, sizeof(error));
        fprintf(stderr, "tune-isdbt failed: %s\n", error);
        return 1;
    }

    rc = smsusb_tune_isdbt_segment(&device, (uint32_t)frequency, SMS_BW_ISDBT_13SEG, error, sizeof(error));
    if (rc != 0) {
        close_device_preserving_error(&device, error, sizeof(error));
        fprintf(stderr, "tune-isdbt failed: %s\n", error);
        return 1;
    }

    rc = smsusb_close(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "close failed: %s\n", error);
        return 1;
    }

    printf("siano-tv tune-isdbt\n");
    printf("  frequency: %lu Hz\n", frequency);
    printf("  tune request: ok\n");
    return 0;
}

static int init_isdbt_command(void) {
    smsusb_device_t device;
    char error[256];

    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "init-isdbt failed: %s\n", error);
        return 1;
    }

    rc = ensure_isdbt_ready_mode(&device, SMS_DEVICE_MODE_ISDBT, error, sizeof(error));
    if (rc != 0) {
        close_device_preserving_error(&device, error, sizeof(error));
        fprintf(stderr, "init-isdbt failed: %s\n", error);
        return 1;
    }

    rc = smsusb_close(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "close failed: %s\n", error);
        return 1;
    }

    printf("siano-tv init-isdbt\n");
    printf("  mode: ISDB-T\n");
    printf("  init request: ok\n");
    return 0;
}

static int init_isdbt_bda_command(void) {
    smsusb_device_t device;
    char error[256];

    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "init-isdbt-bda failed: %s\n", error);
        return 1;
    }

    rc = ensure_isdbt_ready_mode(&device, SMS_DEVICE_MODE_ISDBT_BDA, error, sizeof(error));
    if (rc != 0) {
        close_device_preserving_error(&device, error, sizeof(error));
        fprintf(stderr, "init-isdbt-bda failed: %s\n", error);
        return 1;
    }

    rc = smsusb_close(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "close failed: %s\n", error);
        return 1;
    }

    printf("siano-tv init-isdbt-bda\n");
    printf("  mode: ISDB-T BDA\n");
    printf("  init request: ok\n");
    return 0;
}

static int parse_ulong_arg(const char *text, unsigned long min, unsigned long max, unsigned long *out) {
    char *end = NULL;
    unsigned long value = strtoul(text, &end, 10);
    if (!end || *end != '\0' || value < min || value > max) {
        return -1;
    }
    *out = value;
    return 0;
}

static int capture_isdbt_command(const char *frequency_text, const char *seconds_text, const char *out_path) {
    unsigned long frequency = 0;
    unsigned long seconds = 0;

    if (parse_ulong_arg(frequency_text, 1, 1000000000UL, &frequency) != 0) {
        fprintf(stderr, "capture-isdbt failed: invalid frequency %s\n", frequency_text);
        return 2;
    }
    if (parse_ulong_arg(seconds_text, 1, 300, &seconds) != 0) {
        fprintf(stderr, "capture-isdbt failed: invalid seconds %s\n", seconds_text);
        return 2;
    }

    FILE *out = open_output_file(out_path);
    if (!out) {
        fprintf(stderr, "capture-isdbt failed: could not open %s: %s\n", out_path, strerror(errno));
        return 1;
    }

    smsusb_device_t device;
    char error[256];
    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fclose(out);
        fprintf(stderr, "capture-isdbt failed: %s\n", error);
        return 1;
    }

    rc = ensure_isdbt_ready(&device, error, sizeof(error));
    if (rc != 0) {
        smsusb_close(&device, error, sizeof(error));
        fclose(out);
        fprintf(stderr, "capture-isdbt failed: %s\n", error);
        return 1;
    }

    rc = smsusb_tune_isdbt(&device, (uint32_t)frequency, error, sizeof(error));
    if (rc != 0) {
        smsusb_close(&device, error, sizeof(error));
        fclose(out);
        fprintf(stderr, "capture-isdbt failed: %s\n", error);
        return 1;
    }

    time_t signal_wait_until = time(NULL) + 6;
    while (time(NULL) < signal_wait_until) {
        sms_msg_hdr_t header;
        rc = smsusb_read_message_header(&device, &header, 1000, error, sizeof(error));
        if (rc < 0) {
            smsusb_close(&device, error, sizeof(error));
            fclose(out);
            fprintf(stderr, "capture-isdbt failed: %s\n", error);
            return 1;
        }
        if (header.msg_type == 827 || header.msg_type == 805) {
            break;
        }
    }

    const uint32_t bootstrap_pids[] = {0x0000, 0x0010, 0x0011, 0x0012};
    for (size_t i = 0; i < sizeof(bootstrap_pids) / sizeof(bootstrap_pids[0]); i++) {
        rc = smsusb_add_pid_filter(&device, bootstrap_pids[i], error, sizeof(error));
        if (rc != 0) {
            smsusb_close(&device, error, sizeof(error));
            fclose(out);
            fprintf(stderr, "capture-isdbt failed: %s\n", error);
            return 1;
        }
    }

    unsigned char ts_buffer[8192];
    size_t total = 0;
    time_t end_time = time(NULL) + (time_t)seconds;

    while (time(NULL) < end_time) {
        size_t packet_size = 0;
        rc = smsusb_read_ts_packet(&device, ts_buffer, sizeof(ts_buffer), &packet_size, 1000, error, sizeof(error));
        if (rc != 0) {
            break;
        }
        if (packet_size == 0) {
            continue;
        }
        if (fwrite(ts_buffer, 1, packet_size, out) != packet_size) {
            snprintf(error, sizeof(error), "write failed");
            rc = -1;
            break;
        }
        total += packet_size;
    }

    smsusb_close(&device, error, sizeof(error));
    fclose(out);

    if (rc != 0) {
        fprintf(stderr, "capture-isdbt failed: %s\n", error);
        return 1;
    }

    printf("siano-tv capture-isdbt\n");
    printf("  frequency: %lu Hz\n", frequency);
    printf("  duration: %lu seconds\n", seconds);
    printf("  output: %s\n", out_path);
    printf("  bytes: %lu\n", (unsigned long)total);
    return 0;
}

static const char *msg_name(uint16_t type) {
    switch (type) {
    case SMS_MSG_DVBT_BDA_DATA:
        return "MSG_SMS_DVBT_BDA_DATA";
    case SMS_MSG_DATA_MSG:
        return "MSG_SMS_DATA_MSG";
    case SMS_MSG_RAW_CAPTURE_START_RES:
        return "MSG_SMS_RAW_CAPTURE_START_RES";
    case SMS_MSG_RAW_CAPTURE_ABORT_RES:
        return "MSG_SMS_RAW_CAPTURE_ABORT_RES";
    case SMS_MSG_RAW_CAPTURE_COMPLETE_IND:
        return "MSG_SMS_RAW_CAPTURE_COMPLETE_IND";
    case SMS_MSG_DATA_PUMP_IND:
        return "MSG_SMS_DATA_PUMP_IND";
    case SMS_MSG_DATA_PUMP_RES:
        return "MSG_SMS_DATA_PUMP_RES";
    case SMS_MSG_ENABLE_TS_INTERFACE_RES:
        return "MSG_SMS_ENABLE_TS_INTERFACE_RES";
    case SMS_MSG_DISABLE_TS_INTERFACE_RES:
        return "MSG_SMS_DISABLE_TS_INTERFACE_RES";
    case SMS_MSG_ISDBT_TUNE_RES:
        return "MSG_SMS_ISDBT_TUNE_RES";
    case SMS_MSG_RECEIVE_1SEG_THROUGH_FULLSEG_RES:
        return "MSG_SMS_RECEIVE_1SEG_THROUGH_FULLSEG_RES";
    case SMS_MSG_RECEIVE_VHF_VIA_VHF_INPUT_RES:
        return "MSG_SMS_RECEIVE_VHF_VIA_VHF_INPUT_RES";
    case SMS_MSG_INTERFACE_LOCK_IND:
        return "MSG_SMS_INTERFACE_LOCK_IND";
    case SMS_MSG_INTERFACE_UNLOCK_IND:
        return "MSG_SMS_INTERFACE_UNLOCK_IND";
    case SMS_MSG_SIGNAL_DETECTED_IND:
        return "MSG_SMS_SIGNAL_DETECTED_IND";
    case SMS_MSG_NO_SIGNAL_IND:
        return "MSG_SMS_NO_SIGNAL_IND";
    case SMS_MSG_GET_STATISTICS_RES:
        return "MSG_SMS_GET_STATISTICS_RES";
    case SMS_MSG_GET_STATISTICS_EX_RES:
        return "MSG_SMS_GET_STATISTICS_EX_RES";
    case SMS_MSG_TRANSMISSION_IND:
        return "MSG_SMS_TRANSMISSION_IND";
    case SMS_MSG_HO_PER_SLICES_IND:
        return "MSG_SMS_HO_PER_SLICES_IND";
    case SMS_MSG_SET_PERIODIC_STATISTICS_RES:
        return "MSG_SMS_SET_PERIODIC_STATISTICS_RES";
    default:
        return "unknown";
    }
}

static int stats_score(const sms_isdbt_stats_summary_t *stats);

static int debug_read_command(const char *frequency_text, const char *seconds_text) {
    unsigned long frequency = 0;
    unsigned long seconds = 0;

    if (parse_ulong_arg(frequency_text, 1, 1000000000UL, &frequency) != 0 ||
        parse_ulong_arg(seconds_text, 1, 300, &seconds) != 0) {
        fprintf(stderr, "debug-read failed: invalid arguments\n");
        return 2;
    }

    smsusb_device_t device;
    char error[256];
    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "debug-read failed: %s\n", error);
        return 1;
    }

    rc = ensure_isdbt_ready(&device, error, sizeof(error));
    if (rc == 0) {
        rc = smsusb_tune_isdbt(&device, (uint32_t)frequency, error, sizeof(error));
    }
    if (rc != 0) {
        smsusb_close(&device, error, sizeof(error));
        fprintf(stderr, "debug-read failed: %s\n", error);
        return 1;
    }

    printf("siano-tv debug-read\n");
    printf("  frequency: %lu Hz\n", frequency);
    printf("  duration: %lu seconds\n", seconds);

    const uint32_t debug_pids[] = {0x0000, 0x0010, 0x0011, 0x0012};
    for (size_t i = 0; i < sizeof(debug_pids) / sizeof(debug_pids[0]); i++) {
        rc = smsusb_add_pid_filter(&device, debug_pids[i], error, sizeof(error));
        if (rc != 0) {
            smsusb_close(&device, error, sizeof(error));
            fprintf(stderr, "debug-read failed: %s\n", error);
            return 1;
        }
    }

    time_t end_time = time(NULL) + (time_t)seconds;
    while (time(NULL) < end_time) {
        sms_msg_hdr_t header;
        rc = smsusb_read_message_header(&device, &header, 1000, error, sizeof(error));
        if (rc < 0) {
            break;
        }
        if (rc == 0 || header.msg_type == 0) {
            printf("  timeout\n");
            continue;
        }
        printf("  msg type=%u %s length=%u src=%u dst=%u flags=0x%04x transfer=%d\n",
               header.msg_type,
               msg_name(header.msg_type),
               header.msg_length,
               header.msg_src_id,
               header.msg_dst_id,
               header.msg_flags,
               rc);
    }

    smsusb_close(&device, error, sizeof(error));
    if (rc < 0) {
        fprintf(stderr, "debug-read failed: %s\n", error);
        return 1;
    }

    return 0;
}

static int stats_isdbt_command(const char *frequency_text) {
    unsigned long frequency = 0;
    if (parse_ulong_arg(frequency_text, 1, 1000000000UL, &frequency) != 0) {
        fprintf(stderr, "stats-isdbt failed: invalid frequency %s\n", frequency_text);
        return 2;
    }

    smsusb_device_t device;
    char error[256];
    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "stats-isdbt failed: %s\n", error);
        return 1;
    }

    rc = ensure_isdbt_ready(&device, error, sizeof(error));
    if (rc == 0) {
        rc = smsusb_tune_isdbt(&device, (uint32_t)frequency, error, sizeof(error));
    }
    if (rc != 0) {
        smsusb_close(&device, error, sizeof(error));
        fprintf(stderr, "stats-isdbt failed: %s\n", error);
        return 1;
    }

    sleep(1);

    sms_isdbt_stats_summary_t stats;
    rc = smsusb_get_isdbt_stats(&device, &stats, error, sizeof(error));
    smsusb_close(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "stats-isdbt failed: %s\n", error);
        return 1;
    }

    printf("siano-tv stats-isdbt\n");
    printf("  requested frequency: %lu Hz\n", frequency);
    printf("  reported frequency: %u Hz\n", stats.frequency);
    printf("  rf locked: %u\n", stats.is_rf_locked);
    printf("  demod locked: %u\n", stats.is_demod_locked);
    printf("  modem state: %u\n", stats.modem_state);
    printf("  snr: %d dB\n", stats.snr);
    printf("  rssi: %d dBm\n", stats.rssi);
    printf("  in-band power: %d dBm\n", stats.in_band_power);
    printf("  carrier offset: %d Hz\n", stats.carrier_offset);
    printf("  bandwidth code: %u\n", stats.bandwidth);
    printf("  transmission mode: %u\n", stats.transmission_mode);
    printf("  guard interval: %u\n", stats.guard_interval);
    printf("  layers: %u\n", stats.num_layers);
    return 0;
}

static void print_stats_line(const char *prefix, const sms_isdbt_stats_summary_t *stats) {
    printf("%srf=%u demod=%u modem=%u snr=%d rssi=%d power=%d carrier_offset=%d bandwidth=%u transmission=%u guard=%u layers=%u score=%d\n",
           prefix,
           stats->is_rf_locked,
           stats->is_demod_locked,
           stats->modem_state,
           stats->snr,
           stats->rssi,
           stats->in_band_power,
           stats->carrier_offset,
           stats->bandwidth,
           stats->transmission_mode,
           stats->guard_interval,
           stats->num_layers,
           stats_score(stats));
}

static int stats_isdbt_ex_command(const char *frequency_text) {
    unsigned long frequency = 0;
    if (parse_ulong_arg(frequency_text, 1, 1000000000UL, &frequency) != 0) {
        fprintf(stderr, "stats-isdbt-ex failed: invalid frequency %s\n", frequency_text);
        return 2;
    }

    smsusb_device_t device;
    char error[256];
    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "stats-isdbt-ex failed: %s\n", error);
        return 1;
    }

    rc = ensure_isdbt_ready(&device, error, sizeof(error));
    if (rc == 0) {
        rc = smsusb_tune_isdbt(&device, (uint32_t)frequency, error, sizeof(error));
    }
    if (rc != 0) {
        smsusb_close(&device, error, sizeof(error));
        fprintf(stderr, "stats-isdbt-ex failed: %s\n", error);
        return 1;
    }

    sleep(1);

    sms_isdbt_stats_summary_t stats;
    rc = smsusb_get_isdbt_stats_ex(&device, &stats, error, sizeof(error));
    smsusb_close(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "stats-isdbt-ex failed: %s\n", error);
        return 1;
    }

    printf("siano-tv stats-isdbt-ex\n");
    printf("  requested frequency: %lu Hz\n", frequency);
    printf("  reported frequency: %u Hz\n", stats.frequency);
    print_stats_line("  ", &stats);
    return 0;
}

static uint32_t uhf_channel_frequency(unsigned int channel) {
    return 473142857U + ((channel - 14U) * 6000000U);
}

static uint32_t high_vhf_channel_frequency(unsigned int channel) {
    return 177142857U + ((channel - 7U) * 6000000U);
}

static uint32_t low_vhf_channel_frequency(unsigned int channel) {
    if (channel >= 2 && channel <= 4) {
        return 57142857U + ((channel - 2U) * 6000000U);
    }
    if (channel == 5) {
        return 79142857U;
    }
    if (channel == 6) {
        return 85142857U;
    }
    return 0;
}

static uint32_t br_channel_frequency(unsigned int channel) {
    if (channel == 1) {
        return 47142857U;
    }
    if (channel >= 2 && channel <= 6) {
        return low_vhf_channel_frequency(channel);
    }
    if (channel >= 7 && channel <= 13) {
        return high_vhf_channel_frequency(channel);
    }
    if (channel >= 14 && channel <= BR_SCAN_EXTENDED_MAX_CHANNEL) {
        return uhf_channel_frequency(channel);
    }
    return 0;
}

static const char *br_channel_band(unsigned int channel) {
    if (channel == 1) {
        return "VHF-I legado";
    }
    if (channel >= 2 && channel <= 6) {
        return "VHF baixo";
    }
    if (channel >= 7 && channel <= 13) {
        return "VHF alto";
    }
    if (channel >= 14 && channel <= 59) {
        return "UHF";
    }
    if (channel >= 60 && channel <= 69) {
        return "UHF estendido";
    }
    return "fora_plano";
}

static int channels_br_range_command(unsigned int max_channel, const char *command_name) {
    printf("siano-tv %s\n", command_name);
    printf("  sistema: ISDB-Tb Brasil\n");
    printf("  canais: %u-%u%s\n",
           BR_SCAN_MIN_CHANNEL,
           max_channel,
           max_channel > BR_SCAN_MAX_CHANNEL ? " (inclui UHF estendido historico)" : "");
    for (unsigned int ch = BR_SCAN_MIN_CHANNEL; ch <= max_channel; ch++) {
        uint32_t frequency = br_channel_frequency(ch);
        if (!frequency) {
            continue;
        }
        printf("  canal=%u faixa=%s freq=%u\n", ch, br_channel_band(ch), frequency);
    }
    return 0;
}

static int channels_br_command(void) {
    return channels_br_range_command(BR_SCAN_MAX_CHANNEL, "channels-br");
}

static int channels_br_extended_command(void) {
    return channels_br_range_command(BR_SCAN_EXTENDED_MAX_CHANNEL, "channels-br-extended");
}

static const char *segment_name(uint32_t segment_width) {
    switch (segment_width) {
    case SMS_BW_ISDBT_1SEG:
        return "1seg";
    case SMS_BW_ISDBT_3SEG:
        return "3seg";
    case SMS_BW_ISDBT_13SEG:
        return "13seg";
    default:
        return "unknown";
    }
}

static int stats_score(const sms_isdbt_stats_summary_t *stats) {
    int score = 0;
    if (stats->is_rf_locked) {
        score += 1000;
    }
    if (stats->is_demod_locked) {
        score += 100000;
    }
    if (stats->modem_state > 0 && stats->modem_state < 1000) {
        score += (int)stats->modem_state * 100;
    }
    if (stats->snr > 0 && stats->snr < 1000) {
        score += stats->snr * 10;
    }
    if (stats->in_band_power < 0 && stats->in_band_power > -120) {
        score += 120 + stats->in_band_power;
    }
    int carrier_offset = stats->carrier_offset < 0 ? -stats->carrier_offset : stats->carrier_offset;
    if (carrier_offset > 0 && carrier_offset < 1000000) {
        score += 1000000 - carrier_offset;
    }
    return score;
}

typedef struct msg_count {
    uint16_t type;
    unsigned long count;
    unsigned long bytes;
} msg_count_t;

static void add_msg_count(msg_count_t *counts, size_t count_len, uint16_t type, unsigned int length) {
    for (size_t i = 0; i < count_len; i++) {
        if (counts[i].type == type || counts[i].count == 0) {
            counts[i].type = type;
            counts[i].count++;
            counts[i].bytes += length;
            return;
        }
    }
}

static int debug_channel_br_command(int argc, char **argv) {
    unsigned long channel = 0;
    if (parse_ulong_arg(argv[2], BR_SCAN_MIN_CHANNEL, BR_SCAN_EXTENDED_MAX_CHANNEL, &channel) != 0) {
        fprintf(stderr, "debug-channel-br failed: canal fisico deve estar entre 1 e 69\n");
        return 2;
    }

    unsigned long seconds_per_mode = 5;
    if (argc >= 4 && parse_ulong_arg(argv[3], 1, 30, &seconds_per_mode) != 0) {
        fprintf(stderr, "debug-channel-br failed: seconds_per_mode deve estar entre 1 e 30\n");
        return 2;
    }

    uint32_t frequency = br_channel_frequency((unsigned int)channel);
    if (!frequency) {
        fprintf(stderr, "debug-channel-br failed: canal fisico fora da canalizacao conhecida\n");
        return 2;
    }

    smsusb_device_t device;
    char error[256];
    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "debug-channel-br failed: %s\n", error);
        return 1;
    }

    rc = ensure_isdbt_ready(&device, error, sizeof(error));
    if (rc != 0) {
        smsusb_close(&device, error, sizeof(error));
        fprintf(stderr, "debug-channel-br failed: %s\n", error);
        return 1;
    }
    prepare_reception_experimental_if_enabled(&device);

    printf("siano-tv debug-channel-br\n");
    printf("  sistema: ISDB-Tb Brasil\n");
    printf("  canal: %lu\n", channel);
    printf("  faixa: %s\n", br_channel_band((unsigned int)channel));
    printf("  frequency: %u Hz\n", frequency);
    printf("  seconds_per_mode: %lu\n", seconds_per_mode);

    const uint32_t modes[] = {SMS_BW_ISDBT_1SEG, SMS_BW_ISDBT_13SEG, SMS_BW_ISDBT_3SEG};
    unsigned char message[8192];
    for (size_t mode_i = 0; mode_i < sizeof(modes) / sizeof(modes[0]); mode_i++) {
        uint32_t mode = modes[mode_i];
        printf("  mode=%s tune=...\n", segment_name(mode));
        rc = smsusb_tune_isdbt_segment(&device, frequency, mode, error, sizeof(error));
        if (rc != 0) {
            printf("    tune_error=%s\n", error);
            continue;
        }

        msg_count_t counts[32];
        memset(counts, 0, sizeof(counts));
        unsigned long transfers = 0;
        unsigned long timeouts = 0;
        unsigned long ts_bytes = 0;
        time_t end_time = time(NULL) + (time_t)seconds_per_mode;
        while (time(NULL) < end_time) {
            size_t size = 0;
            rc = smsusb_read_raw_message(&device, message, sizeof(message), &size, 500, error, sizeof(error));
            if (rc != 0) {
                printf("    read_error=%s\n", error);
                break;
            }
            if (size == 0) {
                timeouts++;
                continue;
            }
            sms_msg_hdr_t *header = (sms_msg_hdr_t *)message;
            transfers++;
            add_msg_count(counts, sizeof(counts) / sizeof(counts[0]), header->msg_type, header->msg_length);
            if (header->msg_type == SMS_MSG_DVBT_BDA_DATA && header->msg_length >= sizeof(sms_msg_hdr_t)) {
                ts_bytes += header->msg_length - sizeof(sms_msg_hdr_t);
            }
            printf("    msg type=%u %s length=%u src=%u dst=%u flags=0x%04x transfer=%lu\n",
                   header->msg_type,
                   msg_name(header->msg_type),
                   header->msg_length,
                   header->msg_src_id,
                   header->msg_dst_id,
                   header->msg_flags,
                   (unsigned long)size);
        }

        sms_isdbt_stats_summary_t stats;
        rc = smsusb_get_isdbt_stats(&device, &stats, error, sizeof(error));
        if (rc == 0) {
            print_stats_line("    stats: ", &stats);
        } else {
            printf("    stats_error=%s\n", error);
        }
        rc = smsusb_get_isdbt_stats_ex(&device, &stats, error, sizeof(error));
        if (rc == 0) {
            print_stats_line("    stats_ex: ", &stats);
        } else {
            printf("    stats_ex_error=%s\n", error);
        }

        printf("    summary transfers=%lu timeouts=%lu ts_bytes=%lu\n", transfers, timeouts, ts_bytes);
        for (size_t i = 0; i < sizeof(counts) / sizeof(counts[0]); i++) {
            if (counts[i].count == 0) {
                continue;
            }
            printf("    count type=%u %s messages=%lu bytes=%lu\n",
                   counts[i].type,
                   msg_name(counts[i].type),
                   counts[i].count,
                   counts[i].bytes);
        }
        fflush(stdout);
    }

    smsusb_close(&device, error, sizeof(error));
    return 0;
}

static void diag_write_error_row(
    FILE *csv,
    unsigned long channel,
    uint32_t center_frequency,
    uint32_t frequency,
    int offset,
    const char *mode,
    int score
) {
    fprintf(csv, "%lu,%u,%u,%d,%s,,,,,,,,,,,,%d\n",
            channel,
            center_frequency,
            frequency,
            offset,
            mode,
            score);
}

static int scan_one(smsusb_device_t *device, unsigned int channel, uint32_t frequency, uint32_t segment_width) {
    char error[256];
    int rc = smsusb_tune_isdbt_segment(device, frequency, segment_width, error, sizeof(error));
    if (rc != 0) {
        printf("  ch=%u freq=%u mode=%s tune_error=%s\n", channel, frequency, segment_name(segment_width), error);
        return 0;
    }

    int saw_signal = 0;
    time_t end_time = time(NULL) + 2;
    while (time(NULL) < end_time) {
        sms_msg_hdr_t header;
        rc = smsusb_read_message_header(device, &header, 250, error, sizeof(error));
        if (rc < 0) {
            printf("  ch=%u freq=%u mode=%s read_error=%s\n", channel, frequency, segment_name(segment_width), error);
            return 0;
        }
        if (header.msg_type == 827 || header.msg_type == 805) {
            saw_signal = 1;
        }
    }

    sms_isdbt_stats_summary_t stats;
    rc = smsusb_get_isdbt_stats(device, &stats, error, sizeof(error));
    if (rc != 0) {
        printf("  ch=%u freq=%u mode=%s signal=%d stats_error=%s\n", channel, frequency, segment_name(segment_width), saw_signal, error);
        return 0;
    }

    printf("  ch=%u freq=%u mode=%s signal=%d rf=%u demod=%u snr=%d rssi=%d power=%d layers=%u\n",
           channel,
           frequency,
           segment_name(segment_width),
           saw_signal,
           stats.is_rf_locked,
           stats.is_demod_locked,
           stats.snr,
           stats.rssi,
           stats.in_band_power,
           stats.num_layers);

    return stats.is_demod_locked ? 1 : 0;
}

static int diag_br_command(int argc, char **argv) {
    unsigned long channel = 0;
    if (parse_ulong_arg(argv[2], BR_SCAN_MIN_CHANNEL, BR_SCAN_EXTENDED_MAX_CHANNEL, &channel) != 0) {
        fprintf(stderr, "diag-br failed: canal fisico deve estar entre 1 e 69\n");
        return 2;
    }

    unsigned long seconds_per_trial = 2;
    if (argc >= 4 && parse_ulong_arg(argv[3], 1, 15, &seconds_per_trial) != 0) {
        fprintf(stderr, "diag-br failed: seconds_per_trial deve estar entre 1 e 15\n");
        return 2;
    }

    mkdir("captures", 0755);
    char default_csv[256];
    snprintf(default_csv, sizeof(default_csv), "captures/diag-br-canal-%lu.csv", channel);
    const char *csv_path = argc >= 5 ? argv[4] : default_csv;

    uint32_t center_frequency = br_channel_frequency((unsigned int)channel);
    if (!center_frequency) {
        fprintf(stderr, "diag-br failed: canal fisico fora da canalizacao conhecida\n");
        return 2;
    }

    FILE *csv = fopen(csv_path, "w");
    if (!csv) {
        fprintf(stderr, "diag-br failed: could not open %s\n", csv_path);
        return 1;
    }
    fprintf(csv, "channel,center_hz,frequency_hz,offset_hz,mode,rf,demod,modem,snr,rssi,power,carrier_offset,bandwidth,transmission_mode,guard,layers,score\n");

    smsusb_device_t device;
    char error[256];
    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fclose(csv);
        fprintf(stderr, "diag-br failed: %s\n", error);
        return 1;
    }

    rc = ensure_isdbt_ready(&device, error, sizeof(error));
    if (rc != 0) {
        smsusb_close(&device, error, sizeof(error));
        fclose(csv);
        fprintf(stderr, "diag-br failed: %s\n", error);
        return 1;
    }

    const int offsets[] = {
        0,
        -250000, 250000,
        -125000, 125000,
        -375000, 375000,
        -500000, 500000,
        -625000, 625000,
        -750000, 750000
    };
    const uint32_t modes[] = {
        SMS_BW_ISDBT_1SEG,
        SMS_BW_ISDBT_13SEG,
        SMS_BW_ISDBT_3SEG
    };

    int best_score = -2147483647;
    unsigned int best_frequency = 0;
    int best_offset = 0;
    uint32_t best_mode = 0;
    sms_isdbt_stats_summary_t best_stats;
    memset(&best_stats, 0, sizeof(best_stats));

    printf("siano-tv diag-br\n");
    printf("  sistema: ISDB-Tb Brasil\n");
    printf("  init mode: %s\n", device_mode_name(selected_isdbt_mode()));
    printf("  canal: %lu\n", channel);
    printf("  faixa: %s\n", br_channel_band((unsigned int)channel));
    printf("  centro: %u Hz\n", center_frequency);
    printf("  seconds_per_trial: %lu\n", seconds_per_trial);
    printf("  csv: %s\n", csv_path);

    for (size_t mode_i = 0; mode_i < sizeof(modes) / sizeof(modes[0]); mode_i++) {
        for (size_t offset_i = 0; offset_i < sizeof(offsets) / sizeof(offsets[0]); offset_i++) {
            int offset = offsets[offset_i];
            uint32_t frequency = (uint32_t)((int64_t)center_frequency + offset);
            char local_error[256];
            rc = smsusb_tune_isdbt_segment(&device, frequency, modes[mode_i], local_error, sizeof(local_error));
            if (rc != 0) {
                printf("  mode=%s offset=%d freq=%u tune_error=%s\n", segment_name(modes[mode_i]), offset, frequency, local_error);
                diag_write_error_row(csv, channel, center_frequency, frequency, offset, segment_name(modes[mode_i]), -1);
                if (strstr(local_error, "LIBUSB_ERROR_NO_DEVICE") != NULL) {
                    smsusb_close(&device, error, sizeof(error));
                    sleep(2);
                    rc = smsusb_open(&device, error, sizeof(error));
                    if (rc == 0) {
                        rc = ensure_isdbt_ready(&device, error, sizeof(error));
                    }
                    if (rc != 0) {
                        printf("  usb_reopen_failed=%s\n", error);
                        goto done;
                    }
                    printf("  usb_reopened=1\n");
                }
                continue;
            }

            time_t end_time = time(NULL) + (time_t)seconds_per_trial;
            sms_isdbt_stats_summary_t stats;
            memset(&stats, 0, sizeof(stats));
            int stats_ok = 0;
            while (time(NULL) <= end_time) {
                rc = smsusb_get_isdbt_stats(&device, &stats, local_error, sizeof(local_error));
                if (rc == 0) {
                    stats_ok = 1;
                }
                if (stats.is_demod_locked) {
                    break;
                }
                usleep(250000);
            }

            if (!stats_ok) {
                printf("  mode=%s offset=%d freq=%u stats_error=%s\n", segment_name(modes[mode_i]), offset, frequency, local_error);
                diag_write_error_row(csv, channel, center_frequency, frequency, offset, segment_name(modes[mode_i]), -1);
                if (strstr(local_error, "LIBUSB_ERROR_NO_DEVICE") != NULL) {
                    smsusb_close(&device, error, sizeof(error));
                    sleep(2);
                    rc = smsusb_open(&device, error, sizeof(error));
                    if (rc == 0) {
                        rc = ensure_isdbt_ready(&device, error, sizeof(error));
                    }
                    if (rc != 0) {
                        printf("  usb_reopen_failed=%s\n", error);
                        goto done;
                    }
                    printf("  usb_reopened=1\n");
                }
                continue;
            }

            int score = stats_score(&stats);
            fprintf(csv, "%lu,%u,%u,%d,%s,%u,%u,%u,%d,%d,%d,%d,%u,%u,%u,%u,%d\n",
                    channel,
                    center_frequency,
                    frequency,
                    offset,
                    segment_name(modes[mode_i]),
                    stats.is_rf_locked,
                    stats.is_demod_locked,
                    stats.modem_state,
                    stats.snr,
                    stats.rssi,
                    stats.in_band_power,
                    stats.carrier_offset,
                    stats.bandwidth,
                    stats.transmission_mode,
                    stats.guard_interval,
                    stats.num_layers,
                    score);

            if (score > best_score) {
                best_score = score;
                best_frequency = frequency;
                best_offset = offset;
                best_mode = modes[mode_i];
                best_stats = stats;
            }

            printf("  mode=%s offset=%d freq=%u rf=%u demod=%u modem=%u snr=%d power=%d carrier=%d score=%d\n",
                   segment_name(modes[mode_i]),
                   offset,
                   frequency,
                   stats.is_rf_locked,
                   stats.is_demod_locked,
                   stats.modem_state,
                   stats.snr,
                   stats.in_band_power,
                   stats.carrier_offset,
                   score);
            fflush(stdout);
        }
    }

done:
    smsusb_close(&device, error, sizeof(error));
    fclose(csv);

    printf("  best: mode=%s offset=%d freq=%u rf=%u demod=%u modem=%u snr=%d power=%d carrier=%d score=%d\n",
           segment_name(best_mode),
           best_offset,
           best_frequency,
           best_stats.is_rf_locked,
           best_stats.is_demod_locked,
           best_stats.modem_state,
           best_stats.snr,
           best_stats.in_band_power,
           best_stats.carrier_offset,
           best_score);
    printf("  next: ./build/siano-tv watch-isdbt %u 300 captures/diag-best-%lu.ts\n", best_frequency, channel);

    return best_stats.is_demod_locked ? 0 : 1;
}

static int scan_isdbt_command(void) {
    smsusb_device_t device;
    char error[256];
    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "scan-isdbt failed: %s\n", error);
        return 1;
    }

    rc = ensure_isdbt_ready(&device, error, sizeof(error));
    if (rc != 0) {
        smsusb_close(&device, error, sizeof(error));
        fprintf(stderr, "scan-isdbt failed: %s\n", error);
        return 1;
    }

    const uint32_t modes[] = {SMS_BW_ISDBT_13SEG, SMS_BW_ISDBT_1SEG, SMS_BW_ISDBT_3SEG};
    int locks = 0;
    printf("siano-tv scan-isdbt\n");
    printf("  VHF 1-13\n");
    for (unsigned int ch = BR_SCAN_MIN_CHANNEL; ch <= 13; ch++) {
        uint32_t frequency = br_channel_frequency(ch);
        if (!frequency) {
            continue;
        }
        for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
            locks += scan_one(&device, ch, frequency, modes[i]);
        }
    }
    printf("  UHF 14-59\n");
    for (unsigned int ch = 14; ch <= BR_SCAN_MAX_CHANNEL; ch++) {
        for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
            locks += scan_one(&device, ch, uhf_channel_frequency(ch), modes[i]);
        }
    }

    smsusb_close(&device, error, sizeof(error));
    printf("  demod locks: %d\n", locks);
    return locks > 0 ? 0 : 1;
}

static int scan_br_range_command(unsigned int max_channel, const char *command_name) {
    smsusb_device_t device;
    char error[256];
    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "%s failed: %s\n", command_name, error);
        return 1;
    }

    rc = ensure_isdbt_ready(&device, error, sizeof(error));
    if (rc != 0) {
        smsusb_close(&device, error, sizeof(error));
        fprintf(stderr, "%s failed: %s\n", command_name, error);
        return 1;
    }

    int demod_locks = 0;
    int rf_locks = 0;
    printf("siano-tv %s\n", command_name);
    printf("  sistema: ISDB-Tb Brasil, 6 MHz, full-seg principal\n");
    printf("  canais: %u-%u%s\n",
           BR_SCAN_MIN_CHANNEL,
           max_channel,
           max_channel > BR_SCAN_MAX_CHANNEL ? " (inclui UHF estendido historico)" : "");
    for (unsigned int ch = BR_SCAN_MIN_CHANNEL; ch <= max_channel; ch++) {
        uint32_t frequency = br_channel_frequency(ch);
        if (!frequency) {
            continue;
        }

        char local_error[256];
        rc = smsusb_tune_isdbt_segment(&device, frequency, SMS_BW_ISDBT_13SEG, local_error, sizeof(local_error));
        if (rc != 0) {
            printf("  canal=%u faixa=%s freq=%u tune_error=%s\n", ch, br_channel_band(ch), frequency, local_error);
            continue;
        }

        sleep(1);
        sms_isdbt_stats_summary_t stats;
        rc = smsusb_get_isdbt_stats(&device, &stats, local_error, sizeof(local_error));
        if (rc != 0) {
            printf("  canal=%u faixa=%s freq=%u stats_error=%s\n", ch, br_channel_band(ch), frequency, local_error);
            continue;
        }

        if (stats.is_rf_locked) {
            rf_locks++;
        }
        if (stats.is_demod_locked) {
            demod_locks++;
        }

        printf("  canal=%u faixa=%s freq=%u rf=%u demod=%u snr=%d power=%d status=%s\n",
               ch,
               br_channel_band(ch),
               frequency,
               stats.is_rf_locked,
               stats.is_demod_locked,
               stats.snr,
               stats.in_band_power,
               stats.is_demod_locked ? "pronto_para_imagem" : (stats.is_rf_locked ? "portadora_sem_demod" : "sem_lock"));
    }

    smsusb_close(&device, error, sizeof(error));
    printf("  rf locks: %d\n", rf_locks);
    printf("  demod locks: %d\n", demod_locks);
    return demod_locks > 0 ? 0 : 1;
}

static int scan_br_command(void) {
    return scan_br_range_command(BR_SCAN_MAX_CHANNEL, "scan-br");
}

static int scan_br_extended_command(void) {
    return scan_br_range_command(BR_SCAN_EXTENDED_MAX_CHANNEL, "scan-br-extended");
}

static int maybe_launch_ffplay(const char *out_path) {
    char command[1024];
    int written = snprintf(
        command,
        sizeof(command),
        "command -v ffplay >/dev/null 2>&1 && nohup ffplay -fflags nobuffer -flags low_delay -framedrop '%s' >/tmp/siano-tv-ffplay.log 2>&1 &",
        out_path
    );
    if (written < 0 || (size_t)written >= sizeof(command)) {
        return -1;
    }

    return system(command);
}

static int install_watch_pids(smsusb_device_t *device, char *error, unsigned long error_len) {
    uint8_t pid_src = env_u8_or_default("SIANO_TV_PID_SRC", SMS_DVBT_BDA_CONTROL_MSG_ID);
    uint8_t pid_dst = env_u8_or_default("SIANO_TV_PID_DST", SMS_HIF_TASK);
    printf("  pid route: src=%u dst=%u\n", pid_src, pid_dst);
    const uint32_t pids[] = {0x2000, 0x0000, 0x0010, 0x0011, 0x0012, 0x0014, 0x1fff};
    for (size_t i = 0; i < sizeof(pids) / sizeof(pids[0]); i++) {
        int rc = smsusb_add_pid_filter_route(device, pids[i], pid_src, pid_dst, error, error_len);
        if (rc != 0) {
            return -1;
        }
    }

    uint32_t listed[32];
    size_t listed_count = 0;
    int rc = smsusb_get_pid_filter_list(device, listed, sizeof(listed) / sizeof(listed[0]), &listed_count, error, error_len);
    if (rc == 0) {
        printf("  pid list count=%lu", (unsigned long)listed_count);
        for (size_t i = 0; i < listed_count; i++) {
            printf(" 0x%04x", listed[i]);
        }
        printf("\n");
    } else {
        printf("  pid list unavailable: %s\n", error);
        if (error && error_len > 0) {
            error[0] = '\0';
        }
    }
    return 0;
}

static int run_stream_kicks(smsusb_device_t *device, const char *spec) {
    if (!spec || !*spec) {
        return 0;
    }

    char local_error[256];
    int failures = 0;
    char spec_copy[256];
    snprintf(spec_copy, sizeof(spec_copy), "%s", spec);

    char *cursor = spec_copy;
    while (cursor && *cursor) {
        char *comma = strchr(cursor, ',');
        if (comma) {
            *comma = '\0';
        }

        int rc = 0;
        unsigned int request_type = 0;
        unsigned int response_type = 0;
        unsigned int data_value = 0;
        if (strcmp(cursor, "enable-ts") == 0) {
            rc = smsusb_send_data1_command(device, SMS_MSG_ENABLE_TS_INTERFACE_REQ, SMS_MSG_ENABLE_TS_INTERFACE_RES, 1, 1500, local_error, sizeof(local_error));
        } else if (strcmp(cursor, "disable-ts") == 0) {
            rc = smsusb_send_data1_command(device, SMS_MSG_DISABLE_TS_INTERFACE_REQ, SMS_MSG_DISABLE_TS_INTERFACE_RES, 0, 1500, local_error, sizeof(local_error));
        } else if (strcmp(cursor, "data-pump") == 0) {
            rc = smsusb_send_data1_command(device, SMS_MSG_DATA_PUMP_REQ, SMS_MSG_DATA_PUMP_RES, 1, 1500, local_error, sizeof(local_error));
        } else if (strcmp(cursor, "raw-capture") == 0) {
            rc = smsusb_send_data1_command(device, SMS_MSG_RAW_CAPTURE_START_REQ, SMS_MSG_RAW_CAPTURE_START_RES, 1, 1500, local_error, sizeof(local_error));
        } else if (strcmp(cursor, "raw-abort") == 0) {
            rc = smsusb_send_header_command_public(device, SMS_MSG_RAW_CAPTURE_ABORT_REQ, SMS_MSG_RAW_CAPTURE_ABORT_RES, 1500, local_error, sizeof(local_error));
        } else if (sscanf(cursor, "data:%u:%u:%u", &request_type, &response_type, &data_value) == 3 &&
                   request_type <= 65535 && response_type <= 65535) {
            rc = smsusb_send_data1_command(device, (uint16_t)request_type, (uint16_t)response_type, data_value, 1500, local_error, sizeof(local_error));
        } else if (sscanf(cursor, "header:%u:%u", &request_type, &response_type) == 2 &&
                   request_type <= 65535 && response_type <= 65535) {
            rc = smsusb_send_header_command_public(device, (uint16_t)request_type, (uint16_t)response_type, 1500, local_error, sizeof(local_error));
        } else {
            printf("  stream kick %s: desconhecido\n", cursor);
            failures++;
            cursor = comma ? comma + 1 : NULL;
            continue;
        }

        printf("  stream kick %s: %s%s%s\n",
               cursor,
               rc == 0 ? "ok" : "erro",
               rc == 0 ? "" : " ",
               rc == 0 ? "" : local_error);
        if (rc != 0) {
            failures++;
        }

        cursor = comma ? comma + 1 : NULL;
    }

    return failures == 0 ? 0 : -1;
}

static int choose_watch_mode(smsusb_device_t *device, uint32_t frequency, uint32_t *mode_out, char *error, unsigned long error_len) {
    const uint32_t modes[] = {SMS_BW_ISDBT_1SEG, SMS_BW_ISDBT_13SEG, SMS_BW_ISDBT_3SEG};
    int best_score = -2147483647;
    uint32_t best_mode = SMS_BW_ISDBT_13SEG;
    char last_error[256] = "";

    printf("  autotune: testando 1seg, 13seg e 3seg\n");
    for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
        uint32_t mode = modes[i];
        int rc = smsusb_tune_isdbt_segment(device, frequency, mode, error, error_len);
        if (rc != 0) {
            snprintf(last_error, sizeof(last_error), "%s", error);
            printf("  autotune mode=%s tune_error=%s\n", segment_name(mode), error);
            continue;
        }

        sleep(1);
        sms_isdbt_stats_summary_t stats;
        rc = smsusb_get_isdbt_stats_ex(device, &stats, error, error_len);
        if (rc != 0) {
            rc = smsusb_get_isdbt_stats(device, &stats, error, error_len);
            if (rc != 0) {
                snprintf(last_error, sizeof(last_error), "%s", error);
                printf("  autotune mode=%s stats_error=%s\n", segment_name(mode), error);
                continue;
            }
        }

        int score = stats_score(&stats);
        printf("  autotune mode=%s rf=%u demod=%u modem=%u snr=%d rssi=%d power=%d score=%d\n",
               segment_name(mode),
               stats.is_rf_locked,
               stats.is_demod_locked,
               stats.modem_state,
               stats.snr,
               stats.rssi,
               stats.in_band_power,
               score);

        if (stats.is_demod_locked) {
            *mode_out = mode;
            return smsusb_tune_isdbt_segment(device, frequency, mode, error, error_len);
        }
        if (score > best_score) {
            best_score = score;
            best_mode = mode;
        }
    }

    if (best_score == -2147483647) {
        snprintf(error, error_len, "autotune failed: %s", last_error[0] ? last_error : "nenhum modo sintonizou");
        return -1;
    }

    *mode_out = best_mode;
    printf("  autotune escolhido=%s score=%d sem demod lock; tentando capturar mesmo assim\n", segment_name(best_mode), best_score);
    return smsusb_tune_isdbt_segment(device, frequency, best_mode, error, error_len);
}

static int watch_isdbt_frequency(unsigned long frequency, unsigned long seconds, const char *out_path) {
    FILE *out = open_output_file(out_path);
    if (!out) {
        fprintf(stderr, "watch-isdbt failed: could not open %s: %s\n", out_path, strerror(errno));
        return 1;
    }

    smsusb_device_t device;
    char error[256];
    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fclose(out);
        fprintf(stderr, "watch-isdbt failed: %s\n", error);
        return 1;
    }

    uint32_t selected_mode = SMS_BW_ISDBT_13SEG;
    rc = ensure_isdbt_ready(&device, error, sizeof(error));
    if (rc == 0) {
        prepare_reception_experimental_if_enabled(&device);
        run_stream_kicks(&device, getenv("SIANO_TV_STREAM_KICK_BEFORE_TUNE"));
        if (env_flag_enabled("SIANO_TV_PID_BEFORE_TUNE")) {
            printf("  instalando filtros PID antes do tune\n");
            rc = install_watch_pids(&device, error, sizeof(error));
        }
    }
    if (rc == 0) {
        rc = choose_watch_mode(&device, (uint32_t)frequency, &selected_mode, error, sizeof(error));
    }
    if (rc != 0) {
        close_device_preserving_error(&device, error, sizeof(error));
        fclose(out);
        fprintf(stderr, "watch-isdbt failed: %s\n", error);
        return 1;
    }

    printf("  aguardando demod lock antes dos filtros PID...\n");
    time_t lock_deadline = time(NULL) + 6;
    while (time(NULL) < lock_deadline) {
        sms_isdbt_stats_summary_t stats;
        int stats_rc = smsusb_get_isdbt_stats_ex(&device, &stats, error, sizeof(error));
        if (stats_rc != 0) {
            stats_rc = smsusb_get_isdbt_stats(&device, &stats, error, sizeof(error));
        }
        if (stats_rc == 0 && stats.is_demod_locked) {
            printf("  demod lock: rf=%u demod=%u snr=%d rssi=%d power=%d layers=%u\n",
                   stats.is_rf_locked,
                   stats.is_demod_locked,
                   stats.snr,
                   stats.rssi,
                   stats.in_band_power,
                   stats.num_layers);
            break;
        }
        usleep(250000);
    }

    run_stream_kicks(&device, getenv("SIANO_TV_STREAM_KICK_BEFORE_PID"));
    if (!env_flag_enabled("SIANO_TV_PID_BEFORE_TUNE")) {
        rc = install_watch_pids(&device, error, sizeof(error));
        if (rc != 0) {
            close_device_preserving_error(&device, error, sizeof(error));
            fclose(out);
            fprintf(stderr, "watch-isdbt failed: %s\n", error);
            return 1;
        }
    }
    run_stream_kicks(&device, getenv("SIANO_TV_STREAM_KICK"));

    printf("siano-tv watch-isdbt\n");
    printf("  sistema: ISDB-Tb Brasil\n");
    printf("  mode: %s\n", segment_name(selected_mode));
    printf("  frequency: %lu Hz\n", frequency);
    printf("  duration: %lu seconds\n", seconds);
    printf("  output: %s\n", out_path);
    printf("  ajuste a posicao do dongle; aguardando demod/TS...\n");
    fflush(stdout);

    unsigned char ts_buffer[8192];
    size_t total = 0;
    int launched_player = 0;
    unsigned long non_ts_messages = 0;
    unsigned long read_timeouts = 0;
    time_t start = time(NULL);
    time_t next_stats = start;
    time_t end_time = start + (time_t)seconds;

    while (time(NULL) < end_time) {
        unsigned char raw_message[32768];
        size_t raw_size = 0;
        rc = smsusb_read_raw_message(&device, raw_message, sizeof(raw_message), &raw_size, 250, error, sizeof(error));
        if (rc != 0) {
            break;
        }
        if (raw_size == 0) {
            read_timeouts++;
        }

        size_t packet_size = 0;
        if (raw_size >= sizeof(sms_msg_hdr_t)) {
            sms_msg_hdr_t *header = (sms_msg_hdr_t *)raw_message;
            if (header->msg_type == SMS_MSG_DVBT_BDA_DATA && header->msg_length >= sizeof(sms_msg_hdr_t)) {
                packet_size = header->msg_length - sizeof(sms_msg_hdr_t);
                if (packet_size > sizeof(ts_buffer)) {
                    snprintf(error, sizeof(error), "TS payload %lu exceeds buffer %lu", (unsigned long)packet_size, (unsigned long)sizeof(ts_buffer));
                    rc = -1;
                    break;
                }
                memcpy(ts_buffer, raw_message + sizeof(sms_msg_hdr_t), packet_size);
            } else {
                non_ts_messages++;
                if (non_ts_messages <= 20 || (non_ts_messages % 25) == 0) {
                    printf("  raw msg type=%u %s length=%u src=%u dst=%u flags=0x%04x\n",
                           header->msg_type,
                           msg_name(header->msg_type),
                           header->msg_length,
                           header->msg_src_id,
                           header->msg_dst_id,
                           header->msg_flags);
                }
            }
        }
        if (packet_size > 0) {
            if (fwrite(ts_buffer, 1, packet_size, out) != packet_size) {
                snprintf(error, sizeof(error), "write failed");
                rc = -1;
                break;
            }
            fflush(out);
            total += packet_size;
            if (!launched_player) {
                maybe_launch_ffplay(out_path);
                launched_player = 1;
            }
        }

        time_t now = time(NULL);
        if (now >= next_stats) {
            sms_isdbt_stats_summary_t stats;
            int stats_rc = smsusb_get_isdbt_stats_ex(&device, &stats, error, sizeof(error));
            if (stats_rc != 0) {
                stats_rc = smsusb_get_isdbt_stats(&device, &stats, error, sizeof(error));
            }
            if (stats_rc == 0) {
                printf("  t=%lds rf=%u demod=%u modem=%u snr=%d rssi=%d power=%d layers=%u bytes=%lu status=%s\n",
                       (long)(now - start),
                       stats.is_rf_locked,
                       stats.is_demod_locked,
                       stats.modem_state,
                       stats.snr,
                       stats.rssi,
                       stats.in_band_power,
                       stats.num_layers,
                       (unsigned long)total,
                       stats.is_demod_locked ? "imagem_possivel" : (stats.is_rf_locked ? "melhorar_posicao" : "sem_portadora"));
            } else {
                printf("  t=%lds stats_error=%s bytes=%lu\n", (long)(now - start), error, (unsigned long)total);
            }
            printf("  usb raw: non_ts=%lu timeouts=%lu\n", non_ts_messages, read_timeouts);
            fflush(stdout);
            next_stats = now + 1;
        }
    }

    close_device_preserving_error(&device, error, sizeof(error));
    fclose(out);

    if (rc != 0) {
        fprintf(stderr, "watch-isdbt failed: %s\n", error);
        return 1;
    }

    printf("  final bytes: %lu\n", (unsigned long)total);
    return total > 0 ? 0 : 1;
}

static int watch_isdbt_command(const char *frequency_text, const char *seconds_text, const char *out_path) {
    unsigned long frequency = 0;
    unsigned long seconds = 0;
    if (parse_ulong_arg(frequency_text, 1, 1000000000UL, &frequency) != 0 ||
        parse_ulong_arg(seconds_text, 1, 3600, &seconds) != 0) {
        fprintf(stderr, "watch-isdbt failed: invalid arguments\n");
        return 2;
    }

    return watch_isdbt_frequency(frequency, seconds, out_path);
}

static int watch_br_command(int argc, char **argv) {
    unsigned long channel = 0;
    if (parse_ulong_arg(argv[2], BR_SCAN_MIN_CHANNEL, BR_SCAN_EXTENDED_MAX_CHANNEL, &channel) != 0) {
        fprintf(stderr, "watch-br failed: canal fisico deve estar entre 1 e 69\n");
        return 2;
    }

    unsigned long seconds = 300;
    if (argc >= 4 && parse_ulong_arg(argv[3], 1, 3600, &seconds) != 0) {
        fprintf(stderr, "watch-br failed: seconds invalido\n");
        return 2;
    }

    char default_path[256];
    mkdir("captures", 0755);
    snprintf(default_path, sizeof(default_path), "captures/br-canal-%lu.ts", channel);
    const char *out_path = argc >= 5 ? argv[4] : default_path;
    uint32_t frequency = br_channel_frequency((unsigned int)channel);
    if (!frequency) {
        fprintf(stderr, "watch-br failed: canal fisico fora da canalizacao conhecida\n");
        return 2;
    }

    return watch_isdbt_frequency(frequency, seconds, out_path);
}

static int pid_list_br_command(const char *channel_text) {
    unsigned long channel = 0;
    if (parse_ulong_arg(channel_text, BR_SCAN_MIN_CHANNEL, BR_SCAN_EXTENDED_MAX_CHANNEL, &channel) != 0) {
        fprintf(stderr, "pid-list-br failed: canal fisico deve estar entre 1 e 69\n");
        return 2;
    }

    uint32_t frequency = br_channel_frequency((unsigned int)channel);
    if (!frequency) {
        fprintf(stderr, "pid-list-br failed: canal fisico fora da canalizacao conhecida\n");
        return 2;
    }

    smsusb_device_t device;
    char error[256];
    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "pid-list-br failed: %s\n", error);
        return 1;
    }

    rc = ensure_isdbt_ready(&device, error, sizeof(error));
    if (rc == 0) {
        rc = smsusb_tune_isdbt_segment(&device, frequency, SMS_BW_ISDBT_13SEG, error, sizeof(error));
    }
    if (rc != 0) {
        smsusb_close(&device, error, sizeof(error));
        fprintf(stderr, "pid-list-br failed: %s\n", error);
        return 1;
    }

    printf("siano-tv pid-list-br\n");
    printf("  canal: %lu\n", channel);
    printf("  frequency: %u Hz\n", frequency);
    rc = install_watch_pids(&device, error, sizeof(error));
    smsusb_close(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "pid-list-br failed: %s\n", error);
        return 1;
    }
    return 0;
}

static int stream_kick_br_command(int argc, char **argv) {
    unsigned long channel = 0;
    if (parse_ulong_arg(argv[2], BR_SCAN_MIN_CHANNEL, BR_SCAN_EXTENDED_MAX_CHANNEL, &channel) != 0) {
        fprintf(stderr, "stream-kick-br failed: canal fisico deve estar entre 1 e 69\n");
        return 2;
    }
    const char *kick_spec = argc >= 4 ? argv[3] : "enable-ts,data-pump";

    uint32_t frequency = br_channel_frequency((unsigned int)channel);
    if (!frequency) {
        fprintf(stderr, "stream-kick-br failed: canal fisico fora da canalizacao conhecida\n");
        return 2;
    }

    smsusb_device_t device;
    char error[256];
    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "stream-kick-br failed: %s\n", error);
        return 1;
    }

    rc = ensure_isdbt_ready(&device, error, sizeof(error));
    if (rc == 0) {
        rc = smsusb_tune_isdbt_segment(&device, frequency, SMS_BW_ISDBT_13SEG, error, sizeof(error));
    }
    if (rc == 0) {
        rc = install_watch_pids(&device, error, sizeof(error));
    }
    if (rc != 0) {
        smsusb_close(&device, error, sizeof(error));
        fprintf(stderr, "stream-kick-br failed: %s\n", error);
        return 1;
    }

    printf("siano-tv stream-kick-br\n");
    printf("  canal: %lu\n", channel);
    printf("  frequency: %u Hz\n", frequency);
    printf("  kicks: %s\n", kick_spec);
    run_stream_kicks(&device, kick_spec);

    unsigned long messages = 0;
    unsigned long timeouts = 0;
    time_t end_time = time(NULL) + 5;
    while (time(NULL) < end_time) {
        unsigned char raw_message[32768];
        size_t raw_size = 0;
        rc = smsusb_read_raw_message(&device, raw_message, sizeof(raw_message), &raw_size, 500, error, sizeof(error));
        if (rc != 0) {
            printf("  read_error=%s\n", error);
            break;
        }
        if (raw_size == 0) {
            timeouts++;
            continue;
        }
        sms_msg_hdr_t *header = (sms_msg_hdr_t *)raw_message;
        messages++;
        printf("  msg type=%u %s length=%u src=%u dst=%u flags=0x%04x\n",
               header->msg_type,
               msg_name(header->msg_type),
               header->msg_length,
               header->msg_src_id,
               header->msg_dst_id,
               header->msg_flags);
    }
    smsusb_close(&device, error, sizeof(error));
    printf("  summary messages=%lu timeouts=%lu\n", messages, timeouts);
    return 0;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        usage(argv[0]);
        return 2;
    }

    if (argc == 2 && strcmp(argv[1], "probe") == 0) {
        return probe_command();
    }
    if (argc == 2 && strcmp(argv[1], "version") == 0) {
        return version_command();
    }
    if (argc == 2 && strcmp(argv[1], "usb-state") == 0) {
        return usb_state_command();
    }
    if (argc == 2 && strcmp(argv[1], "usb-reset") == 0) {
        return usb_reset_command();
    }
    if (argc == 2 && strcmp(argv[1], "firmware-path") == 0) {
        return firmware_path_command();
    }
    if (argc == 2 && strcmp(argv[1], "init-isdbt") == 0) {
        return init_isdbt_command();
    }
    if (argc == 2 && strcmp(argv[1], "init-isdbt-bda") == 0) {
        return init_isdbt_bda_command();
    }
    if (argc == 2 && strcmp(argv[1], "prepare-reception") == 0) {
        return prepare_reception_command();
    }
    if (argc == 2 && strcmp(argv[1], "scan-isdbt") == 0) {
        return scan_isdbt_command();
    }
    if (argc == 2 && strcmp(argv[1], "channels-br") == 0) {
        return channels_br_command();
    }
    if (argc == 2 && strcmp(argv[1], "channels-br-extended") == 0) {
        return channels_br_extended_command();
    }
    if (argc == 2 && strcmp(argv[1], "scan-br") == 0) {
        return scan_br_command();
    }
    if (argc == 2 && strcmp(argv[1], "scan-br-extended") == 0) {
        return scan_br_extended_command();
    }
    if ((argc == 3 || argc == 4 || argc == 5) && strcmp(argv[1], "diag-br") == 0) {
        return diag_br_command(argc, argv);
    }
    if ((argc == 3 || argc == 4) && strcmp(argv[1], "debug-channel-br") == 0) {
        return debug_channel_br_command(argc, argv);
    }
    if (argc == 3 && strcmp(argv[1], "pid-list-br") == 0) {
        return pid_list_br_command(argv[2]);
    }
    if ((argc == 3 || argc == 4) && strcmp(argv[1], "stream-kick-br") == 0) {
        return stream_kick_br_command(argc, argv);
    }
    if ((argc == 3 || argc == 4 || argc == 5) && strcmp(argv[1], "watch-br") == 0) {
        return watch_br_command(argc, argv);
    }
    if (argc == 3 && strcmp(argv[1], "firmware-load") == 0) {
        return firmware_load_command(argv[2]);
    }
    if (argc == 3 && strcmp(argv[1], "tune-isdbt") == 0) {
        return tune_isdbt_command(argv[2]);
    }
    if (argc == 3 && strcmp(argv[1], "stats-isdbt") == 0) {
        return stats_isdbt_command(argv[2]);
    }
    if (argc == 3 && strcmp(argv[1], "stats-isdbt-ex") == 0) {
        return stats_isdbt_ex_command(argv[2]);
    }
    if (argc == 5 && strcmp(argv[1], "capture-isdbt") == 0) {
        return capture_isdbt_command(argv[2], argv[3], argv[4]);
    }
    if (argc == 5 && strcmp(argv[1], "watch-isdbt") == 0) {
        return watch_isdbt_command(argv[2], argv[3], argv[4]);
    }
    if (argc == 4 && strcmp(argv[1], "debug-read") == 0) {
        return debug_read_command(argv[2], argv[3]);
    }

    usage(argv[0]);
    return 2;
}
