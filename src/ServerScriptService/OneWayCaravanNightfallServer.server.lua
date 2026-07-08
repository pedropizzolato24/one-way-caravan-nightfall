-- One Way Caravan: Nightfall — MVP servidor autoritativo (design doc v2: Seções 2, 3.1, 4, 6.1–6.8)
-- Toda autoridade de HP, recursos, spawn, dano, morte, rota e economia vive AQUI.
-- Cliente só envia intenção via RemoteEvents validados e rate-limitados.
-- Doc 4.5/4.6/5.4 (Revisão 3): a caravana é PILOTADA por um jogador (VehicleSeat) e a run
-- inteira é um MUNDO CONTÍNUO via StreamingEnabled — POIs e corredores coexistem no mesmo
-- espaço, sem zonas isoladas, sem fade e sem teleporte dentro da run. A única "tela" restante
-- é a fronteira lobby<->run (placeholder do TeleportService do split de places, doc 4.2).
-- Chegada em POI é detectada por volume (poll server-side da posição da caravana: .Touched não
-- é confiável com StreamingEnabled + física no cliente do motorista).
-- Passo 8: boss no Covil, checkpoint, vitória/derrota (wipe) e moeda de run (doc 5.8).

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Lighting = game:GetService("Lighting")

local ZoneBuilder = require(script.Parent.ZoneBuilder)
local RouteGraph = require(script.Parent.RouteGraph)
local ProfileManager = require(script.Parent.ProfileManager)

-- ===== config =====
local DAY_LENGTH = 90 -- janela de dia livre pós-noite: se ficarem no POI até acabar, a noite volta
local PREP_LENGTH = 60 -- janela de preparação ao chegar num POI novo, antes da noite [placeholder]
local NIGHT_LENGTH = 120
local CARAVAN_SANITY_SPEED = 60 -- teto de velocidade horizontal da caravana (anti-exploit do motorista)
-- limites do mundo contínuo (layout fixo do MVP no ZoneBuilder); sanity-check de colocação
local WORLD_BOUNDS = { minX = -700, maxX = 700, minZ = -300, maxZ = 2760 }
local WAVES = { -- 3 ondas por noite, escalando em contagem
	{ time = 6, count = 3 },
	{ time = 45, count = 4 },
	{ time = 80, count = 5 },
}
local WAVE_MAX_COUNT = 8
-- custo noturno estático por tipo de POI (doc 5.5: todo POI serve dia e noite; dificuldade estática, pilar 4)
local POI_DIFFICULTY = { estacao = 0, planicie = 0, mina = 1, acampamento = 1, boss = 0 }
local POOL_SIZE = 24
local ENEMY_MAX_HP = 75
local ENEMY_WALKSPEED = 10
local ENEMY_DMG_PLAYER = 10
local ENEMY_DMG_BARRICADE = 5
local ENEMY_ATTACK_RANGE = 5
local ENEMY_ATTACK_COOLDOWN = 1.2
local AI_TICK = 0.6 -- repath com throttle (doc 4.8), nunca por frame
-- boss (doc 3.1: 1 inimigo comum + 1 boss; luta no funil do Covil)
local BOSS_HP = 600
local BOSS_WALKSPEED = 8
local BOSS_DMG = 25
local BOSS_BARRICADE_DMG = 25
local BOSS_ATTACK_RANGE = 8
local BOSS_ATTACK_COOLDOWN = 1.6
local BOSS_ADDS_INTERVAL = 40 -- reforços do covil durante a luta
local BOSS_ADDS_COUNT = 3
-- economia de run (doc 5.8: recompensa fixa e igual ao grupo por evento compartilhado; valores de exemplo do doc)
local NIGHT_REWARD = 10
local BOSS_REWARD = 20
local RUN_RESTART_DELAY = 15 -- tela de fim de run antes de voltar pro lobby
local WEAPON_DMG = 25
local WEAPON_RANGE = 10
local WOOD_PER_COLLECT = 2
local FOOD_PER_COLLECT = 1
local HEAL_PER_FOOD = 25
local COLLECT_RANGE = 14
local PLACE_RANGE = 35
local DOWNED_HP = 10
local CAMP_FALLBACK = Vector3.new(0, 3, -47)
local MAX_HORIZ_SPEED = 60 -- sanity-check anti speed/teleport (doc 4.1); só horizontal p/ não punir queda
local COSTS = {
	Fogueira = { Wood = 5 },
	Barricada = { Wood = 10 },
	BarricadaReforcada = { Wood = 16 }, -- sidegrade (doc 5.2): aguenta mais, custa mais
}
local BARRICADE_HP = 250
local BARRICADE_REINFORCED_HP = 400
local BARRICADE_COLOR = Color3.fromRGB(140, 100, 50)
local BARRICADE_REINFORCED_COLOR = Color3.fromRGB(96, 84, 70)
local BARRICADE_COLOR_BROKEN = Color3.fromRGB(70, 45, 25)
-- catálogo lateral (doc 5.2: plano, sem árvore; MVP = 1 unlock pra provar o meta-loop ponta a ponta, doc 3.1)
local CATALOG = {
	BarricadaReforcada = { name = "Barricada Reforçada", price = 40 },
}
local RATE_LIMIT = { Collect = 0.3, Damage = 0.2, Place = 0.5, Eat = 0.5, Buy = 0.5 } -- doc 4.1

-- zona atual (funil, posições da caravana); preenchida pelo loop da run
local CurrentZone = nil
-- mundo contínuo da run (zonas + grupos destrutíveis); retorno de ZoneBuilder.buildWorld
local RunWorld = nil
-- estado da run: active liga a checagem de wipe; defeated interrompe as fases
local runState = { active = false, defeated = false }

-- ===== infraestrutura (cria o que faltar p/ o servidor nunca travar em WaitForChild) =====
local remotes = RS:FindFirstChild("Remotes")
if not remotes then
	remotes = Instance.new("Folder")
	remotes.Name = "Remotes"
	remotes.Parent = RS
end
local function ensureRemote(name)
	local r = remotes:FindFirstChild(name)
	if not r then
		r = Instance.new("RemoteEvent")
		r.Name = name
		r.Parent = remotes
	end
	return r
end
local collectRE = ensureRemote("CollectResource")
local damageRE = ensureRemote("DamageEnemy")
local placeRE = ensureRemote("PlaceStructure")
local eatRE = ensureRemote("EatFood")
local enemyDiedRE = ensureRemote("EnemyDied")
local playerDownedRE = ensureRemote("PlayerDowned")
local zoneFadeRE = ensureRemote("ZoneFade")
local announceRE = ensureRemote("Announce")
local runEndedRE = ensureRemote("RunEnded")
local buyRE = ensureRemote("BuyUnlock")

local function ensureFolder(name)
	local f = workspace:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = workspace
	end
	return f
end
local resourceNodes = ensureFolder("ResourceNodes")
local structuresFolder = ensureFolder("Structures")
local enemiesFolder = ensureFolder("Enemies")

local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
if not atmosphere then
	atmosphere = Instance.new("Atmosphere")
	atmosphere.Parent = Lighting
end
atmosphere.Density = 0.3
atmosphere.Haze = 1.6

