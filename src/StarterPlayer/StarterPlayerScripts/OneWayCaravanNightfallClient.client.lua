-- One Way Caravan: Nightfall — MVP cliente: input + UI + preview de colocação + votação. Nenhuma autoridade aqui (doc 4.1).
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")

local plr = Players.LocalPlayer
local remotes = RS:WaitForChild("Remotes")
local collectRE = remotes:WaitForChild("CollectResource")
local placeRE = remotes:WaitForChild("PlaceStructure")
local eatRE = remotes:WaitForChild("EatFood")
local voteStartedRE = remotes:WaitForChild("VoteStarted")
local voteCastRE = remotes:WaitForChild("VoteCast")
local voteUpdateRE = remotes:WaitForChild("VoteUpdate")
local voteEndedRE = remotes:WaitForChild("VoteEnded")
local zoneFadeRE = remotes:WaitForChild("ZoneFade")
local announceRE = remotes:WaitForChild("Announce")
local runEndedRE = remotes:WaitForChild("RunEnded")
local buyRE = remotes:WaitForChild("BuyUnlock")
local mouse = plr:GetMouse()

-- espelhos p/ feedback visual; a validação real é sempre do servidor
local COSTS = { Fogueira = { Wood = 5 }, Barricada = { Wood = 10 }, BarricadaReforcada = { Wood = 16 } }
local GHOST_SIZE = {
	Fogueira = Vector3.new(4, 2.5, 4),
	Barricada = Vector3.new(10, 7, 2),
	BarricadaReforcada = Vector3.new(10, 7, 2),
}
local PLACE_RANGE = 35

-- ===== HUD =====
local gui = Instance.new("ScreenGui")
gui.Name = "OneWayCaravanNightfallHUD"
gui.ResetOnSpawn = false
gui.Parent = plr:WaitForChild("PlayerGui")

local function round(inst)
	local c = Instance.new("UICorner")
	c.CornerRadius = UDim.new(0, 6)
	c.Parent = inst
end

local function mkLabel(name, pos, size)
	local l = Instance.new("TextLabel")
	l.Name = name
	l.Position = pos
	l.Size = size
	l.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	l.BackgroundTransparency = 0.3
	l.TextColor3 = Color3.new(1, 1, 1)
	l.TextScaled = true
	l.Font = Enum.Font.SourceSansBold
	l.Text = ""
	l.Parent = gui
	round(l)
	return l
end

local phaseLbl = mkLabel("Phase", UDim2.new(0.5, -110, 0, 8), UDim2.new(0, 220, 0, 36))
local nodeLbl = mkLabel("Node", UDim2.new(0.5, -110, 0, 48), UDim2.new(0, 220, 0, 22))
nodeLbl.BackgroundTransparency = 0.5
local resLbl = mkLabel("Resources", UDim2.new(0, 8, 0, 8), UDim2.new(0, 240, 0, 36))
local coinLbl = mkLabel("Coins", UDim2.new(0, 8, 0, 48), UDim2.new(0, 240, 0, 26))
coinLbl.BackgroundColor3 = Color3.fromRGB(70, 60, 20)
local enemiesLbl = mkLabel("Enemies", UDim2.new(1, -168, 0, 8), UDim2.new(0, 160, 0, 30))
enemiesLbl.BackgroundColor3 = Color3.fromRGB(70, 25, 25)
enemiesLbl.Visible = false
local msgLbl = mkLabel("Msg", UDim2.new(0.5, -220, 0, 100), UDim2.new(0, 440, 0, 26))
msgLbl.BackgroundTransparency = 1

-- barra de HP do boss
local bossBar = Instance.new("Frame")
bossBar.Name = "BossBar"
bossBar.AnchorPoint = Vector2.new(0.5, 0)
bossBar.Position = UDim2.new(0.5, 0, 0, 74)
bossBar.Size = UDim2.new(0, 300, 0, 22)
bossBar.BackgroundColor3 = Color3.fromRGB(25, 10, 10)
bossBar.Visible = false
bossBar.Parent = gui
round(bossBar)
local bossFill = Instance.new("Frame")
bossFill.Size = UDim2.new(1, 0, 1, 0)
bossFill.BackgroundColor3 = Color3.fromRGB(180, 40, 40)
bossFill.BorderSizePixel = 0
bossFill.Parent = bossBar
round(bossFill)
local bossTxt = Instance.new("TextLabel")
bossTxt.Size = UDim2.new(1, 0, 1, 0)
bossTxt.BackgroundTransparency = 1
bossTxt.TextColor3 = Color3.new(1, 1, 1)
bossTxt.TextScaled = true
bossTxt.Font = Enum.Font.SourceSansBold
bossTxt.ZIndex = 2
bossTxt.Parent = bossBar

