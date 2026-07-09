# Multiplayer: split em 2 places (Lobby + Run) com teleporte de grupo

Guia de implementação do doc 4.2: **Lobby Place** (hub de progressão/catálogo) + **Run Place**
(instância de uma run), ligados por `TeleportService` com **reserved server** pro grupo cair
junto no mesmo servidor. Escrito pra ser seguido sem contexto da sessão que o gerou — as âncoras
de linha referem-se ao commit `162383a` da branch `claude/caravan-traversal-rebuild-fsfpx3`.

## Estado de partida

Hoje é tudo **um place e um script**: `OneWayCaravanNightfallServer.server.lua` alterna
lobby ↔ run num `while true do` (o "loop lobby -> run", linha ~1264). O lobby é uma zona lógica
(`ZoneBuilder.buildLobby()`), e a fronteira lobby↔run é um fade — placeholder exatamente do
teleporte que este guia implementa.

## As 6 mudanças

### 1. Criar o segundo Place na Experience

No Creator Dashboard (ou Studio: **File → Publish As...** → adicionar como novo place na mesma
Experience), crie o place **Run**. Anote os dois `PlaceId` — vão hardcoded num ModuleScript de
config compartilhado (ex.: `src/Shared/Places.lua` retornando `{ LOBBY = ..., RUN = ... }`).

> Teleporte entre places **só funciona dentro da mesma Experience** e com os places publicados.

### 2. Mover os módulos compartilhados pra `src/Shared/`

`ZoneBuilder.lua` e `ProfileManager.lua` são usados pelos dois places:

- **ZoneBuilder**: o Lobby usa `buildLobby()` + o rig da caravana (ela existe e é pilotável no
  posto); o Run usa `buildWorld()`/grupos destrutíveis + o mesmo rig.
- **ProfileManager**: o Lobby carrega/gasta moeda no catálogo; o Run carrega de novo, credita a
  moeda no `endRun` e libera na saída.
- `RouteGraph.lua` só precisa existir no Run (mas não custa compartilhar).

### 3. Quebrar o script monolítico em `LobbyServer` e `RunServer`

O `OneWayCaravanNightfallServer.server.lua` (~1300 linhas) vira dois scripts. A linha de corte é
o "loop lobby -> run" (linha ~1264):

**`LobbyServer.server.lua`** fica com:
- Infraestrutura comum: remotes, `initPlayer`/`PlayerAdded` com `ProfileManager.load` (linha
  ~226), `PlayerRemoving` com `ProfileManager.release` (linha ~259-267), `BindToClose` (linha
  ~271), rate-limit, catálogo/`buyRE` (a compra é validada com `Phase == "Lobby"` — mantenha).
- `ZoneBuilder.buildCaravana()` + `buildLobby()` + pivô + caravana **destravada** (pilotagem
  livre no posto murado).
- O prompt "Iniciar expedição" (linha ~1301): em vez de `started = true` seguir pro setup da
  run, chama o teleporte de grupo (mudança 4).
- **Não** leva: waves/pool de inimigos, IA, boss, fases de dia/noite, `RouteGraph`.

**`RunServer.server.lua`** fica com:
- A mesma infraestrutura comum (duplicada: remotes, initPlayer + load/release/BindToClose,
  anti-exploit, recursos, estruturas, combate, pool, IA).
- No boot: `RouteGraph.generate()` → `ZoneBuilder.buildWorld(graph)` → pivô/spawn → o
  "percurso do POI" (preparação → anoitecer → noite → dia livre → boss) — ou seja, o corpo do
  loop atual SEM o `while true` externo e SEM a parte de lobby.
- `endRun` (linha ~1225): em vez de `task.wait(RUN_RESTART_DELAY)` e voltar pro topo do loop,
  teleporta todo mundo de volta pro Lobby place (mudança 4). A tela de fim de run continua — o
  delay vira o tempo de leitura antes do teleporte.
- Jogador que entra no Run place SEM vir de teleporte (ex.: seguiu um amigo no meio da run):
  aceite e spawne perto da caravana — MVP não precisa de mais que isso.

Cliente: o `OneWayCaravanNightfallClient.client.lua` pode ser compartilhado como está (HUD reage
a atributos; o que não existir em cada place simplesmente não dispara). O fade `ZoneFade` vira
cosmético da partida/chegada de teleporte, ou pode ser removido — `TeleportService` já mostra a
tela de loading nativa entre places.

### 4. Teleporte de grupo com reserved server

API moderna (`TeleportAsync` + `TeleportOptions`), nunca a legada. No **LobbyServer**, no
`prompt.Triggered`:

