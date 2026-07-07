-- One Way Caravan: Nightfall — MVP servidor autoritativo (design doc v2: Seções 2, 3.1, 4, 6.1–6.6)
-- Toda autoridade de HP, recursos, spawn, dano e morte vive AQUI.
-- Cliente só envia intenção via RemoteEvents validados e rate-limitados.

local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Lighting = game:GetService("Lighting")

-- ===== config =====
local DAY_LENGTH = 90
local NIGHT_LENGTH = 120
local WAVES = { -- 3 ondas por noite, escalando em contagem
	{ time = 6, count = 3 },
	{ time = 45, count = 4 },
	{ time = 80, count = 5 },
}
local WAVE_BONUS_PER_NIGHT = 1 -- +1 inimigo por onda a cada noite no mesmo nó (base p/ escalada por permanência, doc 5.4)
local WAVE_MAX_COUNT = 8
local POOL_SIZE = 24
local ENEMY_MAX_HP = 75
local ENEMY_WALKSPEED = 10
local ENEMY_DMG_PLAYER = 10
local ENEMY_DMG_BARRICADE = 5
local ENEMY_ATTACK_RANGE = 5
local ENEMY_ATTACK_COOLDOWN = 1.2
local AI_TICK = 0.6 -- repath com throttle (doc 4.8), nunca por frame
local WEAPON_DMG = 25
local WEAPON_RANGE = 10
local WOOD_PER_COLLECT = 2
local FOOD_PER_COLLECT = 1
local HEAL_PER_FOOD = 25
local COLLECT_RANGE = 14
local PLACE_RANGE = 35
local DOWNED_HP = 10
local MAP_LIMIT = 240 -- meio-lado do mapa gerado pelo build_map.lua
local RIDGE_Z = 30 -- crista do canyon; passagem única em x=0 (funil, doc 5.4)
local GAP_POS = Vector3.new(0, 3, RIDGE_Z)
local CAMP_FALLBACK = Vector3.new(0, 3, -47)
local MAX_HORIZ_SPEED = 60 -- sanity-check anti speed/teleport (doc 4.1); só horizontal p/ não punir queda
local COSTS = {
	Fogueira = { Wood = 5 },
	Barricada = { Wood = 10 },
}
local BARRICADE_HP = 250
local BARRICADE_COLOR = Color3.fromRGB(140, 100, 50)
local BARRICADE_COLOR_BROKEN = Color3.fromRGB(70, 45, 25)
local RATE_LIMIT = { Collect = 0.3, Damage = 0.2, Place = 0.5, Eat = 0.5 } -- rate-limit básico (doc 4.1)

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

-- acampamento = onde a caravana está (doc 4.5: a caravana é a "base que anda")
local function campPos()
	local caravana = workspace:FindFirstChild("Caravana")
	if caravana then
		return caravana:GetPivot().Position
	end
	return CAMP_FALLBACK
end

-- ===== recursos (contagem 100% server-side; atributo no Player é só espelho p/ UI) =====
local resources = {} -- [player] = { Wood = n, Food = n }

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
	plr:SetAttribute("Wood", 0)
	plr:SetAttribute("Food", 0)
	plr:SetAttribute("Downed", false)
	plr.CharacterAdded:Connect(function(char)
		plr:SetAttribute("Downed", false)
		disableNativeRegen(char)
	end)
	if plr.Character then
		disableNativeRegen(plr.Character)
	end
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
end)

-- ===== anti speed/teleport básico (doc 4.1): desloc. horizontal > MAX_HORIZ_SPEED studs/s volta o jogador =====
task.spawn(function()
	while true do
		task.wait(1)
		for _, plr in ipairs(Players:GetPlayers()) do
			local char = plr.Character
			local hrp = char and char:FindFirstChild("HumanoidRootPart")
			if hrp then
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
end)

-- ===== pool de inimigos (doc 4.7: object pooling obrigatório, nunca Instantiate/Destroy por onda) =====
local poolFolder = Instance.new("Folder")
poolFolder.Name = "EnemyPool"
poolFolder.Parent = ServerStorage

local activeEnemies = {} -- set [model] = true

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
	m:SetAttribute("TimesSpawned", 0)
	return m
end

for i = 1, POOL_SIZE do
	makeEnemyRig("Enemy" .. i).Parent = poolFolder
