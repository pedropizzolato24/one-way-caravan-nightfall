# One Way Caravan: Nightfall (Roblox) — MVP

Co-op survival roguelite: dia é coleta e construção, noite é defesa contra ondas, a caravana é a
"base que anda" cruzando uma rota de POIs até o boss.
Design completo em [docs/OneWayCaravanNightfall_Roblox_Design_Doc_v2.md](docs/OneWayCaravanNightfall_Roblox_Design_Doc_v2.md).

## Status

**Passos 1–8 da ordem de build (Seção 6) implementados.**

Passo 8 (boss, checkpoint, vitória/derrota, moeda):

- **Boss no Covil**: chegar ao nó do boss inicia a luta — a criatura (600 HP, dano 25, quebra
  barricada rápido) sai do covil e vem pelo funil, com reforços do pool a cada 40s. Barra de HP
  do boss no HUD. Stats de combate por inimigo agora vivem em atributos do rig (base pra variar
  inimigos depois).
- **Vitória/derrota** (doc 5.4/5.8): matar o boss = vitória; grupo inteiro caído (todos downed ou
  mortos) = derrota, verificada a cada queda/morte/saída de jogador e interrompendo qualquer fase.
- **Economia de run** (doc 5.8, valores de exemplo do doc): noite sobrevivida = +10 pro grupo
  (fixo no valor-base do POI, noites extras não pagam mais); boss = +20 e **checkpoint** (salva a
  moeda acumulada). Vitória consolida o total; derrota consolida o que estava salvo no último
  checkpoint. HUD mostra `Moeda | Salva`. A moeda é estado volátil do servidor da run (doc 4.4) —
  virar perfil persistente (ProfileStore) é o passo 9.
- **Tela de fim de run** com resumo (noites, moeda, garantido) e **reinício automático** da run
  15s depois (grafo novo, zona 1 reconstruída, jogadores respawnados) — no jogo real isso vira
  volta pro lobby no passo 9.

Passo 7 (grafo de rota + travessia + votação):

- **Zonas em runtime**: o mapa não é mais um build único — o servidor constrói cada zona via
  `ZoneBuilder` (terreno 480×480, estrada sul→norte, canyon-funil com passagem de 10 studs,
  acampamento, floresta ao sul, território da ameaça ao norte). Tipos de POI do MVP (doc 3.1):
  **Estação Abandonada** (plataforma, trilhos, caixas de suprimento), **Planície Aberta** (rota
  segura, vazia, com lago), **Mina Desmoronada** (rota arriscada: madeira farta, comida escassa,
  noite +1 de dificuldade), **Acampamento Dizimado** (tendas queimadas, caixas de loot) e o
  **Covil** (nó do boss — o boss em si é o passo 8).
- **Grafo de rota** (`RouteGraph`, doc 4.6): estação → fork **segura** (planície) vs **arriscada**
  (mina) → acampamento dizimado → covil. Forma fixa no MVP; `generate()` é a costura pro
  embaralhamento de tipos por run.
- **Travessia NPC-driven em 3 etapas** (doc 4.5): manhã no POI atual (40s de coleta) → caravana
  parte sozinha em velocidade fixa pela passagem norte (estruturas na estrada são desmontadas) →
  fade → corredor de travessia isolado com a caravana andando em linha reta e jogadores ao redor
  (dá pra coletar no caminho) → fade → próximo POI: a caravana entra pelo sul, anda até o
  acampamento e **a noite cai quando ela para**. Jogadores nunca sobem nela; 2 trocas de zona por
  dia de viagem, com teleporte do grupo pra perto da caravana.
- **Votação de avanço/permanência** (doc 5.4): ao fim de cada noite, UI de voto (20s) com
  "Ficar mais uma noite" + uma opção de avanço por filho do nó (fork = escolha segura vs
  arriscada). Maioria simples; empate → voto do host (primeiro a entrar); host ausente/sem votos →
  default avançar. **Escalada por permanência**: cada noite extra no mesmo POI soma +1 inimigo por
  onda (reseta ao avançar), separada do custo estático por tipo de POI.

