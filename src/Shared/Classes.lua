-- Classes — roster do doc 5.6. Seção 3.2 item 1 (pós-MVP): só o CARPINTEIRO por enquanto,
-- pra validar que classe adiciona sem virar mandatória (pilar 3: comp nunca é pré-requisito).
-- Compartilhado entre Lobby (seleção + compra das passivas, moeda de perfil) e Run (efeitos
-- de gameplay: fortificar/reparar barricada, converter recurso, velocidade de craft/reparo).
--
-- Doc 5.6: "kit inicial (craftável por qualquer um, classe só começa com ele) + 1 passiva base +
-- 2 passivas desbloqueáveis (moeda de run)". O Carpinteiro não tem um item de kit nomeado no doc
-- (só a passiva de velocidade) — [PLACEHOLDER] não inventamos um; a classe é só a passiva base +
-- os 2 unlocks. "Moeda de run" = a moeda que sobrevive a checkpoint e vira moeda de perfil (doc
-- 5.2), então os unlocks de passiva são comprados no catálogo do Lobby como o resto (doc 4.4:
-- unlockedPassives é campo do perfil PERSISTENTE).
--
-- Seleção de classe é GRÁTIS (doc só marca como Robux as classes EXCLUSIVAS, fora de escopo;
-- nada indica custo pra escolher uma classe do roster base) — [PLACEHOLDER] documentado.
return {
	Carpinteiro = {
		id = "Carpinteiro",
		name = "Carpinteiro",
		basePassiveDesc = "Craft/reparo rápido: constrói mais rápido e repara barricada quebrada em menos tempo.",
		passives = {
			Fortificar = {
				id = "Fortificar",
				name = "Fortificar",
				price = 60, -- [PLACEHOLDER] moeda de perfil; ajustar em playtest (doc 5.2 sidegrade)
				desc = "Ação exclusiva do Carpinteiro: fortifica uma barricada recém-construída. Ao ser destruída, ela vira 'quebrada' em vez de sumir — reparável por qualquer um (doc Seção 2).",
			},
			ConversaoRecurso = {
				id = "ConversaoRecurso",
				name = "Conversão de Recurso",
				price = 60, -- [PLACEHOLDER]
				desc = "Ação exclusiva do Carpinteiro: converte madeira em comida. Taxa 3:1 (doc Seção 7 — placeholder de playtest).",
			},
		},
	},
}
