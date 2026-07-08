-- ZoneBuilder — constrói zonas em RUNTIME: terreno, props, recursos, spawns, a caravana e o rig dela.
-- Doc 4.5 (Revisão 3): a caravana é um VEÍCULO pilotado por jogador (VehicleSeat), não mais NPC-driven.
-- Layout comum de POI: estrada sul->norte, acampamento ao sul (a caravana para nele), canyon-funil em
-- z=30 com passagem única de 10 studs, território da ameaça (spawns) ao norte, montanhas fechando tudo.
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")

local ZoneBuilder = {}

local terrain = workspace.Terrain
local HALF = 240
local RIDGE_Z = 30
local CAMP_Z = -47
local CARAVAN_Y = 2.5
local ROCK_COLOR = Color3.fromRGB(104, 101, 96)

-- receita por tipo de POI: densidade de recursos + features. Regra dura do doc 5.5:
-- todo POI serve dia (recurso) e noite (custo) — o custo noturno estático vive no servidor (POI_DIFFICULTY).
local KIND_CONFIG = {
	estacao = { trees = 22, deadTrees = 5, bushes = 8, rocks = 10, lake = false, crates = 3 },
	planicie = { trees = 10, deadTrees = 3, bushes = 12, rocks = 8, lake = true, crates = 0 },
	mina = { trees = 12, deadTrees = 12, bushes = 3, rocks = 22, lake = false, crates = 0 },
	acampamento = { trees = 16, deadTrees = 6, bushes = 6, rocks = 10, lake = false, crates = 2 },
	boss = { trees = 0, deadTrees = 8, bushes = 0, rocks = 18, lake = false, crates = 0 },
}

-- ===== helpers =====
local function ensureFolder(parent, name)
	local f = parent:FindFirstChild(name)
	if not f then
		f = Instance.new("Folder")
		f.Name = name
		f.Parent = parent
	end
	return f
end

local function mkPart(name, size, pos, color, parent, opts)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Position = pos
	p.Anchored = true
	p.Color = color
	p.Material = Enum.Material.Slate
	if opts then
		for k, v in pairs(opts) do p[k] = v end
	end
	p.Parent = parent
	return p
end

local function replaceGround(minV, maxV, from, to)
	terrain:ReplaceMaterial(Region3.new(minV, maxV):ExpandToGrid(4), 4, from, to)
end

-- grupos de colisão: chassi e rodas da caravana não colidem entre si (o eixo visual passa dentro
-- da roda); ambos colidem com o mundo. "GuardrailCaravana" segura SÓ a caravana: jogadores e
-- inimigos (grupo Default) atravessam as paredes invisíveis e seguem coletando fora da estrada.
local function ensureCollisionGroups()
	for _, g in ipairs({ "Caravana", "CaravanaRodas", "GuardrailCaravana" }) do
		pcall(function()
			PhysicsService:RegisterCollisionGroup(g)
		end)
	end
	PhysicsService:CollisionGroupSetCollidable("Caravana", "CaravanaRodas", false)
	PhysicsService:CollisionGroupSetCollidable("GuardrailCaravana", "Default", false)
	PhysicsService:CollisionGroupSetCollidable("GuardrailCaravana", "GuardrailCaravana", false)
	PhysicsService:CollisionGroupSetCollidable("GuardrailCaravana", "Caravana", true)
	PhysicsService:CollisionGroupSetCollidable("GuardrailCaravana", "CaravanaRodas", true)
end

-- parede de guardrail: invisível, alta e enterrada 2 studs (a caravana não cunha por baixo nem
-- vaulta por cima). Engenharia provisória de playtest — o terreno de arte final (canyon,
-- desfiladeiro) substitui isso depois (doc 4.5 "guardrail de terreno" / risco 13).
local function mkGuardrail(parent, name, pos, size)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Position = pos
	p.Anchored = true
	p.Transparency = 1
	p.CanCollide = true
	p.CanQuery = false -- não bloqueia mouse/raycast de colocação
	p.CollisionGroup = "GuardrailCaravana"
	p.Parent = parent
	return p
end

-- altura real da superfície do terreno em (x,z). A superfície suavizada do Terrain fica um pouco
-- acima de y=0, então props posicionados assumindo chão em 0 afundavam; assentar por raycast resolve.
local function terrainGroundY(x, z)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { terrain }
	local hit = workspace:Raycast(Vector3.new(x, 140, z), Vector3.new(0, -300, 0), params)
	return hit and hit.Position.Y or 0
end

local function clearZone()
	for _, n in ipairs({ "Mapa", "EnemySpawns", "GreyboxMap", "Baseplate" }) do
		local x = workspace:FindFirstChild(n)
		if x then x:Destroy() end
	end
	local resourceNodes = ensureFolder(workspace, "ResourceNodes")
	ensureFolder(resourceNodes, "Trees"):ClearAllChildren()
	ensureFolder(resourceNodes, "FoodBushes"):ClearAllChildren()
	ensureFolder(workspace, "Structures"):ClearAllChildren() -- construções ficam pra trás ao avançar (doc 5.3)
	terrain:Clear()
end

local function moveSpawnLocation(pos)
	local sl = workspace:FindFirstChild("SpawnLocation")
	if not sl then
		sl = Instance.new("SpawnLocation")
		sl.Parent = workspace
	end
	sl.Size = Vector3.new(12, 1, 12)
	sl.Position = pos
	sl.Anchored = true
	sl.Neutral = true
	sl.Duration = 0
	sl.Color = Color3.fromRGB(116, 90, 60)
	sl.Material = Enum.Material.WoodPlanks
end

-- ===== recursos =====
local function treesFolder()
	return ensureFolder(ensureFolder(workspace, "ResourceNodes"), "Trees")
end
local function bushesFolder()
	return ensureFolder(ensureFolder(workspace, "ResourceNodes"), "FoodBushes")
end