Base dos passos 1–6 (rodada anterior): ciclo dia/noite com transição de iluminação, coleta
server-side validada com rate-limit, recursos repõem por amanhecer, fogueira/barricada com preview
fantasma e orientação pelo jogador, comida cura, machado + inimigos com HP server-side e object
pooling (24 instâncias), downed/revive hold-button, IA com desvio pelo funil, anti speed/teleport.

Próximos passos (Seção 6): meta-loop do lobby com ProfileStore e catálogo de 1 unlock lateral
(passo 9), playtest em device alvo pra fechar densidade/caps/taxas (passo 10).

## Estrutura

- `src/ServerScriptService/OneWayCaravanNightfallServer.server.lua` — autoridade total (HP, recursos, spawn, dano, morte, rota, votação, travessia, anti-exploit).
- `src/ServerScriptService/ZoneBuilder.lua` — ModuleScript: constrói zonas em runtime (terreno + props + recursos + spawns), a caravana e o movimento dela.
- `src/ServerScriptService/RouteGraph.lua` — ModuleScript: grafo DAG da run (3 nós + boss, fork segura/arriscada).
- `src/StarterPlayer/StarterPlayerScripts/OneWayCaravanNightfallClient.client.lua` — HUD, votação, fade de zona, preview de colocação; só envia intenção.
- `src/StarterPack/Machado/WeaponClient.client.lua` — LocalScript da Tool Machado.
- `tools/setup_place.lua` — setup 1x na Command Bar: limpa builds antigos e cria a Tool Machado. O mapa é construído em runtime pelo servidor.
- `default.project.json` — projeto Rojo.

## Setup num place novo

1. `rojo serve` + plugin Rojo para sincronizar os scripts.
2. Rode `tools/setup_place.lua` na Command Bar do Studio (modo Edit) — limpa o place e cria o Machado.
3. Cole `WeaponClient.client.lua` como LocalScript dentro de `StarterPack.Machado`.
4. Play. O servidor constrói a primeira zona (estação) e a caravana sozinho.

Preview de zona no modo Edit (opcional, com Rojo conectado):
`require(game.ServerScriptService.ZoneBuilder).preview("mina")` na Command Bar.

## Fluxo de uma run (MVP)

1. Dia 1 na Estação (90s) → Noite 1 (3 ondas) → votação. Noite sobrevivida = +10 de moeda.
2. Ficar = mais um dia/noite no mesmo POI com +1 inimigo/onda por noite extra (moeda não sobe).
3. Avançar = manhã de 40s → caravana parte → travessia → chegada no próximo POI → noite na chegada.
4. No fork, a votação oferece Planície (segura) ou Mina (arriscada, +1 de dificuldade à noite).
5. Estação → fork → Acampamento Dizimado → Covil: o boss sai do covil pelo funil.
6. Boss morto = +20, checkpoint e vitória (moeda total). Grupo inteiro caído a qualquer momento =
   derrota (fica só a moeda do checkpoint). Tela de resumo e nova run em 15s.

## Layout de POI (referência rápida)

- Acampamento/spawn: clareira em torno de `(0, -47)`; a caravana para ali e ela É o acampamento.
- Funil: crista de canyon em `z = 30`, passagem única de 10 studs em `x = 0` (marcador verde = slot da barricada).
- Spawns de inimigos: pads vermelhos ao norte (`z ≈ 118–136`), lidos em `workspace.EnemySpawns`.
- Recursos: madeira ao sul (5 usos), madeira seca ao norte (8 usos, lado da horda), arbustos (4 usos), caixas de suprimento (2 usos, comida).

## Bugs conhecidos / dívidas

- Moeda ainda não persiste entre servidores (ProfileStore no passo 9); no fim da run ela é só exibida.
- Estruturas podem sobrepor jogadores/inimigos; caravana atravessa estruturas construídas fora da estrada durante a partida.
- Colocação usa mouse; em touch funciona por tap, mas sem UX dedicada de mobile (passo 10).
- Inimigo é MoveTo direto (sem PathfindingService); pode travar em quina fora do funil — aceito pelo doc 4.8.
- Troca de zona usa fade + teleporte (loading “duro”); doc 4.5 marca isso como detalhe de build, revisar no passo 10.
