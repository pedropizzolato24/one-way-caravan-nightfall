# One Way Caravan: Nightfall (Roblox) — MVP

Co-op survival roguelite: dia é coleta e construção, noite é defesa contra ondas, a caravana é a
"base que anda" cruzando uma rota de POIs até o boss.
Design completo em [docs/OneWayCaravanNightfall_Roblox_Design_Doc_v2.md](docs/OneWayCaravanNightfall_Roblox_Design_Doc_v2.md).

## Status

**Passos 1–9 da ordem de build (Seção 6) implementados, com o modelo de caravana e travessia
reconstruído para a Revisão 3 do doc (seções 4.5/4.6/5.4).**

### Caravana e travessia (Revisão 3 — reconstrução)

A caravana **não é mais NPC-driven** e o mundo **não é mais dividido em zonas isoladas com
teleporte/fade**. O que mudou:

- **Caravana pilotada de verdade** (doc 4.5): um `VehicleSeat` na boleia controla throttle/steer;
  3 `Seat` comuns de passageiro. O rig é um assembly único soldado num `Root` central por
  `WeldConstraint` (técnica do Dead Rails), com rodas em `HingeConstraint` — **tração** por Motor
  nos hinges traseiros e **esterço** por servo nas mangas dianteiras. O motorista sentado recebe
  network ownership da caravana; passageiros ficam welded ao mesmo assembly (é o que elimina o
  jitter de quem não dirige). *Desvio documentado do doc 4.5:* o empuxo por `PrismaticConstraint`
  do Dead Rails pressupõe trilho reto ancorado; com pilotagem livre um prismatic interno não gera
  força líquida, então a tração vai nos hinges das rodas (padrão nativo de veículo do Roblox).
- **Mundo contínuo via StreamingEnabled** (doc 4.5/4.6): a run inteira é um único espaço; todos os
  POIs e corredores coexistem e o streaming carrega/descarrega por distância. Não há fade nem
  teleporte entre POIs — o grupo **dirige** de um ao outro. A única transição de tela que resta é a
  fronteira lobby↔run (placeholder do TeleportService de 2 places, doc 4.2).
- **Fork por escolha física + "sem volta"** (doc 4.5/4.6): no braço de cada ramo do fork há um
  volume de commit; ao a caravana cruzá-lo, o servidor **destrói a geometria do ramo não escolhido**
  (chão vira Air). Sem chão pra voltar, o "sem volta" se cumpre pela geometria.
- **Noite por chegada + dia de preparação** (doc 4.5/5.4): um volume de chegada no acampamento do
  POI detecta a caravana; a chegada abre uma **janela de preparação** (coleta/construção). A noite
  cai por timer (60s [placeholder]) **ou** por um gatilho do grupo (prompt "Convocar a noite" na
  caravana), nunca instantaneamente. Uma cutscene de anoitecer (sol se põe, lua sobe) dispara ao fim
  da janela e a caravana trava no lugar até o amanhecer.
- **Sem votação — permanência/avanço por posição** (doc 5.4): a UI de voto e o tally/host foram
  removidos. Ao amanhecer a caravana destrava e o grupo é livre. Quando a próxima noite cai, a
  **posição física** decide: dentro dos limites do POI = permanência (wave +1 de dificuldade por
  noite extra, recompensa travada no valor-base); já chegou no próximo POI = avanço (contador de
  permanência reseta).

### Meta-loop (passo 9), inalterado nesta reconstrução

- **Lobby "Posto de Partida"**, **persistência** (`ProfileManager`, doc 4.4) e **catálogo com 1
  unlock lateral** (Barricada Reforçada) seguem como antes. A moeda vira perfil só no fim da run
  (vitória = total; derrota = checkpoint).

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

**Split multiplayer em 2 places (doc 4.2): lado de código IMPLEMENTADO** — `LobbyServer` +
`RunServer` separados, módulos compartilhados em `src/Shared/`, teleporte de grupo via
`ReserveServer`/`TeleportAsync` nas duas pontas e dois projetos Rojo. Pra ativar falta só o que
exige o Studio/Dashboard: criar o place Run na Experience, preencher `src/Shared/Places.lua` com
os dois PlaceIds e publicar — roteiro em [docs/multiplayer-2-places.md](docs/multiplayer-2-places.md).
Sem isso configurado, cada place roda standalone (testável no Studio normalmente).