local function mkTree(rng, i, x, z, dead)
	local s = rng:NextNumber(0.85, 1.25)
	local gy = terrainGroundY(x, z)
	local m = Instance.new("Model")
	m.Name = (dead and "ArvoreSeca" or "Arvore") .. i
	local trunkColor = dead and Color3.fromRGB(74, 56, 40) or Color3.fromRGB(110, 76, 44)
	local trunk = mkPart("Tronco", Vector3.new(1.6 * s, 7 * s, 1.6 * s), Vector3.new(x, gy + 3.4 * s, z), trunkColor, m,
		{ Material = Enum.Material.Wood })
	if dead then
		for g = 1, 2 do
			local galho = mkPart("Galho" .. g, Vector3.new(0.7 * s, 4 * s, 0.7 * s), Vector3.new(x, gy + 6.8 * s, z),
				Color3.fromRGB(70, 52, 38), m, { Material = Enum.Material.Wood })
			galho.CFrame = CFrame.new(x, gy + 6.8 * s, z)
				* CFrame.Angles(0, rng:NextNumber(0, 6.28), math.rad(g == 1 and 35 or -30))
				* CFrame.new(0, 1.4 * s, 0)
		end
	else
		local g = 90 + rng:NextInteger(-25, 25)
		mkPart("Copa1", Vector3.new(6 * s, 6 * s, 6 * s), Vector3.new(x, gy + 8.1 * s, z), Color3.fromRGB(56, g, 52), m,
			{ Shape = Enum.PartType.Ball, Material = Enum.Material.Grass, CanCollide = false })
		mkPart("Copa2", Vector3.new(4.2 * s, 4.2 * s, 4.2 * s),
			Vector3.new(x + rng:NextNumber(-1, 1), gy + 10.9 * s, z + rng:NextNumber(-1, 1)), Color3.fromRGB(50, g - 12, 48), m,
			{ Shape = Enum.PartType.Ball, Material = Enum.Material.Grass, CanCollide = false })
	end
	m.PrimaryPart = trunk
	m:SetAttribute("NodeType", "Wood")
	m:SetAttribute("Uses", dead and 8 or 5)
	m:SetAttribute("MaxUses", dead and 8 or 5)
	m.Parent = treesFolder()
end

local function mkBush(rng, i, x, z)
	local s = rng:NextNumber(0.9, 1.2)
	local gy = terrainGroundY(x, z)
	local m = Instance.new("Model")
	m.Name = "Arbusto" .. i
	local folhas = mkPart("Folhas", Vector3.new(3.4 * s, 2.8 * s, 3.4 * s), Vector3.new(x, gy + 1.3 * s, z),
		Color3.fromRGB(64, 118, 56), m, { Shape = Enum.PartType.Ball, Material = Enum.Material.Grass })
	mkPart("Frutas", Vector3.new(1.3, 1.3, 1.3), Vector3.new(x + 0.9 * s, gy + 2.1 * s, z + 0.5 * s),
		Color3.fromRGB(196, 60, 70), m, { Shape = Enum.PartType.Ball, Material = Enum.Material.SmoothPlastic, CanCollide = false })
	m.PrimaryPart = folhas
	m:SetAttribute("NodeType", "Food")
	m:SetAttribute("Uses", 4)
	m:SetAttribute("MaxUses", 4)
	m.Parent = bushesFolder()
end

local function mkCrate(i, x, z, y)
	-- y = altura extra acima do chão (ex.: caixa sobre a plataforma da estação); 0 = assenta no terreno
	local baseY = terrainGroundY(x, z) + (y or 0)
	local m = Instance.new("Model")
	m.Name = "Caixa" .. i
	local box = mkPart("Corpo", Vector3.new(2.2, 2.2, 2.2), Vector3.new(x, baseY + 1.1, z),
		Color3.fromRGB(140, 108, 66), m, { Material = Enum.Material.WoodPlanks })
	mkPart("Tampa", Vector3.new(2.4, 0.3, 2.4), Vector3.new(x, baseY + 2.35, z),
		Color3.fromRGB(120, 92, 56), m, { Material = Enum.Material.WoodPlanks, CanCollide = false })
	m.PrimaryPart = box
	m:SetAttribute("NodeType", "Food")
	m:SetAttribute("Uses", 2)
	m:SetAttribute("MaxUses", 2)
	m.Parent = bushesFolder()
end

-- espalha respeitando estrada, clareira do acampamento, crista e (opcional) lago
local function scatter(rng, count, zMin, zMax, hasLake, placeFn)
	local placed, attempts = 0, 0
	while placed < count and attempts < count * 15 do
		attempts += 1
		local x = rng:NextNumber(-(HALF - 30), HALF - 30)
		local z = rng:NextNumber(zMin, zMax)
		local ok = math.abs(x) > 13
			and not (math.abs(x) < 36 and z > -80 and z < -16)
			and not (z > 12 and z < 48)
		if ok and hasLake and x > -126 and x < -54 and z > -161 and z < -89 then
			ok = false
		end
		if ok then
			placed += 1
			placeFn(placed, x, z)
		end
	end
end

