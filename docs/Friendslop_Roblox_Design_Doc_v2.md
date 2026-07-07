# Friendslop (Roblox) — Documento de Design + Plano de Build (v2)

*Documento vivo. A v1 era um doc de design puro. Esta v2 adiciona as camadas que faltavam pra começar a desenvolver: arquitetura técnica, corte de MVP e ordem de build. As decisões de design travadas foram preservadas; as justificativas longas foram comprimidas.*

*Revisão: modelo de caravana fechado (4.5), mecânica de avanço/permanência com votação adicionada (5.4), exceção de dificuldade por permanência travada (Seção 1, pilar 4). PvP/rebirth cortado. Documento pronto para começar build.*

## 0. Como ler este doc / status de prontidão

- **[TRAVADO]** decisão fechada, pode construir em cima.
- **[PROPOSTO]** decisão técnica nova sugerida nesta v2. Precisa do seu aval, mas tem um default pra você não travar.
- **[CALL SEU]** decisão criativa/estratégica que só você fecha, e que bloqueia trabalho se ficar aberta.
- **[PROTÓTIPO]** só resolve em playtest. Tem um valor inicial pra testar. Não perca tempo fechando no papel.

Regra de prontidão deste projeto: você **não** precisa de tudo definido pra abrir o Studio. Precisa da **Seção 4 (arquitetura)**, do **corte de MVP (Seção 3)** e da **ordem de build (Seção 6)**. O resto se resolve construindo.

---

## 1. Visão e pilares

Co-op survival roguelite. Caravana nômade cruza do ponto A ao B numa run de 15 a 40 min. Dia: coleta e construção. Noite: a caravana para e vira acampamento fixo, defesa contra ameaça sobrenatural. Chegar em B é fim de run, não fim de jogo. Inspiração de gameplay: 99 Nights in the Forest, com acampamento fixo trocado por caravana nômade.

Pilares (o que não pode quebrar):
1. **Contrato dia/noite.** Dia é recurso e escolha, noite é medo. Todo sistema serve os dois lados.
2. **Progressão lateral, não vertical.** Desbloqueio expande *o que* você faz, nunca *quão forte* você é. Sem creep de teto de poder.
3. **Comp nunca é pré-requisito.** Qualquer composição, incluindo 5 iguais, fecha a run.
4. **Skill/conhecimento decide, não sistema interno.** Dificuldade por POI é estática, não escala com grupo nem upgrades de lobby. **Exceção travada:** dificuldade de wave escala com noites consecutivas ficadas no mesmo POI (ver 5.4), pra fechar o exploit de repetir a noite mais fácil indefinidamente. Fora dessa exceção, veterano tem run mais fácil por saber jogar, não por número maior.

---

## 2. Loop central [TRAVADO]

- **Dia:** caravana avança entre nós (POIs). Jogadores coletam (madeira, comida, água), constroem e melhoram construções.
- **Noite:** caravana para, acampamento fixo, defesa de ondas. Não move de noite.
- **Combate de defesa** não é só dano. Eixos: suporte/cura, utilidade de recurso, construção (barricada afunila horda).
- **Aggro:** sem sistema dedicado. Mob mira o mais próximo, comportamento padrão Roblox. Construção (barricada + funil geográfico) é a única ferramenta de controle de horda.
- **Barricada:** bloqueia 100% quando intacta. Sem fortificação do Carpinteiro, ao ser destruída some. Com fortificação, vira estado "quebrado" (só desacelera, reparável por qualquer um).

---

## 3. Escopo: o corte de MVP (a decisão mais importante deste doc)

O doc inteiro descreve o **jogo completo**. Você não constrói o jogo completo primeiro. Constrói a fatia vertical que prova o loop, e só depois expande.

### 3.1 Fatia vertical (MVP) [PROPOSTO]

Objetivo único: **provar que dia-coleta + noite-defesa + escolha de rota é divertido em 15 min de grey-box.** Se não for, todo o resto é irrelevante.

