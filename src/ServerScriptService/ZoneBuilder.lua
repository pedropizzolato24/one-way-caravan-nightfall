-- ZoneBuilder — constrói o MUNDO da run em RUNTIME: terreno, props, recursos, spawns, corredores,
-- a caravana e o rig físico dela.
-- Doc 4.5/4.6 (Revisão 3): mundo CONTÍNUO por run via StreamingEnabled — todos os POIs e corredores
-- coexistem no mesmo espaço, sem zonas isoladas nem teleporte. Cada POI/corredor é um "grupo"
-- destrutível (instâncias + regiões de terreno), pra o servidor apagar o ramo não escolhido no fork
-- e o que ficou pra trás (doc 4.5 "ponto de não-retorno").
-- Layout comum de POI (receita placeholder 480×480, level design manual substitui depois):
-- estrada sul->norte, acampamento ao sul, canyon-funil em z=+30 local com passagem única de
-- 10 studs, território da ameaça (spawns) ao norte, montanhas fechando tudo, portões carvados
-- nas muralhas onde um corredor conecta.
local Players = game:GetService("Players")
local PhysicsService = game:GetService("PhysicsService")

local ZoneBuilder = {}

local terrain = workspace.Terrain
local HALF = 240 -- meia-largura de um POI
local RIDGE_Z = 30 -- funil do canyon (coordenada local do POI)
local CAMP_Z = -47 -- acampamento (coordenada local do POI)
local CARAVAN_Y = 2.5
local ROCK_COLOR = Color3.fromRGB(104, 101, 96)

-- corredores/plazas (mundo contínuo)
local CORR_HALF = 20 -- meia-largura do chão do corredor
local BERM_OFF = 26 -- centro dos taludes de pedra que flanqueiam o corredor
local GUARD_OFF = 16 -- guardrail invisível: a caravana fica na faixa, jogadores atravessam
local PLAZA_HALF = 88 -- plazas de fork/merge
local GATE_W = 40 -- largura da abertura carvada em muralhas/taludes

-- receita por tipo de POI: densidade de recursos + features. Regra dura do doc 5.5:
-- todo POI serve dia (recurso) e noite (custo) — o custo noturno estático vive no servidor (POI_DIFFICULTY).
local KIND_CONFIG = {
	estacao = { trees = 22, deadTrees = 5, bushes = 8, rocks = 10, lake = false, crates = 3 },
	planicie = { trees = 10, deadTrees = 3, bushes = 12, rocks = 8, lake = true, crates = 0 },
	mina = { trees = 12, deadTrees = 12, bushes = 3, rocks = 22, lake = false, crates = 0 },
	acampamento = { trees = 16, deadTrees = 6, bushes = 6, rocks = 10, lake = false, crates = 2 },
	boss = { trees = 0, deadTrees = 8, bushes = 0, rocks = 18, lake = false, crates = 0 },
}

-- estado do mundo da run atual (nil no lobby): zones[id] + groups[nome] destrutíveis
local world = nil

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

local function mundoFolder()
	return ensureFolder(workspace, "Mundo")
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

local function clearWorld()
	local mundo = workspace:FindFirstChild("Mundo")
	if mundo then
		mundo:Destroy()
	end
	for _, n in ipairs({ "Mapa", "GreyboxMap", "Baseplate" }) do -- nomes de builds legados
		local x = workspace:FindFirstChild(n)
		if x then
			x:Destroy()
		end
	end
	ensureFolder(workspace, "EnemySpawns"):ClearAllChildren()
	ensureFolder(workspace, "ResourceNodes"):ClearAllChildren()
	ensureFolder(workspace, "Structures"):ClearAllChildren() -- construções são ativo da run (doc 5.3)
	terrain:Clear()
	world = nil
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
ZoneBuilder.moveSpawnLocation = moveSpawnLocation

-- ===== grupos destrutíveis (fundação do "sem volta", doc 4.5/4.6) =====
local function groupOf(name)
	local g = world.groups[name]
	if not g then
		g = { instances = {}, regions = {}, destroyed = false }
		world.groups[name] = g
	end
	return g