-- ===== POI =====
function ZoneBuilder.buildPOI(kind)
	local cfg = KIND_CONFIG[kind] or KIND_CONFIG.planicie
	clearZone()
	local rng = Random.new()

	-- terreno base
	terrain:FillBlock(CFrame.new(0, -6, 0), Vector3.new(HALF * 2, 12, HALF * 2), Enum.Material.Grass)
	replaceGround(Vector3.new(-8, -10, -HALF), Vector3.new(8, 4, HALF), Enum.Material.Grass, Enum.Material.Ground)
	replaceGround(Vector3.new(-34, -10, -78), Vector3.new(34, 4, -18), Enum.Material.Grass, Enum.Material.Ground)
	replaceGround(Vector3.new(-HALF, -10, 38), Vector3.new(HALF, 4, HALF), Enum.Material.Grass, Enum.Material.LeafyGrass)
	replaceGround(Vector3.new(-52, -10, 96), Vector3.new(52, 4, 152), Enum.Material.LeafyGrass, Enum.Material.Mud)
	if cfg.lake then
		replaceGround(Vector3.new(-122, -10, -157), Vector3.new(-58, 4, -93), Enum.Material.Grass, Enum.Material.Sand)
		terrain:FillBlock(CFrame.new(-90, 0, -125), Vector3.new(48, 8, 48), Enum.Material.Air)
		terrain:FillBlock(CFrame.new(-90, -3.5, -125), Vector3.new(40, 5, 40), Enum.Material.Water)
	end
	-- crista do canyon + passagem única
	terrain:FillBlock(CFrame.new(-124, 6, RIDGE_Z), Vector3.new(232, 16, 14), Enum.Material.Rock)
	terrain:FillBlock(CFrame.new(124, 6, RIDGE_Z), Vector3.new(232, 16, 14), Enum.Material.Rock)
	terrain:FillBlock(CFrame.new(-130, 14, RIDGE_Z), Vector3.new(212, 10, 10), Enum.Material.Rock)
	terrain:FillBlock(CFrame.new(130, 14, RIDGE_Z), Vector3.new(212, 10, 10), Enum.Material.Rock)
	-- perímetro
	terrain:FillBlock(CFrame.new(0, 10, HALF - 6), Vector3.new(HALF * 2 + 40, 32, 28), Enum.Material.Rock)
	terrain:FillBlock(CFrame.new(0, 10, -(HALF - 6)), Vector3.new(HALF * 2 + 40, 32, 28), Enum.Material.Rock)
	terrain:FillBlock(CFrame.new(HALF - 6, 10, 0), Vector3.new(28, 32, HALF * 2 + 40), Enum.Material.Rock)
	terrain:FillBlock(CFrame.new(-(HALF - 6), 10, 0), Vector3.new(28, 32, HALF * 2 + 40), Enum.Material.Rock)

	local mapa = Instance.new("Model")
	mapa.Name = "Mapa"
	mapa.Parent = workspace

	mkPart("PilarOeste", Vector3.new(3, 14, 8), Vector3.new(-6.5, 7, RIDGE_Z), ROCK_COLOR, mapa)
	mkPart("PilarLeste", Vector3.new(3, 14, 8), Vector3.new(6.5, 7, RIDGE_Z), ROCK_COLOR, mapa)
	mkPart("GapMarker", Vector3.new(10, 0.2, 6), Vector3.new(0, terrainGroundY(0, RIDGE_Z) + 0.12, RIDGE_Z),
		Color3.fromRGB(80, 200, 120), mapa, { CanCollide = false, Transparency = 0.5, Material = Enum.Material.Neon })

	-- círculo de fogueira (sugere onde construir)
	local circY = terrainGroundY(13, -42)
	mkPart("CirculoFogueira", Vector3.new(4.4, 0.2, 4.4), Vector3.new(13, circY + 0.1, -42), Color3.fromRGB(45, 40, 36), mapa,
		{ CanCollide = false, Material = Enum.Material.Ground })
	for k = 1, 6 do
		local ang = (k / 6) * math.pi * 2
		local fx, fz = 13 + math.cos(ang) * 2.4, -42 + math.sin(ang) * 2.4
		mkPart("PedraFogueira" .. k, Vector3.new(1.2, 0.9, 1.1),
			Vector3.new(fx, terrainGroundY(fx, fz) + 0.35, fz), ROCK_COLOR, mapa)
	end

	-- pedras decorativas
	scatter(rng, cfg.rocks, -220, 215, cfg.lake, function(i, x, z)
		local s = rng:NextNumber(2.4, 6)
		local ry = terrainGroundY(x, z) + s * 0.3
		local p = mkPart("Pedra" .. i, Vector3.new(s, s * 0.7, s * 0.9), Vector3.new(x, ry, z), ROCK_COLOR, mapa)
		p.CFrame = CFrame.new(x, ry, z) * CFrame.Angles(rng:NextNumber(-0.2, 0.2), rng:NextNumber(0, 6.28), rng:NextNumber(-0.2, 0.2))
	end)

	-- recursos: floresta ao sul, madeira seca (mais usos, mais risco) no norte
	scatter(rng, cfg.trees, -220, 8, cfg.lake, function(i, x, z)
		mkTree(rng, i, x, z, false)
	end)
	scatter(rng, cfg.deadTrees, 52, 200, false, function(i, x, z)
		mkTree(rng, 100 + i, x, z, true)
	end)
	scatter(rng, cfg.bushes, -220, 4, cfg.lake, function(i, x, z)
		mkBush(rng, i, x, z)
	end)

	-- features por tipo
	if kind == "estacao" then
		mkPart("Plataforma", Vector3.new(22, 1.5, 10), Vector3.new(26, 0.75, -46), Color3.fromRGB(118, 92, 62), mapa,
			{ Material = Enum.Material.WoodPlanks })
		mkPart("TrilhoOeste", Vector3.new(0.5, 0.5, 110), Vector3.new(16.6, 0.25, -60), Color3.fromRGB(70, 70, 78), mapa,
			{ Material = Enum.Material.Metal })
		mkPart("TrilhoLeste", Vector3.new(0.5, 0.5, 110), Vector3.new(20.0, 0.25, -60), Color3.fromRGB(70, 70, 78), mapa,
			{ Material = Enum.Material.Metal })
		for d = 0, 10 do
			mkPart("Dormente" .. d, Vector3.new(6, 0.4, 1.2), Vector3.new(18.3, 0.2, -110 + d * 10),
				Color3.fromRGB(80, 60, 40), mapa, { Material = Enum.Material.Wood })
		end
		for c = 1, cfg.crates do
			mkCrate(c, 20 + c * 5, -44, 1.5)
		end
	elseif kind == "mina" then
		terrain:FillBlock(CFrame.new(150, 8, -70), Vector3.new(44, 20, 34), Enum.Material.Rock)
		mkPart("MinaBoca", Vector3.new(2, 9, 8), Vector3.new(127.5, 4.5, -70), Color3.fromRGB(15, 13, 12), mapa,
			{ Material = Enum.Material.Basalt })
		mkPart("MinaVigaSul", Vector3.new(1, 10, 1), Vector3.new(126, 5, -75), Color3.fromRGB(96, 70, 44), mapa,
			{ Material = Enum.Material.Wood })
		mkPart("MinaVigaNorte", Vector3.new(1, 10, 1), Vector3.new(126, 5, -65), Color3.fromRGB(96, 70, 44), mapa,
			{ Material = Enum.Material.Wood })
		mkPart("MinaVerga", Vector3.new(1, 1, 12), Vector3.new(126, 10.5, -70), Color3.fromRGB(96, 70, 44), mapa,
			{ Material = Enum.Material.Wood })
	elseif kind == "acampamento" then
		for t, pos in ipairs({ { -26, -62 }, { 28, -66 }, { -22, -26 } }) do
			local x, z = pos[1], pos[2]
			local a = mkPart("TendaOeste" .. t, Vector3.new(0.6, 7, 5), Vector3.new(x - 1.5, 2.4, z),
				Color3.fromRGB(48, 40, 34), mapa, { Material = Enum.Material.Wood })
			a.CFrame = CFrame.new(x - 1.5, 2.4, z) * CFrame.Angles(0, 0, math.rad(35))
			local b = mkPart("TendaLeste" .. t, Vector3.new(0.6, 7, 5), Vector3.new(x + 1.5, 2.4, z),
				Color3.fromRGB(48, 40, 34), mapa, { Material = Enum.Material.Wood })
			b.CFrame = CFrame.new(x + 1.5, 2.4, z) * CFrame.Angles(0, 0, math.rad(-35))
			mkPart("Cinzas" .. t, Vector3.new(5, 0.2, 5), Vector3.new(x, 0.1, z), Color3.fromRGB(52, 50, 48), mapa,
				{ CanCollide = false, Material = Enum.Material.Ground })
		end
		for c = 1, cfg.crates do
			mkCrate(c, c == 1 and -30 or 34, c == 1 and -40 or -50, 0)
		end
	elseif kind == "boss" then
		-- covil: portal escuro onde a estrada termina (o boss em si é o passo 8)
		mkPart("CovilPilarOeste", Vector3.new(6, 20, 6), Vector3.new(-9, 10, 150), Color3.fromRGB(40, 36, 40), mapa,
			{ Material = Enum.Material.Basalt })
		mkPart("CovilPilarLeste", Vector3.new(6, 20, 6), Vector3.new(9, 10, 150), Color3.fromRGB(40, 36, 40), mapa,
			{ Material = Enum.Material.Basalt })
		mkPart("CovilVerga", Vector3.new(26, 6, 6), Vector3.new(0, 21, 150), Color3.fromRGB(35, 32, 36), mapa,
			{ Material = Enum.Material.Basalt })
		mkPart("CovilFundo", Vector3.new(20, 18, 2), Vector3.new(0, 9, 154), Color3.fromRGB(12, 10, 14), mapa,
			{ Material = Enum.Material.Basalt })
		for b = 1, 6 do
			local ox, oz = rng:NextNumber(-30, 30), rng:NextNumber(60, 140)
			mkPart("Osso" .. b, Vector3.new(rng:NextNumber(1.5, 3), 0.6, 0.6),
				Vector3.new(ox, terrainGroundY(ox, oz) + 0.3, oz),
				Color3.fromRGB(220, 214, 196), mapa, { Material = Enum.Material.SmoothPlastic })
		end
	end

	-- spawns de inimigos (norte, atrás do funil)
	local spawnsFolder = Instance.new("Folder")
	spawnsFolder.Name = "EnemySpawns"
	for i, xz in ipairs({ { -30, 118 }, { 0, 124 }, { 30, 118 }, { -14, 136 }, { 16, 136 } }) do
		local pad = mkPart("Spawn" .. i, Vector3.new(8, 0.4, 8), Vector3.new(xz[1], terrainGroundY(xz[1], xz[2]) + 0.2, xz[2]),
			Color3.fromRGB(170, 60, 60), spawnsFolder, { CanCollide = false, Transparency = 0.55, Material = Enum.Material.Neon })
		pad.Locked = true
	end
	spawnsFolder.Parent = workspace

	moveSpawnLocation(Vector3.new(-16, 0.5, -42))

	return {
		kind = kind,
		campCf = CFrame.new(0, CARAVAN_Y, CAMP_Z), -- caravana para aqui (meio-sul do mapa, doc 4.5 etapa 3)
		entryCf = CFrame.new(0, CARAVAN_Y, -200), -- entra pelo sul
		exitCf = CFrame.new(0, CARAVAN_Y, 120), -- sai pelo norte, através da passagem
		ridgeZ = RIDGE_Z,
		gapPos = Vector3.new(0, 3, RIDGE_Z),
	}
