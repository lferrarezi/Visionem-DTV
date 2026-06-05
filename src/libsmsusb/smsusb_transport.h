#ifndef SMSUSB_TRANSPORT_H
#define SMSUSB_TRANSPORT_H

#include <stdint.h>
#include <stddef.h>

#define SMSUSB_VENDOR_ID 0x187f
#define SMSUSB_PRODUCT_ID 0x0202

#define SMSUSB_INTERFACE_NUMBER 0
#define SMSUSB_ENDPOINT_IN 0x81
#define SMSUSB_ENDPOINT_OUT 0x02
#define SMSUSB_ENDPOINT_MAX_PACKET 512
#define SMS_MSG_HDR_FLAG_SPLIT_MSG 4

typedef struct smsusb_device_info {
    uint16_t vendor_id;
    uint16_t product_id;
    uint8_t interface_number;
    uint8_t endpoint_in;
    uint8_t endpoint_out;
    uint16_t endpoint_max_packet;
} smsusb_device_info_t;

typedef struct smsusb_device {
    void *ctx;
    void *handle;
    smsusb_device_info_t info;
    int claimed;
} smsusb_device_t;

typedef struct sms_msg_hdr {
    uint16_t msg_type;
    uint8_t msg_src_id;
    uint8_t msg_dst_id;
    uint16_t msg_length;
    uint16_t msg_flags;
} sms_msg_hdr_t;

typedef struct sms_version_res {
    sms_msg_hdr_t header;
    uint16_t chip_model;
    uint8_t step;
    uint8_t metal_fix;
    uint8_t firmware_id;
    uint8_t supported_protocols;
    uint8_t version_major;
    uint8_t version_minor;
    uint8_t version_patch;
    uint8_t version_field_patch;
    uint8_t rom_ver_major;
    uint8_t rom_ver_minor;
    uint8_t rom_ver_patch;
    uint8_t rom_ver_field_patch;
    uint8_t text_label[34];
} sms_version_res_t;

typedef struct sms_isdbt_stats_summary {
    uint32_t statistics_type;
    uint32_t full_size;
    uint32_t is_rf_locked;
    uint32_t is_demod_locked;
    int32_t snr;
    int32_t rssi;
    int32_t in_band_power;
    int32_t carrier_offset;
    uint32_t frequency;
    uint32_t bandwidth;
    uint32_t transmission_mode;
    uint32_t modem_state;
    uint32_t guard_interval;
    uint32_t system_type;
    uint32_t partial_reception;
    uint32_t num_layers;
} sms_isdbt_stats_summary_t;

#define SMS_HIF_TASK 11
#define SMS_MSG_SET_MAX_TX_MSG_LEN_REQ 516
#define SMS_MSG_SET_MAX_TX_MSG_LEN_RES 517
#define SMS_MSG_GET_VERSION_EX_REQ 668
#define SMS_MSG_GET_VERSION_EX_RES 669
#define SMS_MSG_DATA_DOWNLOAD_REQ 660
#define SMS_MSG_DATA_DOWNLOAD_RES 661
#define SMS_MSG_DATA_VALIDITY_REQ 662
#define SMS_MSG_DATA_VALIDITY_RES 663
#define SMS_MSG_SWDOWNLOAD_TRIGGER_REQ 664
#define SMS_MSG_SWDOWNLOAD_TRIGGER_RES 665
#define SMS_MSG_RECEIVE_1SEG_THROUGH_FULLSEG_REQ 528
#define SMS_MSG_RECEIVE_1SEG_THROUGH_FULLSEG_RES 529
#define SMS_MSG_RECEIVE_VHF_VIA_VHF_INPUT_REQ 530
#define SMS_MSG_RECEIVE_VHF_VIA_VHF_INPUT_RES 531
#define SMS_MSG_ISDBT_TUNE_REQ 776
#define SMS_MSG_ISDBT_TUNE_RES 777
#define SMS_MSG_DVBT_BDA_DATA 693
#define SMS_MSG_DATA_MSG 699
#define SMS_MSG_RAW_CAPTURE_START_REQ 720
#define SMS_MSG_RAW_CAPTURE_START_RES 721
#define SMS_MSG_RAW_CAPTURE_ABORT_REQ 722
#define SMS_MSG_RAW_CAPTURE_ABORT_RES 723
#define SMS_MSG_RAW_CAPTURE_COMPLETE_IND 728
#define SMS_MSG_DATA_PUMP_IND 729
#define SMS_MSG_DATA_PUMP_REQ 730
#define SMS_MSG_DATA_PUMP_RES 731
#define SMS_MSG_ENABLE_TS_INTERFACE_REQ 736
#define SMS_MSG_ENABLE_TS_INTERFACE_RES 737
#define SMS_MSG_DISABLE_TS_INTERFACE_REQ 742
#define SMS_MSG_DISABLE_TS_INTERFACE_RES 743
#define SMS_MSG_INIT_DEVICE_REQ 578
#define SMS_MSG_INIT_DEVICE_RES 579
#define SMS_MSG_ADD_PID_FILTER_REQ 601
#define SMS_MSG_ADD_PID_FILTER_RES 602
#define SMS_MSG_REMOVE_PID_FILTER_REQ 603
#define SMS_MSG_REMOVE_PID_FILTER_RES 604
#define SMS_MSG_GET_PID_FILTER_LIST_REQ 608
#define SMS_MSG_GET_PID_FILTER_LIST_RES 609
#define SMS_MSG_GET_STATISTICS_REQ 615
#define SMS_MSG_GET_STATISTICS_RES 616
#define SMS_MSG_HO_PER_SLICES_IND 630
#define SMS_MSG_GET_STATISTICS_EX_REQ 653
#define SMS_MSG_GET_STATISTICS_EX_RES 654
#define SMS_MSG_TRANSMISSION_IND 782
#define SMS_MSG_INTERFACE_LOCK_IND 805
#define SMS_MSG_INTERFACE_UNLOCK_IND 806
#define SMS_MSG_SIGNAL_DETECTED_IND 827
#define SMS_MSG_NO_SIGNAL_IND 828
#define SMS_MSG_SET_PERIODIC_STATISTICS_REQ 836
#define SMS_MSG_SET_PERIODIC_STATISTICS_RES 837
#define SMS_MAX_PAYLOAD_SIZE 240
#define SMS_DVBT_BDA_CONTROL_MSG_ID 201
#define SMS_BW_ISDBT_1SEG 4
#define SMS_BW_ISDBT_3SEG 5
#define SMS_BW_ISDBT_13SEG 8
#define SMS_DEVICE_MODE_ISDBT 5
#define SMS_DEVICE_MODE_ISDBT_BDA 6