-- ===== mundo contínuo por streaming (doc 4.5/4.6/4.9: StreamingEnabled ligado) =====
-- Um único espaço por run; o cliente carrega/descarrega geometria por distância do jogador,
-- sem loading screen nem teleporte entre POIs. Radii enxutos p/ mobile/Chromebook (doc 4.9).
workspace.StreamingEnabled = true
workspace.StreamingMinRadius = 256 -- sempre carregado ao redor do jogador
workspace.StreamingTargetRadius = 640 -- alvo de carregamento por distância
pcall(function()
	workspace.StreamingIntegrityMode = Enum.StreamingIntegrityMode.MinimumRadiusPause
end)

local function announce(text)
	announceRE:FireAllClients(text)
	print("[One Way Caravan: Nightfall] " .. text)
end

-- acampamento = onde a caravana está (doc 4.5: a caravana é a "base que anda")
local function campPos()
	local caravana = workspace:FindFirstChild("Caravana")
	if caravana then
		return caravana:GetPivot().Position
	end
	return CAMP_FALLBACK
end

-- ===== economia de run (doc 5.8; persistência de verdade entra no passo 9) =====
local runCurrency = 0 -- acumulada na run, igual pro grupo inteiro
local checkpointCurrency = 0 -- salva a cada boss; é o que sobrevive à derrota

local function syncCurrency()
	RS:SetAttribute("Currency", runCurrency)
	RS:SetAttribute("CheckpointCurrency", checkpointCurrency)
end

-- ===== derrota: grupo inteiro caído (doc 5.4: derrota = grupo inteiro morre) =====
local function checkWipe()
	if not runState.active or runState.defeated then return end
	task.defer(function()
		if not runState.active or runState.defeated then return end
		local anyPlayer = false
		for _, plr in ipairs(Players:GetPlayers()) do
			anyPlayer = true
			local char = plr.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 and not plr:GetAttribute("Downed") then
				return -- alguém ainda está de pé
			end
		end
		if anyPlayer then
			runState.defeated = true
			announce("O grupo inteiro caiu. A caravana se perdeu na noite...")
		end
	end)
end

-- ===== recursos (contagem 100% server-side; atributo no Player é só espelho p/ UI) =====
local resources = {} -- [player] = { Wood = n, Food = n }
local joinOrder = {} -- ordem de entrada; joinOrder[1] = host (desempata votação, doc 5.4)

local function disableNativeRegen(char)
	-- o script "Health" padrão regenera HP e mascarava o estado Downed; sem ele, comida vira a fonte de cura
	task.spawn(function()
		local hs = char:WaitForChild("Health", 5)
		if hs then
			hs:Destroy()
		end
	end)
end

local function initPlayer(plr)
	if resources[plr] then return end
	resources[plr] = { Wood = 0, Food = 0 }
	table.insert(joinOrder, plr)
	plr:SetAttribute("Wood", 0)
	plr:SetAttribute("Food", 0)
	plr:SetAttribute("Downed", false)
	plr.CharacterAdded:Connect(function(char)
		plr:SetAttribute("Downed", false)
		disableNativeRegen(char)
		task.spawn(function()
			local hum = char:WaitForChild("Humanoid", 5)
			if hum then
				hum.Died:Connect(checkWipe)
			end
		end)
	end)
	if plr.Character then
		disableNativeRegen(plr.Character)
	end
	task.spawn(function()
		ProfileManager.load(plr) -- perfil persistente (doc 4.4); atributos ProfileCurrency/Unlock_* espelham pro cliente
	end)
end

local function addResource(plr, kind, amt)
	local r = resources[plr]
	if not r then return end
	r[kind] += amt
	plr:SetAttribute(kind, r[kind])
end

-- ===== rate limit =====
local lastCall = {} -- [player][key] = os.clock()
local function rateOk(plr, key)
	local now = os.clock()
	local t = lastCall[plr]
	if not t then
		t = {}
		lastCall[plr] = t
	end
	if now - (t[key] or 0) < RATE_LIMIT[key] then
		return false
	end
	t[key] = now
	return true
end

local lastPos = {} -- [player] = { char, pos, t } p/ anti-teleport

Players.PlayerAdded:Connect(initPlayer)
for _, plr in ipairs(Players:GetPlayers()) do
	initPlayer(plr)
end
Players.PlayerRemoving:Connect(function(plr)
	resources[plr] = nil
	lastCall[plr] = nil
	lastPos[plr] = nil
	local i = table.find(joinOrder, plr)
	if i then
		table.remove(joinOrder, i)
	end
	ProfileManager.release(plr) -- solta o session-lock e grava o perfil (doc 4.4)
	checkWipe() -- se só sobraram caídos, é derrota
end)

game:BindToClose(function()
	ProfileManager.releaseAll()
end)

-- ===== anti speed/teleport básico (doc 4.1) =====
local lastCaravanaPos = nil -- sanity-check da caravana: o motorista tem network ownership dela
task.spawn(function()
	while true do
		task.wait(1)
		for _, plr in ipairs(Players:GetPlayers()) do
			local char = plr.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if hrp and hum then
				if hum.SeatPart then
					lastPos[plr] = nil -- sentado (a caravana pode ser mais rápida que o teto a pé)
				else
					local rec = lastPos[plr]
					local now = os.clock()
					if rec and rec.char == char then
						local dt = math.max(now - rec.t, 0.1)
						local flat = Vector3.new(hrp.Position.X - rec.pos.X, 0, hrp.Position.Z - rec.pos.Z)
						if flat.Magnitude / dt > MAX_HORIZ_SPEED then
							char:PivotTo(CFrame.new(rec.pos + Vector3.new(0, 2, 0)))
							print("[One Way Caravan: Nightfall] Movimento suspeito de " .. plr.Name .. " — posição revertida")
						else
							lastPos[plr] = { char = char, pos = hrp.Position, t = now }
						end
					else
						lastPos[plr] = { char = char, pos = hrp.Position, t = now }
					end
				end
			end
		end
		-- caravana: motorista é dono da física dela; reverte salto impossível (anti speed/teleport)
		local caravana = workspace:FindFirstChild("Caravana")
		local root = caravana and caravana.PrimaryPart
		if root then
			local now = os.clock()
			if lastCaravanaPos and not root.Anchored then
				local dt = math.max(now - lastCaravanaPos.t, 0.1)
				local flat = Vector3.new(root.Position.X - lastCaravanaPos.pos.X, 0, root.Position.Z - lastCaravanaPos.pos.Z)
				if flat.Magnitude / dt > CARAVAN_SANITY_SPEED then
					caravana:PivotTo(CFrame.new(lastCaravanaPos.pos) * (root.CFrame - root.CFrame.Position))
					root.AssemblyLinearVelocity = Vector3.zero
					print("[One Way Caravan: Nightfall] Movimento suspeito da caravana — posição revertida")
					lastCaravanaPos = { pos = root.Position, t = now }
				else
					lastCaravanaPos = { pos = root.Position, t = now }
				end
			else
				lastCaravanaPos = { pos = root.Position, t = now }
			end
		end
	end
end)