Próximos passos: ativar o split (acima) e o playtest no device alvo (Chromebook/mobile) pra
fechar densidade de POI, cap de inimigos, taxas e ritmo (passo 10). Depois, Seção 3.2
(expansão: Carpinteiro primeiro).

## Estrutura

Dois places (doc 4.2), cada um com seu script de servidor; os módulos em `src/Shared/` são
sincronizados nos dois:

- `src/ServerScriptService/Run/RunServer.server.lua` — servidor do **Run Place**: autoridade total da run (HP, recursos, spawn, dano, morte, rota, trava/soltura da caravana, chegada/permanência por posição, anti-exploit). Monta o mundo no boot, espera o grupo do teleporte e devolve todo mundo pro lobby no fim; sem `Places` configurado, recomeça a run no mesmo servidor (standalone/Studio).
- `src/ServerScriptService/Lobby/LobbyServer.server.lua` — servidor do **Lobby Place**: catálogo lateral (compra validada), caravana pilotável no posto murado e o poste "Iniciar expedição" — reserva um servidor do Run Place (`ReserveServer`) e teleporta o grupo inteiro junto (`TeleportAsync`).
- `src/Shared/ZoneBuilder.lua` — ModuleScript: constrói o **mundo contínuo** da run em runtime (POIs + corredores + plazas), o lobby, o rig físico da caravana (VehicleSeat + HingeConstraints) e os grupos destrutíveis (base do "sem volta" do fork).
- `src/Shared/RouteGraph.lua` — ModuleScript: grafo DAG da run (3 nós + boss, fork segura/arriscada). Decide os TIPOS de POI; as posições são slots fixos no ZoneBuilder.
- `src/Shared/ProfileManager.lua` — ModuleScript: persistência de perfil (doc 4.4) com session-locking por `JobId` (funciona entre places sem mudança); interface pronta pra trocar por ProfileStore.
- `src/Shared/Places.lua` — IDs dos dois places da Experience. **Preencher depois de criar/publicar** (0 = teleporte desativado, modo standalone).
- `src/StarterPlayer/StarterPlayerScripts/OneWayCaravanNightfallClient.client.lua` — HUD e preview de colocação; só envia intenção. Compartilhado pelos dois places; a condução é física (input padrão do VehicleSeat), sem remote de direção.
- `src/StarterPack/Machado/WeaponClient.client.lua` — LocalScript da Tool Machado.
- `tools/setup_place.lua` — setup 1x na Command Bar **de cada place**: liga StreamingEnabled, limpa builds antigos e cria a Tool Machado.
- `run.project.json` / `lobby.project.json` — projetos Rojo, um por place (ambos declaram StreamingEnabled no Workspace e montam `src/Shared` em `ServerScriptService.Shared`).

## Setup dos places

1. Crie os dois places na mesma Experience (o Run via **File → Publish As...** ou Creator
   Dashboard) e preencha `src/Shared/Places.lua` com os dois PlaceIds.
2. Sirva um projeto Rojo por place (dois Studios abertos, um em cada place):
   - Run: `rojo serve run.project.json` (porta padrão 34872)
   - Lobby: `rojo serve lobby.project.json --port 34873`
3. Em cada place, rode `tools/setup_place.lua` na Command Bar (modo Edit) e cole
   `WeaponClient.client.lua` como LocalScript dentro de `StarterPack.Machado`.
4. Play em qualquer um dos dois: o Run constrói o mundo contínuo e começa uma run direto
   (standalone no Studio); o Lobby monta o posto com catálogo e caravana de treino.
5. **Teleporte de verdade só publicado**: publique os dois places e teste no cliente Roblox —
   segurar o poste no lobby deve levar o grupo inteiro pro mesmo servidor de run.

Preview de um POI isolado no modo Edit (opcional, com Rojo conectado):
`require(game.ServerScriptService.Shared.ZoneBuilder).preview("mina")` na Command Bar.

## Fluxo do jogo (MVP)

1. **Lobby (Posto de Partida)**: catálogo lateral no painel à direita (moeda do perfil); qualquer
   um segura o poste "Iniciar expedição" pra partir.
2. Chegada na Estação → **janela de preparação** (coleta/construção; convoquem a noite na caravana
   quando prontos) → **anoitecer** (cutscene) → Noite 1 (3 ondas). Noite sobrevivida = +10 de moeda.
3. Ao amanhecer a caravana **destrava**. Ficar parado no POI até a próxima noite = permanência
   (+1 inimigo/onda por noite extra, recompensa igual). Dirigir pro próximo POI = avanço.
