-- Reconstrói o grey-box do nó MVP num place vazio (rodar na Command Bar do Studio, modo Edit).
-- Cria: mapa/funil, árvores, arbustos, pastas, Remotes e a Tool Machado (com Handle).
-- Os scripts (FriendslopServer/FriendslopClient/WeaponClient) são sincronizados via Rojo,
-- exceto o WeaponClient que deve ser colado dentro da Tool Machado criada aqui.

-- limpeza idempotente de builds anteriores
for _, n in ipairs({"ResourceNodes","Structures","Enemies","GreyboxMap"}) do
	local x = workspace:FindFirstChild(n)
	if x then x:Destroy() end
end
local old = game.ReplicatedStorage:FindFirstChild("Remotes")
if old then old:Destroy() end
old = game.StarterPack:FindFirstChild("Machado")
if old then old:Destroy() end

local function mkPart(name, size, pos, color, parent, opts)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Position = pos
	p.Anchored = true
	p.Color = color
	p.Material = Enum.Material.Concrete
	if opts then
		for k, v in pairs(opts) do p[k] = v end
	end
	p.Parent = parent
	return p
end

local map = Instance.new("Model")
map.Name = "GreyboxMap"
map.Parent = workspace

-- funil geográfico: corredor de spawn + linha de bloqueio com vão central de 10 studs (slot da barricada)
local grey = Color3.fromRGB(110,110,110)
mkPart("WallLeft",  Vector3.new(2,12,86), Vector3.new(-13,6,73), grey, map)
mkPart("WallRight", Vector3.new(2,12,86), Vector3.new(13,6,73),  grey, map)
mkPart("BlockWest", Vector3.new(75,12,2), Vector3.new(-42.5,6,30), grey, map)
mkPart("BlockEast", Vector3.new(75,12,2), Vector3.new(42.5,6,30),  grey, map)
mkPart("EndCap",    Vector3.new(28,12,2), Vector3.new(0,6,116),   grey, map)
mkPart("GapMarker", Vector3.new(10,0.2,2), Vector3.new(0,0.1,30), Color3.fromRGB(80,200,120), map, {CanCollide=false, Transparency=0.4, Material=Enum.Material.Neon})
mkPart("CampMarker", Vector3.new(16,0.2,16), Vector3.new(0,0.1,-20), Color3.fromRGB(200,180,120), map, {CanCollide=false, Transparency=0.5, Material=Enum.Material.SmoothPlastic})
mkPart("EnemySpawnMarker", Vector3.new(20,0.2,10), Vector3.new(0,0.1,108), Color3.fromRGB(200,80,80), map, {CanCollide=false, Transparency=0.5, Material=Enum.Material.Neon})

-- pastas
local resourceNodes = Instance.new("Folder"); resourceNodes.Name = "ResourceNodes"; resourceNodes.Parent = workspace
local trees = Instance.new("Folder"); trees.Name = "Trees"; trees.Parent = resourceNodes
local bushes = Instance.new("Folder"); bushes.Name = "FoodBushes"; bushes.Parent = resourceNodes
local structures = Instance.new("Folder"); structures.Name = "Structures"; structures.Parent = workspace
local enemies = Instance.new("Folder"); enemies.Name = "Enemies"; enemies.Parent = workspace

-- árvores (madeira)
local treePos = {{-30,-10},{-45,5},{30,-5},{45,10},{-20,-50},{25,-45},{-50,-30},{50,-35}}
for i, xz in ipairs(treePos) do
	local m = Instance.new("Model")
	m.Name = "Tree" .. i
	local trunk = mkPart("Trunk", Vector3.new(2,8,2), Vector3.new(xz[1],4,xz[2]), Color3.fromRGB(110,76,44), m, {Material=Enum.Material.Wood})
	mkPart("Leaves", Vector3.new(5,5,5), Vector3.new(xz[1],9,xz[2]), Color3.fromRGB(60,130,60), m, {Shape=Enum.PartType.Ball, Material=Enum.Material.Grass})
	m.PrimaryPart = trunk
	m:SetAttribute("NodeType", "Wood")
	m:SetAttribute("Uses", 5)
	m.Parent = trees
end

-- arbustos (comida)
local bushPos = {{-15,-35},{15,-38},{-35,-20},{35,-18},{0,-55},{-10,12}}
for i, xz in ipairs(bushPos) do
	local b = mkPart("Bush" .. i, Vector3.new(3.5,3.5,3.5), Vector3.new(xz[1],1.75,xz[2]), Color3.fromRGB(150,60,80), bushes, {Shape=Enum.PartType.Ball, Material=Enum.Material.Grass})
	b:SetAttribute("NodeType", "Food")
	b:SetAttribute("Uses", 4)
end

-- spawn dos jogadores no acampamento
local sl = workspace:FindFirstChild("SpawnLocation")
if sl then sl.Position = Vector3.new(0, 0.5, -25) end

-- remotes (recurso, dano, morte + colocação)
local remotes = Instance.new("Folder")
remotes.Name = "Remotes"
for _, n in ipairs({"CollectResource","DamageEnemy","PlaceStructure","EnemyDied","PlayerDowned"}) do
	local re = Instance.new("RemoteEvent")
	re.Name = n
	re.Parent = remotes
end
remotes.Parent = game.ReplicatedStorage

game.ReplicatedStorage:SetAttribute("Phase", "Dia")
game.ReplicatedStorage:SetAttribute("PhaseTimeLeft", 60)
game.ReplicatedStorage:SetAttribute("Cycle", 0)

-- arma: Machado (Tool)
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

game.Lighting.ClockTime = 12

print("[Friendslop] Grey-box reconstruído: mapa, recursos, remotes e Machado prontos")
