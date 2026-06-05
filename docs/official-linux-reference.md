# Referencia Linux Oficial Antiga

Fonte local analisada:

`/Users/lferrarezi/Downloads/Infinito PenTV/Mini_PENTV_USB/Linux`

## Achados Aproveitados

- O pacote inclui uma arvore `v4l-dvb-315bc4b65b4f` com driver Siano antigo.
- O firmware oficial `isdbt_nova_12mhz_b0.inp` tem SHA-256 `88203f1855b396868eb480623ef002ad4d79895d57d5b4b4f00f7bd5a6a80829`.
- Esse firmware tem tamanho diferente do firmware moderno baixado do `linux-firmware`.
- O caminho ISDB-T do driver antigo usa `MSG_SMS_ISDBT_TUNE_REQ`.
- O tune ISDB-T antigo envia:
  - `Data[0] = frequency`
  - `Data[1] = BW_ISDBT_1SEG`
  - `Data[2] = 12000000`
  - `Data[3] = 0`
- O driver antigo declara passo de sintonia de `250000 Hz`.

## Consequencias No macOS

- O CLI prioriza `firmware/isdbt_nova_12mhz_b0_official_2010.inp` quando esse arquivo existir.
- O modo `diag-br` testa `1seg`, `13seg` e `3seg`, com offsets em torno do centro do canal.
- O modo alternativo `SIANO_TV_MODE=isdbt-bda` inicializa o dispositivo com `DEVICE_MODE_ISDBT_BDA`.
- Para trocar de firmware depois que o dongle ja carregou um firmware, reinserir o dispositivo USB e rodar o teste novamente.