end

local function regInstance(name, inst)
	table.insert(groupOf(name).instances, inst)
end

-- FillBlock com registro: destruir o grupo = Air sobre cada região registrada
local function fillT(name, cf, size, material)
	terrain:FillBlock(cf, size, material)
	table.insert(groupOf(name).regions, { cf = cf, size = size })
end

function ZoneBuilder.destroyGroup(name)
	local g = world and world.groups[name]
	if not g or g.destroyed then
		return false
	end
	g.destroyed = true
	for _, inst in ipairs(g.instances) do
		inst:Destroy()
	end
	for _, r in ipairs(g.regions) do
		terrain:FillBlock(r.cf, r.size, Enum.Material.Air)
	end
	return true
end

function ZoneBuilder.isGroupDestroyed(name)
	local g = world and world.groups[name]
	return g ~= nil and g.destroyed
end

-- sela fisicamente uma abertura depois que o chão do outro lado foi destruído (a caravana não
-- pode cair no vazio); jogadores a pé ainda atravessam (grupo GuardrailCaravana)
function ZoneBuilder.sealGate(pos, alongX)
	local size = alongX and Vector3.new(GATE_W + 12, 26, 3) or Vector3.new(3, 26, GATE_W + 12)
	mkGuardrail(mundoFolder(), "SeloSemVolta", Vector3.new(pos.X, 10, pos.Z), size)
end

-- ===== recursos =====
local function mkTree(rng, folder, i, x, z, dead)
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
	m.Parent = folder
end

local function mkBush(rng, folder, i, x, z)
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
	m.Parent = folder
end

local function mkCrate(folder, i, x, z, y)
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
	m.Parent = folder
end

-- espalha em coordenadas LOCAIS do POI respeitando estrada, clareira do acampamento, crista e
-- (opcional) lago; o placeFn recebe as coordenadas locais e soma o offset da zona
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