end

-- ===== zona de transição (doc 4.5 etapa 2: corredor isolado, caravana em linha reta, jogadores ao redor) =====
function ZoneBuilder.buildTransition()
	clearZone()
	local rng = Random.new()

	terrain:FillBlock(CFrame.new(0, -6, 0), Vector3.new(200, 12, HALF * 2), Enum.Material.LeafyGrass)
	replaceGround(Vector3.new(-8, -10, -HALF), Vector3.new(8, 4, HALF), Enum.Material.LeafyGrass, Enum.Material.Ground)
	-- paredões laterais e tampas
	terrain:FillBlock(CFrame.new(-92, 10, 0), Vector3.new(28, 40, HALF * 2 + 40), Enum.Material.Rock)
	terrain:FillBlock(CFrame.new(92, 10, 0), Vector3.new(28, 40, HALF * 2 + 40), Enum.Material.Rock)
	terrain:FillBlock(CFrame.new(0, 10, HALF - 6), Vector3.new(240, 40, 28), Enum.Material.Rock)
	terrain:FillBlock(CFrame.new(0, 10, -(HALF - 6)), Vector3.new(240, 40, 28), Enum.Material.Rock)

	local mapa = Instance.new("Model")
	mapa.Name = "Mapa"
	mapa.Parent = workspace

	-- guardrail provisório (passo 2): a caravana fica presa na faixa da estrada; jogadores
	-- atravessam as paredes (grupo de colisão) pra coletar a vegetação das laterais
	mkGuardrail(mapa, "GuardrailOeste", Vector3.new(-16, 9, 0), Vector3.new(2, 22, HALF * 2))
	mkGuardrail(mapa, "GuardrailLeste", Vector3.new(16, 9, 0), Vector3.new(2, 22, HALF * 2))

	-- vegetação e pedras esparsas ao longo do corredor (dá o que coletar na travessia)
	for i = 1, 10 do
		local side = rng:NextInteger(0, 1) == 0 and -1 or 1
		mkTree(rng, i, side * rng:NextNumber(16, 66), rng:NextNumber(-190, 190), rng:NextNumber() < 0.3)
	end
	for i = 1, 4 do
		local side = rng:NextInteger(0, 1) == 0 and -1 or 1
		mkBush(rng, i, side * rng:NextNumber(16, 66), rng:NextNumber(-180, 180))
	end
	for i = 1, 8 do
		local side = rng:NextInteger(0, 1) == 0 and -1 or 1
		local s = rng:NextNumber(2.4, 6)
		local x, z = side * rng:NextNumber(14, 70), rng:NextNumber(-200, 200)
		local ry = terrainGroundY(x, z) + s * 0.3
		local p = mkPart("Pedra" .. i, Vector3.new(s, s * 0.7, s * 0.9), Vector3.new(x, ry, z), ROCK_COLOR, mapa)
		p.CFrame = CFrame.new(x, ry, z) * CFrame.Angles(0, rng:NextNumber(0, 6.28), 0)
	end

	moveSpawnLocation(Vector3.new(-12, 0.5, -188))

	return {
		kind = "transicao",
		startCf = CFrame.new(0, CARAVAN_Y, -200),
		endCf = CFrame.new(0, CARAVAN_Y, 200),
		ridgeZ = nil, -- sem funil aqui
	}
