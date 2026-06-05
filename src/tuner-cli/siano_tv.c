#include "smsusb_transport.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static void usage(const char *argv0) {
    fprintf(stderr, "Usage: %s probe|version|firmware-load <path>|init-isdbt|tune-isdbt <frequency_hz>|stats-isdbt <frequency_hz>|scan-isdbt|debug-read <frequency_hz> <seconds>|capture-isdbt <frequency_hz> <seconds> <out.ts>|watch-isdbt <frequency_hz> <seconds> <out.ts>\n", argv0);
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
        smsusb_close(&device, error, sizeof(error));
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
        smsusb_close(&device, error, sizeof(error));
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

    rc = smsusb_init_isdbt(&device, error, sizeof(error));
    if (rc != 0) {
        smsusb_close(&device, error, sizeof(error));
        fprintf(stderr, "tune-isdbt failed: %s\n", error);
        return 1;
    }

    rc = smsusb_tune_isdbt(&device, (uint32_t)frequency, error, sizeof(error));
    if (rc != 0) {
        smsusb_close(&device, error, sizeof(error));
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

    rc = smsusb_init_isdbt(&device, error, sizeof(error));
    if (rc != 0) {
        smsusb_close(&device, error, sizeof(error));
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

    FILE *out = fopen(out_path, "wb");
    if (!out) {
        fprintf(stderr, "capture-isdbt failed: could not open %s\n", out_path);
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

    rc = smsusb_init_isdbt(&device, error, sizeof(error));
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
    case SMS_MSG_ISDBT_TUNE_RES:
        return "MSG_SMS_ISDBT_TUNE_RES";
    case 805:
        return "MSG_SMS_INTERFACE_LOCK_IND";
    case 806:
        return "MSG_SMS_INTERFACE_UNLOCK_IND";
    case 827:
        return "MSG_SMS_SIGNAL_DETECTED_IND";
    case 828:
        return "MSG_SMS_NO_SIGNAL_IND";
    case 654:
        return "MSG_SMS_GET_STATISTICS_EX_RES";
    default:
        return "unknown";
    }
}

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

    rc = smsusb_init_isdbt(&device, error, sizeof(error));
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

    rc = smsusb_init_isdbt(&device, error, sizeof(error));
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

static uint32_t uhf_channel_frequency(unsigned int channel) {
    return 473142857U + ((channel - 14U) * 6000000U);
}

static uint32_t vhf_channel_frequency(unsigned int channel) {
    return 177142857U + ((channel - 7U) * 6000000U);
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

static int scan_isdbt_command(void) {
    smsusb_device_t device;
    char error[256];
    int rc = smsusb_open(&device, error, sizeof(error));
    if (rc != 0) {
        fprintf(stderr, "scan-isdbt failed: %s\n", error);
        return 1;
    }

    rc = smsusb_init_isdbt(&device, error, sizeof(error));
    if (rc != 0) {
        smsusb_close(&device, error, sizeof(error));
        fprintf(stderr, "scan-isdbt failed: %s\n", error);
        return 1;
    }

    const uint32_t modes[] = {SMS_BW_ISDBT_13SEG, SMS_BW_ISDBT_1SEG, SMS_BW_ISDBT_3SEG};
    int locks = 0;
    printf("siano-tv scan-isdbt\n");
    printf("  VHF 7-13\n");
    for (unsigned int ch = 7; ch <= 13; ch++) {
        for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
            locks += scan_one(&device, ch, vhf_channel_frequency(ch), modes[i]);
        }
    }
    printf("  UHF 14-51\n");
    for (unsigned int ch = 14; ch <= 51; ch++) {
        for (size_t i = 0; i < sizeof(modes) / sizeof(modes[0]); i++) {
            locks += scan_one(&device, ch, uhf_channel_frequency(ch), modes[i]);
        }
    }

    smsusb_close(&device, error, sizeof(error));
    printf("  demod locks: %d\n", locks);
    return locks > 0 ? 0 : 1;
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

static int watch_isdbt_command(const char *frequency_text, const char *seconds_text, const char *out_path) {
    unsigned long frequency = 0;
    unsigned long seconds = 0;
    if (parse_ulong_arg(frequency_text, 1, 1000000000UL, &frequency) != 0 ||
        parse_ulong_arg(seconds_text, 1, 3600, &seconds) != 0) {
        fprintf(stderr, "watch-isdbt failed: invalid arguments\n");
        return 2;
    }

    FILE *out = fopen(out_path, "wb");
    if (!out) {
        fprintf(stderr, "watch-isdbt failed: could not open %s\n", out_path);
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

    rc = smsusb_init_isdbt(&device, error, sizeof(error));
    if (rc == 0) {
        rc = smsusb_tune_isdbt_segment(&device, (uint32_t)frequency, SMS_BW_ISDBT_13SEG, error, sizeof(error));
    }
    if (rc != 0) {
        smsusb_close(&device, error, sizeof(error));
        fclose(out);
        fprintf(stderr, "watch-isdbt failed: %s\n", error);
        return 1;
    }

    const uint32_t pids[] = {0x0000, 0x0010, 0x0011, 0x0012};
    for (size_t i = 0; i < sizeof(pids) / sizeof(pids[0]); i++) {
        rc = smsusb_add_pid_filter(&device, pids[i], error, sizeof(error));
        if (rc != 0) {
            smsusb_close(&device, error, sizeof(error));
            fclose(out);
            fprintf(stderr, "watch-isdbt failed: %s\n", error);
            return 1;
        }
    }

    printf("siano-tv watch-isdbt\n");
    printf("  frequency: %lu Hz\n", frequency);
    printf("  duration: %lu seconds\n", seconds);
    printf("  output: %s\n", out_path);
    printf("  move the antenna now; waiting for lock/TS...\n");
    fflush(stdout);

    unsigned char ts_buffer[8192];
    size_t total = 0;
    int launched_player = 0;
    time_t start = time(NULL);
    time_t next_stats = start;
    time_t end_time = start + (time_t)seconds;

    while (time(NULL) < end_time) {
        size_t packet_size = 0;
        rc = smsusb_read_ts_packet(&device, ts_buffer, sizeof(ts_buffer), &packet_size, 250, error, sizeof(error));
        if (rc != 0) {
            break;
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
            int stats_rc = smsusb_get_isdbt_stats(&device, &stats, error, sizeof(error));
            if (stats_rc == 0) {
                printf("  t=%lds rf=%u demod=%u modem=%u snr=%d rssi=%d power=%d layers=%u bytes=%lu\n",
                       (long)(now - start),
                       stats.is_rf_locked,
                       stats.is_demod_locked,
                       stats.modem_state,
                       stats.snr,
                       stats.rssi,
                       stats.in_band_power,
                       stats.num_layers,
                       (unsigned long)total);
            } else {
                printf("  t=%lds stats_error=%s bytes=%lu\n", (long)(now - start), error, (unsigned long)total);
            }
            fflush(stdout);
            next_stats = now + 1;
        }
    }

    smsusb_close(&device, error, sizeof(error));
    fclose(out);

    if (rc != 0) {
        fprintf(stderr, "watch-isdbt failed: %s\n", error);
        return 1;
    }

    printf("  final bytes: %lu\n", (unsigned long)total);
    return total > 0 ? 0 : 1;
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
    if (argc == 2 && strcmp(argv[1], "init-isdbt") == 0) {
        return init_isdbt_command();
    }
    if (argc == 2 && strcmp(argv[1], "scan-isdbt") == 0) {
        return scan_isdbt_command();
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