-- ===== POI (agora com origem no mundo contínuo + portões pros corredores) =====
-- gates = { south = bool, north = bool }: carva a abertura na muralha onde um corredor conecta
local function buildPOI(kind, id, center, gates)
	local cfg = KIND_CONFIG[kind] or KIND_CONFIG.planicie
	local rng = Random.new()
	local ox, oz = center.X, center.Z
	local grp = id

	-- terreno base
	fillT(grp, CFrame.new(ox, -6, oz), Vector3.new(HALF * 2, 12, HALF * 2), Enum.Material.Grass)
	replaceGround(Vector3.new(ox - 8, -10, oz - HALF), Vector3.new(ox + 8, 4, oz + HALF), Enum.Material.Grass, Enum.Material.Ground)
	replaceGround(Vector3.new(ox - 34, -10, oz - 78), Vector3.new(ox + 34, 4, oz - 18), Enum.Material.Grass, Enum.Material.Ground)
	replaceGround(Vector3.new(ox - HALF, -10, oz + 38), Vector3.new(ox + HALF, 4, oz + HALF), Enum.Material.Grass, Enum.Material.LeafyGrass)
	replaceGround(Vector3.new(ox - 52, -10, oz + 96), Vector3.new(ox + 52, 4, oz + 152), Enum.Material.LeafyGrass, Enum.Material.Mud)
	if cfg.lake then
		replaceGround(Vector3.new(ox - 122, -10, oz - 157), Vector3.new(ox - 58, 4, oz - 93), Enum.Material.Grass, Enum.Material.Sand)
		terrain:FillBlock(CFrame.new(ox - 90, 0, oz - 125), Vector3.new(48, 8, 48), Enum.Material.Air)
		fillT(grp, CFrame.new(ox - 90, -3.5, oz - 125), Vector3.new(40, 5, 40), Enum.Material.Water)
	end
	-- crista do canyon + passagem única
	fillT(grp, CFrame.new(ox - 124, 6, oz + RIDGE_Z), Vector3.new(232, 16, 14), Enum.Material.Rock)
	fillT(grp, CFrame.new(ox + 124, 6, oz + RIDGE_Z), Vector3.new(232, 16, 14), Enum.Material.Rock)
	fillT(grp, CFrame.new(ox - 130, 14, oz + RIDGE_Z), Vector3.new(212, 10, 10), Enum.Material.Rock)
	fillT(grp, CFrame.new(ox + 130, 14, oz + RIDGE_Z), Vector3.new(212, 10, 10), Enum.Material.Rock)
	-- perímetro
	fillT(grp, CFrame.new(ox, 10, oz + HALF - 6), Vector3.new(HALF * 2 + 40, 32, 28), Enum.Material.Rock)
	fillT(grp, CFrame.new(ox, 10, oz - (HALF - 6)), Vector3.new(HALF * 2 + 40, 32, 28), Enum.Material.Rock)
	fillT(grp, CFrame.new(ox + HALF - 6, 10, oz), Vector3.new(28, 32, HALF * 2 + 40), Enum.Material.Rock)
	fillT(grp, CFrame.new(ox - (HALF - 6), 10, oz), Vector3.new(28, 32, HALF * 2 + 40), Enum.Material.Rock)
	-- portões: carva a abertura da estrada na muralha e re-nivela o chão do vão
	local function carveGate(wallZ)
		terrain:FillBlock(CFrame.new(ox, 14, wallZ), Vector3.new(GATE_W - 12, 28, 36), Enum.Material.Air)
		fillT(grp, CFrame.new(ox, -2, wallZ), Vector3.new(GATE_W - 12, 4, 36), Enum.Material.Ground)
	end
	if gates and gates.south then
		carveGate(oz - (HALF - 6))
	end
	if gates and gates.north then
		carveGate(oz + HALF - 6)
	end

	local mapa = Instance.new("Model")
	mapa.Name = "Mapa_" .. id
	mapa.Parent = mundoFolder()
	regInstance(grp, mapa)

	mkPart("PilarOeste", Vector3.new(3, 14, 8), Vector3.new(ox - 6.5, 7, oz + RIDGE_Z), ROCK_COLOR, mapa)
	mkPart("PilarLeste", Vector3.new(3, 14, 8), Vector3.new(ox + 6.5, 7, oz + RIDGE_Z), ROCK_COLOR, mapa)
	mkPart("GapMarker", Vector3.new(10, 0.2, 6), Vector3.new(ox, terrainGroundY(ox, oz + RIDGE_Z) + 0.12, oz + RIDGE_Z),
		Color3.fromRGB(80, 200, 120), mapa, { CanCollide = false, Transparency = 0.5, Material = Enum.Material.Neon })

	-- círculo de fogueira (sugere onde construir)
	local circY = terrainGroundY(ox + 13, oz - 42)
	mkPart("CirculoFogueira", Vector3.new(4.4, 0.2, 4.4), Vector3.new(ox + 13, circY + 0.1, oz - 42), Color3.fromRGB(45, 40, 36), mapa,
		{ CanCollide = false, Material = Enum.Material.Ground })
	for k = 1, 6 do
		local ang = (k / 6) * math.pi * 2
		local fx, fz = ox + 13 + math.cos(ang) * 2.4, oz - 42 + math.sin(ang) * 2.4
		mkPart("PedraFogueira" .. k, Vector3.new(1.2, 0.9, 1.1),
			Vector3.new(fx, terrainGroundY(fx, fz) + 0.35, fz), ROCK_COLOR, mapa)
	end

	-- pedras decorativas
	scatter(rng, cfg.rocks, -220, 215, cfg.lake, function(i, lx, lz)
		local x, z = ox + lx, oz + lz
		local s = rng:NextNumber(2.4, 6)
		local ry = terrainGroundY(x, z) + s * 0.3
		local p = mkPart("Pedra" .. i, Vector3.new(s, s * 0.7, s * 0.9), Vector3.new(x, ry, z), ROCK_COLOR, mapa)
		p.CFrame = CFrame.new(x, ry, z) * CFrame.Angles(rng:NextNumber(-0.2, 0.2), rng:NextNumber(0, 6.28), rng:NextNumber(-0.2, 0.2))
	end)

	-- recursos por zona: ResourceNodes/<id>/Trees|FoodBushes (o nome interno "Trees"/"FoodBushes"
	-- é o contrato com o clique de coleta do cliente)
	local resZone = ensureFolder(ensureFolder(workspace, "ResourceNodes"), id)
	regInstance(grp, resZone)
	local treesF = ensureFolder(resZone, "Trees")
	local bushesF = ensureFolder(resZone, "FoodBushes")
	scatter(rng, cfg.trees, -220, 8, cfg.lake, function(i, lx, lz)
		mkTree(rng, treesF, i, ox + lx, oz + lz, false)
	end)
	scatter(rng, cfg.deadTrees, 52, 200, false, function(i, lx, lz)
		mkTree(rng, treesF, 100 + i, ox + lx, oz + lz, true)
	end)
	scatter(rng, cfg.bushes, -220, 4, cfg.lake, function(i, lx, lz)
		mkBush(rng, bushesF, i, ox + lx, oz + lz)
	end)

	-- features por tipo
	if kind == "estacao" then
		mkPart("Plataforma", Vector3.new(22, 1.5, 10), Vector3.new(ox + 26, 0.75, oz - 46), Color3.fromRGB(118, 92, 62), mapa,
			{ Material = Enum.Material.WoodPlanks })
		mkPart("TrilhoOeste", Vector3.new(0.5, 0.5, 110), Vector3.new(ox + 16.6, 0.25, oz - 60), Color3.fromRGB(70, 70, 78), mapa,
			{ Material = Enum.Material.Metal })
		mkPart("TrilhoLeste", Vector3.new(0.5, 0.5, 110), Vector3.new(ox + 20.0, 0.25, oz - 60), Color3.fromRGB(70, 70, 78), mapa,
			{ Material = Enum.Material.Metal })
		for d = 0, 10 do
			mkPart("Dormente" .. d, Vector3.new(6, 0.4, 1.2), Vector3.new(ox + 18.3, 0.2, oz - 110 + d * 10),
				Color3.fromRGB(80, 60, 40), mapa, { Material = Enum.Material.Wood })
		end
		for c = 1, cfg.crates do
			mkCrate(bushesF, c, ox + 20 + c * 5, oz - 44, 1.5)
		end
	elseif kind == "mina" then
		fillT(grp, CFrame.new(ox + 150, 8, oz - 70), Vector3.new(44, 20, 34), Enum.Material.Rock)
		mkPart("MinaBoca", Vector3.new(2, 9, 8), Vector3.new(ox + 127.5, 4.5, oz - 70), Color3.fromRGB(15, 13, 12), mapa,
			{ Material = Enum.Material.Basalt })
		mkPart("MinaVigaSul", Vector3.new(1, 10, 1), Vector3.new(ox + 126, 5, oz - 75), Color3.fromRGB(96, 70, 44), mapa,
			{ Material = Enum.Material.Wood })
		mkPart("MinaVigaNorte", Vector3.new(1, 10, 1), Vector3.new(ox + 126, 5, oz - 65), Color3.fromRGB(96, 70, 44), mapa,
			{ Material = Enum.Material.Wood })
		mkPart("MinaVerga", Vector3.new(1, 1, 12), Vector3.new(ox + 126, 10.5, oz - 70), Color3.fromRGB(96, 70, 44), mapa,
			{ Material = Enum.Material.Wood })
	elseif kind == "acampamento" then
		for t, pos in ipairs({ { -26, -62 }, { 28, -66 }, { -22, -26 } }) do
			local x, z = ox + pos[1], oz + pos[2]
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
			mkCrate(bushesF, c, ox + (c == 1 and -30 or 34), oz + (c == 1 and -40 or -50), 0)
		end
	elseif kind == "boss" then
		-- covil: portal escuro onde a estrada termina
		mkPart("CovilPilarOeste", Vector3.new(6, 20, 6), Vector3.new(ox - 9, 10, oz + 150), Color3.fromRGB(40, 36, 40), mapa,
			{ Material = Enum.Material.Basalt })
		mkPart("CovilPilarLeste", Vector3.new(6, 20, 6), Vector3.new(ox + 9, 10, oz + 150), Color3.fromRGB(40, 36, 40), mapa,
			{ Material = Enum.Material.Basalt })
		mkPart("CovilVerga", Vector3.new(26, 6, 6), Vector3.new(ox, 21, oz + 150), Color3.fromRGB(35, 32, 36), mapa,
			{ Material = Enum.Material.Basalt })
		mkPart("CovilFundo", Vector3.new(20, 18, 2), Vector3.new(ox, 9, oz + 154), Color3.fromRGB(12, 10, 14), mapa,
			{ Material = Enum.Material.Basalt })
		for b = 1, 6 do
			local bx, bz = ox + rng:NextNumber(-30, 30), oz + rng:NextNumber(60, 140)
			mkPart("Osso" .. b, Vector3.new(rng:NextNumber(1.5, 3), 0.6, 0.6),
				Vector3.new(bx, terrainGroundY(bx, bz) + 0.3, bz),
				Color3.fromRGB(220, 214, 196), mapa, { Material = Enum.Material.SmoothPlastic })
		end
	end

	-- spawns de inimigos por zona (norte, atrás do funil): EnemySpawns/<id>
	local spawnsFolder = ensureFolder(ensureFolder(workspace, "EnemySpawns"), id)
	regInstance(grp, spawnsFolder)
	for i, xz in ipairs({ { -30, 118 }, { 0, 124 }, { 30, 118 }, { -14, 136 }, { 16, 136 } }) do
		local sx, sz = ox + xz[1], oz + xz[2]
		local pad = mkPart("Spawn" .. i, Vector3.new(8, 0.4, 8), Vector3.new(sx, terrainGroundY(sx, sz) + 0.2, sz),
			Color3.fromRGB(170, 60, 60), spawnsFolder, { CanCollide = false, Transparency = 0.55, Material = Enum.Material.Neon })
		pad.Locked = true
	end

	local zone = {
		id = id,
		kind = kind,
		center = center,
		-- limites físicos do POI (decidem permanência vs avanço no amanhecer, doc 5.4 rev.3)
		bounds = { minX = ox - HALF, maxX = ox + HALF, minZ = oz - HALF, maxZ = oz + HALF },
		-- faixa de chegada logo depois do portão sul (volume de trigger checado por poll no servidor:
		-- .Touched não é confiável com StreamingEnabled + física no cliente do motorista)
		arrivalRect = { minX = ox - 34, maxX = ox + 34, minZ = oz - HALF + 26, maxZ = oz - HALF + 60 },
		campCf = CFrame.new(ox, CARAVAN_Y, oz + CAMP_Z),
		campPos = Vector3.new(ox, 0, oz + CAMP_Z),
		spawnPos = Vector3.new(ox - 16, 0.5, oz - 42),
		ridgeZ = oz + RIDGE_Z,
		gapPos = Vector3.new(ox, 3, oz + RIDGE_Z),
		covilPos = kind == "boss" and Vector3.new(ox, 5, oz + 142) or nil,
	}
	world.zones[id] = zone
	return zone