end

-- ===== lobby (passo 9): posto de partida com catálogo; zona pequena e segura, sem funil e sem inimigos =====
function ZoneBuilder.buildLobby()
	clearZone()

	terrain:FillBlock(CFrame.new(0, -6, 0), Vector3.new(160, 12, 160), Enum.Material.Grass)
	replaceGround(Vector3.new(-26, -10, -26), Vector3.new(26, 4, 34), Enum.Material.Grass, Enum.Material.Ground)
	-- muros de pedra fechando o posto
	terrain:FillBlock(CFrame.new(0, 6, 76), Vector3.new(176, 28, 16), Enum.Material.Rock)
	terrain:FillBlock(CFrame.new(0, 6, -76), Vector3.new(176, 28, 16), Enum.Material.Rock)
	terrain:FillBlock(CFrame.new(76, 6, 0), Vector3.new(16, 28, 176), Enum.Material.Rock)
	terrain:FillBlock(CFrame.new(-76, 6, 0), Vector3.new(16, 28, 176), Enum.Material.Rock)

	local mapa = Instance.new("Model")
	mapa.Name = "Mapa"
	mapa.Parent = workspace

	-- fogueira permanente do posto
	for k = 1, 6 do
		local ang = (k / 6) * math.pi * 2
		local fx, fz = 16 + math.cos(ang) * 2.4, -8 + math.sin(ang) * 2.4
		mkPart("PedraFogueira" .. k, Vector3.new(1.2, 0.9, 1.1),
			Vector3.new(fx, terrainGroundY(fx, fz) + 0.35, fz), ROCK_COLOR, mapa)
	end
	local flame = mkPart("FogoPosto", Vector3.new(1.8, 1.8, 1.8), Vector3.new(16, terrainGroundY(16, -8) + 1.2, -8),
		Color3.fromRGB(255, 140, 30), mapa, { Shape = Enum.PartType.Ball, Material = Enum.Material.Neon, CanCollide = false })
	local fire = Instance.new("Fire")
	fire.Size = 5
	fire.Parent = flame
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 160, 60)
	light.Range = 20
	light.Parent = flame

	-- poste de partida na frente da caravana (o servidor pluga o ProximityPrompt nele)
	local post = mkPart("PostePartida", Vector3.new(1, 6, 1), Vector3.new(6, 3, 26), Color3.fromRGB(110, 80, 48), mapa,
		{ Material = Enum.Material.Wood })
	mkPart("BandeiraPartida", Vector3.new(2.6, 1.4, 0.2), Vector3.new(7.4, 5.2, 26), Color3.fromRGB(190, 70, 55), mapa,
		{ Material = Enum.Material.Fabric, CanCollide = false })

	-- quadro do catálogo perto do spawn (a UI do catálogo abre sozinha no lobby)
	mkPart("QuadroCatalogo", Vector3.new(5, 3.4, 0.5), Vector3.new(-16, 3, 2), Color3.fromRGB(96, 70, 44), mapa,
		{ Material = Enum.Material.WoodPlanks })
	mkPart("QuadroPernaOeste", Vector3.new(0.5, 3, 0.5), Vector3.new(-18, 1.5, 2), Color3.fromRGB(80, 58, 36), mapa,
		{ Material = Enum.Material.Wood })
	mkPart("QuadroPernaLeste", Vector3.new(0.5, 3, 0.5), Vector3.new(-14, 1.5, 2), Color3.fromRGB(80, 58, 36), mapa,
		{ Material = Enum.Material.Wood })

	moveSpawnLocation(Vector3.new(-14, 0.5, -12))

	return {
		kind = "lobby",
		caravanaCf = CFrame.new(0, CARAVAN_Y, 6),
		startPost = post,
		ridgeZ = nil,
	}
end

-- ===== caravana (doc 4.5 rev.3): veículo de verdade, pilotado por jogador =====
-- Rig na técnica do Dead Rails (DevForum "Train Move System [Dead Rails]"): um assembly único
-- soldado num Root central via WeldConstraint, rodas em HingeConstraint, VehicleSeat comandando
-- throttle/steer, e Seats comuns de passageiro — o weld nativo do assento é o que elimina o
-- jitter de quem não está dirigindo.
-- DESVIO DOCUMENTADO do doc 4.5: lá o empuxo é "PrismaticConstraint ActuatorType Motor", que no
-- Dead Rails empurra contra um TRILHO reto ancorado (o trem não esterça). Com pilotagem livre
-- (exigida pelo mesmo doc), um prismatic interno ao assembly não gera força líquida; o empuxo
-- correto vira Motor nos HingeConstraints das rodas traseiras (padrão nativo de veículo por
-- constraints do Roblox). Todo o resto da técnica é mantido como especificado.
local CARAVAN_MAX_SPEED = 24 -- studs/s no chão plano [placeholder de playtest]
local REAR_WHEEL_RADIUS = 2.4
local STEER_ANGLE = 28 -- graus de esterço máximo [placeholder de playtest]
local DRIVE_TORQUE = 400000 -- por roda motriz [placeholder de playtest]
local STEER_TORQUE = 1e7

-- referências vivas do rig (preenchidas por buildCaravana)
local rig = { locked = true, seat = nil, root = nil, motors = {}, servos = {}, seats = {} }

