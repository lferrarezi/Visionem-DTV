#include "smsusb_transport.h"

#include <libusb.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>

static void set_error(char *error, unsigned long error_len, const char *message) {
    if (!error || error_len == 0) {
        return;
    }

    snprintf(error, error_len, "%s", message);
}

static void set_libusb_error(char *error, unsigned long error_len, const char *prefix, int code) {
    if (!error || error_len == 0) {
        return;
    }

    snprintf(error, error_len, "%s: %s", prefix, libusb_error_name(code));
}

int smsusb_open(smsusb_device_t *device, char *error, unsigned long error_len) {
    if (!device) {
        set_error(error, error_len, "device pointer is null");
        return -1;
    }

    memset(device, 0, sizeof(*device));
    device->info = smsusb_known_device();

    libusb_context *ctx = NULL;
    int rc = libusb_init(&ctx);
    if (rc < 0) {
        set_libusb_error(error, error_len, "libusb_init failed", rc);
        return -1;
    }

    libusb_device_handle *handle = libusb_open_device_with_vid_pid(
        ctx,
        device->info.vendor_id,
        device->info.product_id
    );
    if (!handle) {
        libusb_exit(ctx);
        set_error(error, error_len, "device 187f:0202 not found or not openable");
        return -1;
    }

    rc = libusb_claim_interface(handle, device->info.interface_number);
    if (rc < 0) {
        libusb_close(handle);
        libusb_exit(ctx);
        set_libusb_error(error, error_len, "libusb_claim_interface failed", rc);
        return -1;
    }

    device->ctx = ctx;
    device->handle = handle;
    device->claimed = 1;
    set_error(error, error_len, "");
    return 0;
}

int smsusb_close(smsusb_device_t *device, char *error, unsigned long error_len) {
    if (!device) {
        set_error(error, error_len, "device pointer is null");
        return -1;
    }

    libusb_context *ctx = (libusb_context *)device->ctx;
    libusb_device_handle *handle = (libusb_device_handle *)device->handle;

    if (handle && device->claimed) {
        int rc = libusb_release_interface(handle, device->info.interface_number);
        if (rc < 0) {
            set_libusb_error(error, error_len, "libusb_release_interface failed", rc);
            return -1;
        }
    }

    if (handle) {
        libusb_close(handle);
    }
    if (ctx) {
        libusb_exit(ctx);
    }

    memset(device, 0, sizeof(*device));
    set_error(error, error_len, "");
    return 0;
}

static void sms_msg_init(sms_msg_hdr_t *header, uint16_t type, uint16_t length) {
    header->msg_type = type;
    header->msg_src_id = 0;
    header->msg_dst_id = SMS_HIF_TASK;
    header->msg_length = length;
    header->msg_flags = 0;
}

static void sms_msg_init_ex(sms_msg_hdr_t *header, uint16_t type, uint8_t src, uint8_t dst, uint16_t length) {
    header->msg_type = type;
    header->msg_src_id = src;
    header->msg_dst_id = dst;
    header->msg_length = length;
    header->msg_flags = 0;
}

static int smsusb_send(smsusb_device_t *device, const void *buffer, int length, char *error, unsigned long error_len) {
    int transferred = 0;
    libusb_device_handle *handle = (libusb_device_handle *)device->handle;
    int rc = libusb_bulk_transfer(
        handle,
        device->info.endpoint_out,
        (unsigned char *)buffer,
        length,
        &transferred,
        1000
    );
    if (rc < 0) {
        set_libusb_error(error, error_len, "bulk OUT failed", rc);
        return -1;
    }
    if (transferred != length) {
        snprintf(error, error_len, "bulk OUT short write: %d of %d", transferred, length);
        return -1;
    }

    return 0;
}