-- teleporte legítimo do servidor (SÓ na fronteira lobby<->run): reseta o rastreio anti-teleport.
-- Jogadores sentados na caravana são pulados (o pivô da caravana já os leva junto pelo SeatWeld).
local function teleportPlayersBehindCaravana()
	local caravana = workspace:FindFirstChild("Caravana")
	local base = caravana and caravana:GetPivot() or CFrame.new(CAMP_FALLBACK)
	local i = 0
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if char and not (hum and hum.SeatPart) then
			task.spawn(function()
				-- prefetch de streaming do destino (não bloqueia; o fade cobre o carregamento)
				pcall(function()
					plr:RequestStreamAroundAsync(base.Position, 1)
				end)
			end)
			char:PivotTo(base * CFrame.new(-6 + (i % 4) * 4, 1.5, -12 - math.floor(i / 4) * 4))
			lastPos[plr] = nil
			i += 1
		end
	end
end

local function rectContains(r, p)
	return p.X >= r.minX and p.X <= r.maxX and p.Z >= r.minZ and p.Z <= r.maxZ
end

-- ===== commit de fork (passo 4): a escolha do ramo é FÍSICA (doc 4.5/4.6) =====
-- Ao cruzar o volume de trigger de um ramo (a caravana já entrou naquele braço), o servidor
-- destrói o ramo não escolhido. Sem chão pra voltar, o "sem volta" se cumpre pela geometria.
local function tryForkCommit()
	if not RunWorld or RunWorld.forkCommitted or not RunWorld.commitRects then
		return
	end
	local p = campPos()
	for chosen, rect in pairs(RunWorld.commitRects) do
		if rectContains(rect, p) then
			local destroyed = ZoneBuilder.commitFork(chosen)
			if destroyed then
				local zone = RunWorld.zones[chosen]
				local label = zone and zone.kind or chosen
				announce("Rota travada rumo a " .. label .. ". O outro caminho desmoronou — sem volta.")
				print("[One Way Caravan: Nightfall] Fork travado: " .. chosen .. " (ramo " .. destroyed .. " destruído)")
			end
			return
		end
	end
end


-- ===== pool de inimigos (doc 4.7: object pooling obrigatório, nunca Instantiate/Destroy por onda) =====
local poolFolder = Instance.new("Folder")
poolFolder.Name = "EnemyPool"
poolFolder.Parent = ServerStorage

local activeEnemies = {} -- set [model] = true
local bossModel = nil -- criado 1x no boot, guardado em ServerStorage fora do pool comum

local function makeEnemyRig(name)
	local m = Instance.new("Model")
	m.Name = name
	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(2, 2, 1)
	hrp.Transparency = 1
	hrp.CanCollide = true
	hrp.CFrame = CFrame.new(0, 3, 0)
	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.Color = Color3.fromRGB(120, 40, 40)
	torso.CanCollide = false
	torso.CFrame = hrp.CFrame
	local head = Instance.new("Part")
	head.Name = "Head"
	head.Shape = Enum.PartType.Ball
	head.Size = Vector3.new(1.4, 1.4, 1.4)
	head.Color = Color3.fromRGB(160, 60, 60)
	head.CanCollide = false
	head.CFrame = hrp.CFrame * CFrame.new(0, 1.7, 0)
	local w1 = Instance.new("WeldConstraint")
	w1.Part0 = hrp; w1.Part1 = torso; w1.Parent = hrp
	local w2 = Instance.new("WeldConstraint")
	w2.Part0 = hrp; w2.Part1 = head; w2.Parent = hrp
	hrp.Parent = m; torso.Parent = m; head.Parent = m
	m.PrimaryPart = hrp
	local hum = Instance.new("Humanoid")
	hum.MaxHealth = 100000 -- HP real é o atributo; Humanoid é só locomoção
	hum.Health = 100000
	hum.WalkSpeed = ENEMY_WALKSPEED
	hum.HipHeight = 0
	hum.RequiresNeck = false
	hum.BreakJointsOnDeath = false
	hum.Parent = m
	m:SetAttribute("HP", ENEMY_MAX_HP)
	m:SetAttribute("MaxHP", ENEMY_MAX_HP)
	m:SetAttribute("Dmg", ENEMY_DMG_PLAYER)
	m:SetAttribute("BarricadeDmg", ENEMY_DMG_BARRICADE)
	m:SetAttribute("AttackRange", ENEMY_ATTACK_RANGE)
	m:SetAttribute("AttackCooldown", ENEMY_ATTACK_COOLDOWN)
	m:SetAttribute("TimesSpawned", 0)
	return m
end

local function makeBossRig()
	local m = Instance.new("Model")
	m.Name = "Boss"
	local hrp = Instance.new("Part")
	hrp.Name = "HumanoidRootPart"
	hrp.Size = Vector3.new(4, 4, 2)
	hrp.Transparency = 1
	hrp.CanCollide = true
	hrp.CFrame = CFrame.new(0, 5, 0)
	hrp.Parent = m
	local function bpart(name, size, cf, color, opts)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = Enum.Material.Slate
		p.CanCollide = false
		if opts then
			for k, v in pairs(opts) do p[k] = v end
		end
		local w = Instance.new("WeldConstraint")
		w.Part0 = hrp
		w.Part1 = p
		w.Parent = p
		p.Parent = m
		return p
	end
	bpart("Torso", Vector3.new(4, 4, 2), hrp.CFrame, Color3.fromRGB(45, 25, 55))
	bpart("Head", Vector3.new(2.6, 2.6, 2.6), hrp.CFrame * CFrame.new(0, 3.1, 0), Color3.fromRGB(60, 30, 70),
		{ Shape = Enum.PartType.Ball })
	bpart("OlhoOeste", Vector3.new(0.5, 0.5, 0.5), hrp.CFrame * CFrame.new(-0.55, 3.3, -1.15), Color3.fromRGB(255, 40, 40),
		{ Shape = Enum.PartType.Ball, Material = Enum.Material.Neon })
	bpart("OlhoLeste", Vector3.new(0.5, 0.5, 0.5), hrp.CFrame * CFrame.new(0.55, 3.3, -1.15), Color3.fromRGB(255, 40, 40),
		{ Shape = Enum.PartType.Ball, Material = Enum.Material.Neon })
	bpart("BracoOeste", Vector3.new(1.4, 3.8, 1.4), hrp.CFrame * CFrame.new(-2.8, -0.4, 0), Color3.fromRGB(40, 22, 50))
	bpart("BracoLeste", Vector3.new(1.4, 3.8, 1.4), hrp.CFrame * CFrame.new(2.8, -0.4, 0), Color3.fromRGB(40, 22, 50))
	m.PrimaryPart = hrp
	local hum = Instance.new("Humanoid")
	hum.MaxHealth = 100000 -- HP real é o atributo; Humanoid é só locomoção
	hum.Health = 100000
	hum.WalkSpeed = BOSS_WALKSPEED
	hum.HipHeight = 0
	hum.RequiresNeck = false
	hum.BreakJointsOnDeath = false
	hum.Parent = m
	m:SetAttribute("HP", BOSS_HP)
	m:SetAttribute("MaxHP", BOSS_HP)
	m:SetAttribute("Dmg", BOSS_DMG)
	m:SetAttribute("BarricadeDmg", BOSS_BARRICADE_DMG)
	m:SetAttribute("AttackRange", BOSS_ATTACK_RANGE)
	m:SetAttribute("AttackCooldown", BOSS_ATTACK_COOLDOWN)
	return m
end

for i = 1, POOL_SIZE do
	makeEnemyRig("Enemy" .. i).Parent = poolFolder
