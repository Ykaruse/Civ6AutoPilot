-- ===========================================================================
-- Civ6 Auto Pilot - gameplay-side safety net for repeatable Future Tech/Civic.
--
-- The UI script can request a repeatable future tech/civic through
-- UI.RequestPlayerOperation.  When a repeatable item has just completed, the
-- engine may still report that same item as "progressing" while the player is
-- asked to choose again.  In that state a same-item request is a no-op.
--
-- This gameplay-side script directly restarts the loop.  Adding one point of
-- progress starts a fresh iteration and dismisses the chooser state.  The
-- amount is negligible (1 science/culture per completed future iteration).
-- ===========================================================================

local FUTURE_TECH_TYPE  = "TECH_FUTURE_TECH";
local FUTURE_CIVIC_TYPE = "CIVIC_FUTURE_CIVIC";
local LOG_PREFIX        = "[AutoPilotGP] ";

local function Log(message)
	print(LOG_PREFIX .. tostring(message));
end

local function AllNonRepeatableTechsResearched(playerTechs)
	for row in GameInfo.Technologies() do
		if not row.Repeatable and not playerTechs:HasTech(row.Index) then
			return false;
		end
	end
	return true;
end

local function AllNonRepeatableCivicsResearched(playerCulture)
	for row in GameInfo.Civics() do
		if not row.Repeatable and not playerCulture:HasCivic(row.Index) then
			return false;
		end
	end
	return true;
end

local function EnsureFutureTech(playerID, addProgress)
	local player = Players[playerID];
	if player == nil or not player:IsAlive() or not player:IsHuman() then
		return;
	end
	local playerTechs = player:GetTechs();
	local futureTech = GameInfo.Technologies[FUTURE_TECH_TYPE];
	if playerTechs == nil or futureTech == nil then
		return;
	end
	if not AllNonRepeatableTechsResearched(playerTechs) then
		return;
	end

	local current = playerTechs:GetResearchingTech();
	if current ~= futureTech.Index then
		playerTechs:SetResearchingTech(futureTech.Index);
		addProgress = true;
	end
	if addProgress then
		playerTechs:ChangeCurrentResearchProgress(1);
		Log("Restarted Future Tech for player " .. tostring(playerID));
	end
end

local function EnsureFutureCivic(playerID, addProgress)
	local player = Players[playerID];
	if player == nil or not player:IsAlive() or not player:IsHuman() then
		return;
	end
	local playerCulture = player:GetCulture();
	local futureCivic = GameInfo.Civics[FUTURE_CIVIC_TYPE];
	if playerCulture == nil or futureCivic == nil then
		return;
	end
	if not AllNonRepeatableCivicsResearched(playerCulture) then
		return;
	end

	local current = playerCulture:GetProgressingCivic();
	if current ~= futureCivic.Index then
		playerCulture:SetProgressingCivic(futureCivic.Index);
		addProgress = true;
	end
	if addProgress then
		playerCulture:ChangeCurrentCulturalProgress(1);
		Log("Restarted Future Civic for player " .. tostring(playerID));
	end
end

local function OnResearchCompleted(playerID, techID, isCanceled)
	if isCanceled then
		return;
	end
	EnsureFutureTech(playerID, true);
end

local function OnCivicCompleted(playerID, civicID, isCanceled)
	if isCanceled then
		return;
	end
	EnsureFutureCivic(playerID, true);
end

local function OnGameTurnStarted(turn)
	for _, playerID in ipairs(PlayerManager.GetAliveIDs()) do
		local player = Players[playerID];
		if player ~= nil and player:IsAlive() and player:IsHuman() then
			local playerTechs = player:GetTechs();
			if playerTechs ~= nil then
				local futureTech = GameInfo.Technologies[FUTURE_TECH_TYPE];
				if futureTech ~= nil and AllNonRepeatableTechsResearched(playerTechs) then
					local current = playerTechs:GetResearchingTech();
					local progress = 0;
					if current ~= nil then
						local ok, value = pcall(function()
							return playerTechs:GetResearchProgress(current);
						end);
						if ok and value ~= nil then
							progress = value;
						end
					end
					EnsureFutureTech(playerID, current ~= futureTech.Index or progress <= 0);
				end
			end

			local playerCulture = player:GetCulture();
			if playerCulture ~= nil then
				local futureCivic = GameInfo.Civics[FUTURE_CIVIC_TYPE];
				if futureCivic ~= nil and AllNonRepeatableCivicsResearched(playerCulture) then
					local current = playerCulture:GetProgressingCivic();
					local turnsLeft = 0;
					if current ~= nil then
						local ok, value = pcall(function()
							return playerCulture:GetTurnsLeftOnCurrentCivic();
						end);
						if ok and value ~= nil then
							turnsLeft = value;
						end
					end
					EnsureFutureCivic(playerID, current ~= futureCivic.Index or turnsLeft <= 0);
				end
			end
		end
	end
end

Events.ResearchCompleted.Add(OnResearchCompleted);
Events.CivicCompleted.Add(OnCivicCompleted);
GameEvents.OnGameTurnStarted.Add(OnGameTurnStarted);

Log("loaded");