local BTN_COLORS = {
	BuildFire = Color3.fromRGB(50, 70, 50),
	BuildBarricade = Color3.fromRGB(50, 70, 50),
	BuildBarricadeR = Color3.fromRGB(50, 62, 78),
	Eat = Color3.fromRGB(90, 70, 40),
}
local BTN_DISABLED = Color3.fromRGB(55, 55, 55)

local function mkButton(name, pos, text)
	local b = Instance.new("TextButton")
	b.Name = name
	b.Position = pos
	b.Size = UDim2.new(0, 200, 0, 36)
	b.BackgroundColor3 = BTN_COLORS[name]
	b.TextColor3 = Color3.new(1, 1, 1)
	b.TextScaled = true
	b.Font = Enum.Font.SourceSansBold
	b.Text = text
	b.Parent = gui
	round(b)
	return b
end

local fireBtn = mkButton("BuildFire", UDim2.new(0, 8, 1, -174), "Fogueira (5 madeira)")
local barrBtn = mkButton("BuildBarricade", UDim2.new(0, 8, 1, -132), "Barricada (10 madeira)")
local barrRefBtn = mkButton("BuildBarricadeR", UDim2.new(0, 8, 1, -90), "Barricada Reforçada (16)")
local eatBtn = mkButton("Eat", UDim2.new(0, 8, 1, -48), "Comer (1 comida, +25 vida)")

local function refreshUnlocks()
	barrRefBtn.Visible = plr:GetAttribute("Unlock_BarricadaReforcada") == true
end
plr:GetAttributeChangedSignal("Unlock_BarricadaReforcada"):Connect(refreshUnlocks)
refreshUnlocks()

local function refreshRes()
	local wood = plr:GetAttribute("Wood") or 0
	local food = plr:GetAttribute("Food") or 0
	resLbl.Text = string.format("Madeira: %d | Comida: %d", wood, food)
	fireBtn.BackgroundColor3 = wood >= COSTS.Fogueira.Wood and BTN_COLORS.BuildFire or BTN_DISABLED
	barrBtn.BackgroundColor3 = wood >= COSTS.Barricada.Wood and BTN_COLORS.BuildBarricade or BTN_DISABLED
	barrRefBtn.BackgroundColor3 = wood >= COSTS.BarricadaReforcada.Wood and BTN_COLORS.BuildBarricadeR or BTN_DISABLED
	eatBtn.BackgroundColor3 = food >= 1 and BTN_COLORS.Eat or BTN_DISABLED
end
plr:GetAttributeChangedSignal("Wood"):Connect(refreshRes)
plr:GetAttributeChangedSignal("Food"):Connect(refreshRes)
refreshRes()

local PHASE_COLORS = {
	Noite = Color3.fromRGB(45, 25, 70),
	["Votação"] = Color3.fromRGB(25, 45, 80),
	["Manhã"] = Color3.fromRGB(90, 65, 25),
	Partida = Color3.fromRGB(90, 65, 25),
	Travessia = Color3.fromRGB(90, 65, 25),
	Chegada = Color3.fromRGB(90, 65, 25),
	Boss = Color3.fromRGB(90, 20, 20),
	["Vitória"] = Color3.fromRGB(25, 70, 40),
	Derrota = Color3.fromRGB(60, 25, 25),
	Lobby = Color3.fromRGB(25, 70, 70),
}

local function refreshPhase()
	local phase = RS:GetAttribute("Phase") or "?"
	local cycle = RS:GetAttribute("Cycle") or 0
	local t = RS:GetAttribute("PhaseTimeLeft") or 0
	if phase == "Dia" then
		phaseLbl.Text = string.format("Dia %d — %ds", cycle + 1, t)
	elseif phase == "Noite" then
		phaseLbl.Text = string.format("Noite %d — %ds", cycle, t)
	elseif phase == "Boss" then
		phaseLbl.Text = "BOSS — segurem a linha!"
	elseif phase == "Vitória" then
		phaseLbl.Text = "Vitória!"
	elseif phase == "Derrota" then
		phaseLbl.Text = "Derrota"
	elseif phase == "Lobby" then
		phaseLbl.Text = "Lobby — preparem a expedição"
	else
		phaseLbl.Text = string.format("%s — %ds", phase, t)
	end
	phaseLbl.BackgroundColor3 = PHASE_COLORS[phase] or Color3.fromRGB(20, 20, 20)