end
poolFolder:SetAttribute("TotalCreated", POOL_SIZE)
bossModel = makeBossRig()
bossModel.Parent = ServerStorage
print("[One Way Caravan: Nightfall] Pool de inimigos criado: " .. POOL_SIZE .. " instancias + 1 boss (criados 1x no boot, reusados)")

local function countActive()
	local n = 0
	for _ in pairs(activeEnemies) do n += 1 end
	return n
end

local function syncEnemiesAlive()
	RS:SetAttribute("EnemiesAlive", countActive())
end

local function pickSpawnBase()
	-- pads da ZONA atual (EnemySpawns/<id>): no mundo contínuo cada POI tem os seus
	local folder = workspace:FindFirstChild("EnemySpawns")
	local zoneFolder = folder and CurrentZone and CurrentZone.id and folder:FindFirstChild(CurrentZone.id)
	local pads = zoneFolder and zoneFolder:GetChildren() or {}
	if #pads > 0 then
		return pads[math.random(#pads)].Position
	end
	local c = (CurrentZone and CurrentZone.center) or Vector3.zero
	return Vector3.new(c.X, 0, c.Z + 120)
end

local function activateEnemy(e, idx, basePos)
	e:SetAttribute("HP", e:GetAttribute("MaxHP") or ENEMY_MAX_HP)
	e:SetAttribute("LastAttack", 0)
	e:SetAttribute("TimesSpawned", (e:GetAttribute("TimesSpawned") or 0) + 1)
	local x = basePos.X + ((idx % 3) - 1) * 4
	local z = basePos.Z + math.floor(idx / 3) * 4
	e:PivotTo(CFrame.new(x, 3.5, z))
	e.Parent = enemiesFolder
	local hrp = e.PrimaryPart
	if hrp then
		hrp.AssemblyLinearVelocity = Vector3.zero
		pcall(function()
			hrp:SetNetworkOwner(nil) -- física do inimigo fica no servidor (doc 4.1)
		end)
	end
	activeEnemies[e] = true
	syncEnemiesAlive()
end

local function returnToPool(e)
	activeEnemies[e] = nil
	if e == bossModel then
		e.Parent = ServerStorage
		RS:SetAttribute("BossHP", 0)
	else
		e.Parent = poolFolder
	end
	syncEnemiesAlive()
end

local function despawnAll()
	local list = {}
	for e in pairs(activeEnemies) do
		table.insert(list, e)
	end
	for _, e in ipairs(list) do
		returnToPool(e)
	end
	if #list > 0 then
		print("[One Way Caravan: Nightfall] " .. #list .. " inimigos retornaram ao pool")
	end
end

local function spawnWave(waveIdx, count)
	local basePos = pickSpawnBase()
	local spawned = 0
	for i = 1, count do
		local e = poolFolder:FindFirstChildOfClass("Model")
		if not e then
			print("[One Way Caravan: Nightfall] Pool esgotado; onda " .. waveIdx .. " parcial")
			break
		end
		activateEnemy(e, i, basePos)
		spawned += 1
	end
	local label = waveIdx > 0 and ("Onda " .. waveIdx) or "Reforços do covil"
	print(string.format("[One Way Caravan: Nightfall] %s: %d inimigos ativados do pool (pool restante: %d, ativos: %d)", label, spawned, #poolFolder:GetChildren(), countActive()))
end

-- ===== morte de inimigo =====
local function killEnemy(e, byPlr)
	enemyDiedRE:FireAllClients(e.Name)
	print("[One Way Caravan: Nightfall] " .. e.Name .. " morreu" .. (byPlr and (" (por " .. byPlr.Name .. ")") or ""))
	returnToPool(e)
end

-- ===== downed / revive (hold-button via ProximityPrompt nativo) =====
local function revive(plr, char, hum, prompt)
	plr:SetAttribute("Downed", false)
	hum.Health = 50
	hum.WalkSpeed = 16
	hum.JumpPower = 50
	hum.PlatformStand = false
	if prompt then prompt:Destroy() end
	print("[One Way Caravan: Nightfall] " .. plr.Name .. " foi reanimado")
end

local function makeDowned(plr, char, hum)
	plr:SetAttribute("Downed", true)
	hum.Health = DOWNED_HP
	hum.WalkSpeed = 0
	hum.JumpPower = 0
	hum.PlatformStand = true
	local hrp = char:FindFirstChild("HumanoidRootPart")
	if hrp then
		local prompt = Instance.new("ProximityPrompt")
		prompt.Name = "RevivePrompt"
		prompt.ActionText = "Reviver"
		prompt.ObjectText = plr.Name
		prompt.HoldDuration = 4
		prompt.RequiresLineOfSight = false
		prompt.MaxActivationDistance = 8
		prompt.Parent = hrp
		prompt.Triggered:Connect(function(reviver)
			-- reanimar é ação de colega; solo (1 jogador) pode se auto-reanimar p/ não travar a run
			if reviver ~= plr or #Players:GetPlayers() == 1 then
				revive(plr, char, hum, prompt)
			end
		end)
	end
	playerDownedRE:FireAllClients(plr.Name)
	print("[One Way Caravan: Nightfall] " .. plr.Name .. " caiu — segure o botão de reviver por perto")
	checkWipe()
end

-- ===== IA de inimigo (doc 4.8: alvo = jogador vivo mais próximo, repath com throttle) =====
local function nearestTarget(pos)
	local best, bestDist = nil, math.huge
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if hrp and hum and hum.Health > 0 and not plr:GetAttribute("Downed") then
			local d = (hrp.Position - pos).Magnitude
			if d < bestDist then
				best, bestDist = hrp, d
			end
		end
	end
	return best
end

local function blockingBarricade(fromPos, toPos)
	local dir = toPos - fromPos
	if dir.Magnitude < 0.05 then return nil end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { structuresFolder }
	local hit = workspace:Raycast(fromPos, dir, params)
	if hit and hit.Instance then
		local model = hit.Instance:FindFirstAncestorOfClass("Model")
		if model and model:GetAttribute("IsBarricade") then
			return model, hit.Position
		end
	end
	return nil
end

local function attackReady(e)
	local cooldown = e:GetAttribute("AttackCooldown") or ENEMY_ATTACK_COOLDOWN
	if os.clock() - (e:GetAttribute("LastAttack") or 0) < cooldown then
		return false
	end
	e:SetAttribute("LastAttack", os.clock())
	return true
end

local function tryAttackBarricade(e, barr)
	if not attackReady(e) then return end
	local dmg = e:GetAttribute("BarricadeDmg") or ENEMY_DMG_BARRICADE
	local maxHp = barr:GetAttribute("MaxHP") or BARRICADE_HP
	local hp = (barr:GetAttribute("HP") or 0) - dmg
	barr:SetAttribute("HP", hp)
	local body = barr.PrimaryPart
	if body then
		local baseColor = barr:GetAttribute("BaseColor") or BARRICADE_COLOR
		body.Color = BARRICADE_COLOR_BROKEN:Lerp(baseColor, math.clamp(hp / maxHp, 0, 1))
	end
	if hp <= 0 then
		print("[One Way Caravan: Nightfall] Barricada destruida — caminho aberto")
		barr:Destroy() -- doc Seção 2: sem fortificação, barricada destruída some
	end
end

local function tryAttackPlayer(e, char)
	if not attackReady(e) then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local plr = Players:GetPlayerFromCharacter(char)
	if not (hum and plr) or plr:GetAttribute("Downed") then return end
	local dmg = e:GetAttribute("Dmg") or ENEMY_DMG_PLAYER
	if hum.Health - dmg <= DOWNED_HP then
		makeDowned(plr, char, hum)
	else
		hum:TakeDamage(dmg)
	end
end

local function stepEnemy(e)
	local hum = e:FindFirstChildOfClass("Humanoid")
	local hrp = e.PrimaryPart
	if not (hum and hrp) then return end
	local targetHrp = nearestTarget(hrp.Position)
	local targetPos = targetHrp and targetHrp.Position or campPos()
	local range = e:GetAttribute("AttackRange") or ENEMY_ATTACK_RANGE

	-- funil do canyon (se a zona tiver um): linha reta cruza a crista fora da passagem -> mira a passagem
	local desired = targetPos
	local ridgeZ = CurrentZone and CurrentZone.ridgeZ
	if ridgeZ then
		local ez, tz = hrp.Position.Z, targetPos.Z
		if (ez - ridgeZ) * (tz - ridgeZ) < 0 then
			local t = (ridgeZ - ez) / (tz - ez)
			local xCross = hrp.Position.X + (targetPos.X - hrp.Position.X) * t
			-- comparação relativa ao X da passagem (POIs têm offset no mundo contínuo)
			if math.abs(xCross - CurrentZone.gapPos.X) > 4 then
				desired = CurrentZone.gapPos
			end
		end
	end

	local barr, hitPos = blockingBarricade(hrp.Position, desired)
	if barr and hitPos then
		if (hitPos - hrp.Position).Magnitude <= range + 1 then
			hum:MoveTo(hrp.Position) -- parado atacando a barricada
			tryAttackBarricade(e, barr)
		else
			hum:MoveTo(hitPos)
		end
	else
		hum:MoveTo(desired)
		if desired == targetPos and targetHrp and (targetHrp.Position - hrp.Position).Magnitude <= range then
			tryAttackPlayer(e, targetHrp.Parent)
		end
	end
end

task.spawn(function()
	while true do
		task.wait(AI_TICK)
		for e in pairs(activeEnemies) do
			stepEnemy(e)
		end
	end
end)

-- ===== estruturas =====
local function groundYAt(x, z)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = true -- ignora marcadores/pads decorativos sem colisão
	local exclude = { structuresFolder, enemiesFolder }
	local caravana = workspace:FindFirstChild("Caravana")
	if caravana then table.insert(exclude, caravana) end
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then table.insert(exclude, p.Character) end
	end
	params.FilterDescendantsInstances = exclude
	local hit = workspace:Raycast(Vector3.new(x, 60, z), Vector3.new(0, -120, 0), params)
	return hit and hit.Position.Y or 0
end

-- rejeita colocar uma estrutura em cima de um jogador (evita noclip/soft-lock em paredes)
local function overlapsCharacter(cf, size)
	local padXZ = 2.5 -- raio aproximado do personagem + folga
	for _, plr in ipairs(Players:GetPlayers()) do
		local char = plr.Character
		local hrp = char and char:FindFirstChild("HumanoidRootPart")
		if hrp then
			local lp = cf:PointToObjectSpace(hrp.Position)
			if math.abs(lp.X) < size.X / 2 + padXZ
				and math.abs(lp.Z) < size.Z / 2 + padXZ
				and math.abs(lp.Y) < size.Y / 2 + 4 then
				return true
			end
		end
	end
	return false
end

-- retorna o Model criado, ou nil se a posição está bloqueada (o handler não debita recurso nesse caso)
local function buildStructure(structType, groundPos, lookDir)
	local gy = groundYAt(groundPos.X, groundPos.Z)
	local isBarricade = structType == "Barricada" or structType == "BarricadaReforcada"

	-- computa posição/volume ANTES de criar, pra validar sobreposição com jogadores
	local cf, size
	if isBarricade then
		size = Vector3.new(10, 7, 2)
		local at = Vector3.new(groundPos.X, gy + 3.5, groundPos.Z)
		if lookDir and lookDir.Magnitude > 0.05 then
			cf = CFrame.lookAt(at, at + lookDir) -- parede perpendicular a onde o jogador olha
		else
			cf = CFrame.new(at)
		end
	else -- Fogueira: volume aproximado pra checagem
		size = Vector3.new(4, 4, 4)
		cf = CFrame.new(groundPos.X, gy + 2, groundPos.Z)
	end
	if overlapsCharacter(cf, size) then
		return nil
	end

	local m = Instance.new("Model")
	m.Name = structType
	m:SetAttribute("StructureType", structType)
	if isBarricade then
		local reinforced = structType == "BarricadaReforcada"
		local hp = reinforced and BARRICADE_REINFORCED_HP or BARRICADE_HP
		local baseColor = reinforced and BARRICADE_REINFORCED_COLOR or BARRICADE_COLOR
		local p = Instance.new("Part")
		p.Name = "Body"
		p.Size = size
		p.CFrame = cf
		p.Anchored = true
		p.Color = baseColor
		p.Material = Enum.Material.WoodPlanks
		p.Parent = m
		if reinforced then
			for _, dy in ipairs({ -1.8, 1.8 }) do
				local band = Instance.new("Part")
				band.Name = "Reforco"
				band.Size = Vector3.new(10.2, 0.6, 2.2)
				band.CFrame = p.CFrame * CFrame.new(0, dy, 0)
				band.Anchored = true
				band.CanCollide = false
				band.Color = Color3.fromRGB(140, 140, 150)
				band.Material = Enum.Material.Metal
				band.Parent = m
			end
		end
		m.PrimaryPart = p
		m:SetAttribute("IsBarricade", true)
		m:SetAttribute("BaseColor", baseColor)
		m:SetAttribute("HP", hp)
		m:SetAttribute("MaxHP", hp)
	else -- Fogueira
		local base = Instance.new("Part")
		base.Name = "Base"
		base.Shape = Enum.PartType.Cylinder
		base.Size = Vector3.new(1, 4, 4)
		base.CFrame = CFrame.new(groundPos.X, gy + 0.5, groundPos.Z) * CFrame.Angles(0, 0, math.rad(90))
		base.Anchored = true
		base.Color = Color3.fromRGB(90, 90, 90)
		base.Material = Enum.Material.Slate
		base.Parent = m
		local flame = Instance.new("Part")
		flame.Name = "Flame"
		flame.Shape = Enum.PartType.Ball
		flame.Size = Vector3.new(2, 2, 2)
		flame.Position = Vector3.new(groundPos.X, gy + 2, groundPos.Z)
		flame.Anchored = true
		flame.CanCollide = false
		flame.Color = Color3.fromRGB(255, 140, 30)
		flame.Material = Enum.Material.Neon
		flame.Parent = m
		local fire = Instance.new("Fire")
		fire.Size = 6
		fire.Heat = 9
		fire.Parent = flame
		local light = Instance.new("PointLight")
		light.Color = Color3.fromRGB(255, 160, 60)
		light.Range = 24
		light.Brightness = 2
		light.Parent = flame
		m.PrimaryPart = base
	end
	m.Parent = structuresFolder
	return m
end

-- ===== handlers de remotes (validação total server-side, doc 4.1) =====
collectRE.OnServerEvent:Connect(function(plr, node)
	if not rateOk(plr, "Collect") then return end
	if plr:GetAttribute("Downed") then return end
	if typeof(node) ~= "Instance" then return end
	if not node:IsDescendantOf(resourceNodes) then return end
	local kind = node:GetAttribute("NodeType")
	if kind ~= "Wood" and kind ~= "Food" then return end
	local uses = node:GetAttribute("Uses") or 0
	if uses <= 0 then return end
	local char = plr.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	local pos = node:IsA("Model") and node:GetPivot().Position or node.Position
	if (pos - hrp.Position).Magnitude > COLLECT_RANGE then return end
	node:SetAttribute("Uses", uses - 1)
	addResource(plr, kind, kind == "Wood" and WOOD_PER_COLLECT or FOOD_PER_COLLECT)
	if uses - 1 <= 0 then
		local parts = node:IsA("Model") and node:GetDescendants() or { node }
		for _, p in ipairs(parts) do
			if p:IsA("BasePart") then p.Transparency = 0.7 end
		end
	end
end)

damageRE.OnServerEvent:Connect(function(plr)
	if not rateOk(plr, "Damage") then return end
	local char = plr.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not (hrp and hum) or hum.Health <= 0 then return end
	if plr:GetAttribute("Downed") then return end
	if not char:FindFirstChild("Machado") then return end -- arma precisa estar equipada
	local nearest, nd = nil, WEAPON_RANGE
	for e in pairs(activeEnemies) do
		local ehrp = e.PrimaryPart
		if ehrp then
			local d = (ehrp.Position - hrp.Position).Magnitude
			if d <= nd then
				nearest, nd = e, d
			end
		end
	end
	if not nearest then return end
	local hp = (nearest:GetAttribute("HP") or 0) - WEAPON_DMG
	nearest:SetAttribute("HP", hp)
	if nearest == bossModel then
		RS:SetAttribute("BossHP", math.max(hp, 0))
	end
	if hp <= 0 then
		killEnemy(nearest, plr)
	end
end)

placeRE.OnServerEvent:Connect(function(plr, structType, pos)
	if not rateOk(plr, "Place") then return end
	if plr:GetAttribute("Downed") then return end
	if type(structType) ~= "string" or typeof(pos) ~= "Vector3" then return end
	local cost = COSTS[structType]
	if not cost then return end
	-- construção de catálogo exige o unlock no perfil (doc 5.2; passo 9)
	if CATALOG[structType] and plr:GetAttribute("Unlock_" .. structType) ~= true then return end
	local char = plr.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	if (pos - hrp.Position).Magnitude > PLACE_RANGE then return end
	if not rectContains(WORLD_BOUNDS, pos) then return end
	local r = resources[plr]
	if not r then return end
	for kind, amt in pairs(cost) do
		if (r[kind] or 0) < amt then return end
	end
	-- constrói primeiro; só debita se a posição não estava bloqueada por um jogador
	local look = hrp.CFrame.LookVector
	local built = buildStructure(structType, Vector3.new(pos.X, pos.Y, pos.Z), Vector3.new(look.X, 0, look.Z))
	if not built then
		announceRE:FireClient(plr, "Não dá pra construir aí — muito perto de alguém.")
		return
	end
	for kind, amt in pairs(cost) do
		r[kind] -= amt
		plr:SetAttribute(kind, r[kind])
	end
	print("[One Way Caravan: Nightfall] " .. plr.Name .. " construiu " .. structType)
end)

eatRE.OnServerEvent:Connect(function(plr)
	if not rateOk(plr, "Eat") then return end
	if plr:GetAttribute("Downed") then return end
	local char = plr.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then return end
	if hum.Health >= hum.MaxHealth then return end
	local r = resources[plr]
	if not r or (r.Food or 0) < 1 then return end
	r.Food -= 1
	plr:SetAttribute("Food", r.Food)
	hum.Health = math.min(hum.MaxHealth, hum.Health + HEAL_PER_FOOD)
end)

buyRE.OnServerEvent:Connect(function(plr, itemId)
	if not rateOk(plr, "Buy") then return end
	if RS:GetAttribute("Phase") ~= "Lobby" then return end -- catálogo é compra de lobby (doc 5.2)
	if type(itemId) ~= "string" then return end
	local item = CATALOG[itemId]
	if not item then return end
	local ok, err = ProfileManager.tryBuy(plr, itemId, item.price)
	if ok then
		announceRE:FireClient(plr, "Desbloqueado: " .. item.name .. "! Vale pra todas as próximas runs.")
		print("[One Way Caravan: Nightfall] " .. plr.Name .. " comprou " .. itemId)
	else
		announceRE:FireClient(plr, "Compra falhou: " .. tostring(err))
	end
end)

-- ===== ambiente / fases =====
local function applyDayAmbience()
	Lighting.OutdoorAmbient = Color3.fromRGB(128, 128, 128)
	Lighting.Brightness = 2
	atmosphere.Density = 0.3
end

local function applyDuskAmbience()
	Lighting.OutdoorAmbient = Color3.fromRGB(150, 96, 74)
	Lighting.Brightness = 1.4
	atmosphere.Density = 0.5
end

local function applyNightAmbience()
	Lighting.OutdoorAmbient = Color3.fromRGB(90, 95, 128)
	Lighting.Brightness = 1
	atmosphere.Density = 0.42
end

local function transitionClock(from, to, dur)
	local steps = math.max(1, math.floor(dur / 0.05))
	for i = 1, steps do
		Lighting.ClockTime = (from + (to - from) * i / steps) % 24
		task.wait(0.05)
	end
end

local function respawnResources()
	-- novo dia no mesmo nó = recursos repõem (suporta a permanência do doc 5.4)
	for _, node in ipairs(resourceNodes:GetDescendants()) do
		if node:GetAttribute("NodeType") then
			node:SetAttribute("Uses", node:GetAttribute("MaxUses") or node:GetAttribute("Uses") or 0)
			local parts = node:IsA("Model") and node:GetDescendants() or { node }
			for _, p in ipairs(parts) do
				if p:IsA("BasePart") then p.Transparency = 0 end
			end
		end
	end
end

local nightCount = 0

-- cutscene de anoitecer (doc 4.5/5.4): o sol se põe, a lua sobe e a caravana trava no lugar até
-- o amanhecer. Dispara ao fim da janela de preparação, nunca instantaneamente na chegada.
local function nightfallCutscene()
	RS:SetAttribute("Phase", "Anoitecer")
	RS:SetAttribute("PhaseTimeLeft", 0)
	ZoneBuilder.setCaravanaLocked(true) -- vira acampamento fixo até o amanhecer
	announce("O sol se põe e a lua sobe. A caravana para — segurem a linha até o amanhecer.")
	applyDuskAmbience()
	transitionClock(12, 18, 3) -- tarde -> pôr do sol
	applyNightAmbience()
	transitionClock(18, 24, 4) -- crepúsculo -> lua no alto
end

local function nightPhase(waveBonus)
	nightCount += 1
	RS:SetAttribute("Cycle", nightCount)
	RS:SetAttribute("Phase", "Noite")
	ZoneBuilder.setCaravanaLocked(true) -- a caravana vira acampamento fixo até o amanhecer (doc 5.4)
	applyNightAmbience()
	print("[One Way Caravan: Nightfall] === NOITE " .. nightCount .. " (bônus de onda: " .. waveBonus .. ") ===")
	local waveIdx = 1
	local t0 = os.clock()
	while true do
		if runState.defeated then break end
		local elapsed = os.clock() - t0
		if elapsed >= NIGHT_LENGTH then break end
		RS:SetAttribute("PhaseTimeLeft", math.ceil(NIGHT_LENGTH - elapsed))
		if waveIdx <= #WAVES and elapsed >= WAVES[waveIdx].time then
			local count = math.clamp(WAVES[waveIdx].count + waveBonus, 1, WAVE_MAX_COUNT)
			spawnWave(waveIdx, count)
			waveIdx += 1
		end
		task.wait(0.5)
	end
	despawnAll()
	if not runState.defeated then
		-- recompensa fixa por noite sobrevivida, travada no valor-base (doc 5.4/5.8)
		runCurrency += NIGHT_REWARD
		syncCurrency()
		announce("Noite sobrevivida! +" .. NIGHT_REWARD .. " de moeda pro grupo (total: " .. runCurrency .. ").")
	end
end

-- janela de preparação ao CHEGAR num POI novo (doc 4.5/5.4): abre a coleta/construção antes da
-- primeira noite ali; a noite cai por timer OU por um gatilho do grupo (prompt na caravana),
-- nunca instantaneamente na chegada. Retorna sem cair a noite se a run acabou.
local function preparationPhase()
	RS:SetAttribute("Phase", "Preparação")
	applyDayAmbience()
	Lighting.ClockTime = 12 -- a viagem já consumiu a manhã; a chegada segue do meio-dia
	respawnResources()
	print("[One Way Caravan: Nightfall] === PREPARAÇÃO (janela antes da noite) ===")
	announce("Dia de preparação: coletem e construam. Convoquem a noite na caravana quando prontos.")

	-- gatilho do grupo: prompt na caravana pra convocar a noite antes do fim do timer
	local summoned = false
	local prompt
	local caravana = workspace:FindFirstChild("Caravana")
	if caravana and caravana.PrimaryPart then
		prompt = Instance.new("ProximityPrompt")
		prompt.Name = "ConvocarNoite"
		prompt.ActionText = "Convocar a noite"
		prompt.ObjectText = "Caravana"
		prompt.HoldDuration = 1.5
		prompt.RequiresLineOfSight = false
		prompt.MaxActivationDistance = 16
		prompt.Parent = caravana.PrimaryPart
		prompt.Triggered:Connect(function()
			summoned = true
		end)
	end

	for t = PREP_LENGTH, 1, -1 do
		if runState.defeated or summoned then
			break
		end
		RS:SetAttribute("PhaseTimeLeft", t)
		task.wait(1)
	end
	if prompt then
		prompt:Destroy()
	end
	if summoned and not runState.defeated then
		announce("O grupo convocou a noite.")
	end
end

-- desmonta as estruturas plantadas na faixa da estrada (o funil) pra caravana poder sair.
-- Só é chamado quando a caravana de fato AVANÇA pelo funil — durante a permanência a barricada
-- fica de pé (defesa repetida no mesmo POI).
local function clearExitLaneStructures()
	local cx = (CurrentZone and CurrentZone.center and CurrentZone.center.X) or 0
	for _, s in ipairs(structuresFolder:GetChildren()) do
		local pp = s.PrimaryPart
		if pp and math.abs(pp.Position.X - cx) < 8 then
			s:Destroy()
		end
	end
end

-- ===== dia livre + decisão implícita por posição (passo 6, doc 5.4 rev.3) =====
-- Substitui a votação: ao amanhecer a caravana DESTRAVA e o grupo é livre. A posição física
-- decide sem UI de voto — chegar num POI novo = avançar; ficar dentro dos limites do POI atual
-- até o dia acabar = permanência. Retorna:
--   "advance", <id>  -> chegaram fisicamente num POI novo
--   "stay"           -> ficaram no POI atual até a noite voltar
--   "defeated"       -> a run acabou durante o dia
local function freeDayWindow(currentId)
	RS:SetAttribute("Phase", "Dia")
	applyDayAmbience()
	transitionClock(0, 12, 5) -- amanhecer
	respawnResources()
	ZoneBuilder.setCaravanaLocked(false) -- livre pra dirigir (ou ficar parado no POI)
	announce("Amanheceu. Fiquem por outra noite ou dirijam pro próximo ponto — a estrada decide.")

	local dayStart = os.clock()
	local clearedExit = false -- limpa o funil só quando a caravana avança por ele
	while not runState.defeated do
		tryForkCommit()
		local p = campPos()
		-- avançando pelo funil: some com a própria barricada da faixa antes que ela prenda a caravana
		-- (durante a permanência a caravana fica no camp, ao sul do funil, e a barricada é preservada)
		local ridgeZ = CurrentZone and CurrentZone.ridgeZ
		if not clearedExit and ridgeZ and p.Z >= ridgeZ - 15 then
			clearExitLaneStructures()
			clearedExit = true
		end
		-- chegou em POI novo? -> avançar (contador de permanência reseta no próximo POI)
		for id, zone in pairs(RunWorld.zones) do
			if id ~= currentId and not ZoneBuilder.isGroupDestroyed(id) and rectContains(zone.arrivalRect, p) then
				return "advance", id
			end
		end
		local remaining = DAY_LENGTH - (os.clock() - dayStart)
		if remaining <= 0 then
			-- o dia acabou: se a caravana ainda está no POI atual, é permanência; se saiu (em
			-- trânsito), a noite espera até chegarem no próximo POI (doc 5.4: "já fora = avançou")
			local cur = RunWorld.zones[currentId]
			if cur and rectContains(cur.bounds, p) then
				return "stay"
			end
			RS:SetAttribute("PhaseTimeLeft", 0)
		else
			RS:SetAttribute("PhaseTimeLeft", math.ceil(remaining))
		end
		task.wait(0.3)
	end
	return "defeated"
end

-- ===== boss (passo 8): a ameaça sai do covil e vem pelo funil =====
local function bossPhase()
	RS:SetAttribute("Phase", "Boss")
	RS:SetAttribute("PhaseTimeLeft", 0)
	applyNightAmbience()
	transitionClock(12, 24, 5)
	announce("Algo enorme desperta no covil. Segurem a linha!")

	bossModel:SetAttribute("HP", BOSS_HP)
	bossModel:SetAttribute("LastAttack", 0)
	RS:SetAttribute("BossMaxHP", BOSS_HP)
	RS:SetAttribute("BossHP", BOSS_HP)
	local covil = (CurrentZone and CurrentZone.covilPos) or Vector3.new(0, 5, 142)
	bossModel:PivotTo(CFrame.new(covil)) -- na boca do covil, atrás do funil
	bossModel.Parent = enemiesFolder
	local hrp = bossModel.PrimaryPart
	if hrp then
		hrp.AssemblyLinearVelocity = Vector3.zero
		pcall(function()
			hrp:SetNetworkOwner(nil)
		end)
	end
	activeEnemies[bossModel] = true
	syncEnemiesAlive()

	local nextAdds = os.clock() + BOSS_ADDS_INTERVAL
	while true do
		task.wait(0.5)
		if runState.defeated then
			return false
		end
		if not activeEnemies[bossModel] then
			-- boss morto: recompensa + checkpoint (doc 5.8: cada boss salva a moeda acumulada)
			runCurrency += BOSS_REWARD
			checkpointCurrency = runCurrency
			syncCurrency()
			announce("Boss derrotado! +" .. BOSS_REWARD .. " de moeda. Checkpoint salvo: " .. checkpointCurrency .. ".")
			return true
		end
		if os.clock() >= nextAdds then
			spawnWave(0, BOSS_ADDS_COUNT)
			nextAdds = os.clock() + BOSS_ADDS_INTERVAL
		end
		RS:SetAttribute("BossHP", math.max(bossModel:GetAttribute("HP") or 0, 0))
	end
end

-- ===== fim de run (doc 4.4/5.8: vitória = total; derrota = o que estava salvo no checkpoint) =====
local function endRun(victory)
	despawnAll()
	local earned = victory and runCurrency or checkpointCurrency
	-- doc 4.4: a moeda vira dado persistente SÓ no fim da run (vitória = total; derrota = checkpoint)
	for _, plr in ipairs(Players:GetPlayers()) do
		ProfileManager.addCurrency(plr, earned)
	end
	RS:SetAttribute("Phase", victory and "Vitória" or "Derrota")
	RS:SetAttribute("PhaseTimeLeft", 0)
	runEndedRE:FireAllClients({
		victory = victory,
		nights = nightCount,
		currency = runCurrency,
		checkpoint = checkpointCurrency,
		earned = earned,
	})
	if victory then
		announce("VITÓRIA! A caravana cruzou a rota. " .. earned .. " de moeda creditada no perfil de cada um.")
	else
		announce("Fim da run. Moeda do checkpoint creditada no perfil: " .. earned .. ". De volta ao lobby em " .. RUN_RESTART_DELAY .. "s...")
	end
	task.wait(RUN_RESTART_DELAY)
end

local function resetPlayersForNewRun()
	for _, plr in ipairs(Players:GetPlayers()) do
		local r = resources[plr]
		if r then
			r.Wood, r.Food = 0, 0
			plr:SetAttribute("Wood", 0)
			plr:SetAttribute("Food", 0)
		end
		plr:SetAttribute("Downed", false)
		pcall(function()
			plr:LoadCharacter()
		end)
	end
end

-- ===== loop lobby -> run (passo 9: meta-loop; lobby lógico no mesmo place até o publish em 2 places, doc 4.2) =====
task.spawn(function()
	ZoneBuilder.buildCaravana()
	while true do
		-- LOBBY: gastar moeda do perfil no catálogo e partir quando o grupo quiser
		ZoneBuilder.setCaravanaLocked(true)
		ZoneBuilder.unseatAll()
		local lobby = ZoneBuilder.buildLobby()
		CurrentZone = lobby
		ZoneBuilder.pivotCaravanaTo(lobby.caravanaCf)
		runCurrency, checkpointCurrency, nightCount = 0, 0, 0
		syncCurrency()
		RS:SetAttribute("Phase", "Lobby")
		RS:SetAttribute("NodeName", "Posto de Partida")
		RS:SetAttribute("PhaseTimeLeft", 0)
		RS:SetAttribute("BossHP", 0)
		RS:SetAttribute("Cycle", 0)
		RS:SetAttribute("EnemiesAlive", 0)
		applyDayAmbience()
		Lighting.ClockTime = 12
		resetPlayersForNewRun()
		task.wait(1)
		teleportPlayersBehindCaravana()
		announce("Lobby: gastem a moeda no catálogo (painel à direita) e segurem o poste de partida quando estiverem prontos.")

		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Iniciar expedição"
		prompt.ObjectText = "Caravana pronta"
		prompt.HoldDuration = 2
		prompt.RequiresLineOfSight = false
		prompt.MaxActivationDistance = 12
		prompt.Parent = lobby.startPost
		local started = false
		prompt.Triggered:Connect(function()
			started = true
		end)
		while not started do
			task.wait(0.5)
		end
		prompt:Destroy()
		announce("A expedição parte!")
		task.wait(1.5)

		-- SETUP DA RUN: o mundo contínuo inteiro é montado de uma vez (doc 4.6); StreamingEnabled
		-- carrega/descarrega geometria por proximidade. O fade aqui cobre SÓ a fronteira lobby->run
		-- (placeholder do TeleportService entre places, doc 4.2), não uma troca de zona interna.
		local graph = RouteGraph.generate()
		ZoneBuilder.unseatAll()
		zoneFadeRE:FireAllClients(true)
		task.wait(0.7)
		RunWorld = ZoneBuilder.buildWorld(graph)
		local currentId = graph.currentId
		local node = graph.nodes[currentId]
		CurrentZone = RunWorld.zones[currentId]
		ZoneBuilder.setCaravanaLocked(true)
		ZoneBuilder.moveSpawnLocation(CurrentZone.spawnPos)
		ZoneBuilder.pivotCaravanaTo(CurrentZone.campCf)
		teleportPlayersBehindCaravana()
		zoneFadeRE:FireAllClients(false)
		RS:SetAttribute("NodeName", node.label)
		runState.defeated = false
		runState.active = true

		-- ===== percurso do POI (passo 6: sem votação; permanência/avanço por posição) =====
		-- Cada POI: janela de preparação (chegada) -> 1ª noite (base) -> loop de dia livre. No dia
		-- livre a caravana destrava; ficar no POI até a noite voltar = permanência (+dificuldade,
		-- recompensa base); dirigir até o próximo POI = avanço (contador reseta). Boss = terminal.
		local victory = false
		while true do
			-- chegada: janela de preparação, depois a 1ª noite naquele POI (sem bônus de permanência)
			preparationPhase()
			if runState.defeated then break end
			if node.kind == "boss" then
				victory = bossPhase() -- o covil é a noite final; sem loop de permanência
				break
			end
			nightfallCutscene()
			if runState.defeated then break end
			nightPhase(POI_DIFFICULTY[node.kind] or 0)
			if runState.defeated then break end

			-- permanência vs avanço decidido pela posição da caravana (doc 5.4 rev.3)
			local advanced = false
			local stays = 0 -- noites extras neste POI; a recompensa fica travada no valor-base
			while not runState.defeated do
				local ev, arrivedId = freeDayWindow(currentId)
				if ev == "advance" then
					currentId = arrivedId
					node = graph.nodes[currentId]
					CurrentZone = RunWorld.zones[currentId]
					ZoneBuilder.setCaravanaLocked(true)
					ZoneBuilder.moveSpawnLocation(CurrentZone.spawnPos)
					RS:SetAttribute("NodeName", node.label)
					announce("Chegando: " .. node.label .. ". A chegada abre o dia de preparação.")
					advanced = true
					break
				elseif ev == "stay" then
					stays += 1
					announce("Permanência: a noite que vem aqui é +" .. stays .. " de dificuldade (recompensa igual).")
					nightfallCutscene()
					if runState.defeated then break end
					nightPhase((POI_DIFFICULTY[node.kind] or 0) + stays)
				else
					break -- defeated
				end
			end
			if not advanced then
				break -- derrota
			end
		end

		runState.active = false
		endRun(victory)
	end
end)

print("[One Way Caravan: Nightfall] Servidor inicializado")