static inline smsusb_device_info_t smsusb_known_device(void) {
    smsusb_device_info_t info = {
        .vendor_id = SMSUSB_VENDOR_ID,
        .product_id = SMSUSB_PRODUCT_ID,
        .interface_number = SMSUSB_INTERFACE_NUMBER,
        .endpoint_in = SMSUSB_ENDPOINT_IN,
        .endpoint_out = SMSUSB_ENDPOINT_OUT,
        .endpoint_max_packet = SMSUSB_ENDPOINT_MAX_PACKET,
    };
    return info;
}

int smsusb_open(smsusb_device_t *device, char *error, unsigned long error_len);
int smsusb_close(smsusb_device_t *device, char *error, unsigned long error_len);
int smsusb_reset(smsusb_device_t *device, char *error, unsigned long error_len);
int smsusb_get_version(smsusb_device_t *device, sms_version_res_t *version, unsigned int timeout_ms, char *error, unsigned long error_len);
int smsusb_load_firmware(smsusb_device_t *device, const unsigned char *firmware, size_t firmware_size, char *error, unsigned long error_len);
int smsusb_init_device_mode(smsusb_device_t *device, uint32_t mode, char *error, unsigned long error_len);
int smsusb_init_isdbt(smsusb_device_t *device, char *error, unsigned long error_len);
int smsusb_set_max_tx_msg_len(smsusb_device_t *device, uint32_t length, char *error, unsigned long error_len);
int smsusb_receive_1seg_through_fullseg(smsusb_device_t *device, char *error, unsigned long error_len);
int smsusb_receive_vhf_via_vhf_input(smsusb_device_t *device, char *error, unsigned long error_len);
int smsusb_send_data1_command(smsusb_device_t *device, uint16_t request_type, uint16_t response_type, uint32_t data, unsigned int timeout_ms, char *error, unsigned long error_len);
int smsusb_send_header_command_public(smsusb_device_t *device, uint16_t request_type, uint16_t response_type, unsigned int timeout_ms, char *error, unsigned long error_len);
int smsusb_tune_isdbt(smsusb_device_t *device, uint32_t frequency_hz, char *error, unsigned long error_len);
int smsusb_tune_isdbt_segment(smsusb_device_t *device, uint32_t frequency_hz, uint32_t segment_width, char *error, unsigned long error_len);
int smsusb_add_pid_filter(smsusb_device_t *device, uint32_t pid, char *error, unsigned long error_len);
int smsusb_add_pid_filter_route(smsusb_device_t *device, uint32_t pid, uint8_t src, uint8_t dst, char *error, unsigned long error_len);
int smsusb_get_pid_filter_list(smsusb_device_t *device, uint32_t *pids, size_t max_pids, size_t *count_out, char *error, unsigned long error_len);
int smsusb_read_ts_packet(smsusb_device_t *device, unsigned char *buffer, size_t buffer_len, size_t *size_out, unsigned int timeout_ms, char *error, unsigned long error_len);
int smsusb_read_message_header(smsusb_device_t *device, sms_msg_hdr_t *header_out, unsigned int timeout_ms, char *error, unsigned long error_len);
int smsusb_read_raw_message(smsusb_device_t *device, unsigned char *buffer, size_t buffer_len, size_t *size_out, unsigned int timeout_ms, char *error, unsigned long error_len);
int smsusb_get_isdbt_stats(smsusb_device_t *device, sms_isdbt_stats_summary_t *stats, char *error, unsigned long error_len);
int smsusb_get_isdbt_stats_ex(smsusb_device_t *device, sms_isdbt_stats_summary_t *stats, char *error, unsigned long error_len);

#endif