end

-- ===== corredores e plazas (trechos autorados entre POIs) =====
-- corredor no eixo Z: chão + taludes de pedra + guardrails invisíveis
local function corridorZ(grp, x, z1, z2)
	local mid, len = (z1 + z2) / 2, math.abs(z2 - z1)
	fillT(grp, CFrame.new(x, -6, mid), Vector3.new(CORR_HALF * 2, 12, len), Enum.Material.Ground)
	fillT(grp, CFrame.new(x - BERM_OFF, 8, mid), Vector3.new(12, 20, len), Enum.Material.Rock)
	fillT(grp, CFrame.new(x + BERM_OFF, 8, mid), Vector3.new(12, 20, len), Enum.Material.Rock)
	local mapa = Instance.new("Model")
	mapa.Name = "Corr_" .. grp .. "_" .. math.floor(mid)
	mapa.Parent = mundoFolder()
	regInstance(grp, mapa)
	mkGuardrail(mapa, "GuardrailOeste", Vector3.new(x - GUARD_OFF, 9, mid), Vector3.new(2, 22, len))
	mkGuardrail(mapa, "GuardrailLeste", Vector3.new(x + GUARD_OFF, 9, mid), Vector3.new(2, 22, len))
end

-- corredor no eixo X
local function corridorX(grp, z, x1, x2)
	local mid, len = (x1 + x2) / 2, math.abs(x2 - x1)
	fillT(grp, CFrame.new(mid, -6, z), Vector3.new(len, 12, CORR_HALF * 2), Enum.Material.Ground)
	fillT(grp, CFrame.new(mid, 8, z - BERM_OFF), Vector3.new(len, 20, 12), Enum.Material.Rock)
	fillT(grp, CFrame.new(mid, 8, z + BERM_OFF), Vector3.new(len, 20, 12), Enum.Material.Rock)
	local mapa = Instance.new("Model")
	mapa.Name = "Corr_" .. grp .. "_" .. math.floor(mid)
	mapa.Parent = mundoFolder()
	regInstance(grp, mapa)
	mkGuardrail(mapa, "GuardrailSul", Vector3.new(mid, 9, z - GUARD_OFF), Vector3.new(len, 22, 2))
	mkGuardrail(mapa, "GuardrailNorte", Vector3.new(mid, 9, z + GUARD_OFF), Vector3.new(len, 22, 2))
