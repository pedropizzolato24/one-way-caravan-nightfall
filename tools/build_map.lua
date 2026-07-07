-- One Way Caravan: Nightfall — constrói o mapa do nó MVP + caravana (rodar na Command Bar do Studio, modo Edit).
-- Substitui o antigo build_greybox.lua. Agora com:
--   * terreno natural (Terrain API), mapa 480x480 fechado por montanhas (sem parede invisível)
--   * estrada da caravana sul->norte cruzando um canyon com passagem única (funil do doc 5.4)
--   * floresta de recursos ao sul + lago; território da ameaça ao norte (madeira seca arriscada, spawns)
--   * modelo da caravana (doc 4.5): "base que anda", Root ancorado + partes soldadas, pronta p/ PivotTo/tween no passo 7
-- Os scripts (Server/Client) sincronizam via Rojo; o WeaponClient deve ser colado dentro da Tool Machado criada aqui.

local Lighting = game:GetService("Lighting")
local terrain = workspace.Terrain
local rng = Random.new(1897)

-- ===== limpeza idempotente =====
for _, n in ipairs({ "ResourceNodes", "Structures", "Enemies", "EnemySpawns", "GreyboxMap", "Mapa", "Caravana", "Baseplate" }) do
	local x = workspace:FindFirstChild(n)
	if x then x:Destroy() end
end
local old = game.ReplicatedStorage:FindFirstChild("Remotes")
if old then old:Destroy() end
old = game.StarterPack:FindFirstChild("Machado")
if old then old:Destroy() end
terrain:Clear()

-- ===== terreno =====
local HALF = 240
-- chão base de grama, superfície em y=0
terrain:FillBlock(CFrame.new(0, -6, 0), Vector3.new(HALF * 2, 12, HALF * 2), Enum.Material.Grass)

local function replaceGround(minV, maxV, from, to)
	terrain:ReplaceMaterial(Region3.new(minV, maxV):ExpandToGrid(4), 4, from, to)
end

-- estrada da caravana (sul -> norte, atravessa a passagem do canyon)
replaceGround(Vector3.new(-8, -10, -HALF), Vector3.new(8, 4, HALF), Enum.Material.Grass, Enum.Material.Ground)
-- clareira do acampamento
replaceGround(Vector3.new(-34, -10, -78), Vector3.new(34, 4, -18), Enum.Material.Grass, Enum.Material.Ground)
-- metade norte: território da ameaça
replaceGround(Vector3.new(-HALF, -10, 38), Vector3.new(HALF, 4, HALF), Enum.Material.Grass, Enum.Material.LeafyGrass)
replaceGround(Vector3.new(-52, -10, 96), Vector3.new(52, 4, 152), Enum.Material.LeafyGrass, Enum.Material.Mud)
-- lago sudoeste: margem de areia + água
replaceGround(Vector3.new(-122, -10, -157), Vector3.new(-58, 4, -93), Enum.Material.Grass, Enum.Material.Sand)
terrain:FillBlock(CFrame.new(-90, 0, -125), Vector3.new(48, 8, 48), Enum.Material.Air)
terrain:FillBlock(CFrame.new(-90, -3.5, -125), Vector3.new(40, 5, 40), Enum.Material.Water)
-- crista do canyon em z=30 com passagem única em x=0 (funil geográfico, doc 2 e 5.4)
terrain:FillBlock(CFrame.new(-124, 6, 30), Vector3.new(232, 16, 14), Enum.Material.Rock)
terrain:FillBlock(CFrame.new(124, 6, 30), Vector3.new(232, 16, 14), Enum.Material.Rock)
terrain:FillBlock(CFrame.new(-130, 14, 30), Vector3.new(212, 10, 10), Enum.Material.Rock)
terrain:FillBlock(CFrame.new(130, 14, 30), Vector3.new(212, 10, 10), Enum.Material.Rock)
-- montanhas de perímetro
terrain:FillBlock(CFrame.new(0, 10, HALF - 6), Vector3.new(HALF * 2 + 40, 32, 28), Enum.Material.Rock)
terrain:FillBlock(CFrame.new(0, 10, -(HALF - 6)), Vector3.new(HALF * 2 + 40, 32, 28), Enum.Material.Rock)
terrain:FillBlock(CFrame.new(HALF - 6, 10, 0), Vector3.new(28, 32, HALF * 2 + 40), Enum.Material.Rock)
terrain:FillBlock(CFrame.new(-(HALF - 6), 10, 0), Vector3.new(28, 32, HALF * 2 + 40), Enum.Material.Rock)

