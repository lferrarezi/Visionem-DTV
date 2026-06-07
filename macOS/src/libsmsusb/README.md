# libsmsusb

Futura biblioteca de protocolo Siano.

Ordem sugerida:

1. Portar constantes e formatos de mensagem do driver Linux.
2. Implementar transporte USB user-space.
3. Implementar upload de firmware.
4. Implementar tuning ISDB-T.
5. Expor stream MPEG-TS para consumidores.

## Topologia USB Validada

- VID:PID: `187f:0202`
- Interface: `0`
- Endpoint IN: `0x81`, bulk
- Endpoint OUT: `0x02`, bulk
- Max packet: `512`

Esses valores estao codificados inicialmente em `smsusb_transport.h`.