end

-- plaza de junção (fork/merge): chão aberto, taludes com aberturas nos lados conectados
-- e anel de guardrail com os mesmos vãos
local function plaza(grp, center, openings)
	local ox, oz = center.X, center.Z
	fillT(grp, CFrame.new(ox, -6, oz), Vector3.new(PLAZA_HALF * 2, 12, PLAZA_HALF * 2), Enum.Material.Ground)
	local mapa = Instance.new("Model")
	mapa.Name = "Plaza_" .. grp
	mapa.Parent = mundoFolder()
	regInstance(grp, mapa)
	local B = PLAZA_HALF + 6 -- centro do talude
	local G = PLAZA_HALF - 4 -- anel de guardrail
	local span = PLAZA_HALF * 2 + 24
	-- cada lado: talude (e guardrail) inteiro, ou em duas metades deixando o vão da estrada
	local function side(dir) -- dir: "N","S","E","W"
		local open = openings[dir]
		local horizontal = dir == "N" or dir == "S"
		local sign = (dir == "N" or dir == "E") and 1 or -1
		local wallC = horizontal and Vector3.new(ox, 8, oz + sign * B) or Vector3.new(ox + sign * B, 8, oz)
		local guardC = horizontal and Vector3.new(ox, 9, oz + sign * G) or Vector3.new(ox + sign * G, 9, oz)
		if not open then
			fillT(grp, CFrame.new(wallC), horizontal and Vector3.new(span, 20, 12) or Vector3.new(12, 20, span), Enum.Material.Rock)
			mkGuardrail(mapa, "Guard" .. dir, guardC, horizontal and Vector3.new(span, 22, 2) or Vector3.new(2, 22, span))
		else
			local segLen = (span - GATE_W) / 2
			local off = (GATE_W + segLen) / 2
			for _, s2 in ipairs({ -1, 1 }) do
				local wallPos = horizontal and Vector3.new(ox + s2 * off, 8, oz + sign * B) or Vector3.new(ox + sign * B, 8, oz + s2 * off)
				local guardPos = horizontal and Vector3.new(ox + s2 * off, 9, oz + sign * G) or Vector3.new(ox + sign * G, 9, oz + s2 * off)
				fillT(grp, CFrame.new(wallPos), horizontal and Vector3.new(segLen, 20, 12) or Vector3.new(12, 20, segLen), Enum.Material.Rock)
				mkGuardrail(mapa, "Guard" .. dir, guardPos, horizontal and Vector3.new(segLen, 22, 2) or Vector3.new(2, 22, segLen))
			end
		end
	end
	side("N")
	side("S")
	side("E")
	side("W")
