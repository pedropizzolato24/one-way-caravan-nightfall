-- Places — IDs dos places da Experience (doc 4.2: Lobby Place + Run Place).
-- PREENCHA depois de criar o place Run (Creator Dashboard, ou Studio: File -> Publish As...
-- adicionando um novo place na MESMA Experience). O PlaceId aparece na URL do place no
-- Dashboard e em game.PlaceId com o place aberto no Studio.
--
-- 0 = não configurado: o teleporte é desativado e cada place roda em modo standalone —
-- o LobbyServer avisa que falta configurar, e o RunServer reinicia a run no mesmo servidor
-- ao fim (é também o que mantém tudo testável no Studio, onde TeleportService não funciona).
return {
	LOBBY = 0,
	RUN = 0,
}
