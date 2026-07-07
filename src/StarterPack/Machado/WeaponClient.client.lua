-- Machado: só envia intenção de ataque; alcance/dano/alvo validados no servidor
local RS = game:GetService("ReplicatedStorage")
local damageRE = RS:WaitForChild("Remotes"):WaitForChild("DamageEnemy")
local tool = script.Parent

tool.Activated:Connect(function()
	damageRE:FireServer()
end)
