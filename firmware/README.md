# Firmware

Nao commitar blobs binarios de firmware sem verificar licenca.

Arquivos relevantes para pesquisar/testar:

- `isdbt_nova_12mhz_b0.inp`: candidato para ISDB-T.
- `dvb_nova_12mhz_b0.inp`: candidato para DVB-T.

Pacotes Linux conhecidos:

- Debian/Ubuntu: `firmware-siano`
- linux-firmware: contem firmwares Siano historicos

O primeiro teste funcional deve registrar qual firmware foi aceito pelo dispositivo.

Para baixar candidatos conhecidos:

```sh
./tools/fetch-siano-firmware.sh
```

Os arquivos `.inp` ficam ignorados pelo git ate a licenca/distribuicao ser decidida.

## Hashes Da Captura Local

Baixados em 2026-06-04:

- `isdbt_nova_12mhz_b0.inp`: `36cec2ad7b2ac2ce07114b21ad0005dafe8d07e6458cfdb46e857d9ff17c2a15`
- `dvb_nova_12mhz_b0.inp`: `e089379063865bd199b87013474f6697409748b9a8725bb661b5611a9bb759c9`