-- aplica throttle/steer do VehicleSeat nos motores; zera tudo quando travada ou sem motorista
local function refreshDrive()
	if not (rig.seat and rig.root) then
		return
	end
	local driving = not rig.locked and rig.seat.Occupant ~= nil
	local throttle = driving and rig.seat.ThrottleFloat or 0
	for _, motor in ipairs(rig.motors) do
		-- ω = v/r; sinal validado com o rig construído olhando +Z (frente = bois)
		motor.AngularVelocity = throttle * CARAVAN_MAX_SPEED / REAR_WHEEL_RADIUS
	end
	local steer = driving and rig.seat.SteerFloat or 0
	for _, servo in ipairs(rig.servos) do
		-- assento olha +Z (girado 180°), então "direita" do motorista é -X: inverte o sinal
		servo.TargetAngle = -steer * STEER_ANGLE
	end
end

-- física da caravana: motorista sentado ganha network ownership (input responsivo);
-- vazia ou travada, volta pro servidor (mesmo modelo do trem do Dead Rails p/ passageiros)
local function refreshOwnership()
	if not (rig.root and rig.root.Parent) or rig.root.Anchored then
		return
	end
	local occ = rig.seat and rig.seat.Occupant
	local plr = occ and Players:GetPlayerFromCharacter(occ.Parent) or nil
	pcall(function()
		rig.root:SetNetworkOwner(plr)
	end)
end

