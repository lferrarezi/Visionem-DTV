# Plano De Desenvolvimento

## Fase 0 - Inventario Local

- Manter snapshots de `system_profiler` e `ioreg` em `captures/`.
- Confirmar que o dispositivo alvo e sempre `187f:0202`.
- Extrair descritores completos com uma ferramenta libusb quando a dependencia estiver instalada.

Entregavel atual: `src/probe/siano_probe.c`.

Entregavel adicional: `src/probe/siano_libusb_probe.c`, validando abertura do dispositivo e endpoints `0x81`/`0x02`.

## Fase 1 - Referencia Linux

Objetivo: validar o hardware em Linux antes de implementar o protocolo no macOS.

Passos:

1. Testar o receptor em Linux com os modulos `smsusb` e `smsdvb`.
2. Instalar firmware Siano, especialmente `isdbt_nova_12mhz_b0.inp`.
3. Confirmar criacao de `/dev/dvb/adapter0`.
4. Fazer scan ISDB-T de canais locais.
5. Capturar um MPEG-TS curto como evidencia funcional.

Se a validacao Linux falhar, o problema pode ser antena, firmware, padrao de transmissao ou revisao especifica do hardware.

## Fase 2 - Biblioteca USB macOS

Objetivo: portar a parte minima do `smsusb` para user space.

Modulos planejados:

- `smsusb_device`: abertura, claim de interface, endpoints e reset.
- `smsusb_firmware`: upload do `.inp` correto.
- `smscore_messages`: estruturas de comando/resposta Siano.
- `smsdvb_tuner`: set mode, tune, signal stats.
- `mpegts_sink`: grava arquivo, pipe stdout ou socket local.

Primeiro criterio de sucesso: abrir o USB, ler descritores e executar comandos inofensivos.

Status: abertura e leitura de descritores ja validada via libusb.

Segundo criterio: upload de firmware reconhecido pelo dispositivo.

Terceiro criterio: capturar pacotes MPEG-TS validos.

Status atual:

- `MSG_SMS_GET_VERSION_EX_REQ`: validado.
- Upload `isdbt_nova_12mhz_b0.inp`: validado, firmware passa para `DEVICE_MODE_ISDBT`.
- `MSG_SMS_INIT_DEVICE_REQ`: validado.
- `MSG_SMS_ISDBT_TUNE_REQ`: validado.
- `MSG_SMS_SIGNAL_DETECTED_IND`: observado em frequencias UHF testadas.
- `MSG_SMS_GET_STATISTICS_REQ`: validado; RF lock aparece em canais testados.
- `MSG_SMS_DVBT_BDA_DATA`: ainda nao observado; captura TS permanece com 0 bytes.

Hipoteses abertas:

- faltam comandos de configuracao de saida/demux alem de filtros PID;
- filtros PID precisam de outra ordem ou resposta para este firmware;
- frequencias testadas detectam portadora/RF lock, mas nao demod lock suficiente para TS;
- antena/sinal local insuficiente para demodular dados.

## Fase 3 - CLI

Comandos planejados:

```sh
siano-tv probe
siano-tv firmware load firmware/isdbt_nova_12mhz_b0.inp
siano-tv tune --frequency 473142857 --bandwidth 6MHz --out capture.ts
siano-tv scan --country BR --out channels.m3u
```

## Fase 4 - App macOS

Somente depois do CLI funcionar:

- app SwiftUI simples para escolher canal;
- integracao com VLC/ffplay ou player AVFoundation se o transport stream for aceito;
- logs diagnosticos exportaveis.

## DriverKit

DriverKit fica como opcao de distribuicao final, nao como primeiro passo. USBDriverKit exige entitlement de transporte USB e informacoes de VID; como o VID `0x187f` pertence a Siano, a aprovacao pode ser o maior risco do caminho.
