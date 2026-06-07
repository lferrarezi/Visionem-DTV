# Visionem DTV

Visionem DTV e um projeto experimental para recepcao de TV digital brasileira ISDB-Tb usando receptores USB baseados em Siano/MDTV.

## Estrutura

- `macOS/`: projeto atual para macOS, incluindo CLI, firmware loader, diagnosticos USB, app Visionem DTV e empacotamento `.pkg`.
- `iPadOS/`: area reservada para o novo estudo iPadOS. O suporte real depende das restricoes de acesso USB do iPadOS e deve ser tratado como projeto separado.

## macOS

O projeto macOS atual esta em `macOS/`.

Comandos principais:

```sh
cd macOS
make all
./build/siano-tv usb-state
./build/siano-tv scan-br-smart
./build/siano-tv recover-ts-br 18 60 ~/Movies/SianoTV/recover-18.ts
```

Para gerar o instalador:

```sh
cd macOS
./tools/validate-release.sh
./tools/build-gui-installer.sh
```

## iPadOS

O projeto iPadOS sera desenvolvido em `iPadOS/`. A premissa inicial e validar se o receptor USB pode ser acessado por APIs publicas do iPadOS ou se sera necessario outro desenho de arquitetura, como ponte externa, firmware intermediario ou streaming por rede.

