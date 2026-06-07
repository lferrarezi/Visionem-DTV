CC ?= clang
CFLAGS ?= -Wall -Wextra -Wpedantic -std=c11 -O2
BUILD_DIR := build
PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
DATADIR ?= $(PREFIX)/share/siano-tv
LIBUSB_PREFIX ?= $(shell brew --prefix libusb 2>/dev/null)
LIBUSB_CFLAGS := -I$(LIBUSB_PREFIX)/include/libusb-1.0
LIBUSB_LDFLAGS := -L$(LIBUSB_PREFIX)/lib -lusb-1.0
LIBUSB_STATIC := $(LIBUSB_PREFIX)/lib/libusb-1.0.a

.PHONY: all probe iokit-probe libusb-probe cli app install uninstall clean

all: probe cli app

probe: iokit-probe libusb-probe

iokit-probe: $(BUILD_DIR)/siano-probe

libusb-probe: $(BUILD_DIR)/siano-libusb-probe

cli: $(BUILD_DIR)/siano-tv

app: $(BUILD_DIR)/SianoTVPlayer

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/siano-probe: src/probe/siano_probe.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $< -o $@ -framework IOKit -framework CoreFoundation

$(BUILD_DIR)/siano-libusb-probe: src/probe/siano_libusb_probe.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LIBUSB_CFLAGS) $< -o $@ $(LIBUSB_LDFLAGS)

$(BUILD_DIR)/siano-tv: src/tuner-cli/siano_tv.c src/libsmsusb/smsusb_transport.c src/libsmsusb/smsusb_transport.h | $(BUILD_DIR)
	$(CC) $(CFLAGS) $(LIBUSB_CFLAGS) -Isrc/libsmsusb src/tuner-cli/siano_tv.c src/libsmsusb/smsusb_transport.c -o $@ $(LIBUSB_STATIC) -framework IOKit -framework CoreFoundation -framework Security

$(BUILD_DIR)/SianoTVPlayer: apps/SianoTVPlayer/Package.swift apps/SianoTVPlayer/Sources/main.swift | $(BUILD_DIR)
	cd apps/SianoTVPlayer && swift build -c release
	cp apps/SianoTVPlayer/.build/release/SianoTVPlayer $@

clean:
	rm -rf $(BUILD_DIR)

install: all
	install -d "$(BINDIR)"
	install -m 0755 "$(BUILD_DIR)/siano-tv" "$(BINDIR)/siano-tv"
	install -d "$(DATADIR)/firmware"
	if [ -f firmware/isdbt_nova_12mhz_b0.inp ]; then install -m 0644 firmware/isdbt_nova_12mhz_b0.inp "$(DATADIR)/firmware/isdbt_nova_12mhz_b0.inp"; fi

uninstall:
	rm -f "$(BINDIR)/siano-tv"
	rm -rf "$(DATADIR)"