static int smsusb_receive_message(smsusb_device_t *device, void *buffer, int buffer_len, unsigned int timeout_ms, char *error, unsigned long error_len) {
    int transferred = 0;
    libusb_device_handle *handle = (libusb_device_handle *)device->handle;
    int rc = libusb_bulk_transfer(
        handle,
        device->info.endpoint_in,
        (unsigned char *)buffer,
        buffer_len,
        &transferred,
        timeout_ms
    );
    if (rc < 0) {
        set_libusb_error(error, error_len, "bulk IN failed", rc);
        return -1;
    }
    if (transferred < (int)sizeof(sms_msg_hdr_t)) {
        snprintf(error, error_len, "bulk IN short message: %d bytes", transferred);
        return -1;
    }

    sms_msg_hdr_t *header = (sms_msg_hdr_t *)buffer;
    if (header->msg_length > transferred) {
        snprintf(error, error_len, "message length %u exceeds transfer %d", header->msg_length, transferred);
        return -1;
    }

    return transferred;
}

static int smsusb_send_and_wait(smsusb_device_t *device, const void *request, int request_len, uint16_t expected_type, unsigned int timeout_ms, void *response, int response_len, char *error, unsigned long error_len) {
    int rc = smsusb_send(device, request, request_len, error, error_len);
    if (rc != 0) {
        return -1;
    }

    unsigned char local_buffer[SMSUSB_ENDPOINT_MAX_PACKET];
    void *buffer = response ? response : local_buffer;
    int buffer_len = response ? response_len : (int)sizeof(local_buffer);

    for (;;) {
        rc = smsusb_receive_message(device, buffer, buffer_len, timeout_ms, error, error_len);
        if (rc < 0) {
            return -1;
        }

        sms_msg_hdr_t *header = (sms_msg_hdr_t *)buffer;
        if (header->msg_type == expected_type) {
            return rc;
        }
    }
}

int smsusb_get_version(smsusb_device_t *device, sms_version_res_t *version, unsigned int timeout_ms, char *error, unsigned long error_len) {
    if (!device || !device->handle || !version) {
        set_error(error, error_len, "invalid get_version arguments");
        return -1;
    }

    sms_msg_hdr_t request;
    sms_msg_init(&request, SMS_MSG_GET_VERSION_EX_REQ, sizeof(request));

    unsigned char buffer[SMSUSB_ENDPOINT_MAX_PACKET];
    int rc = smsusb_send_and_wait(
        device,
        &request,
        sizeof(request),
        SMS_MSG_GET_VERSION_EX_RES,
        timeout_ms,
        buffer,
        sizeof(buffer),
        error,
        error_len
    );
    if (rc < 0) {
        return -1;
    }

    sms_msg_hdr_t *header = (sms_msg_hdr_t *)buffer;
    if (header->msg_type != SMS_MSG_GET_VERSION_EX_RES) {
        snprintf(error, error_len, "unexpected response type %u length %u", header->msg_type, header->msg_length);
        return -1;
    }
    if (header->msg_length < sizeof(sms_version_res_t)) {
        snprintf(error, error_len, "version response too short: %u bytes", header->msg_length);
        return -1;
    }

    memcpy(version, buffer, sizeof(*version));
    set_error(error, error_len, "");
    return 0;
}

static uint32_t read_le32(const unsigned char *p) {
    return ((uint32_t)p[0]) |
           ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) |
           ((uint32_t)p[3] << 24);
}

typedef struct sms_data_download_msg {
    sms_msg_hdr_t header;
    uint32_t mem_addr;
    unsigned char payload[SMS_MAX_PAYLOAD_SIZE];
} sms_data_download_msg_t;

typedef struct sms_msg_data3 {
    sms_msg_hdr_t header;
    uint32_t data[3];
} sms_msg_data3_t;

typedef struct sms_msg_data5 {
    sms_msg_hdr_t header;
    uint32_t data[5];
} sms_msg_data5_t;

typedef struct sms_msg_data4 {
    sms_msg_hdr_t header;
    uint32_t data[4];
} sms_msg_data4_t;