Dentro do MVP:
- **1 rota**, 3 nós + 1 boss no final.
- **3 tipos de POI**: um de suprimento (estação de trem), um de recurso perigoso (mina *ou* lago), um de lore/loot (acampamento dizimado).
- **2 recursos**: madeira + comida. (Pedra entra só se a barricada precisar de custo diferente de madeira.)
- **2 construções**: fogueira + barricada. Só.
- **Sem classes.** Modelo universal: todo mundo faz tudo. Classe entra depois do loop provar diversão.
- **Combate mínimo**: 1 arma, 1 tipo de inimigo comum + 1 boss.
- **Economia mínima**: moeda por sobreviver a noite + por matar boss. **1 unlock lateral** no lobby (ex.: 1 variante de barricada) só pra provar que meta-progressão funciona ponta a ponta.
- **Escolha de rota**: fork simples segura-vazia vs arriscada-cheia entre os nós.

Fora do MVP (backlog, não apague, só não construa agora):
- 4 classes e suas passivas, kit inicial, exclusivas de Robux.
- Os ~12 POIs restantes.
- 3 modos end-game.
- Missões diárias, login diário, cosméticos, bundles, gamepasses.
- Conversão de recurso do Carpinteiro, sistema de escudo/melee-só, munição escassa.
- Templo, igreja, torre, fonte termal, planície de bisão, etc.

### 3.2 Ordem de expansão pós-MVP [PROPOSTO]

1. **1 classe** (Carpinteiro, casa com barricada) pra validar que classe adiciona sem virar mandatória.
2. Resto dos recursos + munição/ranged nerf + inimigo de escudo.
3. Resto dos POIs em lotes, cada um respeitando a regra dura (recurso de dia + custo de noite).
4. As outras 3 classes.
5. Economia completa (missões diárias, login).
6. Modos end-game.
7. Monetização.

---

## 4. Arquitetura técnica (novo — o que faltava pra "pronto pra desenvolver")

### 4.1 Autoridade servidor/cliente [PROPOSTO]

Servidor é autoritativo sobre tudo que importa:
- HP de jogadores e inimigos, dano, morte, revive.
- Contagem de recursos, moeda, rolls de loot.
- Spawn de inimigos, estado das ondas, progresso da run, checkpoints.
- Desbloqueios persistentes (catálogo lateral, classes, cosméticos).

Cliente cuida de: input, movimento do próprio personagem (validado no servidor), predição de VFX/animação, UI.

Regras não-negociáveis:
- Todo RemoteEvent validado e sanitizado no servidor. Nunca confiar em valor vindo do cliente pra economia ou combate.
- Rate-limit em remotes.
- Sanity-check de posição/velocidade (anti speed/teleport básico) já no MVP, porque survival com moeda atrai exploiter.

### 4.2 Estrutura de places [PROPOSTO]

Padrão Roblox de 2 places:
- **Lobby Place:** hub de progressão, catálogo lateral, escolha de classe, matchmaking, missões, cosméticos. Lê e escreve perfil aqui.
- **Run Place:** instância de uma run. Jogadores chegam via TeleportService. Perfil carregado no join, moeda ganha na run é escrita no fim.

MVP: começar com **reserved server + teleport de grupo saindo do lobby** (mais controlável que matchmaking público). Matchmaking público entra depois.

### 4.3 Jogadores por servidor [PROPOSTO]

Travar **4 pro MVP.** Menos replicação, menos edge case de balanceamento, alinhado a co-op survival. O "solo até X" fica sendo 1 a 4. Escalar só se o playtest pedir.

### 4.4 Persistência [PROPOSTO]

Usar **ProfileStore** (sucessor do ProfileService) ou ProfileService, com session-locking. **Não** usar DataStoreService cru: risco de perda e duplicação de dados que você não vai querer debugar depois.

Separação crítica que a v1 não fazia:
- **Dado persistente (perfil, vai pro DataStore):** moeda "sacada", catálogo desbloqueado, classes, passivas, cosméticos, missões diárias, streak de login.
- **Estado de run (na memória do servidor da run, some ao acabar):** moeda acumulada durante a run, checkpoints, construções, upgrades de construção da run, a caravana inteira.