function ZoneBuilder.buildCaravana()
	local existing = workspace:FindFirstChild("Caravana")
	if existing then
		return existing
	end
	ensureCollisionGroups()

	local m = Instance.new("Model")
	m.Name = "Caravana"

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(6.5, 1, 15)
	root.CFrame = CFrame.new(0, CARAVAN_Y, 0) -- construída na origem olhando +Z; PivotTo posiciona depois
	root.Transparency = 1
	root.CanCollide = false
	root.Anchored = true -- nasce travada (lobby); setCaravanaLocked libera
	root.CollisionGroup = "Caravana"
	root.CustomPhysicalProperties = PhysicalProperties.new(0.35, 0.3, 0)
	root.Parent = m
	m.PrimaryPart = root
	rig.root = root
	rig.locked = true
	rig.motors, rig.servos, rig.seats = {}, {}, {}

	local function cpart(name, size, cf, color, material, opts)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = material or Enum.Material.Wood
		p.Anchored = false
		p.CanCollide = true
		p.CollisionGroup = "Caravana"
		if opts then
			for k, v in pairs(opts) do p[k] = v end
		end
		local w = Instance.new("WeldConstraint")
		w.Part0 = root
		w.Part1 = p
		w.Parent = p
		p.Parent = m
		return p
	end

	local madeira = Color3.fromRGB(124, 92, 58)
	local madeiraClara = Color3.fromRGB(110, 80, 48)
	local madeiraEscura = Color3.fromRGB(86, 62, 40)
	local lona = Color3.fromRGB(233, 225, 205)

	-- chassi (eixos mais curtos que a bitola: a ponta não pode penetrar a roda física)
	cpart("Cama", Vector3.new(6, 0.8, 14), CFrame.new(0, 3.2, -1), madeira)
	cpart("LateralOeste", Vector3.new(0.6, 2.4, 14), CFrame.new(-3.3, 4.6, -1), madeiraClara, Enum.Material.WoodPlanks)
	cpart("LateralLeste", Vector3.new(0.6, 2.4, 14), CFrame.new(3.3, 4.6, -1), madeiraClara, Enum.Material.WoodPlanks)
	cpart("PainelFrente", Vector3.new(7.2, 2.4, 0.6), CFrame.new(0, 4.6, 6), madeiraClara, Enum.Material.WoodPlanks)
	cpart("PainelTras", Vector3.new(7.2, 2.4, 0.6), CFrame.new(0, 4.6, -8), madeiraClara, Enum.Material.WoodPlanks)
	cpart("Viga", Vector3.new(0.8, 0.6, 13), CFrame.new(0, 2.5, -0.5), madeiraEscura)
	cpart("EixoTras", Vector3.new(6.2, 0.5, 0.5), CFrame.new(0, 2.4, -4.5), madeiraEscura)
	cpart("EixoFrente", Vector3.new(6.2, 0.5, 0.5), CFrame.new(0, 1.9, 3.5), madeiraEscura)

	-- rodas físicas: cilindro (eixo do cilindro = X = bitola) preso por HingeConstraint.
	-- Traseiras: hinge direto no Root com ActuatorType Motor (tração).
	-- Dianteiras: manga de eixo (knuckle) presa ao Root por hinge-servo vertical (esterço),
	-- e a roda gira livre num hinge preso à manga.
	local function mkWheel(x, y, z, dia, powered)
		local wheel = Instance.new("Part")
		wheel.Name = powered and "RodaTras" or "RodaFrente"
		wheel.Shape = Enum.PartType.Cylinder
		wheel.Size = Vector3.new(0.7, dia, dia)
		wheel.CFrame = CFrame.new(x, y, z)
		wheel.Color = Color3.fromRGB(74, 52, 34)
		wheel.Material = Enum.Material.Wood
		wheel.Anchored = false
		wheel.CanCollide = true
		wheel.CollisionGroup = "CaravanaRodas"
		wheel.CustomPhysicalProperties = PhysicalProperties.new(1, 2, 0) -- denso e com atrito: é a tração
		wheel.Parent = m
		local wheelAtt = Instance.new("Attachment") -- eixo X do attachment = eixo do hinge = bitola
		wheelAtt.Parent = wheel

		local hub -- parte onde o hinge da roda ancora: Root (trás) ou manga de eixo (frente)
		if powered then
			hub = root
		else
			hub = Instance.new("Part")
			hub.Name = "MangaEixo"
			hub.Size = Vector3.new(0.8, 0.8, 0.8)
			hub.CFrame = CFrame.new(x, y, z)
			hub.Transparency = 1
			hub.CanCollide = false
			hub.CollisionGroup = "CaravanaRodas"
			hub.Parent = m
			-- servo de esterço: eixo vertical (Orientation (0,0,90) aponta o X do attachment pra cima)
			local steerAtt0 = Instance.new("Attachment")
			steerAtt0.Position = root.CFrame:PointToObjectSpace(Vector3.new(x, y, z))
			steerAtt0.Orientation = Vector3.new(0, 0, 90)
			steerAtt0.Parent = root
			local steerAtt1 = Instance.new("Attachment")
			steerAtt1.Orientation = Vector3.new(0, 0, 90)
			steerAtt1.Parent = hub
			local servo = Instance.new("HingeConstraint")
			servo.Name = "ServoEsterco"
			servo.Attachment0 = steerAtt0
			servo.Attachment1 = steerAtt1
			servo.ActuatorType = Enum.ActuatorType.Servo
			servo.ServoMaxTorque = STEER_TORQUE
			servo.AngularSpeed = 4
			servo.LimitsEnabled = true
			servo.LowerAngle = -STEER_ANGLE
			servo.UpperAngle = STEER_ANGLE
			servo.Parent = hub
			table.insert(rig.servos, servo)
		end

		local hubAtt = Instance.new("Attachment")
		hubAtt.Position = hub.CFrame:PointToObjectSpace(Vector3.new(x, y, z))
		hubAtt.Parent = hub
		local hinge = Instance.new("HingeConstraint")
		hinge.Name = powered and "MotorTracao" or "HingeRoda"
		hinge.Attachment0 = hubAtt
		hinge.Attachment1 = wheelAtt
		hinge.Parent = wheel
		if powered then
			hinge.ActuatorType = Enum.ActuatorType.Motor
			hinge.MotorMaxTorque = DRIVE_TORQUE
			hinge.MotorMaxAcceleration = 40
			hinge.AngularVelocity = 0
			table.insert(rig.motors, hinge)
		end
		return wheel
	end
	mkWheel(-3.9, 2.4, -4.5, 4.8, true)
	mkWheel(3.9, 2.4, -4.5, 4.8, true)
	mkWheel(-3.8, 1.9, 3.5, 3.8, false)
	mkWheel(3.8, 1.9, 3.5, 3.8, false)

	-- boleia: VehicleSeat (condução) + Seat de passageiro no mesmo banco.
	-- Girados 180° pro LookVector apontar +Z (frente do rig = bois); sem isso o motorista olha pra trás.
	local vseat = Instance.new("VehicleSeat")
	vseat.Name = "Boleia"
	vseat.Size = Vector3.new(2.6, 0.5, 1.8)
	vseat.CFrame = CFrame.new(1.4, 5.6, 5.6) * CFrame.Angles(0, math.pi, 0)
	vseat.Color = madeira
	vseat.Material = Enum.Material.Wood
	vseat.Anchored = false
	vseat.CanCollide = true
	vseat.CollisionGroup = "Caravana"
	vseat.MaxSpeed = 0 -- motores legados desligados; quem dirige são os hinges via script
	vseat.Torque = 0
	vseat.TurnSpeed = 0
	vseat.HeadsUpDisplay = false
	local vw = Instance.new("WeldConstraint")
	vw.Part0 = root
	vw.Part1 = vseat
	vw.Parent = vseat
	vseat.Parent = m
	rig.seat = vseat
	table.insert(rig.seats, vseat)

	local function mkSeat(name, cf)
		local s = Instance.new("Seat")
		s.Name = name
		s.Size = Vector3.new(2.4, 0.5, 1.8)
		s.CFrame = cf
		s.Color = madeira
		s.Material = Enum.Material.Wood
		s.Anchored = false
		s.CanCollide = true
		s.CollisionGroup = "Caravana"
		local w = Instance.new("WeldConstraint")
		w.Part0 = root
		w.Part1 = s
		w.Parent = s
		s.Parent = m
		table.insert(rig.seats, s)
		return s
	end
	mkSeat("PassageiroBoleia", CFrame.new(-1.4, 5.6, 5.6) * CFrame.Angles(0, math.pi, 0))
	-- passageiros da cama olham pro centro (4 assentos no total = lotação do MVP, doc 4.3)
	mkSeat("PassageiroOeste", CFrame.lookAt(Vector3.new(-2.1, 4.0, -2.6), Vector3.new(2.1, 4.0, -2.6)))
	mkSeat("PassageiroLeste", CFrame.lookAt(Vector3.new(2.1, 4.0, -2.6), Vector3.new(-2.1, 4.0, -2.6)))

	-- encosto ATRÁS do banco (motorista olha +Z, pros bois); estribo na frente é o apoio dos pés
	cpart("Encosto", Vector3.new(5.6, 1.4, 0.4), CFrame.new(0, 6.4, 4.7), madeira)
	cpart("Estribo", Vector3.new(5.6, 1.6, 0.4), CFrame.new(0, 4.6, 7.1) * CFrame.Angles(math.rad(-20), 0, 0), madeiraEscura)

	-- lona em arco
	cpart("LonaOeste1", Vector3.new(0.35, 2.2, 11), CFrame.new(-3.35, 6.8, -2.5) * CFrame.Angles(0, 0, math.rad(-12)),
		lona, Enum.Material.Fabric, { CanCollide = false })
	cpart("LonaLeste1", Vector3.new(0.35, 2.2, 11), CFrame.new(3.35, 6.8, -2.5) * CFrame.Angles(0, 0, math.rad(12)),
		lona, Enum.Material.Fabric, { CanCollide = false })
	cpart("LonaOeste2", Vector3.new(0.35, 2.2, 11), CFrame.new(-2.55, 8.7, -2.5) * CFrame.Angles(0, 0, math.rad(-40)),
		lona, Enum.Material.Fabric, { CanCollide = false })
	cpart("LonaLeste2", Vector3.new(0.35, 2.2, 11), CFrame.new(2.55, 8.7, -2.5) * CFrame.Angles(0, 0, math.rad(40)),
		lona, Enum.Material.Fabric, { CanCollide = false })
	cpart("LonaTopo", Vector3.new(3.6, 0.35, 11), CFrame.new(0, 9.5, -2.5), lona, Enum.Material.Fabric, { CanCollide = false })
	cpart("LonaTras", Vector3.new(5.4, 4.2, 0.3), CFrame.new(0, 7.4, -7.9), lona, Enum.Material.Fabric, { CanCollide = false })

	-- carga
	cpart("Barril1", Vector3.new(2.0, 1.7, 1.7), CFrame.new(-1.5, 4.6, -6) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(105, 75, 45), Enum.Material.Wood, { Shape = Enum.PartType.Cylinder, CanCollide = false })
	cpart("Barril2", Vector3.new(2.0, 1.7, 1.7), CFrame.new(1.5, 4.6, -6) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(105, 75, 45), Enum.Material.Wood, { Shape = Enum.PartType.Cylinder, CanCollide = false })
	cpart("Caixote", Vector3.new(2, 2, 2), CFrame.new(0, 4.6, -4.6), Color3.fromRGB(128, 98, 60),
		Enum.Material.WoodPlanks, { CanCollide = false })
	cpart("Saco1", Vector3.new(1.7, 1.2, 1.7), CFrame.new(-1.6, 4.2, -4.8), Color3.fromRGB(196, 172, 128),
		Enum.Material.Fabric, { Shape = Enum.PartType.Ball, CanCollide = false })
	cpart("Saco2", Vector3.new(1.7, 1.2, 1.7), CFrame.new(0.3, 4.15, -1.6), Color3.fromRGB(196, 172, 128),
		Enum.Material.Fabric, { Shape = Enum.PartType.Ball, CanCollide = false })

	-- lampião
	cpart("GanchoLampiao", Vector3.new(0.3, 0.3, 1.4), CFrame.new(2.9, 7.2, 6.4), madeiraEscura, Enum.Material.Wood,
		{ CanCollide = false })
	local lamp = cpart("Lampiao", Vector3.new(0.7, 1.0, 0.7), CFrame.new(2.9, 6.4, 6.9), Color3.fromRGB(255, 196, 120),
		Enum.Material.Neon, { CanCollide = false })
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 190, 120)
	light.Range = 18
	light.Brightness = 1.4
	light.Parent = lamp

	-- lança + canga + junta de bois (baixas: sem colisão pra não raspar em elevação do terreno)
	cpart("Lanca", Vector3.new(0.5, 0.4, 5.6), CFrame.new(0, 1.7, 8.6), madeiraEscura, nil, { CanCollide = false })
	cpart("Canga", Vector3.new(6.2, 0.5, 0.5), CFrame.new(0, 2.6, 11.2), madeiraEscura, nil, { CanCollide = false })

	local function boi(x, tom)
		cpart("BoiCorpo", Vector3.new(2.4, 2.7, 4.6), CFrame.new(x, 2.75, 12.6), tom, Enum.Material.SmoothPlastic)
		cpart("BoiCabeca", Vector3.new(1.5, 1.6, 1.7), CFrame.new(x, 3.4, 15.5), tom, Enum.Material.SmoothPlastic,
			{ CanCollide = false })
		cpart("BoiFocinho", Vector3.new(1.0, 0.9, 0.8), CFrame.new(x, 2.9, 16.5), Color3.fromRGB(168, 142, 108),
			Enum.Material.SmoothPlastic, { CanCollide = false })
		cpart("BoiChifreOeste", Vector3.new(0.8, 0.22, 0.22), CFrame.new(x - 0.9, 4.2, 15.5), Color3.fromRGB(214, 198, 168),
			Enum.Material.SmoothPlastic, { CanCollide = false })
		cpart("BoiChifreLeste", Vector3.new(0.8, 0.22, 0.22), CFrame.new(x + 0.9, 4.2, 15.5), Color3.fromRGB(214, 198, 168),
			Enum.Material.SmoothPlastic, { CanCollide = false })
		cpart("BoiRabo", Vector3.new(0.22, 1.5, 0.22), CFrame.new(x, 2.9, 10.2), tom, Enum.Material.SmoothPlastic,
			{ CanCollide = false })
		for _, off in ipairs({ { -0.75, -1.7 }, { 0.75, -1.7 }, { -0.75, 1.7 }, { 0.75, 1.7 } }) do
			cpart("BoiPerna", Vector3.new(0.7, 1.4, 0.7), CFrame.new(x + off[1], 0.7, 12.6 + off[2]), tom,
				Enum.Material.SmoothPlastic, { CanCollide = false })
		end
	end
	boi(-2.1, Color3.fromRGB(122, 88, 62))
	boi(2.1, Color3.fromRGB(134, 100, 72))

	m:SetAttribute("IsCaravana", true)

	-- input do VehicleSeat -> motores/servos; troca de motorista atualiza network ownership
	vseat:GetPropertyChangedSignal("ThrottleFloat"):Connect(refreshDrive)
	vseat:GetPropertyChangedSignal("SteerFloat"):Connect(refreshDrive)
	vseat:GetPropertyChangedSignal("Occupant"):Connect(function()
		refreshOwnership()
		refreshDrive()
	end)

	m.Parent = workspace
	refreshDrive()
	return m