int smsusb_load_firmware(smsusb_device_t *device, const unsigned char *firmware, size_t firmware_size, char *error, unsigned long error_len) {
    if (!device || !device->handle || !firmware) {
        set_error(error, error_len, "invalid load_firmware arguments");
        return -1;
    }
    if (firmware_size < 12) {
        set_error(error, error_len, "firmware file is too small");
        return -1;
    }

    uint32_t declared_checksum = read_le32(&firmware[0]);
    uint32_t payload_length = read_le32(&firmware[4]);
    uint32_t start_address = read_le32(&firmware[8]);
    (void)declared_checksum;

    if ((size_t)payload_length > firmware_size - 12) {
        snprintf(error, error_len, "firmware payload length %u exceeds file payload %lu", payload_length, (unsigned long)(firmware_size - 12));
        return -1;
    }

    const unsigned char *payload = firmware + 12;
    uint32_t mem_address = start_address;
    size_t remaining = payload_length;

    while (remaining > 0) {
        sms_data_download_msg_t msg;
        size_t chunk = remaining > SMS_MAX_PAYLOAD_SIZE ? SMS_MAX_PAYLOAD_SIZE : remaining;
        memset(&msg, 0, sizeof(msg));
        sms_msg_init(&msg.header, SMS_MSG_DATA_DOWNLOAD_REQ, (uint16_t)(sizeof(sms_msg_hdr_t) + sizeof(uint32_t) + chunk));
        msg.mem_addr = mem_address;
        memcpy(msg.payload, payload, chunk);

        int rc = smsusb_send_and_wait(
            device,
            &msg,
            msg.header.msg_length,
            SMS_MSG_DATA_DOWNLOAD_RES,
            3000,
            NULL,
            0,
            error,
            error_len
        );
        if (rc < 0) {
            return -1;
        }

        payload += chunk;
        remaining -= chunk;
        mem_address += (uint32_t)chunk;
    }

    sms_msg_data3_t validity;
    memset(&validity, 0, sizeof(validity));
    sms_msg_init(&validity.header, SMS_MSG_DATA_VALIDITY_REQ, sizeof(validity));
    validity.data[0] = start_address;
    validity.data[1] = payload_length;
    validity.data[2] = 0;

    int rc = smsusb_send_and_wait(
        device,
        &validity,
        sizeof(validity),
        SMS_MSG_DATA_VALIDITY_RES,
        5000,
        NULL,
        0,
        error,
        error_len
    );
    if (rc < 0) {
        return -1;
    }

    sms_msg_data5_t trigger;
    memset(&trigger, 0, sizeof(trigger));
    sms_msg_init(&trigger.header, SMS_MSG_SWDOWNLOAD_TRIGGER_REQ, sizeof(trigger));
    trigger.data[0] = start_address;
    trigger.data[1] = 6;
    trigger.data[2] = 0x200;
    trigger.data[3] = 0;
    trigger.data[4] = 4;

    rc = smsusb_send_and_wait(
        device,
        &trigger,
        sizeof(trigger),
        SMS_MSG_SWDOWNLOAD_TRIGGER_RES,
        5000,
        NULL,
        0,
        error,
        error_len
    );
    if (rc < 0) {
        return -1;
    }

    set_error(error, error_len, "");
    return 0;
}

typedef struct sms_msg_data1 {
    sms_msg_hdr_t header;
    uint32_t data;
} sms_msg_data1_t;

int smsusb_init_device_mode(smsusb_device_t *device, uint32_t mode, char *error, unsigned long error_len) {
    if (!device || !device->handle) {
        set_error(error, error_len, "invalid init arguments");
        return -1;
    }

    sms_msg_data1_t init;
    memset(&init, 0, sizeof(init));
    sms_msg_init(&init.header, SMS_MSG_INIT_DEVICE_REQ, sizeof(init));
    init.data = mode;

    int rc = smsusb_send_and_wait(
        device,
        &init,
        sizeof(init),
        SMS_MSG_INIT_DEVICE_RES,
        5000,
        NULL,
        0,
        error,
        error_len
    );
    if (rc < 0) {
        return -1;
    }

    set_error(error, error_len, "");
    return 0;
}