A moeda só vira dado persistente **no fim da run**: na vitória, o total; na derrota, o que estava salvo no último checkpoint. Durante a run é estado volátil de servidor.

Schema de perfil (esboço):
```
Profile = {
  currency = 0,
  unlockedCatalog = {},        -- ids de construção/variante
  unlockedClasses = {},        -- ids de classe
  unlockedPassives = {},       -- classeId -> {passivaIds}
  cosmetics = { owned = {}, equipped = {} },
  dailyMissions = { active = {}, lastRollUtc = 0 },
  loginStreak = { count = 0, lastLoginUtc = 0 },
}
```

### 4.5 Modelo da caravana e travessia [TRAVADO]

Caravana é **NPC-driven, velocidade fixa**, jogadores nunca sobem nela. Papel dela é de "base que anda", não veículo pilotável. Isso elimina a dor original (personagem em pé sobre BasePart em movimento, replicação de física instável) sem exigir travessia contínua de mundo aberto.

Dia em 3 etapas:
1. **POI atual (fim):** jogadores "acordam" a caravana, ela começa a andar sozinha.
2. **Zona de transição:** mapa isolado e fechado, node-based (mesmo princípio de streaming por zona da v2 original). A caravana atravessa em linha reta na frente, jogadores livres no chão ao redor dela, nunca em cima.
3. **Próximo POI (início):** a caravana entra e anda até aproximadamente o meio do mapa daquele POI. É quando a noite cai e ela para.

Isso preserva o modelo node-based (zonas isoladas, sem streaming contínuo de mundo aberto grande) e resolve o risco de física de veículo, porque ninguém pilota nem fica em cima. A fantasia de "ver a caravana se mover" se mantém via NPC + animação, só a interação de pilotagem foi removida.

Consideração de implementação: são 2 transições de carregamento de zona por dia (POI→transição, transição→próximo POI). Loading screen vs streaming contínuo entre elas é detalhe de build, não bloqueia design.

### 4.6 Geração de rota / mapa [PROPOSTO]

- Grafo DAG gerado por run: nó inicial → fork(s) segura vs arriscada → converge nos funis → boss.
- POIs são **zonas pré-autoradas à mão**, sequenciadas proceduralmente. Não gerar geometria proceduralmente no MVP (caro e arriscado). Você embaralha a *ordem/posição* dos tipos, não a geometria.
- Regras de geração: densidade mínima obrigatória de POI por run; regra dura preservada (todo POI serve dia e noite).

### 4.7 Sistema de spawn de ondas [PROPOSTO]

- Spawner server-side. Tabela de ondas por estágio: contagem, tipo, intervalo, orçamento de spawn simultâneo.
- **Object pooling obrigatório:** reusar instâncias de inimigo, nunca Instantiate/Destroy por onda. Instanciação em massa causa hitch de GC em mobile.

### 4.8 IA de inimigo [PROPOSTO]

- PathfindingService ou SimplePath. Alvo = jogador mais próximo. Repath com throttle (a cada 0.5–1s, nunca por frame). Cap de agentes ativos.
- Aceitar o comportamento de travar em quinas (já é decisão sua, precedente de gênero).

### 4.9 Orçamento de performance (mobile / Chromebook) [PROPOSTO]

- StreamingEnabled ligado.
- Cap de inimigos simultâneos: **começar em 30** [PROTÓTIPO], ajustar por device.
- Minimizar lógica em Heartbeat/RenderStepped. Preferir eventos e throttling.
- Vigiar part count por zona e draw calls. Cuidado com Union pesado e luzes dinâmicas (a luz consagrada da igreja precisa ser barata).
- **Testar no device alvo cedo, não no fim.** É a diferença entre ajustar e reescrever.

### 4.10 Anti-exploit MVP [PROPOSTO]

Já coberto em 4.1, resumo: validação server-side de todo remote, rate-limit, economia nunca no cliente, sanity-check de movimento. Não precisa de mais no MVP.

---

## 5. Sistemas de design (decisões travadas, comprimidas)

*Preservado da v1. Construir na ordem da Seção 3, não tudo de uma vez.*

### 5.1 Cenário e tema [TRAVADO, com 1 call pendente]