-- ===== helpers de parts =====
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

local mapa = Instance.new("Model")
mapa.Name = "Mapa"
mapa.Parent = workspace

-- pilares que fecham a passagem em exatamente 10 studs (slot da barricada; o voxel do Terrain não é preciso)
local rockColor = Color3.fromRGB(104, 101, 96)
mkPart("PilarOeste", Vector3.new(3, 14, 8), Vector3.new(-6.5, 7, 30), rockColor, mapa)
mkPart("PilarLeste", Vector3.new(3, 14, 8), Vector3.new(6.5, 7, 30), rockColor, mapa)
mkPart("GapMarker", Vector3.new(10, 0.2, 6), Vector3.new(0, 0.1, 30), Color3.fromRGB(80, 200, 120), mapa,
	{ CanCollide = false, Transparency = 0.5, Material = Enum.Material.Neon })

-- círculo de fogueira do acampamento (decorativo: sugere onde construir)
mkPart("CirculoFogueira", Vector3.new(4.4, 0.2, 4.4), Vector3.new(13, 0.1, -42), Color3.fromRGB(45, 40, 36), mapa,
	{ CanCollide = false, Material = Enum.Material.Ground })
for k = 1, 6 do
	local ang = (k / 6) * math.pi * 2
	mkPart("PedraFogueira" .. k, Vector3.new(1.2, 0.9, 1.1), Vector3.new(13 + math.cos(ang) * 2.4, 0.4, -42 + math.sin(ang) * 2.4), rockColor, mapa)
end

-- pedras espalhadas (decorativas)
local rockPos = {
	{ -20, 44 }, { 26, 46 }, { -60, 20 }, { 70, 16 }, { -120, 44 }, { 130, 20 },
	{ -30, -192 }, { 50, -202 }, { 150, -44 }, { -180, -44 }, { 92, 92 }, { -92, 132 },
	{ 26, 150 }, { -160, 122 }, { 172, 84 }, { 112, 182 },
}
for i, xz in ipairs(rockPos) do
	local s = rng:NextNumber(2.4, 6)
	local p = mkPart("Pedra" .. i, Vector3.new(s, s * 0.7, s * 0.9), Vector3.new(xz[1], s * 0.3, xz[2]), rockColor, mapa)
	p.CFrame = CFrame.new(xz[1], s * 0.3, xz[2]) * CFrame.Angles(rng:NextNumber(-0.2, 0.2), rng:NextNumber(0, 6.28), rng:NextNumber(-0.2, 0.2))
end

-- ===== pastas de gameplay =====
local resourceNodes = Instance.new("Folder"); resourceNodes.Name = "ResourceNodes"; resourceNodes.Parent = workspace
local treesFolder = Instance.new("Folder"); treesFolder.Name = "Trees"; treesFolder.Parent = resourceNodes
local bushesFolder = Instance.new("Folder"); bushesFolder.Name = "FoodBushes"; bushesFolder.Parent = resourceNodes
local structures = Instance.new("Folder"); structures.Name = "Structures"; structures.Parent = workspace
local enemies = Instance.new("Folder"); enemies.Name = "Enemies"; enemies.Parent = workspace

