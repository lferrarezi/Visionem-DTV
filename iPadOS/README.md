# Visionem DTV para iPadOS

Area de desenvolvimento para uma versao iPadOS do Visionem DTV.

## Objetivo

Investigar e prototipar uma experiencia para assistir TV digital brasileira ISDB-Tb no iPad usando o receptor USB conectado via adaptador USB-C.

## Estado atual

Projeto em fase inicial. O iPadOS tem restricoes importantes para acesso direto a dispositivos USB genericos. Antes de portar a interface, o primeiro marco e validar se o receptor aparece para o app por APIs publicas e se ha permissao para comunicacao de baixo nivel suficiente para carregar firmware, sintonizar e receber MPEG-TS.

## Proximos marcos

1. Criar um app minimo iPadOS para inventario USB/acessorios disponiveis.
2. Validar se o receptor e exposto por External Accessory, DriverKit ou outra API publica.
3. Definir se a recepcao sera nativa no iPad ou via ponte externa.
4. Reaproveitar a experiencia visual do Visionem DTV macOS quando a rota tecnica estiver comprovada.