int smsusb_init_isdbt(smsusb_device_t *device, char *error, unsigned long error_len) {
    return smsusb_init_device_mode(device, SMS_DEVICE_MODE_ISDBT, error, error_len);
}

int smsusb_tune_isdbt_segment(smsusb_device_t *device, uint32_t frequency_hz, uint32_t segment_width, char *error, unsigned long error_len) {
    if (!device || !device->handle) {
        set_error(error, error_len, "invalid tune arguments");
        return -1;
    }

    sms_msg_data4_t tune;
    memset(&tune, 0, sizeof(tune));
    sms_msg_init_ex(
        &tune.header,
        SMS_MSG_ISDBT_TUNE_REQ,
        SMS_DVBT_BDA_CONTROL_MSG_ID,
        SMS_HIF_TASK,
        sizeof(tune)
    );
    tune.data[0] = frequency_hz;
    tune.data[1] = segment_width;
    tune.data[2] = 12000000;
    tune.data[3] = 0;

    int rc = smsusb_send_and_wait(
        device,
        &tune,
        sizeof(tune),
        SMS_MSG_ISDBT_TUNE_RES,
        5000,
        NULL,
        0,
        error,
        error_len
    );
    if (rc < 0) {
        return -1;
    }

    set_error(error, error_len, "");
    return 0;
}

int smsusb_tune_isdbt(smsusb_device_t *device, uint32_t frequency_hz, char *error, unsigned long error_len) {
    return smsusb_tune_isdbt_segment(device, frequency_hz, SMS_BW_ISDBT_1SEG, error, error_len);
}

int smsusb_add_pid_filter(smsusb_device_t *device, uint32_t pid, char *error, unsigned long error_len) {
    if (!device || !device->handle) {
        set_error(error, error_len, "invalid add_pid_filter arguments");
        return -1;
    }

    sms_msg_data1_t pid_msg;
    memset(&pid_msg, 0, sizeof(pid_msg));
    sms_msg_init_ex(
        &pid_msg.header,
        SMS_MSG_ADD_PID_FILTER_REQ,
        SMS_DVBT_BDA_CONTROL_MSG_ID,
        SMS_HIF_TASK,
        sizeof(pid_msg)
    );
    pid_msg.data = pid;

    int rc = smsusb_send(
        device,
        &pid_msg,
        sizeof(pid_msg),
        error,
        error_len
    );
    if (rc < 0) {
        return -1;
    }

    set_error(error, error_len, "");
    return 0;
}

int smsusb_read_ts_packet(smsusb_device_t *device, unsigned char *buffer, size_t buffer_len, size_t *size_out, unsigned int timeout_ms, char *error, unsigned long error_len) {
    if (!device || !device->handle || !buffer || !size_out) {
        set_error(error, error_len, "invalid read_ts_packet arguments");
        return -1;
    }

    *size_out = 0;
    unsigned char message[8192];
    int transferred = 0;
    libusb_device_handle *handle = (libusb_device_handle *)device->handle;
    int rc = libusb_bulk_transfer(
        handle,
        device->info.endpoint_in,
        message,
        sizeof(message),
        &transferred,
        timeout_ms
    );
    if (rc == LIBUSB_ERROR_TIMEOUT) {
        set_error(error, error_len, "");
        return 0;
    }
    if (rc < 0) {
        set_libusb_error(error, error_len, "bulk IN failed", rc);
        return -1;
    }
    if (transferred < (int)sizeof(sms_msg_hdr_t)) {
        snprintf(error, error_len, "bulk IN short message: %d bytes", transferred);
        return -1;
    }

    sms_msg_hdr_t *header = (sms_msg_hdr_t *)message;
    if (header->msg_length > transferred) {
        snprintf(error, error_len, "message length %u exceeds transfer %d", header->msg_length, transferred);
        return -1;
    }
    if (header->msg_type != SMS_MSG_DVBT_BDA_DATA) {
        return 0;
    }

    if (header->msg_length < sizeof(sms_msg_hdr_t)) {
        set_error(error, error_len, "invalid TS message length");
        return -1;
    }

    size_t payload_len = header->msg_length - sizeof(sms_msg_hdr_t);
    if (payload_len > buffer_len) {
        snprintf(error, error_len, "TS payload %lu exceeds buffer %lu", (unsigned long)payload_len, (unsigned long)buffer_len);
        return -1;
    }

    memcpy(buffer, message + sizeof(sms_msg_hdr_t), payload_len);
    *size_out = payload_len;
    set_error(error, error_len, "");
    return 0;
}

