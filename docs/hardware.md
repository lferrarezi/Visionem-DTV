# Hardware

## Dispositivo Principal

Captura local via `system_profiler SPUSBDataType` e `ioreg -p IOUSB -l -w 0`:

- Nome: `MDTV Receiver`
- Vendor string: `MDTV Receiver`
- Product string: `MDTV Receiver`
- Vendor ID: `0x187f` (`6271`)
- Product ID: `0x0202` (`514`)
- bcdDevice: `0x0006`
- bcdUSB: `0x0200`
- Device class: `0x00`
- Device subclass: `0x00`
- Device protocol: `0x00`
- Speed: USB 2.0 high speed
- macOS service: `IOUSBHostDevice`

Esse par VID:PID e conhecido no Linux como `Siano Mobile Silicon Nice`, tipo DVB card, suportado pelo driver `smsusb`.

## Descritores libusb

Validado localmente em 2026-06-04:

- `libusb_open`: ok
- Configuracoes: 1
- Configuracao ativa: 1
- Max power: 100 mA
- Interfaces: 1
- Interface 0:
  - Classe: `0xff`
  - Subclasse: `0xff`
  - Protocolo: `0xff`
  - Endpoints: 2
- Endpoint IN: `0x81`, bulk, max packet `512`
- Endpoint OUT: `0x02`, bulk, max packet `512`

Essa topologia bate com a expectativa de transporte proprietario: comandos e respostas trafegam por endpoints bulk, sem classe USB padrao.

## Dispositivo Secundario Observado

- Nome: `MXT USB Device`
- Vendor ID: `0xaaaa`
- Product ID: `0x8816`
- Vendor string: `MXTronics`
- Serial: `150101v01`

Registros publicos tratam esse dispositivo como armazenamento/leitor USB. Ele nao deve ser tratado como tuner na primeira fase.

## Implicacoes

O receptor usa classe vendor-specific, entao nao existe classe USB padrao para o macOS assumir. A implementacao precisa falar o protocolo Siano diretamente, ou empacotar isso em um DriverKit/USBDriverKit futuro.