end

-- ===== o mundo inteiro da run (doc 4.6: grafo abstrato decide o layout; geometria autorada) =====
-- Layout fixo do MVP, espelhando a forma fixa do RouteGraph:
--   n1 (0,0) -> plaza do fork (0,460) -> braços em L -> n2a (-380,1040) | n2b (380,1040)
--   -> braços de merge -> plaza (0,1500) -> n3 (0,1840) -> corredor -> boss (0,2460)
-- Grupos destrutíveis: "n1", "corr_fork", "arm_n2a"/"arm_n2b" (braços de ida E volta do ramo),
-- "n2a"/"n2b", "corr_merge", "n3", "corr_boss", "boss".
local WORLD_CENTERS = {
	n1 = Vector3.new(0, 0, 0),
	n2a = Vector3.new(-380, 0, 1040),
	n2b = Vector3.new(380, 0, 1040),
	n3 = Vector3.new(0, 0, 1840),
	boss = Vector3.new(0, 0, 2460),
}
local FORK_PLAZA = Vector3.new(0, 0, 460)
local MERGE_PLAZA = Vector3.new(0, 0, 1500)

function ZoneBuilder.buildWorld(graph)
	clearWorld()
	world = { zones = {}, groups = {}, forkCommitted = false }

	-- POIs (tipos vêm do grafo abstrato; posição é o slot fixo do layout)
	buildPOI(graph.nodes.n1.kind, "n1", WORLD_CENTERS.n1, { south = false, north = true })
	buildPOI(graph.nodes.n2a.kind, "n2a", WORLD_CENTERS.n2a, { south = true, north = true })
	buildPOI(graph.nodes.n2b.kind, "n2b", WORLD_CENTERS.n2b, { south = true, north = true })
	buildPOI(graph.nodes.n3.kind, "n3", WORLD_CENTERS.n3, { south = true, north = true })
	buildPOI(graph.nodes.boss.kind, "boss", WORLD_CENTERS.boss, { south = true, north = false })

	-- corredor pré-fork + plaza do fork (aberturas: sul=n1, oeste/leste=ramos)
	corridorZ("corr_fork", 0, HALF - 14, FORK_PLAZA.Z - PLAZA_HALF + 8)
	plaza("corr_fork", FORK_PLAZA, { S = true, E = true, W = true, N = false })

	-- braços do fork e do merge, por ramo (grupo do ramo: some junto com ele)
	for _, branch in ipairs({ { id = "n2a", sign = -1 }, { id = "n2b", sign = 1 } }) do
		local grp = "arm_" .. branch.id
		local bx = WORLD_CENTERS[branch.id].X
		local bz = WORLD_CENTERS[branch.id].Z
		-- ida: plaza do fork -> POI do ramo (braço em L, eixos alinhados)
		corridorX(grp, FORK_PLAZA.Z, branch.sign * (PLAZA_HALF - 8), bx + branch.sign * BERM_OFF)
		corridorZ(grp, bx, FORK_PLAZA.Z - BERM_OFF, bz - HALF + 14)
		-- volta: POI do ramo -> plaza do merge
		corridorZ(grp, bx, bz + HALF - 14, MERGE_PLAZA.Z + BERM_OFF)
		corridorX(grp, MERGE_PLAZA.Z, bx - branch.sign * BERM_OFF, branch.sign * (PLAZA_HALF - 8))
	end

	-- plaza do merge (aberturas: oeste/leste=ramos, norte=n3) + stub até o portão de n3
	plaza("corr_merge", MERGE_PLAZA, { S = false, E = true, W = true, N = true })
	corridorZ("corr_merge", 0, MERGE_PLAZA.Z + PLAZA_HALF - 8, WORLD_CENTERS.n3.Z - HALF + 14)

	-- corredor n3 -> covil
	corridorZ("corr_boss", 0, WORLD_CENTERS.n3.Z + HALF - 14, WORLD_CENTERS.boss.Z - HALF + 14)

	-- retângulos de commit do fork (passo 4): dentro de cada braço, passada a plaza
	world.commitRects = {
		n2a = { minX = -180, maxX = -140, minZ = FORK_PLAZA.Z - CORR_HALF, maxZ = FORK_PLAZA.Z + CORR_HALF },
		n2b = { minX = 140, maxX = 180, minZ = FORK_PLAZA.Z - CORR_HALF, maxZ = FORK_PLAZA.Z + CORR_HALF },
	}

	return world
