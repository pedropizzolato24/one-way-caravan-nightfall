# One Way Caravan: Nightfall (Roblox) — MVP

Co-op survival roguelite: dia é coleta e construção, noite é defesa contra ondas.
Design completo em [docs/OneWayCaravanNightfall_Roblox_Design_Doc_v2.md](docs/OneWayCaravanNightfall_Roblox_Design_Doc_v2.md).

## Status

**Loop núcleo do MVP (Seção 6, passos 1–6) pronto, com a base reforçada para o passo 7:**

- **Mapa real** (não é mais grey-box): terreno 480×480 via Terrain API, fechado por montanhas.
  Estrada de terra sul→norte (a rota da caravana), clareira de acampamento, canyon com passagem
  única de 10 studs (funil geográfico do doc 5.4, slot da barricada), floresta de recursos ao sul,
  lago com margem de areia, e território da ameaça ao norte (chão de lama, madeira seca com mais
  usos — risco/recompensa) onde ficam os spawns.
- **Caravana** (doc 4.5): carroça coberta parada na estrada no meio do acampamento — chassi, rodas,
  boleia, lona em arco, carga, lampião com luz, lança e junta de bois. `Root` invisível ancorado +
  todas as partes soldadas via WeldConstraint: pronta pra ser movida por CFrame/tween na travessia
  NPC-driven do passo 7. O servidor já trata a posição dela como o acampamento (alvo de fallback
  dos inimigos).
- **Loop**: ciclo dia (90s) / noite (120s) com transição de iluminação e ambiente; coleta de
  madeira/comida server-side com remotes validados e rate-limit; recursos repõem a cada amanhecer
  (suporta "ficar mais uma noite" do doc 5.4); fogueira e barricada colocáveis com preview
  fantasma no cliente e orientação pela direção do jogador; comer comida cura (+25); machado +
  inimigo com HP server-side; downed/revive por hold-button; 3 ondas por noite (3/4/5, +1 por
  noite no mesmo nó — base da escalada por permanência) com object pooling (24 instâncias criadas
  1x no boot, nunca Destroy); IA desvia pelo funil do canyon e ataca a barricada que bloquear o
  caminho; spawns lidos da pasta `EnemySpawns` do mapa; anti speed/teleport básico (doc 4.1).

Fora desta rodada (próximos passos, Seção 6): grafo de rota + travessia + votação (passo 7),
boss/fim de run (passo 8), meta-loop do lobby com ProfileStore (passo 9), playtest em device
alvo (passo 10).

## Estrutura

- `src/ServerScriptService/OneWayCaravanNightfallServer.server.lua` — toda a autoridade (HP, recursos, spawn, dano, morte, ciclo, anti-exploit).
- `src/StarterPlayer/StarterPlayerScripts/OneWayCaravanNightfallClient.client.lua` — HUD + input + preview de colocação; só envia intenção.
- `src/StarterPack/Machado/WeaponClient.client.lua` — LocalScript da Tool Machado (a Tool em si é criada pelo build script).
- `tools/build_map.lua` — reconstrói terreno, mapa, caravana, recursos, spawns, Remotes e a Tool Machado num place (Command Bar do Studio). Substitui o antigo `build_greybox.lua`.
- `default.project.json` — projeto Rojo (sincroniza os dois scripts principais).

## Setup num place novo

1. Rode `tools/build_map.lua` na Command Bar do Studio (modo Edit). É idempotente: pode rodar de novo pra reconstruir.
2. `rojo serve` + plugin Rojo para sincronizar os scripts (ou cole-os manualmente nos caminhos acima).
3. Cole `WeaponClient.client.lua` como LocalScript dentro de `StarterPack.Machado` (refazer sempre que o build script recriar a Tool).
4. Play. Dia dura 90s, noite 120s.

## Layout do mapa (referência rápida)

- Acampamento/spawn: clareira em torno de `(0, -47)`; caravana parada na estrada olhando pro norte.
- Funil: crista de canyon em `z = 30`, passagem única de 10 studs em `x = 0` (marcador verde = slot da barricada).
- Spawns de inimigos: pads vermelhos ao norte (`z ≈ 118–136`), lidos pelo servidor em `workspace.EnemySpawns`.
- Recursos: floresta ao sul (madeira, 5 usos) + arbustos (comida, 4 usos); madeira seca ao norte com 8 usos.

## Bugs conhecidos / dívidas

- Sem condição de derrota (grupo inteiro downed) — chega no passo 8.
- Estruturas podem ser colocadas sobrepondo jogadores/inimigos/outras estruturas.
- Colocação usa mouse; em touch funciona por tap, mas sem UX dedicada de mobile (passo 10).
- Inimigo ainda é MoveTo direto (sem PathfindingService); pode travar em quina fora do funil — aceito pelo doc 4.8.
