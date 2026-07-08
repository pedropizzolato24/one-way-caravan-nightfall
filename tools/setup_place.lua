-- Setup mínimo do place (rodar 1x na Command Bar do Studio, modo Edit).
-- O MAPA agora é construído em RUNTIME pelo servidor (ZoneBuilder), porque o passo 7 sequencia
-- várias zonas por run (POIs + travessia). Este script só:
--   1. limpa restos de builds antigos (grey-box / mapa estático)
--   2. cria a Tool Machado no StarterPack (Tool com LocalScript não dá pra criar em runtime)
-- Depois: cole WeaponClient.client.lua como LocalScript dentro de StarterPack.Machado.
--
-- Preview de zona no modo Edit (opcional, com Rojo conectado):
--   require(game.ServerScriptService.ZoneBuilder).preview()          -- estação
--   require(game.ServerScriptService.ZoneBuilder).preview("mina")    -- ou outro tipo

-- mundo contínuo por streaming (doc 4.5/4.6): o servidor também liga isso em runtime, mas deixar
-- ligado no place evita um primeiro frame sem streaming
workspace.StreamingEnabled = true

-- limpeza de builds antigos (inclui "Mundo", o novo container contínuo)
for _, n in ipairs({ "Mundo", "ResourceNodes", "Structures", "Enemies", "EnemySpawns", "GreyboxMap", "Mapa", "Caravana", "Baseplate" }) do
	local x = workspace:FindFirstChild(n)
	if x then x:Destroy() end
end
local old = game.ReplicatedStorage:FindFirstChild("Remotes")
if old then old:Destroy() end
old = game.StarterPack:FindFirstChild("Machado")
if old then old:Destroy() end
workspace.Terrain:Clear()

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

print("[One Way Caravan: Nightfall] Setup pronto: place limpo + Machado criado. Cole o WeaponClient dentro da Tool e dê Play — o servidor constrói o mapa sozinho.")
