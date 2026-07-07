-- One Way Caravan: Nightfall — MVP cliente: input + UI. Nenhuma autoridade aqui (doc 4.1).
local Players = game:GetService("Players")
local RS = game:GetService("ReplicatedStorage")

local plr = Players.LocalPlayer
local remotes = RS:WaitForChild("Remotes")
local collectRE = remotes:WaitForChild("CollectResource")
local placeRE = remotes:WaitForChild("PlaceStructure")
local mouse = plr:GetMouse()

-- ===== HUD =====
local gui = Instance.new("ScreenGui")
gui.Name = "OneWayCaravanNightfallHUD"
gui.ResetOnSpawn = false
gui.Parent = plr:WaitForChild("PlayerGui")

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
	return l
end

local phaseLbl = mkLabel("Phase", UDim2.new(0.5, -100, 0, 8), UDim2.new(0, 200, 0, 34))
local resLbl = mkLabel("Resources", UDim2.new(0, 8, 0, 8), UDim2.new(0, 230, 0, 34))
local msgLbl = mkLabel("Msg", UDim2.new(0.5, -180, 0, 48), UDim2.new(0, 360, 0, 26))
msgLbl.BackgroundTransparency = 1

local function mkButton(name, pos, text)
	local b = Instance.new("TextButton")
	b.Name = name
	b.Position = pos
	b.Size = UDim2.new(0, 190, 0, 36)
	b.BackgroundColor3 = Color3.fromRGB(50, 70, 50)
	b.TextColor3 = Color3.new(1, 1, 1)
	b.TextScaled = true
	b.Font = Enum.Font.SourceSansBold
	b.Text = text
	b.Parent = gui
	return b
end

local fireBtn = mkButton("BuildFire", UDim2.new(0, 8, 1, -90), "Fogueira (5 madeira)")
local barrBtn = mkButton("BuildBarricade", UDim2.new(0, 8, 1, -48), "Barricada (10 madeira)")

local function refreshRes()
	resLbl.Text = string.format("Madeira: %d | Comida: %d", plr:GetAttribute("Wood") or 0, plr:GetAttribute("Food") or 0)
end
plr:GetAttributeChangedSignal("Wood"):Connect(refreshRes)
plr:GetAttributeChangedSignal("Food"):Connect(refreshRes)
refreshRes()

local function refreshPhase()
	local phase = RS:GetAttribute("Phase") or "?"
	phaseLbl.Text = phase .. " — " .. tostring(RS:GetAttribute("PhaseTimeLeft") or 0) .. "s"
	phaseLbl.BackgroundColor3 = (phase == "Noite") and Color3.fromRGB(45, 25, 70) or Color3.fromRGB(20, 20, 20)
end
RS:GetAttributeChangedSignal("Phase"):Connect(refreshPhase)
RS:GetAttributeChangedSignal("PhaseTimeLeft"):Connect(refreshPhase)
refreshPhase()

-- ===== colocação e coleta por clique =====
local placing = nil
local armedAt = 0

fireBtn.MouseButton1Click:Connect(function()
	placing = "Fogueira"
	armedAt = os.clock()
	msgLbl.Text = "Clique no chão para colocar a Fogueira"
end)
barrBtn.MouseButton1Click:Connect(function()
	placing = "Barricada"
	armedAt = os.clock()
	msgLbl.Text = "Clique no chão para colocar a Barricada"
end)

mouse.Button1Down:Connect(function()
	if placing then
		if os.clock() - armedAt < 0.15 then return end -- ignora o clique que armou o botão
		if mouse.Hit then
			placeRE:FireServer(placing, mouse.Hit.Position)
		end
		placing = nil
		msgLbl.Text = ""
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