- "Marcha ao Oeste", América do Norte, velho oeste. Dia: caça. Noite: horror sobrenatural (espírito Lethal Company).
- **[CALL SEU — bloqueia produção de arte, não bloqueia o MVP grey-box]** Identidade das criaturas noturnas. Skinwalker/Wendigo têm risco real (crenças vivas Navajo/Algonquina, subtexto colono-herói vs nativo-monstro, risco de moderação Roblox). Pé Grande é risco baixo. Recomendação: criaturas originais, ameaça vinda da própria terra reagindo à ganância colonial (mineração predatória, massacre, expedição encalhada tipo Donner Party). **Isto não trava o protótipo** (use placeholder), mas precisa ser fechado antes de investir em modelagem/animação/lore.

### 5.2 Progressão lateral (catálogo do lobby) [TRAVADO]

- Catálogo plano, sem árvore de dependência, sem gate de ordem.
- Escopo: tipos de construção. Variante entra como item comum do mesmo catálogo.
- Custo: moeda de run salva em checkpoint (a que sobrevive à derrota).
- **Regra dura:** toda construção nova é sidegrade (custo maior, especialização estreita, ou contra-indicação), nunca upgrade estrito.
- Soft-cap de loadout = escassez de recurso na run, não limite no lobby. Veterano tem acesso a tudo, nunca recurso pra tudo ao mesmo tempo.
- Dentro da run, cada construção tem níveis próprios (modelo crafting table do 99 Nights), vertical mas local à run, reseta a cada run.
- Disparidade de nível entre jogadores do grupo: aceita como intrínseca ao gênero. Não equalizar via balanceamento; dar conteúdo end-game pro veterano.
- Dificuldade da run estática, não escala com grupo nem com upgrades de lobby (exceção travada: escalada por permanência consecutiva no mesmo POI, ver 5.4).

### 5.3 Ativos e persistência [TRAVADO]

- Personagem + upgrades = ativo persistente entre runs.
- Caravana = ativo local da run, perdida integralmente na derrota. Peso real à derrota.
- Lobby: lateral puro. Upgrade numérico removido definitivamente.

### 5.4 Estrutura de run [TRAVADO / 1 item PROTÓTIPO]

- Trecho de dia em 3 etapas: POI atual (caravana acorda e sai) → zona de transição (travessia, ver 4.5) → próximo POI (caravana anda até o meio do mapa, noite cai).
- 15 a 40 min é o alvo do fluxo padrão (1 rota, sem permanência extra), não um teto rígido: o grupo pode optar por ficar mais tempo no mesmo POI (ver decisão de avanço abaixo), o que estende a run sem limite superior.
- Mapa Slay-the-Spire pra escolha de rota (segura vazia vs arriscada cheia). Essa escolha decide **pra onde** ir.
- **Decisão de avanço:** ao fim de cada noite, enquanto os jogadores dormem, o grupo vota entre **avançar** pro próximo POI ou **ficar** mais uma noite no atual. Decide **quando** ir, e convive com a escolha de rota acima (rota = destino, avanço = timing).
  - Votação por maioria simples. Empate quebrado pelo voto do host.
  - **Fallback:** host desconectado no momento da votação → default avançar.
  - **Escalada por permanência:** cada noite extra consecutiva no mesmo POI aumenta a dificuldade da wave em relação à noite 1 daquele POI. Contador reseta a zero ao avançar. Exceção travada ao pilar de dificuldade estática (Seção 1, pilar 4).
  - **Recompensa não acompanha:** a moeda fixa por noite sobrevivida fica travada no valor-base daquele POI, independente de quantas noites extras o grupo já ficou. Repetir nunca é estritamente melhor (dificuldade sobe, recompensa não), fechando o exploit de farm da noite mais fácil.
  - Funis geográficos (vales, desertos, montanhas) concentram a rota num ponto: onde ficam os bosses. Dificuldade de boss/funil escala por **posição na rota**, trilha separada da escalada por permanência acima; as duas não se somam.
- Vitória: completar funis/bosses. Derrota: grupo inteiro morre.
- **[PROTÓTIPO]** Densidade de POI vs tempo morto de deslocamento. Testar com 3–4 nós por run inicial.