end
RS:GetAttributeChangedSignal("Phase"):Connect(refreshPhase)
RS:GetAttributeChangedSignal("PhaseTimeLeft"):Connect(refreshPhase)
RS:GetAttributeChangedSignal("Cycle"):Connect(refreshPhase)
refreshPhase()

local function refreshNode()
	nodeLbl.Text = RS:GetAttribute("NodeName") or ""
	nodeLbl.Visible = nodeLbl.Text ~= ""
end
RS:GetAttributeChangedSignal("NodeName"):Connect(refreshNode)
refreshNode()

local function refreshEnemies()
	local n = RS:GetAttribute("EnemiesAlive") or 0
	enemiesLbl.Visible = n > 0
	enemiesLbl.Text = "Inimigos: " .. n
end
RS:GetAttributeChangedSignal("EnemiesAlive"):Connect(refreshEnemies)
refreshEnemies()

local function refreshCoins()
	coinLbl.Text = string.format("Moeda: %d | Salva: %d", RS:GetAttribute("Currency") or 0, RS:GetAttribute("CheckpointCurrency") or 0)
end
RS:GetAttributeChangedSignal("Currency"):Connect(refreshCoins)
RS:GetAttributeChangedSignal("CheckpointCurrency"):Connect(refreshCoins)
refreshCoins()

local function refreshBoss()
	local hp = RS:GetAttribute("BossHP") or 0
	local maxHp = RS:GetAttribute("BossMaxHP") or 1
	bossBar.Visible = hp > 0
	if hp > 0 then
		bossFill.Size = UDim2.new(math.clamp(hp / maxHp, 0, 1), 0, 1, 0)
		bossTxt.Text = string.format("Boss: %d / %d", hp, maxHp)
	end
end
RS:GetAttributeChangedSignal("BossHP"):Connect(refreshBoss)
RS:GetAttributeChangedSignal("BossMaxHP"):Connect(refreshBoss)
refreshBoss()

-- ===== votação de avanço/permanência =====
local voteFrame = Instance.new("Frame")
voteFrame.Name = "Vote"
voteFrame.AnchorPoint = Vector2.new(0.5, 0)
voteFrame.Position = UDim2.new(0.5, 0, 0, 104)
voteFrame.Size = UDim2.new(0, 380, 0, 60)
voteFrame.BackgroundColor3 = Color3.fromRGB(15, 15, 25)
voteFrame.BackgroundTransparency = 0.15
voteFrame.Visible = false
voteFrame.Parent = gui
round(voteFrame)

local voteTitle = Instance.new("TextLabel")
voteTitle.Position = UDim2.new(0, 8, 0, 6)
voteTitle.Size = UDim2.new(1, -16, 0, 24)
voteTitle.BackgroundTransparency = 1
voteTitle.TextColor3 = Color3.new(1, 1, 1)
voteTitle.TextScaled = true
voteTitle.Font = Enum.Font.SourceSansBold
voteTitle.Text = "A caravana descansa. Avançar ou ficar?"
voteTitle.Parent = voteFrame

local voteButtons = {} -- id -> TextButton
local voteLabels = {} -- id -> texto base

