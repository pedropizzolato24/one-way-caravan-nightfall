-- RouteGraph — grafo DAG da run (doc 4.6): nó inicial -> fork segura vs arriscada -> converge -> boss.
-- MVP (doc 3.1): 1 rota, 3 nós + 1 boss, forma fixa. generate() é a costura pra depois embaralhar
-- a ordem/posição dos TIPOS por run (nunca a geometria, que é pré-autorada no ZoneBuilder).
local RouteGraph = {}

function RouteGraph.generate()
	local nodes = {
		n1 = { id = "n1", kind = "estacao", label = "Estação Abandonada", depth = 1, children = { "n2a", "n2b" } },
		n2a = { id = "n2a", kind = "planicie", label = "Planície Aberta", tag = "segura", depth = 2, children = { "n3" } },
		n2b = { id = "n2b", kind = "mina", label = "Mina Desmoronada", tag = "arriscada", depth = 2, children = { "n3" } },
		n3 = { id = "n3", kind = "acampamento", label = "Acampamento Dizimado", depth = 3, children = { "boss" } },
		boss = { id = "boss", kind = "boss", label = "Covil da Ameaça", depth = 4, children = {} },
	}
	return { nodes = nodes, currentId = "n1" }
end

return RouteGraph
