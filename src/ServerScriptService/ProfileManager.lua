-- ProfileManager — persistência de perfil (doc 4.4) com session-locking leve via UpdateAsync.
-- Interface estável (load/get/addCurrency/tryBuy/release); a implementação interna pode ser trocada
-- pelo ProfileStore oficial (loleris), que é o que o doc recomenda, sem mexer no resto do servidor.
-- Este módulo cobre o MVP com a mesma disciplina: nada de DataStore cru espalhado pelo código,
-- lock de sessão contra escrita dupla, escrita num ponto só, e modo memória automático quando o
-- Studio está sem acesso à API (perfil não persiste, mas o jogo continua testável).
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local ProfileManager = {}

local STORE_NAME = "PlayerProfiles_v1"
local LOCK_TTL = 90 -- segundos até um lock de outra sessão ser considerado morto
local AUTOSAVE_INTERVAL = 45
local TEMPLATE = { -- schema do doc 4.4
	currency = 0,
	unlockedCatalog = {},
	unlockedClasses = {},
	unlockedPassives = {},
	cosmetics = { owned = {}, equipped = {} },
	dailyMissions = { active = {}, lastRollUtc = 0 },
	loginStreak = { count = 0, lastLoginUtc = 0 },
}

local SESSION_ID = game.JobId ~= "" and game.JobId or ("studio_" .. os.time())

local store
do
	local ok, s = pcall(function()
		return DataStoreService:GetDataStore(STORE_NAME)
	end)
	if ok then
		store = s
	end
end

local profiles = {} -- [player] = { Data = t, loaded = bool, mock = bool }

local function deepCopy(t)
	local c = {}
	for k, v in pairs(t) do
		c[k] = type(v) == "table" and deepCopy(v) or v
	end
	return c
end

local function reconcile(data, template)
	for k, v in pairs(template) do
		if data[k] == nil then
			data[k] = type(v) == "table" and deepCopy(v) or v
		elseif type(v) == "table" and type(data[k]) == "table" then
			reconcile(data[k], v)
		end
	end
	return data
end

local function keyFor(plr)
	return "p_" .. plr.UserId
end

local function sync(plr)
	local e = profiles[plr]
	if not e or not plr.Parent then return end
	plr:SetAttribute("ProfileCurrency", e.Data.currency or 0)
	plr:SetAttribute("ProfileLoaded", e.loaded == true)
	for _, id in ipairs(e.Data.unlockedCatalog or {}) do
		plr:SetAttribute("Unlock_" .. id, true)
	end
end

-- escreve o perfil; releaseLock=true solta o lock (saída do jogador). Nunca escreve por cima de lock alheio vivo.
local function persist(plr, releaseLock)
	local e = profiles[plr]
	if not e or not e.loaded or e.mock or not store then return end
	pcall(function()
		store:UpdateAsync(keyFor(plr), function(rec)
			rec = rec or {}
			if rec.lockId and rec.lockId ~= SESSION_ID and (os.time() - (rec.lockTime or 0)) < LOCK_TTL then
				return nil -- outra sessão assumiu o perfil; aborta a escrita
			end
			rec.data = e.Data
			if releaseLock then
				rec.lockId = nil
				rec.lockTime = nil
			else
				rec.lockId = SESSION_ID
				rec.lockTime = os.time()
			end
			return rec
		end)
	end)
end

function ProfileManager.load(plr)
	if profiles[plr] then return end
	local e = { Data = deepCopy(TEMPLATE), loaded = false, mock = false }
	profiles[plr] = e
	local attempts = RunService:IsStudio() and 1 or 4
	if store then
		for attempt = 1, attempts do
			local lockedByOther = false
			local ok = pcall(function()
				store:UpdateAsync(keyFor(plr), function(rec)
					rec = rec or {}
					if rec.lockId and rec.lockId ~= SESSION_ID and (os.time() - (rec.lockTime or 0)) < LOCK_TTL then
						lockedByOther = true
						return nil
					end
					rec.lockId = SESSION_ID
					rec.lockTime = os.time()
					if rec.data then
						e.Data = reconcile(rec.data, TEMPLATE)
					end
					return rec
				end)
			end)
			if ok and not lockedByOther then
				e.loaded = true
				break
			end
			task.wait(4 * attempt) -- espera o lock alheio expirar / API se recuperar
		end
	end
	if not e.loaded then
		-- fallback: perfil em memória só nesta sessão (Studio sem API, ou lock preso em outra sessão)
		e.mock = true
		e.loaded = true
		warn("[ProfileManager] DataStore indisponível pra " .. plr.Name
			.. " — perfil em memória (não persiste). No Studio, ligue 'Enable Studio Access to API Services' pra testar persistência.")
	end
	sync(plr)
end

function ProfileManager.get(plr)
	local e = profiles[plr]
	return (e and e.loaded) and e or nil
end

function ProfileManager.isUnlocked(plr, id)
	local e = ProfileManager.get(plr)
	return e ~= nil and table.find(e.Data.unlockedCatalog, id) ~= nil
end

function ProfileManager.addCurrency(plr, amt)
	local e = ProfileManager.get(plr)
	if not e or amt <= 0 then return end
	e.Data.currency += amt
	sync(plr)
	task.spawn(persist, plr, false)
end

function ProfileManager.tryBuy(plr, id, price)
	local e = ProfileManager.get(plr)
	if not e then
		return false, "perfil ainda carregando"
	end
	if table.find(e.Data.unlockedCatalog, id) then
		return false, "já desbloqueado"
	end
	if (e.Data.currency or 0) < price then
		return false, "moeda insuficiente (" .. (e.Data.currency or 0) .. "/" .. price .. ")"
	end
	e.Data.currency -= price
	table.insert(e.Data.unlockedCatalog, id)
	sync(plr)
	task.spawn(persist, plr, false)
	return true
end

function ProfileManager.release(plr)
	local e = profiles[plr]
	if e then
		persist(plr, true)
		profiles[plr] = nil
	end
end

function ProfileManager.releaseAll()
	for plr in pairs(profiles) do
		persist(plr, true)
	end
	table.clear(profiles)
	task.wait(1) -- dá tempo das escritas saírem antes do shutdown
end

-- autosave periódico + renovação do lock de sessão
task.spawn(function()
	while true do
		task.wait(AUTOSAVE_INTERVAL)
		for plr in pairs(profiles) do
			if plr.Parent then
				task.spawn(persist, plr, false)
			end
		end
	end
end)

return ProfileManager