voteStartedRE.OnClientEvent:Connect(function(options)
	for _, b in pairs(voteButtons) do
		b:Destroy()
	end
	voteButtons, voteLabels = {}, {}
	for i, o in ipairs(options) do
		local b = Instance.new("TextButton")
		b.Position = UDim2.new(0, 8, 0, 34 + (i - 1) * 38)
		b.Size = UDim2.new(1, -16, 0, 32)
		b.BackgroundColor3 = Color3.fromRGB(50, 60, 80)
		b.TextColor3 = Color3.new(1, 1, 1)
		b.TextScaled = true
		b.Font = Enum.Font.SourceSansBold
		b.Text = o.label .. " (0)"
		b.Parent = voteFrame
		round(b)
		voteButtons[o.id] = b
		voteLabels[o.id] = o.label
		b.MouseButton1Click:Connect(function()
			voteCastRE:FireServer(o.id)
			for id2, b2 in pairs(voteButtons) do
				b2.BackgroundColor3 = id2 == o.id and Color3.fromRGB(70, 110, 70) or Color3.fromRGB(50, 60, 80)
			end
		end)
	end
	voteFrame.Size = UDim2.new(0, 380, 0, 42 + #options * 38)
	voteFrame.Visible = true
end)

voteUpdateRE.OnClientEvent:Connect(function(counts)
	for id, b in pairs(voteButtons) do
		b.Text = string.format("%s (%d)", voteLabels[id] or "", counts[id] or 0)
	end
end)

voteEndedRE.OnClientEvent:Connect(function(resultLabel)
	voteFrame.Visible = false
	msgLbl.Text = "Decisão do grupo: " .. tostring(resultLabel)
	task.delay(5, function()
		if string.find(msgLbl.Text, "Decisão", 1, true) then msgLbl.Text = "" end
	end)
end)

-- ===== fade de troca de zona =====
local fadeGui = Instance.new("ScreenGui")
fadeGui.Name = "OneWayCaravanNightfallFade"
fadeGui.ResetOnSpawn = false
fadeGui.IgnoreGuiInset = true
fadeGui.DisplayOrder = 50
fadeGui.Parent = plr:WaitForChild("PlayerGui")
local fadeFrame = Instance.new("Frame")
fadeFrame.Size = UDim2.new(1, 0, 1, 0)
fadeFrame.BackgroundColor3 = Color3.new(0, 0, 0)
fadeFrame.BackgroundTransparency = 1
fadeFrame.BorderSizePixel = 0
fadeFrame.Parent = fadeGui

zoneFadeRE.OnClientEvent:Connect(function(on)
	TweenService:Create(fadeFrame, TweenInfo.new(on and 0.4 or 0.8), { BackgroundTransparency = on and 0 or 1 }):Play()
end)

announceRE.OnClientEvent:Connect(function(text)
	msgLbl.Text = text
	task.delay(6, function()
		if msgLbl.Text == text then msgLbl.Text = "" end
	end)
end)

-- ===== catálogo do lobby (passo 9: 1 unlock lateral, doc 3.1/5.2) =====
local CATALOG_UI = {
	{
		id = "BarricadaReforcada",
		name = "Barricada Reforçada",
		price = 40,
		desc = "400 HP com faixas de metal, mas custa 16 madeira. Sidegrade: aguenta mais, drena mais recurso.",
	},
}

local catalogFrame = Instance.new("Frame")
catalogFrame.Name = "Catalog"
catalogFrame.AnchorPoint = Vector2.new(1, 0.5)
catalogFrame.Position = UDim2.new(1, -8, 0.5, 0)
catalogFrame.Size = UDim2.new(0, 260, 0, 70 + #CATALOG_UI * 112)
catalogFrame.BackgroundColor3 = Color3.fromRGB(18, 24, 24)
catalogFrame.BackgroundTransparency = 0.15
catalogFrame.Visible = false
catalogFrame.Parent = gui
round(catalogFrame)

local catTitle = Instance.new("TextLabel")
catTitle.Position = UDim2.new(0, 8, 0, 6)
catTitle.Size = UDim2.new(1, -16, 0, 26)
catTitle.BackgroundTransparency = 1
catTitle.TextColor3 = Color3.new(1, 1, 1)
catTitle.TextScaled = true
catTitle.Font = Enum.Font.SourceSansBold
catTitle.Text = "Catálogo Lateral"
catTitle.Parent = catalogFrame

local walletLbl = Instance.new("TextLabel")
walletLbl.Position = UDim2.new(0, 8, 0, 34)
walletLbl.Size = UDim2.new(1, -16, 0, 22)
walletLbl.BackgroundTransparency = 1
walletLbl.TextColor3 = Color3.fromRGB(240, 220, 140)
walletLbl.TextScaled = true
walletLbl.Font = Enum.Font.SourceSansBold
walletLbl.Parent = catalogFrame

local buyButtons = {} -- id -> TextButton
for i, item in ipairs(CATALOG_UI) do
	local y = 62 + (i - 1) * 112
	local nameLbl = Instance.new("TextLabel")
	nameLbl.Position = UDim2.new(0, 8, 0, y)
	nameLbl.Size = UDim2.new(1, -16, 0, 24)
	nameLbl.BackgroundTransparency = 1
	nameLbl.TextColor3 = Color3.new(1, 1, 1)
	nameLbl.TextScaled = true
	nameLbl.Font = Enum.Font.SourceSansBold
	nameLbl.Text = item.name
	nameLbl.Parent = catalogFrame
	local descLbl = Instance.new("TextLabel")
	descLbl.Position = UDim2.new(0, 8, 0, y + 26)
	descLbl.Size = UDim2.new(1, -16, 0, 44)
	descLbl.BackgroundTransparency = 1
	descLbl.TextColor3 = Color3.fromRGB(200, 200, 200)
	descLbl.TextSize = 14
	descLbl.TextWrapped = true
	descLbl.TextYAlignment = Enum.TextYAlignment.Top
	descLbl.Font = Enum.Font.SourceSans
	descLbl.Text = item.desc
	descLbl.Parent = catalogFrame
	local buyBtn = Instance.new("TextButton")
	buyBtn.Position = UDim2.new(0, 8, 0, y + 74)
	buyBtn.Size = UDim2.new(1, -16, 0, 30)
	buyBtn.TextColor3 = Color3.new(1, 1, 1)
	buyBtn.TextScaled = true
	buyBtn.Font = Enum.Font.SourceSansBold
	buyBtn.Parent = catalogFrame
	round(buyBtn)
	buyBtn.MouseButton1Click:Connect(function()
		buyRE:FireServer(item.id)
	end)
	buyButtons[item.id] = buyBtn
end

local function refreshCatalog()
	local wallet = plr:GetAttribute("ProfileCurrency") or 0
	walletLbl.Text = "Sua moeda (perfil): " .. wallet
	for _, item in ipairs(CATALOG_UI) do
		local b = buyButtons[item.id]
		if b then
			local owned = plr:GetAttribute("Unlock_" .. item.id) == true
			b.Text = owned and "Desbloqueado" or ("Comprar por " .. item.price)
			b.BackgroundColor3 = owned and Color3.fromRGB(45, 65, 45)
				or (wallet >= item.price and Color3.fromRGB(60, 95, 60) or Color3.fromRGB(55, 55, 55))
		end
	end
end
plr:GetAttributeChangedSignal("ProfileCurrency"):Connect(refreshCatalog)
for _, item in ipairs(CATALOG_UI) do
	plr:GetAttributeChangedSignal("Unlock_" .. item.id):Connect(refreshCatalog)
end
refreshCatalog()

local function refreshCatalogVisible()
	catalogFrame.Visible = RS:GetAttribute("Phase") == "Lobby"
end
RS:GetAttributeChangedSignal("Phase"):Connect(refreshCatalogVisible)
refreshCatalogVisible()

-- ===== tela de fim de run =====
local endFrame = Instance.new("Frame")
endFrame.Name = "RunEnd"
endFrame.AnchorPoint = Vector2.new(0.5, 0.5)
endFrame.Position = UDim2.new(0.5, 0, 0.45, 0)
endFrame.Size = UDim2.new(0, 400, 0, 190)
endFrame.BackgroundColor3 = Color3.fromRGB(12, 12, 18)
endFrame.BackgroundTransparency = 0.1
endFrame.Visible = false
endFrame.Parent = gui
round(endFrame)
local endTitle = Instance.new("TextLabel")
endTitle.Position = UDim2.new(0, 8, 0, 10)
endTitle.Size = UDim2.new(1, -16, 0, 44)
endTitle.BackgroundTransparency = 1
endTitle.TextScaled = true
endTitle.Font = Enum.Font.SourceSansBold
endTitle.Parent = endFrame
local endBody = Instance.new("TextLabel")
endBody.Position = UDim2.new(0, 16, 0, 60)
endBody.Size = UDim2.new(1, -32, 1, -72)
endBody.BackgroundTransparency = 1
endBody.TextColor3 = Color3.new(1, 1, 1)
endBody.TextSize = 20
endBody.TextWrapped = true
endBody.TextYAlignment = Enum.TextYAlignment.Top
endBody.Font = Enum.Font.SourceSans
endBody.Parent = endFrame

runEndedRE.OnClientEvent:Connect(function(data)
	endTitle.Text = data.victory and "VITÓRIA!" or "A CARAVANA SE PERDEU"
	endTitle.TextColor3 = data.victory and Color3.fromRGB(120, 230, 140) or Color3.fromRGB(230, 100, 90)
	endBody.Text = string.format(
		"Noites sobrevividas: %d\nMoeda da run: %d | Checkpoint: %d\nCreditado no perfil: %d | Perfil agora: %d\n\nDe volta ao lobby...",
		data.nights or 0, data.currency or 0, data.checkpoint or 0, data.earned or 0,
		plr:GetAttribute("ProfileCurrency") or 0)
	endFrame.Visible = true
	task.delay(16, function()
		endFrame.Visible = false
	end)
end)

-- ===== colocação com preview fantasma =====
local placing = nil
local ghost = nil
local armedAt = 0

local function clearPlacing()
	placing = nil
	if msgLbl.Text == "Clique no chão para colocar (Esc cancela)" then
		msgLbl.Text = ""
	end
	if ghost then
		ghost:Destroy()
		ghost = nil
	end
	mouse.TargetFilter = nil
end

local function startPlacing(structType)
	if placing == structType then
		clearPlacing()
		return
	end
	clearPlacing()
	placing = structType
	armedAt = os.clock()
	msgLbl.Text = "Clique no chão para colocar (Esc cancela)"
	ghost = Instance.new("Part")
	ghost.Name = "GhostPreview"
	ghost.Size = GHOST_SIZE[structType]
	ghost.Anchored = true
	ghost.CanCollide = false
	ghost.CanQuery = false
	ghost.Transparency = 0.55
	ghost.Material = Enum.Material.Neon
	ghost.Color = Color3.fromRGB(90, 220, 120)
	ghost.Parent = workspace
	mouse.TargetFilter = ghost
end

fireBtn.MouseButton1Click:Connect(function() startPlacing("Fogueira") end)
barrBtn.MouseButton1Click:Connect(function() startPlacing("Barricada") end)
barrRefBtn.MouseButton1Click:Connect(function() startPlacing("BarricadaReforcada") end)
eatBtn.MouseButton1Click:Connect(function() eatRE:FireServer() end)

RunService.RenderStepped:Connect(function()
	if not (placing and ghost) then return end
	local char = plr.Character
	local hrp = char and char:FindFirstChild("HumanoidRootPart")
	local hit = mouse.Hit
	if not (hrp and hit) then
		ghost.Transparency = 1
		return
	end
	ghost.Transparency = 0.55
	local pos = hit.Position
	local up = Vector3.new(0, ghost.Size.Y / 2, 0)
	if placing == "Barricada" then
		-- mesmo critério do servidor: parede perpendicular a onde o personagem olha
		local look = hrp.CFrame.LookVector
		look = Vector3.new(look.X, 0, look.Z)
		if look.Magnitude > 0.05 then
			ghost.CFrame = CFrame.lookAt(pos + up, pos + up + look)
		else
			ghost.CFrame = CFrame.new(pos + up)
		end
	else
		ghost.CFrame = CFrame.new(pos + up)
	end
	local ok = (pos - hrp.Position).Magnitude <= PLACE_RANGE
	for kind, amt in pairs(COSTS[placing]) do
		if (plr:GetAttribute(kind) or 0) < amt then ok = false end
	end
	-- espelha a checagem do servidor: não colocar em cima do próprio personagem (evita prender)
	local lp = ghost.CFrame:PointToObjectSpace(hrp.Position)
	local sz = ghost.Size
	if math.abs(lp.X) < sz.X / 2 + 2.5 and math.abs(lp.Z) < sz.Z / 2 + 2.5 and math.abs(lp.Y) < sz.Y / 2 + 4 then
		ok = false
	end
	ghost.Color = ok and Color3.fromRGB(90, 220, 120) or Color3.fromRGB(230, 80, 70)
end)

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed then return end
	if input.KeyCode == Enum.KeyCode.Escape and placing then
		clearPlacing()
	end
end)

mouse.Button1Down:Connect(function()
	if placing then
		if os.clock() - armedAt < 0.15 then return end -- ignora o clique que armou o botão
		if mouse.Hit then
			placeRE:FireServer(placing, mouse.Hit.Position)
		end
		clearPlacing()
		return
	end
	local node = mouse.Target
	while node and node.Parent do
		if node.Parent.Name == "Trees" or node.Parent.Name == "FoodBushes" then
			collectRE:FireServer(node)
			return
		end
		node = node.Parent
	end
end)

-- ===== feedback de morte/queda =====
remotes:WaitForChild("EnemyDied").OnClientEvent:Connect(function(name)
	msgLbl.Text = name .. " morreu"
	task.delay(2, function()
		if msgLbl.Text == name .. " morreu" then msgLbl.Text = "" end
	end)
end)
remotes:WaitForChild("PlayerDowned").OnClientEvent:Connect(function(name)
	msgLbl.Text = name .. " caiu! Segure o botão de reviver por perto"
end)