end

function ZoneBuilder.getWorld()
	return world
end

-- passo 4: trava a escolha do fork. Destrói a geometria do ramo NÃO escolhido (braço de ida/volta
-- + o POI) e sela a abertura correspondente da plaza pra caravana não cair no vazio deixado pelo
-- chão destruído. Retorna o id do ramo destruído, ou nil se o fork já foi travado.
function ZoneBuilder.commitFork(chosenId)
	if not world or world.forkCommitted then
		return nil
	end
	world.forkCommitted = true
	local other = chosenId == "n2a" and "n2b" or "n2a"
	ZoneBuilder.destroyGroup("arm_" .. other)
	ZoneBuilder.destroyGroup(other)
	-- parede na abertura da plaza do lado destruído (só a caravana colide; jogadores atravessam)
	local sign = other == "n2a" and -1 or 1
	ZoneBuilder.sealGate(Vector3.new(sign * (PLAZA_HALF - 4), 0, FORK_PLAZA.Z), false)
	return other
end

function ZoneBuilder.isForkCommitted()
	return world ~= nil and world.forkCommitted == true
end

-- ===== lobby (passo 9): posto de partida com catálogo; zona pequena e segura, sem funil e sem inimigos =====
function ZoneBuilder.buildLobby()
	clearWorld()

	terrain:FillBlock(CFrame.new(0, -6, 0), Vector3.new(160, 12, 160), Enum.Material.Grass)
	replaceGround(Vector3.new(-26, -10, -26), Vector3.new(26, 4, 34), Enum.Material.Grass, Enum.Material.Ground)
	-- muros de pedra fechando o posto
	terrain:FillBlock(CFrame.new(0, 6, 76), Vector3.new(176, 28, 16), Enum.Material.Rock)
	terrain:FillBlock(CFrame.new(0, 6, -76), Vector3.new(176, 28, 16), Enum.Material.Rock)
	terrain:FillBlock(CFrame.new(76, 6, 0), Vector3.new(16, 28, 176), Enum.Material.Rock)
	terrain:FillBlock(CFrame.new(-76, 6, 0), Vector3.new(16, 28, 176), Enum.Material.Rock)

	local mapa = Instance.new("Model")
	mapa.Name = "Mapa_lobby"
	mapa.Parent = mundoFolder()

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
		id = "lobby",
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
	-- a caravana é o pivô do gameplay: nunca pode ser descarregada pelo streaming no cliente
	m.ModelStreamingMode = Enum.ModelStreamingMode.Persistent

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

-- trava/destrava a caravana (noite, lobby): Root ancorado = assembly inteiro parado.
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

-- tira todo mundo dos assentos (necessário antes de pivôs longos de lobby/início de run)
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
	clearWorld()
	world = { zones = {}, groups = {} }
	local info = buildPOI(kind or "estacao", "preview", Vector3.zero, { south = false, north = true })
	moveSpawnLocation(info.spawnPos)
	ZoneBuilder.pivotCaravanaTo(info.campCf)
	print("[ZoneBuilder] Preview construído: " .. (kind or "estacao"))
	return info
end

return ZoneBuilder
