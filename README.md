# One Way Caravan: Nightfall (Roblox) — MVP

Co-op survival roguelite: dia é coleta e construção, noite é defesa contra ondas.
Design completo em [docs/OneWayCaravanNightfall_Roblox_Design_Doc_v2.md](docs/OneWayCaravanNightfall_Roblox_Design_Doc_v2.md).

## Status

**Loop núcleo do MVP pronto e verificado em play mode** (Seção 6 do doc, passos 1–6):
ciclo dia/noite automático, coleta de madeira/comida server-side com remotes validados e
rate-limit, fogueira e barricada colocáveis, machado + inimigo com HP server-side,
downed/revive por hold-button, 3 ondas por noite (3/4/5) com object pooling
(12 instâncias criadas 1x no boot, nunca Destroy), barricada + funil geográfico
controlando a rota da horda. Verificado: 6+ ciclos sem erro de console; bloqueio
(inimigos pinados em z=32 com barricada intacta) e passagem (z=−18 pós-destruição)
comprovados por amostragem posicional.

Fora desta rodada (próximos passos, Seção 6): grafo de rota (passo 7), boss/fim de run
(passo 8), meta-loop do lobby com ProfileStore (passo 9), playtest em device alvo (passo 10).

## Estrutura

- `src/ServerScriptService/OneWayCaravanNightfallServer.server.lua` — toda a autoridade (HP, recursos, spawn, dano, morte, ciclo).
- `src/StarterPlayer/StarterPlayerScripts/OneWayCaravanNightfallClient.client.lua` — HUD + input; só envia intenção.
- `src/StarterPack/Machado/WeaponClient.client.lua` — LocalScript da Tool Machado (a Tool em si é criada pelo build script).
- `tools/build_greybox.lua` — reconstrói o mapa grey-box, pastas, Remotes e a Tool Machado num place vazio (Command Bar do Studio).
- `default.project.json` — projeto Rojo (sincroniza os dois scripts principais).

## Setup num place novo

1. Rode `tools/build_greybox.lua` na Command Bar do Studio (modo Edit).
2. `rojo serve` + plugin Rojo para sincronizar os scripts (ou cole-os manualmente nos caminhos acima).
3. Cole `WeaponClient.client.lua` como LocalScript dentro de `StarterPack.Machado`.
4. Play. Dia dura 60s, noite 100s.

## Bugs conhecidos

- Regen nativo do Humanoid recupera HP de jogador downed sem limpar o estado.
- Coleta/colocação não checam estado Downed.
- Barricada sempre orientada no eixo X.
- Sem sanity-check global anti-teleport (doc 4.1 pede já no MVP).