int smsusb_read_message_header(smsusb_device_t *device, sms_msg_hdr_t *header_out, unsigned int timeout_ms, char *error, unsigned long error_len) {
    if (!device || !device->handle || !header_out) {
        set_error(error, error_len, "invalid read_message_header arguments");
        return -1;
    }

    unsigned char message[8192];
    int transferred = 0;
    libusb_device_handle *handle = (libusb_device_handle *)device->handle;
    int rc = libusb_bulk_transfer(
        handle,
        device->info.endpoint_in,
        message,
        sizeof(message),
        &transferred,
        timeout_ms
    );
    if (rc == LIBUSB_ERROR_TIMEOUT) {
        memset(header_out, 0, sizeof(*header_out));
        set_error(error, error_len, "");
        return 0;
    }
    if (rc < 0) {
        set_libusb_error(error, error_len, "bulk IN failed", rc);
        return -1;
    }
    if (transferred < (int)sizeof(sms_msg_hdr_t)) {
        snprintf(error, error_len, "bulk IN short message: %d bytes", transferred);
        return -1;
    }

    memcpy(header_out, message, sizeof(*header_out));
    set_error(error, error_len, "");
    return transferred;
}

int smsusb_get_isdbt_stats(smsusb_device_t *device, sms_isdbt_stats_summary_t *stats, char *error, unsigned long error_len) {
    if (!device || !device->handle || !stats) {
        set_error(error, error_len, "invalid stats arguments");
        return -1;
    }

    sms_msg_hdr_t request;
    sms_msg_init_ex(
        &request,
        SMS_MSG_GET_STATISTICS_REQ,
        SMS_DVBT_BDA_CONTROL_MSG_ID,
        SMS_HIF_TASK,
        sizeof(request)
    );

    unsigned char response[8192];
    int rc = smsusb_send_and_wait(
        device,
        &request,
        sizeof(request),
        SMS_MSG_GET_STATISTICS_RES,
        5000,
        response,
        sizeof(response),
        error,
        error_len
    );
    if (rc < 0) {
        return -1;
    }

    sms_msg_hdr_t *header = (sms_msg_hdr_t *)response;
    size_t offset = sizeof(sms_msg_hdr_t);
    if (header->msg_length < offset + (17 * sizeof(uint32_t))) {
        snprintf(error, error_len, "statistics response too short: %u bytes", header->msg_length);
        return -1;
    }

    uint32_t *data = (uint32_t *)(response + offset);
    memset(stats, 0, sizeof(*stats));
    stats->statistics_type = data[0];
    stats->full_size = data[1];
    stats->is_rf_locked = data[2];
    stats->is_demod_locked = data[3];
    stats->snr = (int32_t)data[5];
    stats->rssi = (int32_t)data[6];
    stats->in_band_power = (int32_t)data[7];
    stats->carrier_offset = (int32_t)data[8];
    stats->frequency = data[9];
    stats->bandwidth = data[10];
    stats->transmission_mode = data[11];
    stats->modem_state = data[12];
    stats->guard_interval = data[13];
    stats->system_type = data[14];
    stats->partial_reception = data[15];
    stats->num_layers = data[16];

    set_error(error, error_len, "");
    return 0;
}
