# Siano TV Digital CLI

CLI para operar o receptor Siano/Infinitoo TV Digital em macOS user-space.

Comandos esperados:

- `probe`
- `firmware load`
- `tune`
- `scan`
- `capture`
- `watch`

## Implementado

```sh
./build/siano-tv probe
./build/siano-tv version
./build/siano-tv firmware-load firmware/isdbt_nova_12mhz_b0.inp
./build/siano-tv tune-isdbt 473142857
./build/siano-tv capture-isdbt 473142857 10 capture.ts
./build/siano-tv scan-isdbt
./build/siano-tv channels-br
./build/siano-tv channels-br-extended
./build/siano-tv scan-br
./build/siano-tv scan-br-extended
./build/siano-tv diag-br 23 2 captures/diag-canal-23.csv
SIANO_TV_MODE=isdbt-bda ./build/siano-tv scan-br
./build/siano-tv watch-isdbt 527142857 120 captures/watch.ts
```

O comando abre `187f:0202`, faz claim da interface `0` e libera a interface sem enviar comandos ao hardware.

`version` envia `MSG_SMS_GET_VERSION_EX_REQ` e espera `MSG_SMS_GET_VERSION_EX_RES`.

`firmware-load` envia chunks `MSG_SMS_DATA_DOWNLOAD_REQ`, valida com `MSG_SMS_DATA_VALIDITY_REQ` e dispara `MSG_SMS_SWDOWNLOAD_TRIGGER_REQ`.

`tune-isdbt` envia `MSG_SMS_ISDBT_TUNE_REQ` para uma frequencia em Hz.

`capture-isdbt` sintoniza e grava payloads `MSG_SMS_DVBT_BDA_DATA` em MPEG-TS bruto.

`scan-br` cobre a canalizacao brasileira padrao 1-59. `scan-br-extended` cobre 1-69 para investigacao historica ou diagnostica.

`diag-br` testa offsets finos e modos `1seg`, `13seg` e `3seg`, gravando CSV para comparar combinacoes.

Estado validado no Mac local:

- `version`: ok, ROM `firmware_id=255` antes do firmware.
- `firmware-load`: ok com `isdbt_nova_12mhz_b0.inp`.
- `version`: ok, `firmware_id=5` apos firmware ISDB-T.
- `init-isdbt`: ok.
- `tune-isdbt`: ok.
- `debug-read`: observa `MSG_SMS_SIGNAL_DETECTED_IND`.
- `stats-isdbt`: observa `rf locked: 1` em canais testados.
- `watch-isdbt`: imprime telemetria por segundo e abre `ffplay` se houver TS.
- `capture-isdbt`: ainda gera 0 bytes no ambiente atual porque `demod locked` permanece `0`.
