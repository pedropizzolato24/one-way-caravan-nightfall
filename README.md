# One Way Caravan: Nightfall (Roblox) — MVP

Co-op survival roguelite: dia é coleta e construção, noite é defesa contra ondas, a caravana é a
"base que anda" cruzando uma rota de POIs até o boss.
Design completo em [docs/OneWayCaravanNightfall_Roblox_Design_Doc_v2.md](docs/OneWayCaravanNightfall_Roblox_Design_Doc_v2.md).

## Status

**Passos 1–9 da ordem de build (Seção 6) implementados.**

Passo 9 (meta-loop: lobby, persistência, 1 unlock lateral):

- **Lobby "Posto de Partida"**: entre runs, o grupo volta pra uma zona segura com a caravana
  parada, catálogo (painel na direita da tela) e um poste "Iniciar expedição" (segurar E) que
  dispara a próxima run. *Decisão de implementação:* o doc 4.2 pede 2 places com TeleportService,
  mas teleporte entre places só funciona publicado — o lobby entra como zona/estado no mesmo place,
  com perfil e catálogo já isolados em módulo pra separação física virar só troca de transporte.
- **Persistência** (`ProfileManager`, doc 4.4): schema completo do doc, session-locking leve via
  UpdateAsync, autosave, release no BindToClose, e modo memória automático no Studio sem API.
  Interface estável pra trocar por ProfileStore (loleris) depois sem mexer no resto. A moeda vira
  perfil **só no fim da run** (vitória = total; derrota = checkpoint), como o doc 4.4 manda.
- **Catálogo com 1 unlock lateral** (doc 3.1/5.2): **Barricada Reforçada** — 400 HP com faixas de
  metal, custo 16 madeira (sidegrade: aguenta mais, drena mais), preço 40 de moeda de perfil.
  Compra validada no servidor (só no lobby, só com saldo, sem duplicar), replicada por atributo
  `Unlock_*`, e o botão de construção aparece nas runs seguintes. **Isso fecha o ciclo completo
  pela primeira vez**: coleta → defesa → rota → boss → moeda → perfil → unlock → próxima run.

**Revisão de gameplay (decisão do jogo, sobrepõe o doc 4.5 etapa 3):** ao chegar num novo POI, a
noite NÃO cai mais imediatamente — a chegada abre um **dia de preparação** (coleta e construção)
antes da primeira noite ali, inclusive no Covil antes do boss.

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
  (dá pra coletar no caminho) → fade → próximo POI: a caravana entra pelo sul e anda até o
  acampamento (a chegada abre um dia de preparação — ver revisão de gameplay acima). Jogadores
  nunca sobem nela; 2 trocas de zona por dia de viagem, com teleporte do grupo pra perto da caravana.
- **Votação de avanço/permanência** (doc 5.4): ao fim de cada noite, UI de voto (20s) com
  "Ficar mais uma noite" + uma opção de avanço por filho do nó (fork = escolha segura vs
  arriscada). Maioria simples; empate → voto do host (primeiro a entrar); host ausente/sem votos →
  default avançar. **Escalada por permanência**: cada noite extra no mesmo POI soma +1 inimigo por
  onda (reseta ao avançar), separada do custo estático por tipo de POI.

Base dos passos 1–6 (rodada anterior): ciclo dia/noite com transição de iluminação, coleta
server-side validada com rate-limit, recursos repõem por amanhecer, fogueira/barricada com preview
fantasma e orientação pelo jogador, comida cura, machado + inimigos com HP server-side e object
pooling (24 instâncias), downed/revive hold-button, IA com desvio pelo funil, anti speed/teleport.

Próximo passo (Seção 6): playtest no device alvo (Chromebook/mobile) pra fechar densidade de POI,
cap de inimigos, taxas e ritmo (passo 10). Depois, Seção 3.2 (expansão: Carpinteiro primeiro).

## Estrutura

- `src/ServerScriptService/OneWayCaravanNightfallServer.server.lua` — autoridade total (HP, recursos, spawn, dano, morte, rota, votação, travessia, anti-exploit).
- `src/ServerScriptService/ZoneBuilder.lua` — ModuleScript: constrói zonas em runtime (terreno + props + recursos + spawns), a caravana e o movimento dela.
- `src/ServerScriptService/RouteGraph.lua` — ModuleScript: grafo DAG da run (3 nós + boss, fork segura/arriscada).
- `src/ServerScriptService/ProfileManager.lua` — ModuleScript: persistência de perfil (doc 4.4) com session-locking; interface pronta pra trocar por ProfileStore.
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

## Fluxo do jogo (MVP)

1. **Lobby (Posto de Partida)**: catálogo lateral no painel à direita (moeda do perfil); qualquer
   um segura o poste "Iniciar expedição" pra partir.
2. Dia 1 na Estação (90s) → Noite 1 (3 ondas) → votação. Noite sobrevivida = +10 de moeda de run.
3. Ficar = mais um dia/noite no mesmo POI com +1 inimigo/onda por noite extra (moeda não sobe).
4. Avançar = manhã de 40s → caravana parte → travessia → chegada no próximo POI → **dia de
   preparação** → noite.
5. No fork, a votação oferece Planície (segura) ou Mina (arriscada, +1 de dificuldade à noite).
6. Estação → fork → Acampamento Dizimado → Covil: dia de preparação e o boss sai do covil pelo funil.
7. Boss morto = +20, checkpoint e vitória. Grupo inteiro caído = derrota (credita só o checkpoint).
   No fim, a moeda garantida vira moeda de perfil de cada jogador e o grupo volta ao lobby.

## Layout de POI (referência rápida)

- Acampamento/spawn: clareira em torno de `(0, -47)`; a caravana para ali e ela É o acampamento.
- Funil: crista de canyon em `z = 30`, passagem única de 10 studs em `x = 0` (marcador verde = slot da barricada).
- Spawns de inimigos: pads vermelhos ao norte (`z ≈ 118–136`), lidos em `workspace.EnemySpawns`.
- Recursos: madeira ao sul (5 usos), madeira seca ao norte (8 usos, lado da horda), arbustos (4 usos), caixas de suprimento (2 usos, comida).

## Bugs conhecidos / dívidas

- Persistência no Studio exige "Enable Studio Access to API Services" (Game Settings → Security)
  e place publicado; sem isso o ProfileManager roda em modo memória (avisa no Output).
- Split físico em 2 places (lobby + run, TeleportService com reserved server, doc 4.2) pendente de
  publish; o lobby hoje é uma zona no mesmo place. ProfileManager caseiro — trocar a implementação
  interna pelo ProfileStore oficial (loleris) quando importar o módulo (interface já compatível).
- Estruturas podem sobrepor jogadores/inimigos; caravana atravessa estruturas construídas fora da estrada durante a partida.
- Colocação usa mouse; em touch funciona por tap, mas sem UX dedicada de mobile (passo 10).
- Inimigo é MoveTo direto (sem PathfindingService); pode travar em quina fora do funil — aceito pelo doc 4.8.
- Troca de zona usa fade + teleporte (loading “duro”); doc 4.5 marca isso como detalhe de build, revisar no passo 10.
