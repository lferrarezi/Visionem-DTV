# USB TV Digital Driver

Projeto para pesquisar e desenvolver suporte macOS para o receptor de TV digital USB vendido como Infinitoo TV Digital.

Versao local: `1.0.0`.

## Estado Atual

O dispositivo local foi identificado no macOS como:

- Produto USB: `MDTV Receiver`
- USB VID:PID: `187f:0202`
- Fabricante real: `Siano Mobile Silicon`
- Modelo conhecido no Linux: `Siano Mobile Silicon Nice`
- Driver Linux de referencia: `smsusb` / `smsdvb`
- Firmware provavel: `isdbt_nova_12mhz_b0.inp` para ISDB-T e `dvb_nova_12mhz_b0.inp` para DVB-T

Tambem foi detectado um `MXT USB Device` (`aaaa:8816`), que aparenta ser armazenamento/leitor USB e nao o tuner.

## Objetivo

Construir uma cadeia de suporte em macOS para:

1. Enumerar e abrir o dispositivo USB `187f:0202`.
2. Entender e reproduzir o protocolo Siano usado pelo driver Linux.
3. Carregar firmware adequado.
4. Sintonizar frequencias ISDB-T brasileiras.
5. Capturar o fluxo MPEG-TS para arquivo, stdout ou player externo.

## Primeiros Comandos

```sh
make probe
./build/siano-probe
./build/siano-libusb-probe
./build/siano-tv probe
```

Para salvar um snapshot do USB local:

```sh
./tools/capture-usb-descriptors.sh
```

Para executar o teste pratico de recepcao com tentativa de imagem:

```sh
./tools/reception-test.sh
```

Esse script carrega firmware, varre canais, tenta capturar MPEG-TS e abre `ffplay` quando houver dados.

Para um teste manual em tempo real enquanto ajusta a antena:

```sh
./build/siano-tv watch-isdbt 527142857 120 captures/watch.ts
```

O comando imprime lock/estatisticas a cada segundo, grava MPEG-TS se aparecer, e tenta abrir `ffplay` automaticamente quando receber bytes.

## Instalacao Local

```sh
./tools/install-local.sh
```

Depois:

```sh
~/.local/bin/siano-tv version
~/.local/bin/siano-tv scan-isdbt
~/.local/bin/siano-tv watch-isdbt 527142857 120 captures/watch.ts
```

## Entrega

Este projeto entrega um driver user-space macOS baseado em `libusb`, com firmware Siano, scan ISDB-T, estatisticas, captura MPEG-TS e abertura automatica via `ffplay` quando houver stream.

Nao e um DriverKit assinado pela Apple. Um DriverKit USB final exigiria entitlement da Apple para o vendor ID `0x187f`, que pertence a Siano.

## Estado De Recepcao Local

Validado neste Mac:

- USB abre e faz claim da interface.
- Firmware ISDB-T carrega.
- Init ISDB-T e tune sao aceitos.
- Estatisticas mostram `rf locked: 1` em frequencias testadas.
- O ambiente atual ainda mostra `demod locked: 0`, portanto nao ha MPEG-TS/imagem ate melhorar sinal, antena ou completar configuracao de demod.

## Estrutura

- `docs/hardware.md`: identificacao local e referencias.
- `docs/development-plan.md`: plano tecnico por fases.
- `src/probe`: probe nativo macOS baseado em IOKit.
- `src/probe/siano_libusb_probe.c`: probe libusb para descritores, interfaces e endpoints.
- `src/libsmsusb`: futura biblioteca de protocolo Siano.
- `src/tuner-cli`: futuro CLI para firmware, scan e captura.
- `src/tuner-cli/siano_tv.c`: CLI inicial com comando `probe`.
- `firmware`: instrucoes para obter firmware; blobs binarios nao sao versionados por padrao.
