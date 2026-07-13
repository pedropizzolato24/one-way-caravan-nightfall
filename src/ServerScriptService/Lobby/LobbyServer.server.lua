-- One Way Caravan: Nightfall — servidor do LOBBY PLACE (doc 4.2: hub de progressão).
-- Aqui vive só o meta-loop: catálogo lateral (compra validada no servidor), a caravana
-- pilotável no posto murado (treino de VehicleSeat sem risco) e o poste "Iniciar expedição",
-- que reserva um servidor do Run Place e teleporta o GRUPO INTEIRO junto (reserved server).
-- Sem combate, sem recursos, sem dia/noite — isso tudo é do RunServer, no outro place.
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local Lighting = game:GetService("Lighting")
local TeleportService = game:GetService("TeleportService")

local Shared = script.Parent:WaitForChild("Shared")
local ZoneBuilder = require(Shared.ZoneBuilder)
local ProfileManager = require(Shared.ProfileManager)
local Places = require(Shared.Places)

-- segura o spawn até o posto existir (evita o 1º jogador spawnar na origem antes do buildLobby)
Players.CharacterAutoLoads = false
local lobbyReady = false

-- catálogo lateral (doc 5.2; mesma tabela do RunServer — o preço só é cobrado aqui)
local CATALOG = {
	BarricadaReforcada = { name = "Barricada Reforçada", price = 40 },
}
local RATE_LIMIT = { Buy = 0.5 } -- doc 4.1

-- ===== infraestrutura: TODOS os remotes existem nos dois places (contrato de WaitForChild do
-- cliente compartilhado); no lobby só o BuyUnlock tem handler — os demais ficam mudos =====
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
for _, name in ipairs({ "CollectResource", "DamageEnemy", "PlaceStructure", "EatFood", "EnemyDied", "PlayerDowned", "RunEnded" }) do
	ensureRemote(name)
end
local announceRE = ensureRemote("Announce")
local buyRE = ensureRemote("BuyUnlock")

local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
if not atmosphere then
	atmosphere = Instance.new("Atmosphere")
	atmosphere.Parent = Lighting
end
atmosphere.Density = 0.3
atmosphere.Haze = 1.6
Lighting.OutdoorAmbient = Color3.fromRGB(128, 128, 128)
Lighting.Brightness = 2
Lighting.ClockTime = 12

local function announce(text)
	announceRE:FireAllClients(text)
	print("[One Way Caravan: Nightfall] " .. text)
end

-- ===== jogadores: só perfil + atributos de HUD (sem recursos/combate no lobby) =====
local function initPlayer(plr)
	plr:SetAttribute("Wood", 0)
	plr:SetAttribute("Food", 0)
	plr:SetAttribute("Downed", false)
	task.spawn(function()
		ProfileManager.load(plr) -- atributos ProfileCurrency/Unlock_* espelham pro cliente
	end)
	if lobbyReady and not plr.Character then
		task.spawn(function()
			pcall(function()
				plr:LoadCharacter()
			end)
		end)
	end
end

Players.PlayerAdded:Connect(initPlayer)
for _, plr in ipairs(Players:GetPlayers()) do
	initPlayer(plr)
end
Players.PlayerRemoving:Connect(function(plr)
	-- PlayerRemoving dispara também no teleporte pro Run Place: solta o session-lock e grava
	-- o perfil ANTES do RunServer carregá-lo de novo (o load de lá tem retry se propagar devagar)
	ProfileManager.release(plr)
end)
game:BindToClose(function()
	ProfileManager.releaseAll()
end)

-- ===== rate limit (só compra existe aqui) =====
local lastCall = {}
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
Players.PlayerRemoving:Connect(function(plr)
	lastCall[plr] = nil
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

-- ===== teleporte de grupo (doc 4.2): reserved server garante todo mundo no MESMO servidor =====
local function startExpedition()
	if Places.RUN == 0 then
		announce("Teleporte não configurado: crie o place Run na Experience e preencha Shared/Places.lua (ver docs/multiplayer-2-places.md).")
		return false
	end
	local okReserve, accessCode = pcall(function()
		return TeleportService:ReserveServer(Places.RUN)
	end)
	if not okReserve then
		announce("Falha ao reservar servidor da expedição — tentem de novo em instantes.")
		return false
	end
	local options = Instance.new("TeleportOptions")
	options.ReservedServerAccessCode = accessCode
	local players = Players:GetPlayers() -- lista NO MOMENTO do teleporte
	local okTp, err = pcall(function()
		TeleportService:TeleportAsync(Places.RUN, players, options)
	end)
	if not okTp then
		-- no Studio TeleportAsync sempre falha; publicado, é erro transitório — o grupo tenta de novo
		announce("Teleporte falhou (" .. tostring(err) .. "). No Studio isso é esperado; publicado, tentem de novo.")
		return false
	end
	return true
end

-- ===== o posto de partida =====
RS:SetAttribute("Phase", "Lobby")
RS:SetAttribute("NodeName", "Posto de Partida")
RS:SetAttribute("PhaseTimeLeft", 0)
RS:SetAttribute("Currency", 0)
RS:SetAttribute("CheckpointCurrency", 0)
RS:SetAttribute("EnemiesAlive", 0)
RS:SetAttribute("BossHP", 0)
RS:SetAttribute("Cycle", 0)

ZoneBuilder.buildCaravana()
local lobby = ZoneBuilder.buildLobby()
ZoneBuilder.pivotCaravanaTo(lobby.caravanaCf)
ZoneBuilder.setCaravanaLocked(false) -- posto murado: dá pra treinar a pilotagem sem risco

-- posto pronto: libera o spawn e materializa quem já estava aqui (chegou durante o build)
lobbyReady = true
for _, plr in ipairs(Players:GetPlayers()) do
	if not plr.Character then
		task.spawn(function()
			pcall(function()
				plr:LoadCharacter()
			end)
		end)
	end
end
announce("Lobby: gastem a moeda no catálogo (painel à direita) e segurem o poste de partida quando estiverem prontos.")

local prompt = Instance.new("ProximityPrompt")
prompt.ActionText = "Iniciar expedição"
prompt.ObjectText = "Caravana pronta"
prompt.HoldDuration = 2
prompt.RequiresLineOfSight = false
prompt.MaxActivationDistance = 12
prompt.Parent = lobby.startPost

local teleporting = false
prompt.Triggered:Connect(function()
	if teleporting then
		return
	end
	teleporting = true
	if startExpedition() then
		announce("A expedição parte!")
	end
	-- falhou (Studio/sem config/erro transitório): o poste continua armado pra nova tentativa
	teleporting = false
end)

print("[One Way Caravan: Nightfall] LobbyServer inicializado (place " .. game.PlaceId .. ")")