4. No fork, dirigir até o ramo escolhido cruza o **trigger de commit** e o outro ramo desmorona
   (chão destruído): Planície (segura) vs Mina (arriscada, +1 de dificuldade à noite).
5. Estação → fork → Acampamento Dizimado → Covil: cada chegada abre preparação; no covil o boss sai
   pelo funil.
6. Boss morto = +20, checkpoint e vitória. Grupo inteiro caído = derrota (credita só o checkpoint).
   No fim, a moeda garantida vira moeda de perfil de cada jogador e o grupo volta ao lobby.

## Layout do mundo e de POI (referência rápida)

- **Mundo contínuo**: POIs em slots fixos ligados por corredores/plazas, todos no mesmo espaço.
  n1 na origem → plaza de fork (`z≈460`) → n2a (oeste) / n2b (leste) → plaza de merge (`z≈1500`)
  → n3 (`z≈1840`) → covil (`z≈2460`). Streaming carrega/descarrega por distância.
- **Coordenadas de POI são locais ao centro do POI**: acampamento em `centro + (0,-47)` (a caravana
  para ali quando o grupo a leva até lá); funil de canyon em `centro + z=30`, passagem de 10 studs;
  spawns de inimigos ao norte (`centro + z≈118–136`, em `workspace.EnemySpawns/<id>`).
- **Recursos por zona** em `workspace.ResourceNodes/<id>/Trees|FoodBushes`: madeira ao sul (5 usos),
  madeira seca ao norte (8 usos, lado da horda), arbustos (4 usos), caixas de suprimento (2, comida).
- **Guardrails invisíveis** (grupo de colisão `GuardrailCaravana`) flanqueiam os corredores: seguram
  só a caravana; jogadores e inimigos atravessam pra coletar nas laterais. Provisório de playtest —
  o terreno de arte final (canyon/desfiladeiro) substitui isso depois.

## Problemas conhecidos / dívidas

- **Persistência no Studio** exige "Enable Studio Access to API Services" (Game Settings → Security)
  e place publicado; sem isso o `ProfileManager` roda em modo memória (avisa no Output).
- **Split físico em 2 places** (doc 4.2): código pronto (LobbyServer/RunServer + teleporte de
  grupo), mas **inativo até criar o place Run, preencher `src/Shared/Places.lua` e publicar** —
  roteiro em [docs/multiplayer-2-places.md](docs/multiplayer-2-places.md). O fluxo publicado
  ponta a ponta (lobby → reserved server → run → volta) ainda não foi testado em produção.
  `ProfileManager` caseiro — trocar por ProfileStore (loleris) depois (interface já compatível).
- **Latência de throttle da caravana**: a condução é responsiva pro esterço, mas os motores de
  tração são acionados no servidor a partir do `ThrottleFloat` replicado do motorista, então há ~1
  RTT de atraso na aceleração. Aceitável pra co-op PvE; revisar no playtest (passo 10) — mover o
  acionamento dos motores pro cliente-dono se ficar ruim.
- **Jitter de passageiro**: mitigado pela técnica do assembly soldado + Seats nativos (doc 4.5), mas
  o doc (risco 12) pede validação num playtest real com 2+ jogadores simultâneos — não dá pra
  confirmar sem isso.
- **Caravana parada onde chega**: o volume de chegada trava a caravana perto do acampamento quando o
  grupo a leva até lá; o terreno de POI é placeholder 480×480 (fora de escopo), então a posição
  exata da caravana vs. as decorações de camp pode não casar até o level design manual.
- **Guardrail é geometria provisória** (paredes de colisão invisíveis), não o canyon/desfiladeiro de
  arte final (doc 4.5, risco 13). Distância do guardrail (`GUARD_OFF=16` do eixo) e a velocidade da
  caravana (`CARAVAN_MAX_SPEED=24`) são placeholders de playtest.
- **Grupo parado no meio da estrada** (fora dos limites do POI, sem ter chegado no próximo) não
  dispara a noite — ela espera a chegada. A estrada é de mão única e curta, mas é um AFK-lock em
  teoria (alinhado ao risco 10 do doc; revisar antes de matchmaking público).
- **Colocação usa mouse**; em touch funciona por tap, mas sem UX dedicada de mobile (passo 10).
- **Inimigo é MoveTo direto** (sem PathfindingService); pode travar em quina fora do funil — aceito
  pelo doc 4.8.
