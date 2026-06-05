# Referencia Linux

O dispositivo `187f:0202` e suportado no Linux como `Siano Mobile Silicon Nice`.

## Componentes Relevantes

- Driver USB: `drivers/media/usb/siano/smsusb.c`
- Core Siano: `drivers/media/common/siano/`
- Frontend DVB: `drivers/media/usb/siano/smsdvb.c`
- Kconfig: `CONFIG_SMS_USB_DRV`

## Firmware

Arquivos observados em distribuicoes Linux:

- `dvb_nova_12mhz_b0.inp`
- `isdbt_nova_12mhz_b0.inp`

Para o Brasil, o candidato prioritario e `isdbt_nova_12mhz_b0.inp`.

## Links De Pesquisa

- https://linux-hardware.org/?id=usb%3A187f-0202
- https://cateee.net/lkddb/web-lkddb/SMS_USB_DRV.html
- https://packages.debian.org/bookworm/firmware-siano
- https://kernel.googlesource.com/pub/scm/linux/kernel/git/firmware/linux-firmware/

## Proxima Extracao Tecnica

Mapear do driver Linux:

1. Endpoints usados por `smsusb`.
2. Sequencia de probe e reset.
3. Formato das mensagens `smscore`.
4. Fluxo de upload do firmware.
5. Comandos para selecionar modo ISDB-T.
6. Comandos de tuning e leitura de estatisticas.
7. Caminho dos pacotes MPEG-TS ate o subsistema DVB.