-- ===== árvores (madeira) =====
local function mkTree(i, x, z, dead)
	local s = rng:NextNumber(0.85, 1.25)
	local m = Instance.new("Model")
	m.Name = (dead and "ArvoreSeca" or "Arvore") .. i
	local trunkColor = dead and Color3.fromRGB(74, 56, 40) or Color3.fromRGB(110, 76, 44)
	local trunk = mkPart("Tronco", Vector3.new(1.6 * s, 7 * s, 1.6 * s), Vector3.new(x, 3.5 * s, z), trunkColor, m,
		{ Material = Enum.Material.Wood })
	if dead then
		for g = 1, 2 do
			local galho = mkPart("Galho" .. g, Vector3.new(0.7 * s, 4 * s, 0.7 * s), Vector3.new(x, 6.8 * s, z),
				Color3.fromRGB(70, 52, 38), m, { Material = Enum.Material.Wood })
			galho.CFrame = CFrame.new(x, 6.8 * s, z)
				* CFrame.Angles(0, rng:NextNumber(0, 6.28), math.rad(g == 1 and 35 or -30))
				* CFrame.new(0, 1.4 * s, 0)
		end
	else
		local g = 90 + rng:NextInteger(-25, 25)
		mkPart("Copa1", Vector3.new(6 * s, 6 * s, 6 * s), Vector3.new(x, 8.2 * s, z), Color3.fromRGB(56, g, 52), m,
			{ Shape = Enum.PartType.Ball, Material = Enum.Material.Grass, CanCollide = false })
		mkPart("Copa2", Vector3.new(4.2 * s, 4.2 * s, 4.2 * s),
			Vector3.new(x + rng:NextNumber(-1, 1), 11 * s, z + rng:NextNumber(-1, 1)), Color3.fromRGB(50, g - 12, 48), m,
			{ Shape = Enum.PartType.Ball, Material = Enum.Material.Grass, CanCollide = false })
	end
	m.PrimaryPart = trunk
	m:SetAttribute("NodeType", "Wood")
	m:SetAttribute("Uses", dead and 8 or 5)
	m:SetAttribute("MaxUses", dead and 8 or 5)
	m.Parent = treesFolder
end

-- floresta sul + algumas antes da crista (coleta segura)
local treePos = {
	{ -52, -58 }, { -68, -46 }, { -60, -74 }, { -80, -62 }, { -44, -88 }, { -48, -96 },
	{ -36, -120 }, { -52, -142 }, { -30, -162 }, { -70, -172 }, { -102, -182 }, { -132, -152 },
	{ -142, -112 }, { -152, -72 }, { -122, -42 }, { -172, -132 }, { -182, -84 },
	{ 40, -42 }, { 56, -54 }, { 48, -72 }, { 72, -64 }, { 92, -50 }, { 64, -92 },
	{ 44, -112 }, { 82, -122 }, { 112, -92 }, { 132, -132 }, { 102, -162 }, { 62, -172 },
	{ 152, -62 }, { 172, -112 }, { 142, -172 }, { 30, -142 },
	{ -32, 2 }, { 38, -6 }, { -54, 12 }, { 58, 8 },
}
for i, xz in ipairs(treePos) do
	mkTree(i, xz[1], xz[2], false)
end
-- madeira seca no norte: mais usos, mas é o lado de onde a horda vem (risco diurno baixo, aposta de rota)
local deadTreePos = { { -30, 70 }, { 42, 82 }, { -62, 112 }, { 72, 122 }, { -22, 152 }, { 34, 172 }, { -72, 162 }, { 58, 58 } }
for i, xz in ipairs(deadTreePos) do
	mkTree(100 + i, xz[1], xz[2], true)
end

-- ===== arbustos (comida) =====
local function mkBush(i, x, z)
	local s = rng:NextNumber(0.9, 1.2)
	local m = Instance.new("Model")
	m.Name = "Arbusto" .. i
	local folhas = mkPart("Folhas", Vector3.new(3.4 * s, 2.8 * s, 3.4 * s), Vector3.new(x, 1.4 * s, z),
		Color3.fromRGB(64, 118, 56), m, { Shape = Enum.PartType.Ball, Material = Enum.Material.Grass })
	mkPart("Frutas", Vector3.new(1.3, 1.3, 1.3), Vector3.new(x + 0.9 * s, 2.2 * s, z + 0.5 * s),
		Color3.fromRGB(196, 60, 70), m, { Shape = Enum.PartType.Ball, Material = Enum.Material.SmoothPlastic, CanCollide = false })
	m.PrimaryPart = folhas
	m:SetAttribute("NodeType", "Food")
	m:SetAttribute("Uses", 4)
	m:SetAttribute("MaxUses", 4)
	m.Parent = bushesFolder
end

local bushPos = {
	{ -40, -30 }, { 38, -36 }, { -56, -92 }, { 50, -86 }, { -26, -132 }, { 32, -122 },
	{ -84, -96 }, { -108, -158 }, { 92, -142 }, { 122, -72 }, { 64, -26 }, { -146, -102 },
	{ -42, 92 }, { 52, 102 },
}
for i, xz in ipairs(bushPos) do
	mkBush(i, xz[1], xz[2])
end