### 5.5 Pontos de interesse [TRAVADO]

Regra dura: todo POI serve dia (recurso) e noite (custo/risco). Upside sem downside noturno vira parada obrigatória e mata a escolha de rota. Locais fixos, posição embaralhada por sessão.

MVP usa 3 (estação, mina *ou* lago, acampamento dizimado). Backlog: rio (estrangulamento), lago (caça garantida, exposição noturna), igreja (luz consagrada finita), templo indígena (fonte de horror, custo ao mexer), montanha nevada (dreno de stamina, exige fogueira) + fonte termal pareada, torre de vigia (revela mapa de dia, saída única de noite), sítio do massacre (arena de boss), planície de bisão (neutro que revida), covil de urso (perigo diurno natural). Mina tem regra de categoria: ameaça diurna dela é bicho territorial, diferente da entidade noturna. Fazenda: rejeitada em definitivo.

### 5.6 Classes [TRAVADO — todas pós-MVP]

Estrutura de cada uma: kit inicial (craftável por qualquer um, classe só começa com ele) + 1 passiva base + 2 passivas desbloqueáveis (moeda de run).
- **Regra dura:** cada desbloqueável é interação nova, nunca número maior do mesmo efeito.
- Passiva dura a run inteira, não só o início.
- Modelo revisado: classe pode ter ação genuinamente exclusiva, mas nenhuma ação exclusiva pode ser requisito de progresso.

Roster (4): **Caçador** (velocidade de ataque; unlock stun; unlock piercing +1). **Carpinteiro** (craft/reparo rápido; unlock fortificar; unlock conversão de recurso). **Médico** (revive +20%; unlock cura à distância; unlock auto-revive 2x tempo). **Batedor** (mais loot; unlock chance de loot raro só pra si; unlock boost de velocidade em kill/dano). Exclusivas de Robux: fora de escopo, estilo de gameplay diferente (ex.: Vampiro com lifesteal + fraqueza ao sol), teto de poder adiado.

### 5.7 Combate [TRAVADO / 1 risco]

- Ranged nerfado por munição escassa (cedo) e inimigos com ataque à distância.
- Estágios avançados: inimigo de escudo (só melee quebra), mas munição afrouxa; late-game tende a ranged, melee vira situacional.
- **Risco aberto:** ranged sem penalidade estrutural contra a maioria (sem escudo) no late-game. A passiva do Caçador evita piorar, não resolve. Endereçar no sistema de armas, pós-MVP.

### 5.8 Economia de run e penalidade de morte [TRAVADO]

- Fonte principal: recompensa fixa e igual ao grupo por evento compartilhado (ex.: noite = 10, boss = 20; exemplos).
- Estágios avançados: recompensa fixa proporcionalmente maior por noite/funil, sem mexer na moeda por ação individual. Existe pra compensar a penalidade de morte.
- Recompensa por noite é fixa **por POI**: ficar noites extras no mesmo POI não aumenta a recompensa (ver 5.4), só a dificuldade. Repetir a noite mais fácil nunca compensa.
- Checkpoint = cada boss salva a moeda acumulada. Morrer entre checkpoints custa só a diferença desde o último. Grupo inteiro morre: run acaba, todos recebem o salvo. Um jogador morre: revivível, sem perda individual.
- Revive não falha: segurar botão perto do caído. Item/Médico só aceleram.

### 5.9 Multiplayer, monetização, missões diárias [TRAVADO / itens em aberto]

Multiplayer: 1 a 4 por run (travado em 4 no MVP). Recompensa fixa igual a todos, recompensa de missão individual mas de peso pequeno.

Monetização (toda pós-MVP): cosméticos exclusivos e não-exclusivos via Robux (run dá parecido/igual mais lento), bundles de moeda, classes compráveis por grind (Robux pula grind, não dá exclusivo), classes exclusivas de Robux (poucas). Login diário **[em aberto]**. Gamepasses **[em aberto]**.

