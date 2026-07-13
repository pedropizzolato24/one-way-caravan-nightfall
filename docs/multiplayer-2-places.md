# Multiplayer: split em 2 places (Lobby + Run) com teleporte de grupo

Implementação do doc 4.2: **Lobby Place** (hub de progressão/catálogo) + **Run Place**
(instância de uma run), ligados por `TeleportService` com **reserved server** pro grupo cair
junto no mesmo servidor.

## Status

**Mudanças 1–5 concluídas. Falta só a 6** (republicar depois dos últimos fixes e confirmar o
fluxo publicado ponta a ponta):

| # | Mudança | Status |
|---|---------|--------|
| 1 | Criar o place Run na Experience + preencher `Places.lua` | **Feito** (IDs preenchidos) |
| 2 | Módulos compartilhados em `src/Shared/` | Feito |
| 3 | Split em `LobbyServer` / `RunServer` | Feito |
| 4 | `ReserveServer` + `TeleportAsync` nas duas pontas | Feito |
| 5 | Dois projetos Rojo (`lobby.project.json` / `run.project.json`) | Feito |
| 6 | Publicar os dois places e testar ponta a ponta | **PENDENTE (manual)** |

O que falta na mudança 6, concretamente:
1. `git pull` na branch e **re-sync do Rojo nos dois places** — houve fixes depois do primeiro
   publish (limpeza de scripts legados/contaminação no `setup_place.lua`, e o hardening de spawn
   que segura o character até o mundo existir). Sem re-sync + republish, o servidor publicado
   roda a versão antiga.
2. Rodar `setup_place.lua` na Command Bar de cada place (depois de conectar o Rojo — ele agora
   se auto-limpa, inclusive removendo o server-script do outro place se veio por engano).
3. **Publish** dos dois places.
4. Testar no cliente Roblox (não no Studio) com 2+ contas: lobby → segurar poste → grupo cai no
   mesmo servidor de run → jogar → volta pro lobby com a moeda creditada.

Até a 6 fechar de verdade no publicado, **tudo continua testável isolado**: cada place roda
standalone com Play no Studio (o Run começa uma run direto; o Lobby roda catálogo + caravana e
só o teleporte fica indisponível — `TeleportAsync` sempre falha no Studio, por design).

## O que foi implementado (mapa do código)

- **`src/Shared/`** — `ZoneBuilder`, `ProfileManager`, `RouteGraph` e `Places` (config de
  PlaceIds), montados em `ServerScriptService.Shared` pelos dois projetos Rojo.
- **`src/ServerScriptService/Lobby/LobbyServer.server.lua`** — catálogo (compra validada,
  `Phase == "Lobby"`), caravana pilotável no posto murado, perfil (load/release/BindToClose) e
  o poste "Iniciar expedição": `ReserveServer(Places.RUN)` → `TeleportOptions` com
  `ReservedServerAccessCode` → `TeleportAsync` com a lista de jogadores capturada no momento do
  teleporte. Falhou (Studio/sem config/erro transitório)? O poste continua armado pra nova
  tentativa e o motivo é anunciado.
- **`src/ServerScriptService/Run/RunServer.server.lua`** — toda a run (mundo contínuo, fases,
  combate, boss, economia, anti-exploit). No boot monta o mundo ANTES de esperar jogadores
  (quem chega do teleporte já spawna no SpawnLocation do primeiro POI); espera o grupo entrar
  (janela de 120s + 2s de folga pra retardatários) e roda o percurso de POIs. No `endRun`,
  credita a moeda, mostra a tela de fim e `TeleportAsync(Places.LOBBY, ...)` devolve o grupo;
  quem ficar (teleporte indisponível) recomeça uma run nova no mesmo servidor.
- **Cliente compartilhado** — o mesmo `OneWayCaravanNightfallClient` roda nos dois places (os
  remotes existem nos dois; no Lobby só `BuyUnlock` tem handler). O fade de zona foi removido:
  a transição lobby↔run agora é a tela de loading nativa do teleporte.
- **Perfil entre places** — zero mudança no `ProfileManager`: o session-lock usa `game.JobId`
  (único por servidor na plataforma toda) e `PlayerRemoving` dispara também no teleporte, então
  o lock é solto e o perfil gravado na saída de cada place; o `load` do outro lado já tem retry
  com backoff se a escrita demorar a propagar.

## O que falta você fazer (mudanças 1 e 6)

### 1. Criar o place Run e configurar os IDs

1. No Creator Dashboard (ou Studio: **File → Publish As...** → adicionar como novo place na
   **mesma Experience**), crie o place **Run**.
2. Anote os dois `PlaceId` (aparecem na URL do place no Dashboard, ou em `game.PlaceId` com o
   place aberto no Studio).
3. Preencha `src/Shared/Places.lua`:

```lua
return {
	LOBBY = 111111111, -- PlaceId do place inicial (o atual)
	RUN = 222222222, -- PlaceId do place novo
}
```

> Teleporte entre places **só funciona dentro da mesma Experience** e com os places publicados.

### 6. Publicar e testar

`TeleportService` **não funciona em Edit/Play do Studio** — teleporta pra servidor real:

1. Conecte um Rojo em cada place e sincronize:
   - Run: `rojo serve run.project.json` (porta padrão 34872)
   - Lobby: `rojo serve lobby.project.json --port 34873`
   (dois Studios abertos, um em cada place: File → Open from Roblox)
2. Em cada place, rode `tools/setup_place.lua` na Command Bar 1x e cole o `WeaponClient` na
   Tool Machado (ver README).
3. **Publique os dois places** (Publish, não só salvar). Republique a cada iteração no fluxo
   de teleporte.
4. Teste no cliente Roblox com 2+ contas. Critério de aceite: lobby → segurar poste → grupo
   inteiro cai **no mesmo** servidor de Run → jogar a run → vitória/derrota → grupo volta ao
   lobby com a moeda creditada no perfil.

Iteração rápida sem republicar: cada place é testável isolado com Play normal (o Run começa
uma run direto; o Lobby roda catálogo/caravana e só o teleporte fica indisponível).

## Notas de design da implementação

- **Grupo no mesmo servidor**: `ReserveServer` devolve um access code de servidor privado;
  `TeleportOptions.ReservedServerAccessCode` faz o `TeleportAsync` levar todo mundo pra ele.
  Ninguém de fora entra (matchmaking público fica pra depois do MVP, doc 4.2).
- **Fallback standalone**: `Places.LOBBY/RUN = 0` desativa o teleporte dos dois lados sem
  quebrar nada — é o que mantém o jogo testável no Studio e o repo utilizável antes do publish.
- **Jogador que entra no Run place no meio da run** (ex.: follow de amigo): é aceito, spawna
  no SpawnLocation do POI atual e entra na luta — suficiente pro MVP.
- **Servidor de Run vazio**: se ninguém chegar em 120s (ou todos saírem no fim), o loop apenas
  rearma o mundo e espera; a plataforma recicla reserved servers vazios sozinha.
- O cliente ainda não trata `TeleportInitFailed` com retry automático (raro; o poste rearmado
  no lobby cobre a retentativa manual). Melhorar se aparecer em playtest.