-- ===== pontos de spawn de inimigos (o servidor lê esta pasta) =====
local spawnsFolder = Instance.new("Folder")
spawnsFolder.Name = "EnemySpawns"
for i, xz in ipairs({ { -30, 118 }, { 0, 124 }, { 30, 118 }, { -14, 136 }, { 16, 136 } }) do
	local pad = mkPart("Spawn" .. i, Vector3.new(8, 0.4, 8), Vector3.new(xz[1], 0.2, xz[2]),
		Color3.fromRGB(170, 60, 60), spawnsFolder, { CanCollide = false, Transparency = 0.55, Material = Enum.Material.Neon })
	pad.Locked = true
end
spawnsFolder.Parent = workspace

-- ===== spawn dos jogadores no acampamento =====
local sl = workspace:FindFirstChild("SpawnLocation")
if not sl then
	sl = Instance.new("SpawnLocation")
	sl.Parent = workspace
end
sl.Size = Vector3.new(12, 1, 12)
sl.Position = Vector3.new(-16, 0.5, -42)
sl.Anchored = true
sl.Neutral = true
sl.Duration = 0
sl.Color = Color3.fromRGB(116, 90, 60)
sl.Material = Enum.Material.WoodPlanks

-- ===== caravana (doc 4.5: NPC-driven, "base que anda"; Root ancorado + tudo soldado p/ mover via CFrame no passo 7) =====
local function buildCaravana(pivotCf)
	local m = Instance.new("Model")
	m.Name = "Caravana"

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(6.5, 1, 15)
	root.CFrame = CFrame.new(0, 2.5, 0) -- construída na origem olhando +Z; PivotTo posiciona no fim
	root.Transparency = 1
	root.CanCollide = false
	root.Anchored = true
	root.Parent = m
	m.PrimaryPart = root

	local function cpart(name, size, cf, color, material, opts)
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cf
		p.Color = color
		p.Material = material or Enum.Material.Wood
		p.Anchored = false
		p.CanCollide = true
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

	-- chassi
	cpart("Cama", Vector3.new(6, 0.8, 14), CFrame.new(0, 3.2, -1), madeira)
	cpart("LateralOeste", Vector3.new(0.6, 2.4, 14), CFrame.new(-3.3, 4.6, -1), madeiraClara, Enum.Material.WoodPlanks)
	cpart("LateralLeste", Vector3.new(0.6, 2.4, 14), CFrame.new(3.3, 4.6, -1), madeiraClara, Enum.Material.WoodPlanks)
	cpart("PainelFrente", Vector3.new(7.2, 2.4, 0.6), CFrame.new(0, 4.6, 6), madeiraClara, Enum.Material.WoodPlanks)
	cpart("PainelTras", Vector3.new(7.2, 2.4, 0.6), CFrame.new(0, 4.6, -8), madeiraClara, Enum.Material.WoodPlanks)
	cpart("Viga", Vector3.new(0.8, 0.6, 13), CFrame.new(0, 2.5, -0.5), madeiraEscura)
	cpart("EixoTras", Vector3.new(8, 0.5, 0.5), CFrame.new(0, 2.4, -4.5), madeiraEscura)
	cpart("EixoFrente", Vector3.new(7.4, 0.5, 0.5), CFrame.new(0, 1.9, 3.5), madeiraEscura)

	-- rodas (traseiras maiores, estilo carroça coberta)
	for _, r in ipairs({ { -3.9, 2.4, -4.5, 4.8 }, { 3.9, 2.4, -4.5, 4.8 }, { -3.8, 1.9, 3.5, 3.8 }, { 3.8, 1.9, 3.5, 3.8 } }) do
		cpart("Roda", Vector3.new(0.7, r[4], r[4]), CFrame.new(r[1], r[2], r[3]), Color3.fromRGB(74, 52, 34), Enum.Material.Wood,
			{ Shape = Enum.PartType.Cylinder })
		cpart("Cubo", Vector3.new(1.0, 1.1, 1.1), CFrame.new(r[1] + (r[1] > 0 and 0.2 or -0.2), r[2], r[3]), madeiraEscura,
			Enum.Material.Wood, { Shape = Enum.PartType.Cylinder, CanCollide = false })
	end

	-- boleia (banco do condutor)
	cpart("Banco", Vector3.new(5.6, 0.5, 1.8), CFrame.new(0, 5.6, 5.6), madeira)
	cpart("Encosto", Vector3.new(5.6, 1.4, 0.4), CFrame.new(0, 6.4, 6.5), madeira)
	cpart("Estribo", Vector3.new(5.6, 1.6, 0.4), CFrame.new(0, 4.6, 7.1) * CFrame.Angles(math.rad(-20), 0, 0), madeiraEscura)

	-- lona em arco (5 segmentos + aba traseira)
	cpart("LonaOeste1", Vector3.new(0.35, 2.2, 11), CFrame.new(-3.35, 6.8, -2.5) * CFrame.Angles(0, 0, math.rad(-12)), lona,
		Enum.Material.Fabric, { CanCollide = false })
	cpart("LonaLeste1", Vector3.new(0.35, 2.2, 11), CFrame.new(3.35, 6.8, -2.5) * CFrame.Angles(0, 0, math.rad(12)), lona,
		Enum.Material.Fabric, { CanCollide = false })
	cpart("LonaOeste2", Vector3.new(0.35, 2.2, 11), CFrame.new(-2.55, 8.7, -2.5) * CFrame.Angles(0, 0, math.rad(-40)), lona,
		Enum.Material.Fabric, { CanCollide = false })
	cpart("LonaLeste2", Vector3.new(0.35, 2.2, 11), CFrame.new(2.55, 8.7, -2.5) * CFrame.Angles(0, 0, math.rad(40)), lona,
		Enum.Material.Fabric, { CanCollide = false })
	cpart("LonaTopo", Vector3.new(3.6, 0.35, 11), CFrame.new(0, 9.5, -2.5), lona, Enum.Material.Fabric, { CanCollide = false })
	cpart("LonaTras", Vector3.new(5.4, 4.2, 0.3), CFrame.new(0, 7.4, -7.9), lona, Enum.Material.Fabric, { CanCollide = false })

	-- carga
	cpart("Barril1", Vector3.new(2.0, 1.7, 1.7), CFrame.new(-1.5, 4.6, -6) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(105, 75, 45), Enum.Material.Wood, { Shape = Enum.PartType.Cylinder, CanCollide = false })
	cpart("Barril2", Vector3.new(2.0, 1.7, 1.7), CFrame.new(1.5, 4.6, -6) * CFrame.Angles(0, 0, math.rad(90)),
		Color3.fromRGB(105, 75, 45), Enum.Material.Wood, { Shape = Enum.PartType.Cylinder, CanCollide = false })
	cpart("Caixote", Vector3.new(2, 2, 2), CFrame.new(1.3, 4.6, -3.2), Color3.fromRGB(128, 98, 60),
		Enum.Material.WoodPlanks, { CanCollide = false })
	cpart("Saco1", Vector3.new(1.7, 1.2, 1.7), CFrame.new(-1.4, 4.2, -3.4), Color3.fromRGB(196, 172, 128),
		Enum.Material.Fabric, { Shape = Enum.PartType.Ball, CanCollide = false })
	cpart("Saco2", Vector3.new(1.7, 1.2, 1.7), CFrame.new(0.3, 4.15, -1.6), Color3.fromRGB(196, 172, 128),
		Enum.Material.Fabric, { Shape = Enum.PartType.Ball, CanCollide = false })

	-- lampião
	cpart("GanchoLampiao", Vector3.new(0.3, 0.3, 1.4), CFrame.new(2.9, 7.2, 6.4), madeiraEscura, Enum.Material.Wood, { CanCollide = false })
	local lamp = cpart("Lampiao", Vector3.new(0.7, 1.0, 0.7), CFrame.new(2.9, 6.4, 6.9), Color3.fromRGB(255, 196, 120),
		Enum.Material.Neon, { CanCollide = false })
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 190, 120)
	light.Range = 18
	light.Brightness = 1.4
	light.Parent = lamp

	-- lança + canga + junta de bois
	cpart("Lanca", Vector3.new(0.5, 0.4, 5.6), CFrame.new(0, 1.7, 8.6), madeiraEscura)
	cpart("Canga", Vector3.new(6.2, 0.5, 0.5), CFrame.new(0, 2.6, 11.2), madeiraEscura)

	local function boi(x, tom)
		cpart("BoiCorpo", Vector3.new(2.4, 2.7, 4.6), CFrame.new(x, 2.75, 12.6), tom, Enum.Material.SmoothPlastic)
		cpart("BoiCabeca", Vector3.new(1.5, 1.6, 1.7), CFrame.new(x, 3.4, 15.5), tom, Enum.Material.SmoothPlastic, { CanCollide = false })
		cpart("BoiFocinho", Vector3.new(1.0, 0.9, 0.8), CFrame.new(x, 2.9, 16.5), Color3.fromRGB(168, 142, 108),
			Enum.Material.SmoothPlastic, { CanCollide = false })
		cpart("BoiChifreOeste", Vector3.new(0.8, 0.22, 0.22), CFrame.new(x - 0.9, 4.2, 15.5), Color3.fromRGB(214, 198, 168),
			Enum.Material.SmoothPlastic, { CanCollide = false })
		cpart("BoiChifreLeste", Vector3.new(0.8, 0.22, 0.22), CFrame.new(x + 0.9, 4.2, 15.5), Color3.fromRGB(214, 198, 168),
			Enum.Material.SmoothPlastic, { CanCollide = false })
		cpart("BoiRabo", Vector3.new(0.22, 1.5, 0.22), CFrame.new(x, 2.9, 10.2), tom, Enum.Material.SmoothPlastic, { CanCollide = false })
		for _, off in ipairs({ { -0.75, -1.7 }, { 0.75, -1.7 }, { -0.75, 1.7 }, { 0.75, 1.7 } }) do
			cpart("BoiPerna", Vector3.new(0.7, 1.4, 0.7), CFrame.new(x + off[1], 0.7, 12.6 + off[2]), tom,
				Enum.Material.SmoothPlastic, { CanCollide = false })
		end
	end
	boi(-2.1, Color3.fromRGB(122, 88, 62))
	boi(2.1, Color3.fromRGB(134, 100, 72))

	m:SetAttribute("IsCaravana", true)
	m.Parent = workspace
	m:PivotTo(pivotCf)
	return m