```lua
local TeleportService = game:GetService("TeleportService")
local Places = require(script.Parent.Places) -- { LOBBY = ..., RUN = ... }

local function startExpedition()
	local players = Players:GetPlayers() -- lista NO MOMENTO do teleporte
	local ok, accessCode = pcall(function()
		return TeleportService:ReserveServer(Places.RUN)
	end)
	if not ok then
		announce("Falha ao reservar servidor — tentem de novo.")
		return
	end
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = accessCode
	-- opcional: options:SetTeleportData({ ... }) pra levar seed/rota decidida no lobby
	local success, err = pcall(function()
		TeleportService:TeleportAsync(Places.RUN, players, options)
	end)
	if not success then
		announce("Teleporte falhou: " .. tostring(err))
	end
end
```

`ReserveServer` + `ReservedServerAccessCode` é o que garante o **grupo inteiro no mesmo
servidor** (servidor privado, ninguém de fora entra). A volta, no `endRun` do **RunServer**,
não precisa de reserva:

```lua
TeleportService:TeleportAsync(Places.LOBBY, Players:GetPlayers())
```

No cliente, trate `TeleportService.TeleportInitFailed` pra dar feedback se falhar (raro).
Retry simples com 1-2 tentativas resolve o MVP.

### 5. Dois projetos Rojo

`default.project.json` vira dois, cada um com os Shared + o server-script do seu place:

```
lobby.project.json  -> ServerScriptService: LobbyServer + Shared/*
run.project.json    -> ServerScriptService: RunServer + Shared/* + RouteGraph
```

Ambos mantêm `Workspace.$properties.StreamingEnabled` (o Run precisa; no Lobby é inofensivo) e
o `StarterPlayerScripts` compartilhado. Pra servir os dois ao mesmo tempo:

```
rojo serve lobby.project.json               # porta padrão 34872
rojo serve run.project.json --port 34873
```

Dois Studios abertos, um em cada place (File → Open from Roblox → escolher o place na
Experience), cada um conectado ao seu `rojo serve`.

### 6. Publicar e testar

`TeleportService` **não funciona em Edit/Play local** — teleporta pra servidor real publicado:

- Publique os dois places (Publish, não só salvar) pelo menos uma vez antes do teste ponta a
  ponta; republique a cada iteração no fluxo de teleporte.
- Iteração rápida: teste cada place isolado com Play normal (lobby sozinho; run sozinho com um
  bypass de boot que chama `buildWorld` direto), e só publique quando for testar o teleporte.
- Teste de grupo: 2+ contas (ou "Start Server + Players" local pra tudo que NÃO é teleporte).
- Critério de aceite: lobby → segurar poste → grupo inteiro cai **no mesmo** servidor de Run →
  jogar a run → vitória/derrota → grupo volta ao lobby com a moeda creditada no perfil.

## Perfil/moeda entre places — nada muda no ProfileManager

Conferido a fundo; o módulo já foi desenhado pra isso (passo 9):

- `SESSION_ID` usa `game.JobId`, único **por servidor na plataforma inteira** (não por place) —
  o session-lock funciona entre places sem alteração.
- `PlayerRemoving` dispara também em teleporte (não só desconexão), então
  `ProfileManager.release` já solta o lock e grava o perfil na saída do Lobby automaticamente.
- Se o Run carregar o perfil antes do release propagar, `ProfileManager.load` já tem retry com
  backoff (4 tentativas fora do Studio).
- Único trabalho: **duplicar** as chamadas triviais em cada script novo (load no
  `PlayerAdded`, release no `PlayerRemoving`, `releaseAll` no `BindToClose`).

## Ordem sugerida

1. Criar o place Run, anotar `PlaceId`s (mudança 1) e criar `src/Shared/Places.lua`.
2. Mover `ZoneBuilder`/`ProfileManager` pra `src/Shared/` (mudança 2).
3. Extrair `LobbyServer` e testar sozinho com Play até catálogo/prompt/caravana funcionarem.
4. Extrair `RunServer` com bypass de boot e testar a run sozinha até o loop de POI rodar igual.
5. Escrever os dois `.project.json` e plugar os dois `rojo serve` (mudança 5).
6. Publicar, plugar o `ReserveServer`/`TeleportAsync` nas duas pontas (mudança 4) e rodar o
   teste ponta a ponta (mudança 6).

A parte trabalhosa é a 3 (separar lifecycles de um script de ~1300 linhas); a persistência é a
parte que menos dá trabalho, porque o `ProfileManager` já estava pronto pra isso.
