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
./build/siano-tv firmware-path
./build/siano-tv firmware-load firmware/isdbt_nova_12mhz_b0.inp
./build/siano-tv prepare-reception
./build/siano-tv tune-isdbt 473142857
./build/siano-tv capture-isdbt 473142857 10 capture.ts
./build/siano-tv scan-isdbt
./build/siano-tv channels-br
./build/siano-tv channels-br-extended
./build/siano-tv scan-br
./build/siano-tv scan-br-extended
./build/siano-tv diag-br 23 2 captures/diag-canal-23.csv
./build/siano-tv debug-channel-br 23 5
./build/siano-tv pid-list-br 23
./build/siano-tv stream-kick-br 23 enable-ts
./build/siano-tv stats-isdbt-ex 527142857
SIANO_TV_MODE=isdbt-bda ./build/siano-tv scan-br
./build/siano-tv watch-isdbt 527142857 120 captures/watch.ts
```

O comando abre `187f:0202`, faz claim da interface `0` e libera a interface sem enviar comandos ao hardware.

`version` envia `MSG_SMS_GET_VERSION_EX_REQ` e espera `MSG_SMS_GET_VERSION_EX_RES`.

`firmware-load` envia chunks `MSG_SMS_DATA_DOWNLOAD_REQ`, valida com `MSG_SMS_DATA_VALIDITY_REQ` e dispara `MSG_SMS_SWDOWNLOAD_TRIGGER_REQ`.

`tune-isdbt` envia `MSG_SMS_ISDBT_TUNE_REQ` para uma frequencia em Hz.

`capture-isdbt` sintoniza e grava payloads `MSG_SMS_DVBT_BDA_DATA` em MPEG-TS bruto.

No firmware oficial ISDB-Tb deste receptor, o fluxo TS tambem pode chegar como `MSG_SMS_DAB_CHANNEL` (`607`) com payload alinhado em pacotes de 188 bytes. `watch-br` e `dump-ts` tratam esse tipo como TS.

`scan-br` cobre a canalizacao brasileira padrao 1-59. `scan-br-extended` cobre 1-69 para investigacao historica ou diagnostica.

`diag-br` testa offsets finos e modos `1seg`, `13seg` e `3seg`, gravando CSV para comparar combinacoes.

`debug-channel-br` faz uma leitura fina por canal brasileiro: testa `1seg`, `13seg` e `3seg`, imprime cada mensagem recebida do firmware, resume contagem por tipo, compara estatistica normal e expandida, e indica se algum payload MPEG-TS apareceu.

`watch-br` configura MTU `15792`, imprime contadores de mensagens brutas e aceita `SIANO_TV_PID_SRC` / `SIANO_TV_PID_DST` para testar rotas alternativas de filtro PID.

`pid-list-br` instala os filtros PID usados pelo `watch-br` e consulta `MSG_SMS_GET_PID_FILTER_LIST_REQ` para verificar se o firmware registrou os filtros.

`stream-kick-br` testa comandos experimentais de ativacao de dados (`enable-ts`, `data-pump`, `raw-capture`, `raw-abort`). Tambem aceita kicks genericos `data:req:res:value` e `header:req:res` para testar mensagens Siano sem recompilar. `watch-br` aceita `SIANO_TV_STREAM_KICK_BEFORE_TUNE=<lista>`, `SIANO_TV_STREAM_KICK_BEFORE_PID=<lista>` e `SIANO_TV_STREAM_KICK=<lista>` para executar os mesmos kicks antes do tune, antes dos filtros PID ou antes de aguardar TS. `SIANO_TV_CTRL_SRC` e `SIANO_TV_CTRL_DST` permitem variar a rota dos comandos de controle.

`usb-reset` aciona reset USB via libusb. Em alguns hubs o MDTV Receiver sai do barramento e precisa ser reinserido fisicamente para reenumerar.

`dump-ts <seconds> <out.ts>` nao envia comandos de controle; ele apenas despeja payloads TS ja presentes no bulk IN. E util quando o firmware ja iniciou streaming e comandos OUT passam a dar timeout. Alem de mensagens Siano com header, o transporte aceita transferencias MPEG-TS cruas quando o bulk IN comeca diretamente em sync byte `0x47`.

`SIANO_TV_FIRMWARE=/caminho/firmware.inp` força um firmware ISDB-T especifico. A leitura USB normaliza mensagens splitadas conforme a estrategia do driver Linux `smsusb`.

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