end

buildCaravana(CFrame.new(0, 2.5, -47)) -- parada na estrada, no meio do acampamento, olhando pro norte (rota da run)

-- ===== remotes =====
local remotes = Instance.new("Folder")
remotes.Name = "Remotes"
for _, n in ipairs({ "CollectResource", "DamageEnemy", "PlaceStructure", "EatFood", "EnemyDied", "PlayerDowned" }) do
	local re = Instance.new("RemoteEvent")
	re.Name = n
	re.Parent = remotes
end
remotes.Parent = game.ReplicatedStorage

game.ReplicatedStorage:SetAttribute("Phase", "Dia")
game.ReplicatedStorage:SetAttribute("PhaseTimeLeft", 90)
game.ReplicatedStorage:SetAttribute("Cycle", 0)
game.ReplicatedStorage:SetAttribute("EnemiesAlive", 0)

-- ===== arma: Machado (Tool) =====
local tool = Instance.new("Tool")
tool.Name = "Machado"
tool.ToolTip = "Machado (clique para atacar)"
local handle = Instance.new("Part")
handle.Name = "Handle"
handle.Size = Vector3.new(0.8, 3.2, 0.8)
handle.Color = Color3.fromRGB(120, 90, 60)
handle.Material = Enum.Material.Wood
handle.Parent = tool
local blade = Instance.new("Part")
blade.Name = "Blade"
blade.Size = Vector3.new(0.4, 0.8, 1.6)
blade.Color = Color3.fromRGB(180, 180, 190)
blade.Material = Enum.Material.Metal
blade.CFrame = handle.CFrame * CFrame.new(0, 1.2, -0.6)
local weld = Instance.new("WeldConstraint")
weld.Part0 = handle
weld.Part1 = blade
weld.Parent = handle
blade.Parent = tool
tool.Parent = game.StarterPack

-- ===== ambientação =====
local atmo = Lighting:FindFirstChildOfClass("Atmosphere")
if not atmo then
	atmo = Instance.new("Atmosphere")
	atmo.Parent = Lighting
end
atmo.Density = 0.3
atmo.Haze = 1.6
Lighting.ClockTime = 12
Lighting.Brightness = 2

print("[One Way Caravan: Nightfall] Mapa reconstruído: terreno 480x480, canyon-funil, estrada, floresta, lago, caravana, spawns, remotes e Machado prontos")
