# Siano TV Digital

Projeto para pesquisar e desenvolver suporte macOS para o receptor de TV digital USB vendido como Infinitoo TV Digital.

Versao local: `1.6.9`.

## Estado Atual

O dispositivo local foi identificado no macOS como:

- Produto USB: `MDTV Receiver`
- USB VID:PID: `187f:0202`
- Fabricante real: `Siano Mobile Silicon`
- Modelo conhecido no Linux: `Siano Mobile Silicon Nice`
- Driver Linux de referencia: `smsusb` / `smsdvb`
- Firmware usado: `isdbt_nova_12mhz_b0_official_2010.inp` quando disponivel, com fallback para `isdbt_nova_12mhz_b0.inp`

Tambem foi detectado um `MXT USB Device` (`aaaa:8816`), que aparenta ser armazenamento/leitor USB e nao o tuner.

## Objetivo

Construir uma cadeia de suporte em macOS somente para o sistema brasileiro de TV digital:

1. Enumerar e abrir o dispositivo USB `187f:0202`.
2. Entender e reproduzir o protocolo Siano usado pelo driver Linux.
3. Carregar automaticamente o firmware ISDB-Tb.
4. Sintonizar canais fisicos brasileiros em 6 MHz: varredura padrao 1-59 e varredura estendida 1-69 para diagnostico/historico.
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
./build/siano-tv channels-br
./build/siano-tv scan-br
./build/siano-tv scan-br-extended
./build/siano-tv diag-br 23 2 captures/diag-canal-23.csv
./build/siano-tv debug-channel-br 23 5
./build/siano-tv pid-list-br 23
./build/siano-tv stream-kick-br 23 enable-ts
./build/siano-tv stats-isdbt-ex 527142857
./build/siano-tv watch-br 23 300 captures/canal-23.ts
```

O comando imprime lock/estatisticas a cada segundo, grava MPEG-TS se aparecer, e tenta abrir `ffplay` automaticamente quando receber bytes.

O dispositivo informado nao aceita antena externa. Para teste real, mova o dongle inteiro para perto de janela ou area aberta e rode `watch-br` no canal fisico mais promissor do `scan-br`.

Se `scan-br` ficar em `rf=1 demod=0`, rode `diag-br` e depois `debug-channel-br`. O `diag-br` testa offsets finos ao redor do centro do canal e variantes `1seg`, `13seg` e `3seg`, gravando CSV. O `debug-channel-br` sintoniza o canal fisico nos tres modos, registra mensagens brutas vindas do dispositivo, compara `GET_STATISTICS` e `GET_STATISTICS_EX`, e mostra se ha pacotes MPEG-TS.

O `watch-br` aplica o MTU `15792` observado no driver Linux oficial para placas ONDA/MDTV, imprime contadores USB (`non_ts` e `timeouts`) e aceita rotas de filtro PID para diagnostico: `SIANO_TV_PID_SRC=<id>` e `SIANO_TV_PID_DST=<id>`. As preparacoes experimentais `1seg-through-fullseg` e `vhf-via-vhf-input` podem ser testadas com `prepare-reception` ou ativadas no fluxo normal com `SIANO_TV_EXPERIMENTAL_PREP=1`.

Para comparar firmwares sem editar arquivos, use `SIANO_TV_FIRMWARE=/caminho/arquivo.inp`. O comando `firmware-path` mostra qual blob sera escolhido. A camada USB tambem normaliza mensagens splitadas como o driver Linux `smsusb` e limpa halt nos endpoints ao abrir o dispositivo.

Para investigar a entrega de MPEG-TS, `pid-list-br <canal>` instala os filtros padrao e consulta a lista interna reportada pelo firmware. `SIANO_TV_PID_BEFORE_TUNE=1` instala os filtros antes da sintonia para testar a ordem alternativa do pipeline.

`stream-kick-br <canal> [kicks]` testa comandos experimentais de ativacao do caminho de dados. Os kicks conhecidos sao `enable-ts`, `data-pump`, `raw-capture`, `raw-abort` e podem ser combinados por virgula. No `watch-br`, o mesmo caminho pode ser acionado com `SIANO_TV_STREAM_KICK_BEFORE_TUNE`, `SIANO_TV_STREAM_KICK_BEFORE_PID` ou `SIANO_TV_STREAM_KICK`.

## Canalizacao Brasileira

`scan-br` cobre canais fisicos 1-59 para maximizar a captura local sem varrer lixo de espectro. A leitura pratica e:

- canal 1: legado/diagnostico, centro aproximado em 47,142857 MHz;
- canais 2-6: VHF baixo, 54-88 MHz;
- canais 7-13: VHF alto, 174-216 MHz;
- canais 14-59: UHF atual, 470-746 MHz.

`scan-br-extended` vai ate o canal 69 para investigar alocacoes antigas ou situacoes excepcionais, mas nao e o caminho padrao porque acima do canal 59 a faixa de 700 MHz foi reorganizada no Brasil.

Para testar o modo alternativo observado na referencia Linux antiga:

```sh
SIANO_TV_MODE=isdbt-bda ./build/siano-tv scan-br
SIANO_TV_MODE=isdbt-bda ./build/siano-tv diag-br 23 2 captures/diag-bda-canal-23.csv
```

Tambem existe o comando direto:

```sh
./build/siano-tv init-isdbt-bda
```

## Firmware Oficial Linux Antigo

A referencia oficial Linux antiga pode trazer um firmware ISDB-T diferente do `linux-firmware` moderno. Para importar o arquivo local baixado:

```sh
./tools/import-official-linux-firmware.sh
```

Isso cria `firmware/isdbt_nova_12mhz_b0_official_2010.inp`, que passa a ser priorizado pelo CLI e pelo instalador. O blob continua fora do git.

## Instalador Grafico

Para gerar o instalador macOS `.pkg`:

```sh
./tools/build-gui-installer.sh
```

Saida esperada:

```text
dist/siano-tv-1.6.9-macos-installer.pkg
```

O instalador coloca:

- `/usr/local/bin/siano-tv`
- `/Library/Application Support/Siano TV Digital/firmware/isdbt_nova_12mhz_b0.inp`
- `/Applications/Siano TV Digital.app`

Depois de instalar, abra `Siano TV Digital.app`. A janela mostra video/estado de recepcao a esquerda e a lista de canais brasileiros mapeados a direita. Ao selecionar um canal, o app chama `siano-tv watch-br`, grava o TS em `~/Movies/SianoTV/` e inicia reproducao quando houver stream.

Tambem e possivel rodar pelo Terminal:

```sh
/usr/local/bin/siano-tv scan-br
/usr/local/bin/siano-tv channels-br
/usr/local/bin/siano-tv scan-br-extended
/usr/local/bin/siano-tv debug-channel-br 23 5
/usr/local/bin/siano-tv watch-br 23 300 ~/Movies/SianoTV/canal-23.ts
```

## Instalacao Local

```sh
./tools/install-local.sh
```

Depois:

```sh
~/.local/bin/siano-tv version
~/.local/bin/siano-tv channels-br
~/.local/bin/siano-tv scan-br
~/.local/bin/siano-tv scan-br-extended
~/.local/bin/siano-tv watch-br 23 300 captures/canal-23.ts
```

## Entrega

Este projeto entrega um driver user-space macOS baseado em `libusb`, com firmware Siano ISDB-Tb, scan brasileiro, estatisticas, captura MPEG-TS e abertura automatica via `ffplay` quando houver stream.

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
- `src/tuner-cli`: CLI para firmware, scan, diagnostico fino e captura.
- `src/tuner-cli/siano_tv.c`: CLI principal `siano-tv`.
- `apps/SianoTVPlayer`: aplicacao macOS simples para selecionar e assistir canais.

## App De Canais

O app `Siano TV Digital.app` tem duas areas:

- esquerda: exibicao do canal/estado de recepcao;
- direita: lista de canais brasileiros mapeados.

Ao selecionar um canal, o app executa `/usr/local/bin/siano-tv watch-br <canal>`, grava em `~/Movies/SianoTV/` e inicia a reproducao quando houver MPEG-TS. Enquanto `demod=0` ou `bytes=0`, ele mostra estado de espera em vez de fingir imagem.
- `firmware`: instrucoes para obter firmware; blobs binarios nao sao versionados por padrao.