Missões diárias (pós-MVP): 3/dia, não completar substitui no dia seguinte, recompensa fixa em moeda. Ações: matar X, coletar X de recurso, construir/consertar X. Sempre com desafio atrelado (ex.: numa única noite).

---

## 6. Ordem de build (o que abrir no Studio e fazer, em sequência)

Cada passo produz algo testável. Não pule pra frente antes do passo anterior rodar.

1. **Setup.** 2 places (lobby, run). ProfileStore no lobby. Versionamento (Rojo + git recomendado, ou Studio direto se preferir). Um nó vazio jogável na run.
2. **Loop dia/noite** num nó só: timer de dia, transição, timer de noite. Sem inimigo ainda.
3. **Coleta de recurso:** cortar árvore → madeira contada no servidor. UI de contagem. Comida como segundo recurso.
4. **Acampamento:** colocar fogueira e barricada. Barricada bloqueia passagem.
5. **Combate mínimo:** 1 arma, 1 inimigo, HP server-side, morte + revive hold-button. Inimigo bloqueado pela barricada.
6. **Ondas noturnas:** spawner + object pooling, 2–3 ondas escalando. Barricada + funil como controle de horda.
7. **Grafo de rota:** 3 nós + boss. Travessia NPC-driven em 3 etapas (ver 4.5). Fork segura vs arriscada. Votação de avanço/permanência com fallback de host desconectado, e escalada de dificuldade por permanência (ver 5.4).
8. **Fim de run:** boss, checkpoint, vitória/derrota, cálculo da moeda salva.
9. **Meta-loop:** lobby com catálogo de 1 unlock lateral, persistência de moeda e unlock, aplicar na run seguinte. Aqui você fecha o ciclo completo pela primeira vez.
10. **Playtest no device alvo** (Chromebook/mobile). Só agora decida densidade de POI, cap de inimigo, taxas e ritmo. Antes disso, é chute.

Depois do passo 10, você entra na Seção 3.2 (expansão).

---

## 7. A resolver em protótipo [PROTÓTIPO — valores iniciais pra testar]

- Densidade de POI vs tempo morto: 3–4 nós por run.
- Cap de inimigo simultâneo: começar em 30, ajustar por perf.
- Taxa de conversão do Carpinteiro: 3:1.
- Contágio de aggro do bisão: começar com chance fixa (ex.: 50% de 1 vizinho entrar), medir.
- Curva de decaimento de fome/stamina/vida: placeholder linear, ajustar no teste.
- Modo hardcore escala por grupo ou é tier fixo: decidir só quando o core estiver jogável.
- Valores de moeda por noite/boss e escala de recompensa tardia: balancear em teste.

---

## 8. Calls pendentes que bloqueiam trabalho (resolver antes dos passos indicados)

1. **Identidade das criaturas (5.1).** Não bloqueia o protótipo grey-box, bloqueia produção de arte/animação/lore. Fechar antes de investir em assets.

---

## 9. Riscos consolidados

1. Ranged sem penalidade estrutural no late-game (sistema de armas, pós-MVP).
2. Escopo total grande demais pra construir sem corte de MVP (endereçado na Seção 3).
3. Persistência sem session-locking = perda/dup de dados (endereçado com ProfileStore, 4.4).
4. Modo hardcore escala vs fixo, reabre "escala pra quem" em grupo misto.
5. Densidade de POI vs tempo morto: só playtest resolve.
6. Curva de fome/stamina e mecânica de revive além do Médico: não especificadas.
7. Contágio de aggro do bisão: mecanismo exato indefinido.
8. Classes futuras superarem as atuais no mesmo eixo: risco aceito, adiado.
9. Teto de poder de classes exclusivas de Robux: indefinido, adiado.
10. Permanência sem teto pode deixar um grupo AFK/parado ocupando um servidor indefinidamente. Fora de escopo do MVP (reserved server, grupo pequeno), mas revisar antes de matchmaking público (considerar timeout de sessão ou detecção de inatividade).
11. Escalada por permanência e escalada por posição são trilhas separadas por design, mas o jogador pode não perceber a diferença ("por que a wave ficou mais difícil sem eu ter avançado?"). Validar clareza de feedback/UI em playtest.
