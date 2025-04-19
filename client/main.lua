-- client/main.lua

local kvpname = GetCurrentServerEndpoint()..'_inshells'
local currentMloRoomDoorStates = {} -- Stocke l'état local des portes de chambre MLO [nomMotel][indexChambre][indexSousPorte] = etat (0=déverrouillé, 1=verrouillé)
local currentZoneData = nil -- Stocke les données du motel de la zone actuelle
local currentZoneTargets = {} -- Stocke les IDs des cibles pour suppression { nomCible = true }
local inMotelZone = false
local zones, shelzones, blips = {}, {}, {} -- Initialise les tables globales utilisées
local PlayerData = {} -- Sera rempli par le framework
local ESX, QBCORE = nil, nil
local cache = {} -- Pour stocker le ped etc.

--[[ Fonctions utilitaires (Assure-toi qu'elles sont définies ou utilise celles de ton framework/libs) ]]

-- Exemple: Notification (si tu utilises ox_lib)
Notify = function(msg, type, duration)
    if lib and lib.notify then
        lib.notify({
            description = msg,
            type = type or 'inform',
            duration = duration or 5000,
            position = 'top'
        })
    else
        print(('[renzu_motels] Notify: %s (Type: %s)'):format(msg, type or 'inform')) -- Affichage de secours
    end
end

-- Exemple: Récupérer les items (si tu utilises ox_inventory)
GetInventoryItems = function(itemType)
    if exports.ox_inventory then
        local inventory = exports.ox_inventory:Search('slots', itemType)
        return inventory and #inventory > 0 and inventory or false
    end
    print("[renzu_motels] Attention: Fonction GetInventoryItems non implémentée ou ox_inventory non trouvé.")
    return false
end

-- Exemple: Ouvrir Stash (si tu utilises ox_inventory)
OpenStash = function(data, stashid)
    if exports.ox_inventory then
        local inventoryType = data.type or 'stash' -- Utilise data.type (ex: 'fridge') ou 'stash' par défaut
        local fullStashId = ('%s_%s_%s_%s'):format(inventoryType, data.motel, stashid, data.index)
        print(('[renzu_motels] Ouverture inventaire: %s avec ID: %s'):format(inventoryType, fullStashId))
        exports.ox_inventory:openInventory('stash', { id = fullStashId })
    else
        Notify("Système d'inventaire non trouvé.", "error")
    end
end

-- Vérifie si le joueur actuel est listé comme locataire de cette chambre
DoesPlayerHaveAccess = function(playersTable)
    if not PlayerData or not PlayerData.identifier then
        -- print("[renzu_motels] Attention: PlayerData.identifier non disponible dans DoesPlayerHaveAccess.")
        return false
    end
    if not playersTable then return false end
    -- Vérifie si l'identifiant du joueur actuel est une clé dans la table des joueurs de la chambre
    return playersTable[PlayerData.identifier] ~= nil
end

-- Vérifie si le joueur a une clé pour cette chambre spécifique
DoesPlayerHaveKey = function(doorData, roomData)
	local items = GetInventoryItems('keys')
	if not items then return false end
    if not roomData or not roomData.players then return false end -- Ajout vérification roomData.players

	for k,v in pairs(items) do
        -- Utilisation de l'opérateur ?. pour éviter les erreurs si metadata n'existe pas
		if v.metadata?.type == doorData.motel and v.metadata?.serial == doorData.index then
            -- Vérifie si la clé appartient à un joueur qui est actuellement dans la liste des joueurs de la chambre
            -- OU si le propriétaire de la clé est le joueur actuel (même s'il n'est pas dans roomData.players, utile si on donne la clé)
			return (v.metadata?.owner and roomData.players[v.metadata.owner] ~= nil) or (v.metadata?.owner == PlayerData.identifier)
		end
	end
	return false
end

-- Vérifie si le joueur est propriétaire ou employé du motel
IsOwnerOrEmployee = function(motelName)
	local motels = GlobalState.Motels
    if not motels or not motels[motelName] or not PlayerData or not PlayerData.identifier then return false end
	return motels[motelName].owned == PlayerData.identifier or (motels[motelName].employees and motels[motelName].employees[PlayerData.identifier])
end

-- Vérifie si le loyer est expiré
isRentExpired = function(data) -- data = { motel = '...', index = ... }
    if not GlobalState.Motels or not GlobalState.MotelTimer then return true end -- Considère expiré si données non dispo
	local room = GlobalState.Motels[data.motel]?.rooms[data.index]
	local playerRentInfo = room?.players[PlayerData.identifier]
    -- Retourne true si pas d'info de location ou si la durée est passée
	return not playerRentInfo?.duration or playerRentInfo.duration < GlobalState.MotelTimer
end


--[[ Fonctions principales du script ]]

CreateBlips = function()
    if not config or not config.motels then print("[renzu_motels] Erreur: config.motels non trouvé.") return end
	for k,v in pairs(config.motels) do
        if not v.rentcoord then print(("[renzu_motels] Attention: rentcoord manquant pour le motel %s"):format(v.label or k)) goto continue end
		local blip = AddBlipForCoord(v.rentcoord.x,v.rentcoord.y,v.rentcoord.z)
		SetBlipSprite(blip,475)
		SetBlipColour(blip,2)
		SetBlipAsShortRange(blip,true)
		SetBlipScale(blip,0.6)
		BeginTextCommandSetBlipName("STRING")
		AddTextComponentString(v.label or ('Motel %s'):format(k))
		EndTextCommandSetBlipName(blip)
        table.insert(blips, blip) -- Ajoute le blip à la table pour suppression éventuelle
        ::continue::
	end
end

RegisterNetEvent('renzu_motels:invoice', function(data)
    if not lib or not lib.alertDialog or not lib.callback then print("[renzu_motels] Erreur: ox_lib non disponible pour la facture.") return end
	local motels = GlobalState.Motels
    local buy = lib.alertDialog({
		header = 'Facture',
		content = '![motel](nui://renzu_motels/data/image/'..data.motel..'.png) \n ## INFO \n **Description:** '..data.description..'  \n  **Montant:** $ '..data.amount..'  \n **Méthode de paiement:** '..data.payment,
		centered = true,
		labels = {
			cancel = 'Fermer',
			confirm = 'Payer'
		},
		cancel = true
	})
	if buy ~= 'cancel' then
		local success = lib.callback.await('renzu_motels:payinvoice',false,data)
		if success then
			Notify('Vous avez payé la facture avec succès','success')
		else
			Notify('Échec du paiement de la facture','error')
		end
	end
end)

GetPlayerKeys = function(data,room)
	local items = GetInventoryItems('keys')
	if not items then return false end
	local keys = {}
	for k,v in pairs(items) do
		if v.metadata?.type == data.motel and v.metadata?.serial == data.index then
			local keyOwnerData = v.metadata?.owner and room?.players[v.metadata?.owner]
			if keyOwnerData then
				keys[v.metadata.owner] = keyOwnerData.name or ('Citoyen %s'):format(v.metadata.owner)
			end
		end
	end
	return keys
end

-- Fonction pour interagir avec la porte de CHAMBRE (MODIFIÉE pour MLO)
Door = function(data)
    -- data contient: motel, index (chambre), doorindex (sous-porte), coord, Mlo, door (modèle)

    local motel = GlobalState.Motels[data.motel]
	local motelRoomData = motel and motel.rooms[data.index] -- Données de la chambre spécifique

    -- Vérifie l'accès (locataire de CETTE chambre, propriétaire, employé, ou clé pour CETTE chambre)
    local hasAccess = (motelRoomData and DoesPlayerHaveAccess(motelRoomData.players)) or
                      (motelRoomData and DoesPlayerHaveKey(data, motelRoomData)) or
                      IsOwnerOrEmployee(data.motel)

    if hasAccess then
        -- Joue l'animation d'interaction
		lib.RequestAnimDict('mp_doorbell')
		TaskPlayAnim(PlayerPedId(), "mp_doorbell", "open_door", 1.0, 1.0, 1000, 1, 1, 0, 0, 0)
        Wait(500) -- Petite attente pour l'animation

        local text = "Erreur lors du changement d'état de la porte"
        local soundPlayed = false

		if data.Mlo then
            -- Logique MLO: Utilise les natives Get/SetStateOfDoor
            local doorHash = data.door -- Hash/modèle de la porte de chambre
            if not doorHash then
                print(('[renzu_motels] Erreur: Hash de modèle manquant pour la porte MLO %s-%s-%s'):format(data.motel, data.index, data.doorindex))
                Notify('Erreur de configuration de porte.', 'error')
                return
            end

            -- Trouve l'objet porte le plus proche correspondant au hash et aux coordonnées
            local doorObj = GetClosestObjectOfType(data.coord.x, data.coord.y, data.coord.z, 1.5, doorHash, false, false, false)

            if doorObj ~= 0 then
                local currentState = GetStateOfDoor(doorObj) -- 0 = déverrouillé, 1 = verrouillé
                local newState = currentState == 0 and 1 or 0 -- Bascule l'état

                -- Applique le nouvel état, sans son natif, mais avec synchronisation
                SetStateOfDoor(doorObj, newState, false, true)

                -- Met à jour notre suivi local (optionnel mais peut être utile)
                if not currentMloRoomDoorStates[data.motel] then currentMloRoomDoorStates[data.motel] = {} end
                if not currentMloRoomDoorStates[data.motel][data.index] then currentMloRoomDoorStates[data.motel][data.index] = {} end
                currentMloRoomDoorStates[data.motel][data.index][data.doorindex] = newState

                text = newState == 1 and 'Vous avez verrouillé la porte de la chambre' or 'Vous avez déverrouillé la porte de la chambre'

                -- Joue le son via NUI
                local soundData = { file = 'door', volume = 0.5 }
                SendNUIMessage({ type = "playsound", content = soundData })
                soundPlayed = true
                print(('[renzu_motels] Porte MLO basculée %s-%s-%s à l\'état %s'):format(data.motel, data.index, data.doorindex, newState))
            else
                print(('[renzu_motels] Erreur: Impossible de trouver l\'objet porte MLO près de %s pour le modèle %s'):format(tostring(data.coord), doorHash))
                text = "Impossible de trouver l'objet porte"
                Notify(text, 'error')
            end
		else
            -- Logique Non-MLO (Shell): Déclenche l'événement serveur qui gère l'état logique
            TriggerServerEvent('renzu_motels:Door', {
                motel = data.motel,
                index = data.index,
                coord = data.coord,
                Mlo = data.Mlo,
            })
            -- Le texte est basé sur l'état logique *avant* le toggle serveur
			text = not motelRoomData?.lock and 'Vous avez verrouillé la porte de la chambre' or 'Vous avez déverrouillé la porte de la chambre'
            -- Joue le son via NUI
            local soundData = { file = 'door', volume = 0.5 }
            SendNUIMessage({ type = "playsound", content = soundData })
            soundPlayed = true
		end

		Wait(500) -- Attente après l'action

        -- Affiche la notification si le son a été joué (évite double notif si erreur avant)
		if soundPlayed then
            Notify(text, 'inform')
        end
	else
		Notify('Vous n\'avez pas accès à cette porte de chambre', 'error')
    end
end

-- Assure que RoomFunction passe les bonnes données à Door
RoomFunction = function(data,identifier) -- identifier est pour stash/fridge
	-- Vérifie l'expiration du loyer pour CETTE chambre
    local rentCheckData = { motel = data.motel, index = data.index }
	if isRentExpired(rentCheckData) then
		return Notify('Votre loyer est expiré. Veuillez payer pour accéder', 'error')
	end

	if data.type == 'door' then
        -- Appelle la fonction Door avec toutes les données nécessaires
		return Door(data) -- data contient déjà motel, index, doorindex, coord, Mlo, door(model)
	elseif data.type == 'stash' then
		local stashid = identifier or data.uniquestash and PlayerData.identifier or 'room'
		return OpenStash(data,stashid)
	elseif data.type == 'wardrobe' then
        if not config.wardrobe or not config.wardrobes[config.wardrobe] then
            Notify("Système de garde-robe non configuré correctement.", "error")
            return
        end
		return config.wardrobes[config.wardrobe]()
	elseif config.extrafunction and config.extrafunction[data.type] then
		local stashid = identifier or data.uniquestash and PlayerData.identifier or 'room'
		return config.extrafunction[data.type](data,stashid)
    else
        Notify(("Fonctionnalité '%s' non implémentée."):format(data.type), "error")
	end
end

-- Fonction LockPick (potentiellement modifiée pour MLO)
LockPick = function(data)
	local success = nil
    local cancelled = false
	SetTimeout(1000,function()
        -- Utilise lib.progress pour la barre de progression
		success = lib.progress({
			duration = 10000,
			label = 'Crochetage en cours..',
			useWhileDead = false,
			canCancel = true,
            -- disable = { move = true, car = true, combat = true }, -- Désactive actions pendant le crochetage
			anim = {
				dict = 'veh@break_in@0h@p_m_one@',
				clip = 'low_force_entry_ds'
			},
            prop = { -- Optionnel: ajouter un prop
                model = `prop_tool_consaw`,
                pos = vec3(0.0, 0.0, 0.0),
                rot = vec3(0.0, 0.0, 0.0),
            },
            onCancel = function()
                cancelled = true
                Notify("Crochetage annulé.", "inform")
            end,
            onFinish = function(didComplete)
                if not didComplete then cancelled = true end -- Si échoue ou annulé
            end
		})

        -- Lance le skill check pendant la barre de progression
        if success then -- Si la barre a démarré sans erreur
            success = lib.skillCheck({'easy', 'easy', {areaSize = 60, speedMultiplier = 2}, 'easy'})
            if not success then
                lib.cancelProgress() -- Annule la barre si le skill check échoue
                Notify("Crochetage échoué.", "error")
            end
        else
            cancelled = true -- La barre n'a pas démarré
        end
	end)

    -- Attend la fin de la progression ou l'annulation
    while success == nil and not cancelled do Wait(100) end

    -- Si réussi et non annulé
	if success and not cancelled then
        Notify("Serrure forcée !", "success")
        if data.Mlo then
            -- Appelle directement la fonction client pour changer l'état MLO (déverrouille)
            local doorHash = data.door
            if not doorHash then return Notify('Erreur de configuration de porte.', 'error') end
            local doorObj = GetClosestObjectOfType(data.coord.x, data.coord.y, data.coord.z, 1.5, doorHash, false, false, false)
            if doorObj ~= 0 then
                SetStateOfDoor(doorObj, 0, false, true) -- 0 = unlocked
                if not currentMloRoomDoorStates[data.motel] then currentMloRoomDoorStates[data.motel] = {} end
                if not currentMloRoomDoorStates[data.motel][data.index] then currentMloRoomDoorStates[data.motel][data.index] = {} end
                currentMloRoomDoorStates[data.motel][data.index][data.doorindex] = 0
                print(('[renzu_motels] Porte MLO crochetée %s-%s-%s à l\'état 0'):format(data.motel, data.index, data.doorindex))
                -- Joue le son
                local soundData = { file = 'door', volume = 0.5 }
                SendNUIMessage({ type = "playsound", content = soundData })
            else
                Notify("Impossible de trouver l'objet porte à déverrouiller.", "error")
            end
        else
            -- Comportement original pour non-MLO (déverrouille côté serveur)
            TriggerServerEvent('renzu_motels:Door', {
                motel = data.motel,
                index = data.index,
                coord = data.coord,
                Mlo = false,
                -- forceUnlock = true -- Optionnel: Ajouter un flag si le serveur doit forcer le déverrouillage
            })
             -- Joue le son
            local soundData = { file = 'door', volume = 0.5 }
            SendNUIMessage({ type = "playsound", content = soundData })
        end
	end
end

-- Menus (MyRoomMenu, RoomList, MotelRentalMenu, MotelOwner, etc.)
MyRoomMenu = function(data)
    if not lib or not lib.registerContext or not lib.inputDialog or not lib.alertDialog then return Notify("Librairie UI (ox_lib) non disponible.", "error") end
	local motels = GlobalState.Motels
    if not motels or not motels[data.motel] then return Notify("Données du motel non trouvées.", "error") end
	local rate = motels[data.motel].hour_rate or data.rate

	local options = {
		{
			title = 'Ma Chambre ['..data.index..'] - Payer le loyer',
			description = 'Payez votre loyer dû ou en avance pour la porte '..data.index..' \n Durée restante: '..data.duration..' \n Taux par '..data.rental_period..': $ '..rate,
			icon = 'money-bill-wave-alt',
			onSelect = function()
				local input = lib.inputDialog('Payer ou déposer au motel', {
					{type = 'number', label = 'Montant à déposer', description = '$ '..rate..' par '..data.rental_period..'  \n  Méthode de paiement: '..data.payment, icon = 'money', default = rate, min = rate}, -- Ajout min=rate
				})
				if not input or not input[1] then return end
				local success = lib.callback.await('renzu_motels:payrent',false,{
					payment = data.payment,
					index = data.index,
					motel = data.motel,
					amount = input[1],
					rate = rate,
					rental_period = data.rental_period
				})
				if success then
					Notify('Loyer payé avec succès', 'success')
				else
					Notify('Échec du paiement du loyer', 'error')
				end
			end,
			arrow = true,
		},
		{
			title = 'Générer une clé',
			description = 'Demander une clé de porte',
			icon = 'key',
			onSelect = function()
				local success = lib.callback.await('renzu_motels:motelkey',false,{
					index = data.index,
					motel = data.motel,
				})
				if success then
					Notify('Clé de motel partageable demandée avec succès', 'success')
				else
					Notify('Échec de la génération de la clé', 'error')
				end
			end,
			arrow = true,
		},
		{
			title = 'Terminer la location',
			description = 'Mettre fin à votre période de location',
			icon = 'ban',
			onSelect = function()
                -- Vérifie si le loyer est expiré (ne devrait pas pouvoir terminer si expiré avec dette potentielle)
				if isRentExpired(data) then
					Notify('Impossible de terminer la location pour la chambre '..data.index..'  \n  Raison: votre loyer est déjà dû. Payez d\'abord si nécessaire.','error')
					return
				end
				local End = lib.alertDialog({
					header = '## Attention',
					content = ' Vous n\'aurez plus accès à la porte et à vos coffres.',
					centered = true,
					labels = {
						cancel = 'Fermer',
						confirm = 'Terminer',
					},
					cancel = true
				})
				if End == 'cancel' then return end
				local success = lib.callback.await('renzu_motels:removeoccupant',false,data,data.index,PlayerData.identifier)
				if success then
					Notify('Vous avez terminé avec succès votre location pour la chambre '..data.index,'success')
				else
					Notify('Échec de la fin de location pour la chambre '..data.index,'error')
				end
			end,
			arrow = true,
		},
	}
	lib.registerContext({
        id = 'myroom',
		menu = 'roomlist', -- Permet de revenir au menu précédent
        title = 'Options de ma chambre de motel',
        options = options
    })
	lib.showContext('myroom')
end

CountOccupants = function(players)
	local count = 0
	if not players then return 0 end
	for k,v in pairs(players) do
		count += 1
	end
	return count
end

RoomList = function(data)
    if not lib or not lib.registerContext or not lib.inputDialog then return Notify("Librairie UI (ox_lib) non disponible.", "error") end
	local motels , time = lib.callback.await('renzu_motels:getMotels',false)
    if not motels or not motels[data.motel] then return Notify("Données du motel non disponibles.", "error") end
	local rate = motels[data.motel].hour_rate or data.rate
	local options = {}

	for doorindex=1, #data.doors do -- Itère sur les index numériques des portes configurées
        local roomData = motels[data.motel].rooms[doorindex]
        if not roomData then
            print(('[renzu_motels] Attention: Données de chambre manquantes pour %s-%s dans RoomList'):format(data.motel, doorindex))
            goto continue -- Saute cette chambre si les données manquent
        end

		local playerroom = roomData.players[PlayerData.identifier]
		local duration = playerroom?.duration
		local occupants = CountOccupants(roomData.players)

		if occupants < data.maxoccupants and not duration then
			table.insert(options,{
				title = 'Louer la chambre #'..doorindex,
				description = 'Choisir la chambre #'..doorindex..' \n Occupants: '..occupants..'/'..data.maxoccupants,
				icon = 'door-closed',
				onSelect = function()
					local input = lib.inputDialog('Durée de location', {
						{type = 'number', label = 'Sélectionner une durée en '..data.rental_period..'(s)', description = '$ '..rate..' par '..data.rental_period..'   \n   Méthode de paiement: '..data.payment, icon = 'clock', default = 1, min = 1},
					})
					if not input or not input[1] then return end
					local success = lib.callback.await('renzu_motels:rentaroom',false,{
						index = doorindex,
						motel = data.motel,
						duration = input[1],
						rate = rate,
						rental_period = data.rental_period,
						payment = data.payment,
						uniquestash = data.uniquestash
					})
					if success then
						Notify('Chambre louée avec succès', 'success')
					else
						Notify('Échec de la location de la chambre', 'error')
					end
				end,
				arrow = true,
			})
		elseif duration then
            local timeLeft = duration - time
            local duration_left = "Expiré"
            if timeLeft > 0 then
                local hour = math.floor(timeLeft / 3600)
                local minute = math.floor((timeLeft / 60) % 60)
                duration_left = hour .. ' Heures : '.. minute ..' Minutes'
            end
			table.insert(options,{
				title = 'Options de ma chambre #'..doorindex,
				description = 'Durée de location restante: '..duration_left,
				icon = 'cog',
				onSelect = function()
					return MyRoomMenu({
						payment = data.payment,
						index = doorindex,
						motel = data.motel,
						duration = duration_left, -- Passe la string calculée
						rate = rate,
						rental_period = data.rental_period
					})
				end,
				arrow = true,
			})
		end
        ::continue::
	end
    lib.registerContext({
        id = 'roomlist',
		menu = 'rentmenu', -- Permet de revenir au menu précédent
        title = 'Choisir une chambre',
        options = options
    })
	lib.showContext('roomlist')
end

MotelRentalMenu = function(data)
    if not lib or not lib.registerContext then return Notify("Librairie UI (ox_lib) non disponible.", "error") end
	local motels = GlobalState.Motels
    if not motels or not motels[data.motel] then return Notify("Données du motel non disponibles.", "error") end
	local rate = motels[data.motel].hour_rate or data.rate
	local options = {}

	if not data.manual then
		table.insert(options,{
			title = 'Louer une nouvelle chambre',
			description = '!rent \n Choisir une chambre à louer \n Taux par '..data.rental_period..': $'..rate,
			icon = 'hotel',
			onSelect = function()
				return RoomList(data)
			end,
			arrow = true,
		})
	end

    -- Vérifie si l'achat de business est activé globalement ET si ce motel spécifique a un prix défini
	if config.business and data.businessprice and data.businessprice > 0 then
        local isCurrentlyOwned = motels[data.motel].owned ~= nil
        local canManage = isCurrentlyOwned and IsOwnerOrEmployee(data.motel)

        if not isCurrentlyOwned or canManage then
            local title = not isCurrentlyOwned and 'Acheter le Motel' or 'Gestion du Motel'
            local description = not isCurrentlyOwned and ('Coût: $%s'):format(data.businessprice) or 'Gérer employés, occupants et finances.'
            table.insert(options,{
                title = title,
                description = description,
                icon = 'briefcase', -- Icône différente pour business
                onSelect = function()
                    return MotelOwner(data) -- Fonction pour gérer l'achat ou la gestion
                end,
                arrow = true,
            })
        end
	end

	if #options == 0 then
        if data.manual then
            Notify('Ce Motel accepte les occupants manuellement. Contactez le propriétaire.')
            Wait(1500)
            return SendMessageApi(data.motel) -- Propose d'envoyer un message
        else
             Notify('Aucune chambre disponible ou aucune action possible pour le moment.') -- Message générique
        end
		return
	end

    lib.registerContext({
        id = 'rentmenu',
        title = data.label,
        options = options
    })
	lib.showContext('rentmenu')
end

SendMessageApi = function(motel)
    if not lib or not lib.alertDialog or not lib.inputDialog then return Notify("Librairie UI (ox_lib) non disponible.", "error") end
	local message = lib.alertDialog({
		header = 'Voulez-vous envoyer un message au propriétaire ?',
		content = '## Envoyer un message au propriétaire du Motel',
		centered = true,
		labels = {
			cancel = 'Fermer',
			confirm = 'Envoyer',
		},
		cancel = true
	})
	if message == 'cancel' then return end
	local input = lib.inputDialog('Message', {
		{type = 'input', label = 'Titre', description = 'Titre de votre message', icon = 'heading', required = true},
		{type = 'textarea', label = 'Description', description = 'Votre message', icon = 'envelope', required = true},
		-- {type = 'number', label = 'Numéro de contact', icon = 'phone', required = false}, -- Commenté car non utilisé dans config.messageApi par défaut
	})
    if not input or not input[1] or not input[2] then return end -- Vérifie que les inputs requis sont remplis

    if config.messageApi then
	    config.messageApi({title = input[1], message = input[2], motel = motel})
    else
        Notify("API de messagerie non configurée.", "error")
    end
end

-- Fonctions Owner.* (inchangées pour l'instant, mais nécessitent ox_lib)
Owner = {}
Owner.Rooms = {}
Owner.Rooms.Occupants = function(data,index)
    if not lib or not lib.registerContext or not lib.alertDialog or not lib.inputDialog then return Notify("Librairie UI (ox_lib) non disponible.", "error") end
	local motels , time = lib.callback.await('renzu_motels:getMotels',false)
    if not motels or not motels[data.motel] then return Notify("Données du motel non disponibles.", "error") end
	local motel = motels[data.motel]
	local players = motel.rooms[index] and motel.rooms[index].players or {}
	local options = {}
	for player,char in pairs(players) do
        local timeLeft = (char.duration or 0) - time
        local name = char.name or ('Citoyen %s'):format(player)
        local duration_left = "Expiré"
        if timeLeft > 0 then
            local hour = math.floor(timeLeft / 3600)
            local minute = math.floor((timeLeft / 60) % 60)
            duration_left = hour .. ' Heures : '.. minute ..' Minutes'
        end
		table.insert(options,{
			title = 'Occupant '..name,
			description = 'Durée de location: '..duration_left,
			icon = 'user',
			onSelect = function()
				local kick = lib.alertDialog({
					header = 'Confirmation',
					content = '## Expulser l\'occupant \n  **Nom:** '..name,
					centered = true,
					labels = {
						cancel = 'Fermer',
						confirm = 'Expulser',
					},
					cancel = true
				})
				if kick == 'cancel' then return end
				local success = lib.callback.await('renzu_motels:removeoccupant',false,data,index,player)
				if success then
					Notify(name..' expulsé(e) avec succès de la chambre '..index,'success')
                    lib.hideContext(true) -- Ferme le menu actuel après succès
				else
					Notify('Échec de l\'expulsion de '..name..' de la chambre '..index,'error')
				end
			end,
			arrow = true,
		})
	end
	if data.maxoccupants > CountOccupants(players) then -- Utilise CountOccupants
		for i = 1, data.maxoccupants - CountOccupants(players) do
			table.insert(options,{
				title = 'Emplacement libre ',
                description = "Ajouter un nouvel occupant à cette chambre.",
				icon = 'plus',
				onSelect = function()
					local input = lib.inputDialog('Nouvel Occupant', {
						{type = 'number', label = 'ID Citoyen', description = 'ID du citoyen à ajouter', icon = 'id-card', required = true},
						{type = 'number', label = 'Sélectionner une durée en '..data.rental_period..'(s)', description = 'Combien de '..data.rental_period..'(s)', icon = 'clock', default = 1, min = 1},
					})
					if not input or not input[1] or not input[2] then return end
					local success = lib.callback.await('renzu_motels:addoccupant',false,data,index,input)
					if success == 'exist' then
						Notify('Le joueur loue déjà une chambre dans ce motel.','error') -- Message plus clair
					elseif success then
						Notify('Occupant ajouté avec succès à la chambre '..index,'success')
                        lib.hideContext(true) -- Ferme le menu actuel après succès
					else
						Notify('Échec de l\'ajout de l\'occupant à la chambre '..index,'error')
					end
				end,
				arrow = true,
			})
		end
	end
	lib.registerContext({
		menu = 'owner_rooms', -- Permet de revenir en arrière
        id = 'occupants_lists',
        title = 'Chambre #'..index..' Occupants',
        options = options
    })
	lib.showContext('occupants_lists')
end

Owner.Rooms.List = function(data)
    if not lib or not lib.registerContext then return Notify("Librairie UI (ox_lib) non disponible.", "error") end
	local motels = GlobalState.Motels
    if not motels or not motels[data.motel] then return Notify("Données du motel non disponibles.", "error") end
	local options = {}
	for doorindex=1, #data.doors do
        local roomData = motels[data.motel].rooms[doorindex]
        if not roomData then goto continue end -- Saute si données de chambre manquantes
		local occupants = CountOccupants(roomData.players)
		table.insert(options,{
			title = 'Chambre #'..doorindex,
			description = 'Ajouter ou Expulser des occupants de la chambre #'..doorindex..' \n ***Occupants:*** '..occupants..'/'..data.maxoccupants,
			icon = 'door-open',
			onSelect = function()
				return Owner.Rooms.Occupants(data,doorindex)
			end,
			arrow = true,
		})
        ::continue::
	end
	lib.registerContext({
		menu = 'motelmenu', -- Permet de revenir en arrière
        id = 'owner_rooms',
        title = data.label .. ' - Chambres',
        options = options
    })
	lib.showContext('owner_rooms')
end

Owner.Employee = {}
Owner.Employee.Manage = function(data)
    if not lib or not lib.registerContext or not lib.inputDialog then return Notify("Librairie UI (ox_lib) non disponible.", "error") end
	local motel = GlobalState.Motels[data.motel]
    if not motel then return Notify("Données du motel non disponibles.", "error") end
	local options = {
		{
			title = 'Ajouter Employé',
			description = 'Ajouter un citoyen à vos employés du motel',
			icon = 'user-plus',
			onSelect = function()
				local input = lib.inputDialog('Ajouter Employé', {
					{type = 'number', label = 'ID Citoyen', description = 'ID du citoyen à ajouter', icon = 'id-card', required = true},
				})
				if not input or not input[1] then return end
				local success = lib.callback.await('renzu_motels:addemployee',false,data.motel,input[1])
				if success then
					Notify('Ajouté avec succès à la liste des employés','success')
                    lib.hideContext(true) -- Ferme le menu
				else
					Notify('Échec de l\'ajout à la liste des employés (Joueur non trouvé ou déjà employé?)','error')
				end
			end,
			arrow = true,
		}
	}
    if motel.employees then
       for identifier,name in pairs(motel.employees) do
          table.insert(options,{
			title = name or ('Citoyen %s'):format(identifier),
			description = 'Retirer '..(name or identifier)..' de votre liste d\'employés',
			icon = 'user-minus',
			onSelect = function()
                -- Confirmation avant suppression
                local confirm = lib.alertDialog({ header = 'Confirmer', content = 'Retirer '..(name or identifier)..' des employés ?', centered = true, cancel = true})
                if confirm == 'cancel' then return end
				local success = lib.callback.await('renzu_motels:removeemployee',false,data.motel,identifier)
					if success then
						Notify('Retiré avec succès de la liste des employés','success')
                        lib.hideContext(true) -- Ferme le menu
					else
						Notify('Échec du retrait de la liste des employés','error')
					end
			end,
			arrow = true,
		})
	   end
	end
	lib.registerContext({
        id = 'employee_manage',
        menu = 'motelmenu', -- Permet de revenir en arrière
        title = 'Gestion des Employés',
        options = options
    })
	lib.showContext('employee_manage')
end

MotelOwner = function(data)
    if not lib or not lib.registerContext or not lib.alertDialog or not lib.inputDialog then return Notify("Librairie UI (ox_lib) non disponible.", "error") end
	local motels = GlobalState.Motels
    if not motels or not motels[data.motel] then return Notify("Données du motel non disponibles.", "error") end

    -- Logique d'achat si non possédé
	if not motels[data.motel].owned then
		local buy = lib.alertDialog({
			header = data.label,
			content = '!motel \n ## INFO \n **Chambres:** '..#data.doors..'  \n  **Occupants Max:** '..(#data.doors * data.maxoccupants)..'  \n  **Prix:** $'..data.businessprice,
			centered = true,
			labels = { cancel = 'Fermer', confirm = 'Acheter' },
			cancel = true
		})
		if buy ~= 'cancel' then
			local success = lib.callback.await('renzu_motels:buymotel',false,data)
			if success then
				Notify('Vous avez acheté le motel avec succès','success')
			else
				Notify('Échec de l\'achat du motel (Pas assez d\'argent?)','error')
			end
		end
    -- Logique de gestion si propriétaire ou employé
	elseif IsOwnerOrEmployee(data.motel) then
		local revenue = motels[data.motel].revenue or 0
		local rate = motels[data.motel].hour_rate or data.rate
		local options = {
			{
				title = 'Chambres du Motel',
				description = 'Gérer les occupants',
				icon = 'door-open',
				onSelect = function() return Owner.Rooms.List(data) end,
				arrow = true,
			},
			{
				title = 'Envoyer une Facture',
				description = 'Facturer les citoyens à proximité',
				icon = 'file-invoice-dollar',
				onSelect = function()
					local input = lib.inputDialog('Envoyer une Facture', {
						{type = 'number', label = 'ID Citoyen', description = 'ID du citoyen à proximité', icon = 'id-card', required = true},
						{type = 'number', label = 'Montant', description = 'Montant total à demander', icon = 'dollar-sign', required = true, min = 1},
						{type = 'input', label = 'Description', description = 'Description de la facture (optionnel)', icon = 'info'},
						{type = 'checkbox', label = {'Paiement via Compte Bancaire'}}, -- Utilise une table pour le label du checkbox
					})
					if not input or not input[1] or not input[2] then return end
                    local paymentType = input[4] and 'bank' or 'money' -- Récupère la valeur du checkbox
					Notify('Envoi de la facture à '..input[1]..'...','inform')
                    -- Utilise une coroutine pour ne pas bloquer le joueur pendant l'attente du paiement
                    Citizen.CreateThread(function()
                        local success = lib.callback.await('renzu_motels:sendinvoice',false,data.motel,{input[1], input[2], input[3] or "Service Motel", paymentType}) -- Passe le type de paiement
                        if success == true then -- Vérifie explicitement true (car peut retourner false ou nil)
                            Notify('La facture a été payée','success')
                        elseif success == false then
                            Notify('La facture n\'a pas été payée ou a été rejetée.','error')
                        else
                            Notify('Échec de l\'envoi de la facture (Joueur non trouvé?).','error')
                        end
                    end)
				end,
				arrow = true,
			}
		}
        -- Options réservées au propriétaire
		if motels[data.motel].owned == PlayerData.identifier then
			table.insert(options,{
				title = 'Ajuster Taux par '..data.rental_period,
				description = 'Modifier les taux actuels par '..data.rental_period..'. \n Taux Actuel: $'..rate,
				icon = 'sliders-h',
				onSelect = function()
					local input = lib.inputDialog('Modifier Taux par '..data.rental_period, {
						{type = 'number', label = 'Taux', description = 'Taux par '..data.rental_period..'', icon = 'dollar-sign', required = true, min = 0},
					})
					if not input or not input[1] then return end
					local success = lib.callback.await('renzu_motels:editrate',false,data.motel,input[1])
					if success then
						Notify('Vous avez modifié avec succès le taux par '..data.rental_period,'success')
                        lib.hideContext(true) -- Ferme le menu
					else
						Notify('Échec de la modification du taux','error')
					end
				end,
				arrow = true,
			})
			table.insert(options,{
				title = 'Revenu du Motel',
				description = 'Revenu Total: $'..revenue,
				icon = 'wallet',
				onSelect = function()
                    if revenue <= 0 then return Notify("Aucun revenu à retirer.", "inform") end
					local input = lib.inputDialog('Retirer des Fonds', {
						{type = 'number', label = 'Montant', icon = 'dollar-sign', required = true, max = revenue, min = 1},
					})
					if not input or not input[1] then return end
					local success = lib.callback.await('renzu_motels:withdrawfund',false,data.motel,input[1])
					if success then
						Notify('Vous avez retiré les fonds avec succès','success')
                        lib.hideContext(true) -- Ferme le menu
					else
						Notify('Échec du retrait (Montant invalide?)','error')
					end
				end,
				arrow = true,
			})
			table.insert(options,{
				title = 'Gestion des Employés',
				description = 'Ajouter / Retirer Employé',
				icon = 'users-cog',
				onSelect = function() return Owner.Employee.Manage(data) end,
				arrow = true,
			})
			table.insert(options,{
				title = 'Transférer la Propriété',
				description = 'Transférer à un autre citoyen',
				icon = 'exchange-alt',
				onSelect = function()
					local input = lib.inputDialog('Transférer le Motel', {
						{type = 'number', label = 'ID Citoyen', description = 'ID du citoyen à qui transférer la propriété', icon = 'id-card', required = true},
					})
					if not input or not input[1] then return end
                    -- Confirmation
                    local confirm = lib.alertDialog({ header = 'Confirmer Transfert', content = 'Êtes-vous sûr de vouloir transférer la propriété de '..data.label..'?', centered = true, cancel = true})
                    if confirm == 'cancel' then return end
					local success = lib.callback.await('renzu_motels:transfermotel',false,data.motel,input[1])
					if success then
						Notify('Propriété du Motel transférée avec succès','success')
                        lib.hideContext(true) -- Ferme le menu
					else
						Notify('Échec du transfert (Joueur non trouvé?)','error')
					end
				end,
				arrow = true,
			})
			table.insert(options,{
				title = 'Vendre le Motel',
				description = 'Vendre le motel pour la moitié du prix',
				icon = 'dollar-sign',
				onSelect = function()
                    local sellValue = math.floor(data.businessprice / 2)
					local sell = lib.alertDialog({
						header = data.label,
						content = '!motel \n ## INFO \n  **Valeur de Vente:** $'..sellValue,
						centered = true,
						labels = { cancel = 'Fermer', confirm = 'Vendre' },
						cancel = true
					})
					if sell ~= 'cancel' then
						local success = lib.callback.await('renzu_motels:sellmotel',false,data)
						if success then
							Notify('Vous avez vendu le motel avec succès','success')
                            lib.hideContext(true) -- Ferme le menu
						else
							Notify('Échec de la vente du motel','error')
						end
					end
				end,
				arrow = true,
			})
		end
		lib.registerContext({
			id = 'motelmenu',
			menu = 'rentmenu', -- Permet de revenir en arrière
			title = data.label .. ' - Gestion',
			options = options
		})
		lib.showContext('motelmenu')
	end
end

-- Point de location
MotelRentalPoints = function(data)
    -- Assure que les composants ox_lib sont disponibles
    if not lib or not lib.points or not lib.showTextUI or not lib.hideTextUI then
        print("[renzu_motels] Erreur: ox_lib points/textui non disponible pour MotelRentalPoints.")
        return nil -- Retourne nil si lib est manquante
    end

    -- Vérifie si data et rentcoord sont valides avant de créer le point
    if not data or not data.rentcoord or type(data.rentcoord) ~= 'vector3' then
         print(("[renzu_motels] Attention: rentcoord invalide ou manquant pour le motel '%s'. Création du point de location annulée."):format(data and data.label or 'INCONNU'))
         return nil -- Retourne nil si les coordonnées sont invalides
    end

    local point = lib.points.new({
        coords = data.rentcoord,
        distance = 5.0, -- Distance à laquelle onEnter/onExit/nearby sont appelés
    })

    function point:onEnter()
		lib.showTextUI('[E] - '..(data.label or 'Location Motel'), {
			position = "top-center",
			icon = 'hotel',
			style = {
				borderRadius = 0,
				backgroundColor = '#141517',
				color = 'white'
			}
		})
	end

    function point:onExit()
		lib.hideTextUI()
	end

    function point:nearby(playerCoords, playerPed) -- Arguments corrects fournis par ox_lib
        -- ***** NOUVELLE PROTECTION AJOUTÉE ICI *****
        if not playerCoords then
            -- print("[renzu_motels] Attention: playerCoords est nil dans point:nearby.") -- Optionnel: pour débugger si ça arrive souvent
            return -- Quitte la fonction pour cette frame si playerCoords est nil
        end
        -- ***** FIN NOUVELLE PROTECTION *****

        -- Protection pour self.coords (au cas où)
        if not self.coords or not self.coords.x or not self.coords.y or not self.coords.z then
            return -- Arrête l'exécution si les coords du point sont mauvaises
        end

        -- Dessine le marqueur
        DrawMarker(2, self.coords.x, self.coords.y, self.coords.z - 0.95, 0.0, 0.0,0.0, 0.0, 0.0, 0.0, 0.7, 0.7, 0.7, 200, 200, 200, 100, false,true, 2, nil, nil, false)

        -- Calcule la distance au carré (plus performant que Vdist)
        local distanceSq = Vdist2(playerCoords.x, playerCoords.y, playerCoords.z, self.coords.x, self.coords.y, self.coords.z)

        -- Vérifie la distance au carré et la touche d'interaction
        -- On compare avec la distance d'interaction souhaitée au carré (1.5 * 1.5 = 2.25)
        if distanceSq < (1.5 * 1.5) and IsControlJustReleased(0, 38) then -- 38 = E
            MotelRentalMenu(data)
        end
    end

	return point
end



-- Fonction pour créer les interactions (appelée dans onEnter)
CreateMotelInteractions = function(data)
    currentZoneData = data -- Sauvegarde les données pour onExit
    currentZoneTargets = {} -- Réinitialise les cibles

    -- Création des interactions pour les portes/fonctions des CHAMBRES
    if not data.doors then print(('[renzu_motels] Attention: Aucune porte définie pour le motel %s'):format(data.motel)) return end

    for roomIndex, roomContent in pairs(data.doors) do
        if type(roomContent) ~= 'table' then goto room_continue end -- Ignore si pas une table

        for interactionType, interactionInfo in pairs(roomContent) do
            if type(interactionInfo) ~= 'table' and type(interactionInfo) ~= 'vector3' then goto interaction_continue end -- Ignore si pas table ou vec3

            if interactionType == 'door' then -- Cas spécial pour les portes de chambre (peut y en avoir plusieurs)
                if type(interactionInfo) ~= 'table' then goto interaction_continue end -- Doit être une table pour les portes

                for doorSubIndex, doorData in pairs(interactionInfo) do
                    if type(doorData) ~= 'table' or not doorData.coord or not doorData.model then
                        print(('[renzu_motels] Attention: Configuration de porte invalide pour %s-%s-%s'):format(data.motel, roomIndex, doorSubIndex))
                        goto door_continue
                    end

                    local targetName = ('motel_room_door:%s:%s:%s'):format(data.motel, roomIndex, doorSubIndex)
                    local interactionData = {
                        Mlo = data.Mlo,
                        type = interactionType, -- 'door'
                        index = roomIndex, -- Index de la chambre
                        doorindex = doorSubIndex, -- Index de la porte DANS la chambre
                        coord = doorData.coord,
                        label = config.Text[interactionType] or 'Porte',
                        motel = data.motel,
                        door = doorData.model -- Hash/modèle de la porte de chambre
                    }

                    if config.target then
                        if not exports.ox_target then print("[renzu_motels] Erreur: ox_target non démarré.") goto door_continue end
                        exports.ox_target:addSphereZone({
                            coords = doorData.coord,
                            radius = 1.5,
                            debug = false,
                            options = {
                                {
                                    name = targetName,
                                    icon = config.icons[interactionType] or 'fas fa-door-open',
                                    label = interactionData.label,
                                    onSelect = function() RoomFunction(interactionData) end,
                                    canInteract = function()
                                        if isRentExpired({ motel = data.motel, index = roomIndex }) then
                                            return false
                                        end
                                        local motel = GlobalState.Motels[data.motel]
                                        local motelRoomData = motel and motel.rooms[roomIndex]
                                        if not motelRoomData then
                                            -- print(('[renzu_motels] Attention: motelRoomData non trouvé pour %s-%s dans canInteract'):format(data.motel, roomIndex))
                                            return false
                                        end
                                        local hasRenterAccess = DoesPlayerHaveAccess(motelRoomData.players)
                                        local hasKeyAccess = DoesPlayerHaveKey(interactionData, motelRoomData)
                                        local isOwnerOrEmp = IsOwnerOrEmployee(data.motel)
                                        return hasRenterAccess or hasKeyAccess or isOwnerOrEmp
                                    end
                                    --[[ Optionnel: Icône/Label dynamique
                                    icon = function()
                                       local doorObj = GetClosestObjectOfType(interactionData.coord.x, interactionData.coord.y, interactionData.coord.z, 1.0, interactionData.door, false, false, false)
                                       return (doorObj ~= 0 and GetStateOfDoor(doorObj) == 1) and 'fas fa-lock' or 'fas fa-lock-open'
                                    end,
                                    label = function()
                                       local doorObj = GetClosestObjectOfType(interactionData.coord.x, interactionData.coord.y, interactionData.coord.z, 1.0, interactionData.door, false, false, false)
                                       return (doorObj ~= 0 and GetStateOfDoor(doorObj) == 1) and 'Déverrouiller' or 'Verrouiller'
                                    end,
                                    --]]
                                }
                                -- ... (Option Lockpick si besoin) ...
                            },
                            distance = 2.0
                        })
                        currentZoneTargets[targetName] = true
                    else
                        -- Logique pour les markers si config.target = false
                        -- DrawMarker(...)
                        -- Check distance and key press
                        -- Check access before calling RoomFunction(interactionData)
                    end

                    -- Verrouillage initial de la porte MLO
                    if data.Mlo and doorData.model then
                         Citizen.CreateThread(function()
                            Wait(150) -- Augmente légèrement l'attente
                            local doorObj = GetClosestObjectOfType(doorData.coord.x, doorData.coord.y, doorData.coord.z, 1.0, doorData.model, false, false, false)
                            if doorObj ~= 0 then
                                local initialState = currentMloRoomDoorStates[data.motel] and currentMloRoomDoorStates[data.motel][roomIndex] and currentMloRoomDoorStates[data.motel][roomIndex][doorSubIndex]
                                if initialState == nil then
                                    SetStateOfDoor(doorObj, 1, false, true) -- 1 = locked
                                    if not currentMloRoomDoorStates[data.motel] then currentMloRoomDoorStates[data.motel] = {} end
                                    if not currentMloRoomDoorStates[data.motel][roomIndex] then currentMloRoomDoorStates[data.motel][roomIndex] = {} end
                                    currentMloRoomDoorStates[data.motel][roomIndex][doorSubIndex] = 1
                                    -- print(('[renzu_motels] Verrouillage initial porte MLO %s-%s-%s'):format(data.motel, roomIndex, doorSubIndex))
                                else
                                    if GetStateOfDoor(doorObj) ~= initialState then
                                        SetStateOfDoor(doorObj, initialState, false, true)
                                        -- print(('[renzu_motels] État restauré %s pour porte MLO %s-%s-%s'):format(initialState, data.motel, roomIndex, doorSubIndex))
                                    end
                                end
                            else
                                -- print(('[renzu_motels] Attention: Objet porte non trouvé pour verrouillage initial %s-%s-%s'):format(data.motel, roomIndex, doorSubIndex))
                            end
                        end)
                    end
                    ::door_continue::
                end
            else -- Autres fonctions (stash, wardrobe, fridge, etc.)
                 if type(interactionInfo) ~= 'vector3' then goto interaction_continue end -- Doit être vec3 pour les autres

                 local targetName = ('motel_room_func:%s:%s:%s'):format(data.motel, roomIndex, interactionType)
                 local interactionData = {
                     payment = data.payment or 'money',
                     uniquestash = data.uniquestash,
                     shell = data.shell,
                     Mlo = data.Mlo,
                     type = interactionType,
                     index = roomIndex,
                     coord = interactionInfo,
                     label = config.Text[interactionType] or interactionType:gsub("^%l", string.upper),
                     motel = data.motel,
                     door = data.door -- Modèle porte principale chambre (peu utile ici)
                 }
                  if config.target then
                     if not exports.ox_target then print("[renzu_motels] Erreur: ox_target non démarré.") goto interaction_continue end
                     exports.ox_target:addSphereZone({
                         coords = interactionData.coord,
                         radius = 1.5,
                         debug = false,
                         options = {
                             {
                                 name = targetName,
                                 icon = config.icons[interactionType] or 'fas fa-question-circle',
                                 label = interactionData.label,
                                 onSelect = function() RoomFunction(interactionData) end,
                                 canInteract = function()
                                     if isRentExpired({ motel = data.motel, index = roomIndex }) then
                                         return false
                                     end
                                     local motelRoomData = GlobalState.Motels[data.motel]?.rooms[roomIndex]
                                     -- Seul le locataire de CETTE chambre peut accéder stash/wardrobe/etc.
                                     if not (motelRoomData and DoesPlayerHaveAccess(motelRoomData.players)) then
                                         return false
                                     end
                                     return true
                                 end
                             }
                         },
                         distance = 2.0
                     })
                     currentZoneTargets[targetName] = true
                 else
                     -- Logique pour markers si config.target = false
                 end
            end
            ::interaction_continue::
        end
        ::room_continue::
    end

    -- Crée le point de location
    return MotelRentalPoints(data)
end

-- Fonction pour supprimer les interactions (appelée dans onExit)
RemoveMotelInteractions = function()
    if not currentZoneData then return end

    if config.target and exports.ox_target then
        for targetName, _ in pairs(currentZoneTargets) do
            exports.ox_target:removeZone(targetName)
        end
    else
        -- Supprimer markers/zones créés si config.target = false
    end
    currentZoneTargets = {} -- Vide la table

    currentZoneData = nil -- Réinitialise les données de la zone
end

-- Gestion des zones de motel
MotelZone = function(data)
	local point = nil -- Référence pour le point de location

    function onEnter(zone)
        if inMotelZone then return end
		inMotelZone = true
        -- print(('[renzu_motels] Entré dans la zone du motel: %s'):format(data.label))
        point = CreateMotelInteractions(data)
	end

    function onExit(zone)
        if not inMotelZone then return end
		inMotelZone = false
        -- print(('[renzu_motels] Sorti de la zone du motel: %s'):format(data.label))
        if point then point:remove() point = nil end
        RemoveMotelInteractions()
	end

    if not lib or not lib.zones then return print("[renzu_motels] Erreur: ox_lib zones non disponible.") end
    lib.zones.sphere({
        coords = data.coord,
        radius = data.radius,
        debug = false,
        onEnter = onEnter,
        onExit = onExit,
        data = data
    })
end

-- Fonctions qb-interior (Shells)
local house
local inhouse = false
function Teleport(x, y, z, h ,exit)
    CreateThread(function()
        DoScreenFadeOut(500)
        while not IsScreenFadedOut() do Wait(10) end
        SetEntityCoords(cache.ped, x, y, z, 0, 0, 0, false)
        SetEntityHeading(cache.ped, h or 0.0)
        Wait(500) -- Attente après téléportation
        DoScreenFadeIn(1000)
    end)
	if exit then
		inhouse = false
		TriggerEvent('qb-weathersync:client:EnableSync') -- Adapte si tu n'utilises pas qb-weathersync
		for k,id in pairs(shelzones) do
			-- removeTargetZone(id) -- Assure-toi que cette fonction existe si tu utilises des zones spécifiques aux shells
		end
        if house and DoesEntityExist(house) then DeleteEntity(house) house = nil end
		-- lib.callback.await('renzu_motels:SetRouting',false,data,'exit') -- Commenté car SetRouting n'est pas défini dans le serveur fourni
		shelzones = {}
		DeleteResourceKvp(kvpname)
        -- Vérifie si LocalPlayer.state existe avant de l'utiliser
		if LocalPlayer and LocalPlayer.state then LocalPlayer.state:set('inshell',false,true) end
	end
end

-- Fonction pour entrer dans un shell (simplifiée)
EnterShell = function(data,login)
    if not config or not config.shells or not config.shells[data.shell or data.motel] then
        Notify("Configuration de shell manquante pour ce motel.", "error")
        return
    end
	local motels = GlobalState.Motels
    -- Vérifie si la chambre non-MLO est verrouillée logiquement
	if not data.Mlo and motels[data.motel]?.rooms[data.index]?.lock and not login then
		Notify('Porte verrouillée', 'error')
		return false
	end

	local shelldata = config.shells[data.shell or data.motel]
	-- lib.callback.await('renzu_motels:SetRouting',false,data,'enter') -- Commenté
	inhouse = true
	Wait(1000)
	local spawn = vec3(data.coord.x,data.coord.y,data.coord.z)+vec3(0.0,0.0,1500.0) -- Position haute pour le shell
    local offsets = shelldata.offsets
	local model = shelldata.shell

	DoScreenFadeOut(500)
    while not IsScreenFadedOut() do Wait(10) end

	TriggerEvent('qb-weathersync:client:DisableSync') -- Adapte si besoin
	RequestModel(model)
	while not HasModelLoaded(model) do Wait(100) end -- Réduit l'attente

	local lastloc = GetEntityCoords(cache.ped)
	house = CreateObject(model, spawn.x, spawn.y, spawn.z, false, false, false)
    FreezeEntityPosition(house, true)

    -- Sauvegarde la dernière position (vérifie si LocalPlayer.state existe)
    if LocalPlayer and LocalPlayer.state then LocalPlayer.state:set('lastloc', data.lastloc or lastloc, false) end
	data.lastloc = data.lastloc or lastloc

	if not login then SendNUIMessage({ type = 'door' }) end -- Joue le son d'entrée

	Teleport(spawn.x + offsets.exit.x, spawn.y + offsets.exit.y, spawn.z + offsets.exit.z + 0.1, offsets.exit.h) -- Ajoute offset Z
	SetResourceKvp(kvpname,json.encode(data)) -- Sauvegarde les données pour re-login

	Citizen.CreateThreadNow(function()
		-- ShellTargets(data,offsets,spawn,house) -- Assure-toi que cette fonction est définie si tu as des cibles DANS le shell
		while inhouse do
			SetWeatherTypePersist('CLEAR') -- Force le beau temps dans le shell
			SetWeatherTypeNow('CLEAR')
			NetworkOverrideClockTime(18, 0, 0) -- Force l'heure (optionnel)
			Wait(60000) -- Vérifie toutes les minutes
		end
	end)
    return house
end

-- Fonctions Raycast (inchangées)
function RotationToDirection(rotation)
	local adjustedRotation = { x = (math.pi / 180) * rotation.x, y = (math.pi / 180) * rotation.y, z = (math.pi / 180) * rotation.z }
	local direction = { x = -math.sin(adjustedRotation.z) * math.abs(math.cos(adjustedRotation.x)), y = math.cos(adjustedRotation.z) * math.abs(math.cos(adjustedRotation.x)), z = math.sin(adjustedRotation.x) }
	return direction
end

function RayCastGamePlayCamera(distance,flag)
    local cameraRotation = GetGameplayCamRot()
    local cameraCoord = GetGameplayCamCoord()
	local direction = RotationToDirection(cameraRotation)
	local destination = vector3(cameraCoord.x + direction.x * distance, cameraCoord.y + direction.y * distance, cameraCoord.z + direction.z * distance )
    if not flag then flag = -1 end -- Utilise -1 pour ignorer le joueur par défaut
	local rayHandle = StartShapeTestRay(cameraCoord.x, cameraCoord.y, cameraCoord.z, destination.x, destination.y, destination.z, flag, cache.ped, 7) -- Ignore le ped actuel
    local _, hit, endCoords, surfaceNormal, entityHit = GetShapeTestResult(rayHandle)
	return hit, endCoords, entityHit
end

-- Gestion de l'effraction par tir (Break-in)
local lastweapon = nil
lib.onCache('weapon', function(weapon)
	if not inMotelZone then return end -- Ne s'active que dans la zone d'un motel
	if not PlayerData or not PlayerData.job or not config.breakinJobs or not config.breakinJobs[PlayerData.job.name] then return end -- Vérifie job et config

	lastweapon = weapon
    while weapon and weapon == lastweapon do
		Wait(100) -- Vérifie moins souvent
		if IsPedShooting(cache.ped) then
			local hit, bulletCoords, entityHit = RayCastGamePlayCamera(50.0, 10) -- Raycast plus court, flag 10? (à vérifier)
			if hit then
                -- Itère sur les motels DANS LA ZONE ACTUELLE (plus optimisé)
                if currentZoneData and currentZoneData.doors then
                    local data = currentZoneData -- Utilise les données de la zone actuelle
                    for roomIndex, roomContent in pairs(data.doors) do
                        if roomContent.door then
                            for doorSubIndex, doorData in pairs(roomContent.door) do
                                -- Vérifie si la balle est proche de la porte ET si la chambre est verrouillée
                                if #(bulletCoords - doorData.coord) < 1.5 then
                                    local isLocked = false
                                    if data.Mlo then
                                        local doorObj = GetClosestObjectOfType(doorData.coord.x, doorData.coord.y, doorData.coord.z, 1.0, doorData.model, false, false, false)
                                        isLocked = (doorObj ~= 0 and GetStateOfDoor(doorObj) == 1)
                                    else
                                        isLocked = GlobalState.Motels[data.motel]?.rooms[roomIndex]?.lock
                                    end

                                    if isLocked then
                                        Notify('Vous avez tiré sur la serrure !', 'warning')
                                        Wait(500) -- Délai avant déverrouillage
                                        -- Appelle la fonction Door pour déverrouiller (simule une interaction réussie)
                                        Door({
                                            motel = data.motel,
                                            index = roomIndex,
                                            doorindex = doorSubIndex,
                                            coord = doorData.coord,
                                            Mlo = data.Mlo,
                                            door = doorData.model
                                        })
                                        lastweapon = nil -- Arrête la boucle pour cette arme
                                        goto breakin_end_loops -- Sort des boucles internes
                                    end
                                end
                            end
                        end
                    end
                end
			end
		end
	end
    ::breakin_end_loops::
end)

-- Réception message propriétaire (inchangé)
RegisterNetEvent('renzu_motels:MessageOwner', function(data)
    -- Utilise la notification ox_lib si disponible
    if lib and lib.notify then
        lib.notify({
            title = data.title or ('Message de %s'):format(data.motel),
            description = data.message,
            type = 'inform',
            icon = 'envelope' -- Icône pour message
        })
    else -- Fallback vers l'ancienne méthode si ox_lib non dispo
	    AddTextEntry('renzuMotelMsg', data.message)
        BeginTextCommandThefeedPost('renzuMotelMsg')
	    ThefeedSetNextPostBackgroundColor(1)
	    -- AddTextComponentSubstringPlayerName(data.message) -- Redondant si déjà dans AddTextEntry
        EndTextCommandThefeedPostMessagetext('CHAR_FACEBOOK', 'CHAR_FACEBOOK', false, 4, data.motel, data.title)
        EndTextCommandThefeedPostTicker(false, true)
    end
end)

-- Initialisation Client
Citizen.CreateThread(function()
    -- Attend ox_lib (si utilisé)
    while not lib do Wait(100) end
    -- Attend le chargement du joueur via le framework
    local playerLoaded = false
    if GetResourceState('es_extended') == 'started' then
        ESX = exports['es_extended']:getSharedObject()
        while not ESX.IsPlayerLoaded() do Wait(500) end
        PlayerData = ESX.GetPlayerData()
        playerLoaded = true
        RegisterNetEvent('esx:playerLoaded', function(xPlayer) PlayerData = xPlayer; playerLoaded = true end)
        RegisterNetEvent('esx:setJob', function(job) if PlayerData then PlayerData.job = job end end)
    elseif GetResourceState('qb-core') == 'started' then
        QBCORE = exports['qb-core']:GetCoreObject()
        while QBCORE == nil do Wait(100) end -- Attend que QBCORE soit chargé
        PlayerData = QBCORE.Functions.GetPlayerData()
        while PlayerData == nil or PlayerData.citizenid == nil do -- Attend que les données soient valides
             PlayerData = QBCORE.Functions.GetPlayerData()
             Wait(500)
        end
        playerLoaded = true
        RegisterNetEvent('QBCore:Client:OnPlayerLoaded', function() PlayerData = QBCORE.Functions.GetPlayerData(); playerLoaded = true end)
        RegisterNetEvent('QBCore:Client:OnJobUpdate', function(job) if PlayerData then PlayerData.job = job end end)
        RegisterNetEvent('QBCore:Player:SetPlayerData', function(val) PlayerData = val end)
    else
        -- Framework non détecté, utilise un placeholder (peut nécessiter une adaptation)
        print("[renzu_motels] Attention: ESX ou QB-Core non détecté. PlayerData pourrait être incomplet.")
        PlayerData = { identifier = 'steam:placeholder', job = { name = 'unemployed' } } -- Placeholder
        playerLoaded = true -- Suppose chargé pour continuer
    end

    -- Attend que PlayerData soit effectivement chargé
    while not playerLoaded do Wait(500) end
    cache.ped = PlayerPedId() -- Définit le ped après chargement
    print('[renzu_motels] PlayerData chargé.')

    -- Attend que GlobalState.Motels soit initialisé (reçu du serveur)
	while GlobalState.Motels == nil do Wait(500) end
    print('[renzu_motels] GlobalState.Motels reçu.')

    -- Crée les zones pour chaque motel défini dans la config
    if config and config.motels then
        for _, motelData in pairs(config.motels) do
            MotelZone(motelData)
        end
    else
        print("[renzu_motels] Erreur: config.motels non trouvé pendant l'initialisation.")
    end
    -- Crée les blips globaux
	CreateBlips()

    print('[renzu_motels] Initialisation client terminée.')
end)

-- Assure que LocalPlayer.state existe si utilisé (dépend de ton core/framework)
-- Exemple:
-- if LocalPlayer == nil then LocalPlayer = {} end
-- if LocalPlayer.state == nil then LocalPlayer.state = {} end
-- LocalPlayer.state.set = function(key, value, replicated)
--     -- Implémente la logique de state bag si nécessaire
--     LocalPlayer.state[key] = value
-- end