end
poolFolder:SetAttribute("TotalCreated", POOL_SIZE)
print("[One Way Caravan: Nightfall] Pool de inimigos criado: " .. POOL_SIZE .. " instancias (criadas 1x no boot, reusadas entre ondas)")

local function countActive()
	local n = 0
	for _ in pairs(activeEnemies) do n += 1 end
	return n
end

local function syncEnemiesAlive()
	RS:SetAttribute("EnemiesAlive", countActive())
end

local function pickSpawnBase()
	local folder = workspace:FindFirstChild("EnemySpawns")
	local pads = folder and folder:GetChildren() or {}
	if #pads > 0 then
		return pads[math.random(#pads)].Position
	end
	return Vector3.new(0, 0, 120)
end

local function activateEnemy(e, idx, basePos)
	e:SetAttribute("HP", ENEMY_MAX_HP)
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
	e.Parent = poolFolder
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
		print("[One Way Caravan: Nightfall] Amanheceu: " .. #list .. " inimigos retornaram ao pool")
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
	print(string.format("[One Way Caravan: Nightfall] Onda %d: %d inimigos ativados do pool (pool restante: %d, ativos: %d)", waveIdx, spawned, #poolFolder:GetChildren(), countActive()))
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
	if not hrp then return end
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
	playerDownedRE:FireAllClients(plr.Name)
	print("[One Way Caravan: Nightfall] " .. plr.Name .. " caiu — segure o botão de reviver por perto")
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
		if model and model:GetAttribute("StructureType") == "Barricada" then
			return model, hit.Position
		end
	end
	return nil
end

local function attackReady(e)
	if os.clock() - (e:GetAttribute("LastAttack") or 0) < ENEMY_ATTACK_COOLDOWN then
		return false
	end
	e:SetAttribute("LastAttack", os.clock())
	return true
end

local function tryAttackBarricade(e, barr)
	if not attackReady(e) then return end
	local maxHp = barr:GetAttribute("MaxHP") or BARRICADE_HP
	local hp = (barr:GetAttribute("HP") or 0) - ENEMY_DMG_BARRICADE
	barr:SetAttribute("HP", hp)
	local body = barr.PrimaryPart
	if body then
		-- feedback visual: escurece conforme apanha
		body.Color = BARRICADE_COLOR_BROKEN:Lerp(BARRICADE_COLOR, math.clamp(hp / maxHp, 0, 1))
	end
	if hp <= 0 then
		print("[One Way Caravan: Nightfall] Barricada destruida — caminho aberto")
		barr:Destroy() -- doc Seção 2: sem fortificação, barricada destruída some (pooling é só p/ inimigos)
	end
end

local function tryAttackPlayer(e, char)
	if not attackReady(e) then return end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local plr = Players:GetPlayerFromCharacter(char)
	if not (hum and plr) or plr:GetAttribute("Downed") then return end
	if hum.Health - ENEMY_DMG_PLAYER <= DOWNED_HP then
		makeDowned(plr, char, hum)
	else
		hum:TakeDamage(ENEMY_DMG_PLAYER)
	end
end

local function stepEnemy(e)
	local hum = e:FindFirstChildOfClass("Humanoid")
	local hrp = e.PrimaryPart
	if not (hum and hrp) then return end
	local targetHrp = nearestTarget(hrp.Position)
	local targetPos = targetHrp and targetHrp.Position or campPos()

	-- funil do canyon: se a linha reta até o alvo cruza a crista fora da passagem, mira a passagem primeiro
	local desired = targetPos
	local ez, tz = hrp.Position.Z, targetPos.Z
	if (ez - RIDGE_Z) * (tz - RIDGE_Z) < 0 then
		local t = (RIDGE_Z - ez) / (tz - ez)
		local xCross = hrp.Position.X + (targetPos.X - hrp.Position.X) * t
		if math.abs(xCross) > 4 then
			desired = GAP_POS
		end
	end

	local barr, hitPos = blockingBarricade(hrp.Position, desired)
	if barr and hitPos then
		if (hitPos - hrp.Position).Magnitude <= ENEMY_ATTACK_RANGE + 1 then
			hum:MoveTo(hrp.Position) -- parado atacando a barricada
			tryAttackBarricade(e, barr)
		else
			hum:MoveTo(hitPos)
		end
	else
		hum:MoveTo(desired)
		if desired == targetPos and targetHrp and (targetHrp.Position - hrp.Position).Magnitude <= ENEMY_ATTACK_RANGE then
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

local function buildStructure(structType, groundPos, lookDir)
	local m = Instance.new("Model")
	m.Name = structType
	m:SetAttribute("StructureType", structType)
	local gy = groundYAt(groundPos.X, groundPos.Z)
	if structType == "Barricada" then
		local p = Instance.new("Part")
		p.Name = "Body"
		p.Size = Vector3.new(10, 7, 2)
		local at = Vector3.new(groundPos.X, gy + 3.5, groundPos.Z)
		if lookDir and lookDir.Magnitude > 0.05 then
			p.CFrame = CFrame.lookAt(at, at + lookDir) -- parede perpendicular a onde o jogador olha
		else
			p.CFrame = CFrame.new(at)
		end
		p.Anchored = true
		p.Color = BARRICADE_COLOR
		p.Material = Enum.Material.WoodPlanks
		p.Parent = m
		m.PrimaryPart = p
		m:SetAttribute("HP", BARRICADE_HP)
		m:SetAttribute("MaxHP", BARRICADE_HP)
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
	local char = plr.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	if not hrp then return end
	if (pos - hrp.Position).Magnitude > PLACE_RANGE then return end
	if math.abs(pos.X) > MAP_LIMIT or math.abs(pos.Z) > MAP_LIMIT then return end
	local r = resources[plr]
	if not r then return end
	for kind, amt in pairs(cost) do
		if (r[kind] or 0) < amt then return end
	end
	for kind, amt in pairs(cost) do
		r[kind] -= amt
		plr:SetAttribute(kind, r[kind])
	end
	local look = hrp.CFrame.LookVector
	buildStructure(structType, Vector3.new(pos.X, pos.Y, pos.Z), Vector3.new(look.X, 0, look.Z))
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

-- ===== ciclo dia/noite =====
local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")

local function applyDayAmbience()
	Lighting.OutdoorAmbient = Color3.fromRGB(128, 128, 128)
	Lighting.Brightness = 2
	if atmosphere then atmosphere.Density = 0.3 end
end

local function applyNightAmbience()
	Lighting.OutdoorAmbient = Color3.fromRGB(90, 95, 128)
	Lighting.Brightness = 1
	if atmosphere then atmosphere.Density = 0.42 end
end

local function transitionClock(from, to, dur)
	local steps = math.max(1, math.floor(dur / 0.05))
	for i = 1, steps do
		Lighting.ClockTime = (from + (to - from) * i / steps) % 24
		task.wait(0.05)
	end
end

local function respawnResources()
	-- novo dia = nós de recurso repõem (suporta ficar mais noites no mesmo nó, doc 5.4)
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

task.spawn(function()
	local cycle = 1
	Lighting.ClockTime = 12
	while true do
		RS:SetAttribute("Phase", "Dia")
		RS:SetAttribute("Cycle", cycle)
		applyDayAmbience()
		if cycle > 1 then
			transitionClock(0, 12, 5) -- amanhecer
		else
			Lighting.ClockTime = 12
		end
		respawnResources()
		print("[One Way Caravan: Nightfall] === DIA " .. cycle .. " ===")
		for t = DAY_LENGTH, 1, -1 do
			RS:SetAttribute("PhaseTimeLeft", t)
			task.wait(1)
		end
		RS:SetAttribute("Phase", "Noite")
		applyNightAmbience()
		transitionClock(12, 24, 5) -- anoitecer
		print("[One Way Caravan: Nightfall] === NOITE " .. cycle .. " ===")
		local waveIdx = 1
		local t0 = os.clock()
		while true do
			local elapsed = os.clock() - t0
			if elapsed >= NIGHT_LENGTH then break end
			RS:SetAttribute("PhaseTimeLeft", math.ceil(NIGHT_LENGTH - elapsed))
			if waveIdx <= #WAVES and elapsed >= WAVES[waveIdx].time then
				local count = math.min(WAVES[waveIdx].count + (cycle - 1) * WAVE_BONUS_PER_NIGHT, WAVE_MAX_COUNT)
				spawnWave(waveIdx, count)
				waveIdx += 1
			end
			task.wait(0.5)
		end
		despawnAll()
		cycle += 1
	end
end)

print("[One Way Caravan: Nightfall] Servidor inicializado")