end

-- trava/destrava a caravana (noite, lobby, votação): Root ancorado = assembly inteiro parado.
-- Destravar zera velocidades e devolve a física pro motorista atual (se houver).
function ZoneBuilder.setCaravanaLocked(locked)
	rig.locked = locked
	local root = rig.root
	if not (root and root.Parent) then
		return
	end
	root.Anchored = locked
	if not locked then
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		refreshOwnership()
	end
	refreshDrive()
end

-- tira todo mundo dos assentos (necessário antes de pivôs longos de troca de zona/lobby)
function ZoneBuilder.unseatAll()
	for _, s in ipairs(rig.seats) do
		local occ = s.Parent and s.Occupant
		if occ then
			occ.Sit = false
		end
	end
	task.wait(0.1) -- deixa os SeatWelds morrerem antes do pivô
end

function ZoneBuilder.pivotCaravanaTo(cf)
	local c = workspace:FindFirstChild("Caravana")
	if c then
		c:PivotTo(cf)
		local root = c.PrimaryPart
		if root and not root.Anchored then
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end
	end
end

-- preview no modo Edit (Command Bar, com Rojo conectado):
--   require(game.ServerScriptService.ZoneBuilder).preview()
function ZoneBuilder.preview(kind)
	ZoneBuilder.buildCaravana()
	local info = ZoneBuilder.buildPOI(kind or "estacao")
	ZoneBuilder.pivotCaravanaTo(info.campCf)
	print("[ZoneBuilder] Preview construído: " .. (kind or "estacao"))
	return info
end

return ZoneBuilder
