-- ===========================================================================
-- Civ6 Auto Pilot
-- Auto city production and Future Tech / Future Civic looping.
--
-- All game actions are issued from the InGame UI context.  The city AI's own
-- recommendation APIs are used so the mod follows the game's evaluation of
-- what each city needs instead of using a hard-coded build order.
-- ===========================================================================

local RELOAD_CACHE_ID        = "Civ6AutoPilot";
local SETTINGS_CONFIG_KEY    = "Civ6AutoPilot_Settings_v2";
local LOG_PREFIX             = "[AutoPilot] ";
local DEBUG                  = false;

local m_settings = {
	-- City production is intentionally off by default for now.
	production = false,
	future     = true,
	autoPlace  = false,
};

local m_stats = {
	production  = 0,
	futureTech  = 0,
	futureCivic = 0,
	repair      = 0,
};

local m_running       = false;
local m_uiReady       = false;
local m_launchButton  = nil;

-- ===========================================================================
-- Small utilities
-- ===========================================================================

local function Log(message)
	if DEBUG then
		print(LOG_PREFIX .. tostring(message));
	end
end

local function LogError(message)
	print(LOG_PREFIX .. "ERROR: " .. tostring(message));
end

local function SafeCall(fn, ...)
	local ok, a, b = pcall(fn, ...);
	if ok then
		return a, b;
	end
	return nil, nil;
end

local function GetLocalPlayerID()
	local ok, playerID = pcall(function()
		return Game.GetLocalPlayer();
	end);
	if ok and playerID ~= nil and playerID >= 0 then
		return playerID;
	end
	return nil;
end

local function SettingsToString()
	return (m_settings.production and "1" or "0") .. "," ..
	       (m_settings.future and "1" or "0") .. "," ..
	       (m_settings.autoPlace and "1" or "0");
end

local function LoadSettings()
	local playerID = GetLocalPlayerID();
	if playerID == nil or PlayerConfigurations == nil then
		return;
	end
	local config = PlayerConfigurations[playerID];
	if config == nil then
		return;
	end
	local value = SafeCall(function()
		return config:GetValue(SETTINGS_CONFIG_KEY);
	end);
	if type(value) ~= "string" then
		return;
	end
	-- Two-value (older) or three-value settings; autoPlace defaults off.
	local a, b, c = value:match("^(%d),(%d),(%d)");
	if a == nil then
		a, b = value:match("^(%d),(%d)");
	end
	if a ~= nil then
		m_settings.production = (a == "1");
		m_settings.future     = (b == "1");
		m_settings.autoPlace  = (c == "1");
	end
end

local function SaveSettings()
	local playerID = GetLocalPlayerID();
	if playerID == nil or PlayerConfigurations == nil then
		return;
	end
	local config = PlayerConfigurations[playerID];
	if config == nil then
		return;
	end
	SafeCall(function()
		config:SetValue(SETTINGS_CONFIG_KEY, SettingsToString());
	end);
end

-- ===========================================================================
-- UI
-- ===========================================================================

local function UpdateStatus()
	if not m_uiReady or Controls == nil or Controls.StatusLabel == nil then
		return;
	end
	Controls.StatusLabel:SetText(Locale.Lookup("LOC_AUTOPILOT_STATUS",
		m_stats.production,
		m_stats.futureTech,
		m_stats.futureCivic,
		m_stats.repair));
end

local function SyncCheckboxes()
	if not m_uiReady or Controls == nil then
		return;
	end
	Controls.ProductionCheck:SetCheck(m_settings.production);
	Controls.FutureCheck:SetCheck(m_settings.future);
	Controls.AutoPlaceCheck:SetCheck(m_settings.autoPlace);
end

local function OpenPanel()
	Controls.Root:SetHide(false);
	Controls.OpenButton:SetHide(true);
	SyncCheckboxes();
	UpdateStatus();
end

local function ClosePanel()
	Controls.Root:SetHide(true);
	if m_launchButton == nil then
		Controls.OpenButton:SetHide(false);
	end
end

local function AttachLaunchBarButton()
	local buttonStack = ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack");
	if buttonStack == nil then
		return false;
	end

	-- Prefer the existing gear slot used by the old AutoBuilder mod.  Reusing
	-- that real button gives us the exact arrowed position and a native hit box.
	local gearButton = nil;
	for _, child in ipairs(buttonStack:GetChildren()) do
		local tooltip = SafeCall(function()
			return child:GetToolTipString();
		end);
		if type(tooltip) == "string"
			and (string.find(tooltip, "建造者自动改良", 1, true) ~= nil
				or string.find(string.lower(tooltip), "autobuilder", 1, true) ~= nil) then
			gearButton = child;
			break
		end
	end

	if gearButton ~= nil then
		pcall(function()
			gearButton:ClearCallback(Mouse.eLClick);
		end);
		local clickOK = pcall(function()
			gearButton:RegisterCallback(Mouse.eLClick, OpenPanel);
		end);
		if not clickOK then
			return false;
		end
		pcall(function()
			gearButton:RegisterCallback(Mouse.eMouseEnter, function()
				UI.PlaySound("Main_Menu_Mouse_Over");
			end);
			gearButton:SetToolTipString(Locale.Lookup("LOC_AUTOPILOT_OPEN_TT"));
		end);
		local textControl = SafeCall(function()
			return gearButton:GetTextControl();
		end);
		if textControl ~= nil then
			pcall(function()
				textControl:SetText(Locale.Lookup("LOC_AUTOPILOT_LAUNCH"));
				textControl:SetColor(240, 218, 168, 255);
			end);
		end
		m_launchButton = { LaunchButton = gearButton };
		return true;
	end

	-- No AutoBuilder gear: append a normal launch-bar button.
	local instance = {};
	local ok = pcall(function()
		ContextPtr:BuildInstanceForControl("AutoPilotLaunchButton", instance, buttonStack);
	end);
	if not ok or instance.LaunchButton == nil then
		return false;
	end

	instance.LaunchButton:RegisterCallback(Mouse.eLClick, OpenPanel);
	instance.LaunchButton:RegisterCallback(Mouse.eMouseEnter, function()
		UI.PlaySound("Main_Menu_Mouse_Over");
	end);
	m_launchButton = instance;

	buttonStack:CalculateSize();
	local stackSizeX = buttonStack:GetSizeX();
	local backing = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBacking");
	if backing ~= nil then
		backing:SetSizeX(stackSizeX + 116);
	end
	local backingTile = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBackingTile");
	if backingTile ~= nil then
		backingTile:SetSizeX(math.max(20, stackSizeX - 20));
	end
	LuaEvents.LaunchBar_Resize(stackSizeX);
	return true;
end

local function EnsureLaunchBarButton()
	if m_launchButton ~= nil or Controls == nil or Controls.OpenButton == nil then
		return;
	end
	if AttachLaunchBarButton() then
		Controls.OpenButton:SetHide(true);
	end
end

local function OnToggleProduction()
	m_settings.production = Controls.ProductionCheck:IsChecked();
	SaveSettings();
end

local function OnToggleFuture()
	m_settings.future = Controls.FutureCheck:IsChecked();
	SaveSettings();
end

local function OnToggleAutoPlace()
	m_settings.autoPlace = Controls.AutoPlaceCheck:IsChecked();
	SaveSettings();
end

local function OnInputHandler(inputStruct)
	if inputStruct == nil then
		return false;
	end
	local messageType = inputStruct:GetMessageType();
	if messageType == KeyEvents.KeyUp then
		if inputStruct:GetKey() == Keys.VK_ESCAPE and not Controls.Root:IsHidden() then
			ClosePanel();
			return true;
		end
	end
	return false;
end

-- ===========================================================================
-- Future Tech / Future Civic
-- ===========================================================================

local function AllNonRepeatableTechsResearched(playerTechs)
	for row in GameInfo.Technologies() do
		if not row.Repeatable then
			local has = SafeCall(function()
				return playerTechs:HasTech(row.Index);
			end);
			if not has then
				return false;
			end
		end
	end
	return true;
end

local function AllNonRepeatableCivicsResearched(playerCulture)
	for row in GameInfo.Civics() do
		if not row.Repeatable then
			local has = SafeCall(function()
				return playerCulture:HasCivic(row.Index);
			end);
			if not has then
				return false;
			end
		end
	end
	return true;
end

local function TryFutureTech(playerID, force)
	local player = Players[playerID];
	if player == nil then
		return false;
	end
	local playerTechs = player:GetTechs();
	if playerTechs == nil then
		return false;
	end

	local futureTech = GameInfo.Technologies["TECH_FUTURE_TECH"];
	if futureTech == nil then
		return false;
	end

	-- Only skip when Future Tech is already the active research.  At the
	-- instant a tech completes the old tech may still be reported here, so a
	-- stricter "must be idle" check would leave the player on the chooser.
	local current = SafeCall(function()
		return playerTechs:GetResearchingTech();
	end);
	if current == futureTech.Index and not force then
		local progress = SafeCall(function()
			return playerTechs:GetResearchProgress(current);
		end);
		if progress ~= nil and progress > 0 then
			return false;
		end
	end

	if not AllNonRepeatableTechsResearched(playerTechs) then
		return false;
	end

	local canResearch = SafeCall(function()
		return playerTechs:CanResearch(futureTech.Index);
	end);
	if not canResearch then
		return false;
	end

	local params = {};
	params[PlayerOperations.PARAM_TECH_TYPE] = futureTech.Hash;
	params[PlayerOperations.PARAM_INSERT_MODE] = PlayerOperations.VALUE_EXCLUSIVE;
	local ok = pcall(function()
		UI.RequestPlayerOperation(playerID, PlayerOperations.RESEARCH, params);
	end);
	if ok then
		m_stats.futureTech = m_stats.futureTech + 1;
		Log("Selected Future Tech.");
		return true;
	end
	return false;
end

local function TryFutureCivic(playerID, force)
	local player = Players[playerID];
	if player == nil then
		return false;
	end
	local playerCulture = player:GetCulture();
	if playerCulture == nil then
		return false;
	end

	local futureCivic = GameInfo.Civics["CIVIC_FUTURE_CIVIC"];
	if futureCivic == nil then
		return false;
	end

	-- Same timing guard as Future Tech: do not require the previous civic to
	-- be fully cleared before selecting its replacement.
	local current = SafeCall(function()
		return playerCulture:GetProgressingCivic();
	end);
	if current == futureCivic.Index and not force then
		local progress = SafeCall(function()
			return playerCulture:GetCulturalProgress(current);
		end);
		if progress ~= nil and progress > 0 then
			return false;
		end
	end

	if not AllNonRepeatableCivicsResearched(playerCulture) then
		return false;
	end

	local params = {};
	params[PlayerOperations.PARAM_CIVIC_TYPE] = futureCivic.Hash;
	params[PlayerOperations.PARAM_INSERT_MODE] = PlayerOperations.VALUE_EXCLUSIVE;
	local ok = pcall(function()
		UI.RequestPlayerOperation(playerID, PlayerOperations.PROGRESS_CIVIC, params);
	end);
	if ok then
		m_stats.futureCivic = m_stats.futureCivic + 1;
		Log("Selected Future Civic.");
		return true;
	end
	return false;
end

-- ===========================================================================
-- City production helpers
-- ===========================================================================

local function MakeBuildParams()
	local params = {};
	params[CityOperationTypes.PARAM_INSERT_MODE] = CityOperationTypes.VALUE_REPLACE_AT;
	params[CityOperationTypes.PARAM_QUEUE_DESTINATION_LOCATION] = 0;
	return params;
end

local function RequestCityBuild(city, params)
	local canStart = SafeCall(function()
		return CityManager.CanStartOperation(city, CityOperationTypes.BUILD, params, true);
	end);
	if not canStart then
		canStart = SafeCall(function()
			return CityManager.CanStartOperation(city, CityOperationTypes.BUILD, params);
		end);
	end
	if not canStart then
		return false;
	end

	local ok = pcall(function()
		CityManager.RequestOperation(city, CityOperationTypes.BUILD, params);
	end);
	return ok;
end

local function GetOperationPlots(city, params)
	local results = SafeCall(function()
		return CityManager.GetOperationTargets(city, CityOperationTypes.BUILD, params);
	end);
	if results == nil then
		return nil;
	end
	local plots = nil;
	if CityOperationResults ~= nil and CityOperationResults.PLOTS ~= nil then
		plots = results[CityOperationResults.PLOTS];
	end
	if plots == nil then
		plots = results.PLOTS;
	end
	return plots;
end

local function PlotFromEntry(entry)
	if entry == nil then
		return nil;
	end
	if type(entry) == "number" then
		return Map.GetPlotByIndex(entry);
	end
	if type(entry) == "table" and entry.GetX ~= nil then
		return entry;
	end
	return nil;
end

local function ChooseBestDistrictPlot(city, plots, districtHash)
	local playerID = GetLocalPlayerID();
	local bestPlot = nil;
	local bestScore = -math.huge;

	for i = 1, #plots do
		local plot = PlotFromEntry(plots[i]);
		if plot ~= nil then
			local score = 0;
			local ok = pcall(function()
				for yield in GameInfo.Yields() do
					local value = plot:GetAdjacencyYield(playerID, city:GetID(), districtHash, yield.Index);
					if value ~= nil then
						score = score + value;
					end
				end
				local appeal = plot:GetAppeal();
				if appeal ~= nil then
					score = score + appeal * 0.05;
				end
			end);
			if not ok then
				score = 0;
			end
			if bestPlot == nil or score > bestScore then
				bestPlot = plot;
				bestScore = score;
			end
		end
	end

	if bestPlot == nil and #plots > 0 then
		bestPlot = PlotFromEntry(plots[1]);
	end
	return bestPlot;
end

local function ChooseFirstPlot(plots)
	for i = 1, #plots do
		local plot = PlotFromEntry(plots[i]);
		if plot ~= nil then
			return plot;
		end
	end
	return nil;
end

local function AddPlacement(params, city, buildHash, isDistrict)
	local query = {};
	if isDistrict then
		query[CityOperationTypes.PARAM_DISTRICT_TYPE] = buildHash;
	else
		query[CityOperationTypes.PARAM_BUILDING_TYPE] = buildHash;
	end
	local plots = GetOperationPlots(city, query);
	if plots == nil or #plots == 0 then
		return false;
	end

	local plot = nil;
	if isDistrict then
		plot = ChooseBestDistrictPlot(city, plots, buildHash);
	else
		plot = ChooseFirstPlot(plots);
	end
	if plot == nil then
		return false;
	end

	params[CityOperationTypes.PARAM_X] = plot:GetX();
	params[CityOperationTypes.PARAM_Y] = plot:GetY();
	return true;
end

local function TryRepairCity(city)
	local buildQueue = city:GetBuildQueue();
	if buildQueue == nil then
		return false;
	end

	-- Pillaged districts first: they are usually the largest loss of yields.
	local districtCollection = city:GetDistricts();
	if districtCollection ~= nil then
		for _, district in districtCollection:Members() do
			local districtInfo = GameInfo.Districts[district:GetType()];
			if districtInfo ~= nil
				and districtInfo.DistrictType ~= "DISTRICT_NEIGHBORHOOD"
				and district:GetX() ~= nil and district:GetY() ~= nil then
				local plot = Map.GetPlot(district:GetX(), district:GetY());
				local pillaged = false;
				if plot ~= nil then
					pillaged = SafeCall(function()
						return districtCollection:IsPillaged(districtInfo.Index, plot);
					end);
					if pillaged == nil then
						pillaged = SafeCall(function()
							return districtCollection:IsPillaged(district:GetType(), plot);
						end);
					end
					if pillaged == nil then
						pillaged = SafeCall(function()
							return district:IsPillaged();
						end);
					end
				end
				if pillaged then
					local canProduce = SafeCall(function()
						return buildQueue:CanProduce(districtInfo.Hash, true);
					end);
					if canProduce then
						local params = MakeBuildParams();
						params[CityOperationTypes.PARAM_DISTRICT_TYPE] = districtInfo.Hash;
						if RequestCityBuild(city, params) then
							m_stats.repair = m_stats.repair + 1;
							Log("Repairing district " .. tostring(districtInfo.DistrictType));
							return true;
						end
					end
				end
			end
		end
	end

	-- Then pillaged buildings.
	local cityBuildings = city:GetBuildings();
	if cityBuildings ~= nil then
		for buildingInfo in GameInfo.Buildings() do
			local hasBuilding = SafeCall(function()
				return cityBuildings:HasBuilding(buildingInfo.Index);
			end);
			if hasBuilding then
				local pillaged = SafeCall(function()
					return cityBuildings:IsPillaged(buildingInfo.Hash);
				end);
				if pillaged == nil then
					pillaged = SafeCall(function()
						return cityBuildings:IsPillaged(buildingInfo.Index);
					end);
				end
				if pillaged == nil then
					pillaged = SafeCall(function()
						return cityBuildings:IsPillaged(buildingInfo.BuildingType);
					end);
				end
				if pillaged then
					local canProduce = SafeCall(function()
						return buildQueue:CanProduce(buildingInfo.Hash, true);
					end);
					if canProduce then
						local params = MakeBuildParams();
						params[CityOperationTypes.PARAM_BUILDING_TYPE] = buildingInfo.Hash;
						if RequestCityBuild(city, params) then
							m_stats.repair = m_stats.repair + 1;
							Log("Repairing building " .. tostring(buildingInfo.BuildingType));
							return true;
						end
					end
				end
			end
		end
	end

	return false;
end

local function IsBuilderUnitInfo(unitInfo)
	if unitInfo == nil or unitInfo.FoundCity then
		return false;
	end
	local typeName = unitInfo.UnitType or unitInfo.Type;
	if type(typeName) ~= "string" then
		return false;
	end
	return typeName == "UNIT_BUILDER" or string.find(typeName, "BUILDER", 1, true) ~= nil;
end

local function GetBuildCategory(buildHash)
	local unitInfo = GameInfo.Units[buildHash];
	if unitInfo ~= nil then
		if IsBuilderUnitInfo(unitInfo) then
			return 3;
		end
		return nil;
	end

	local districtInfo = GameInfo.Districts[buildHash];
	if districtInfo ~= nil then
		if districtInfo.DistrictType == "DISTRICT_NEIGHBORHOOD" then
			return nil;
		end
		return 1;
	end

	local buildingInfo = GameInfo.Buildings[buildHash];
	if buildingInfo ~= nil then
		if buildingInfo.IsWonder then
			return 2;
		end
		return 1;
	end

	return nil;
end

local function IsPlacementRequired(buildHash, hasBeenPlaced)
	local districtInfo = GameInfo.Districts[buildHash];
	if districtInfo ~= nil then
		return districtInfo.RequiresPlacement and not hasBeenPlaced;
	end
	local buildingInfo = GameInfo.Buildings[buildHash];
	if buildingInfo ~= nil then
		return buildingInfo.RequiresPlacement and not hasBeenPlaced;
	end
	return false;
end

local function IsExcludedDistrict(districtInfo)
	return districtInfo ~= nil and districtInfo.DistrictType == "DISTRICT_NEIGHBORHOOD";
end

local function CityHasBuilder(city)
	local ownerID = city:GetOwner();
	local player = ownerID ~= nil and Players[ownerID] or nil;
	if player == nil then
		return false;
	end
	local units = SafeCall(function()
		return player:GetUnits();
	end);
	if units == nil then
		return false;
	end
	for _, unit in units:Members() do
		local unitInfo = GameInfo.Units[unit:GetType()];
		if IsBuilderUnitInfo(unitInfo) then
			if unit:GetX() == city:GetX() and unit:GetY() == city:GetY() then
				return true;
			end
			local unitCity = SafeCall(function()
				return Cities.GetCityInPlot(unit:GetX(), unit:GetY());
			end);
			if unitCity ~= nil and unitCity:GetID() == city:GetID() then
				return true;
			end
		end
	end
	return false;
end

local function HasNoPlacementBuildingOption(buildQueue)
	for row in GameInfo.Buildings() do
		if not row.RequiresPlacement then
			local canProduce = SafeCall(function()
				return buildQueue:CanProduce(row.Hash, true);
			end);
			if canProduce then
				return true;
			end
		end
	end
	return false;
end

local function HasLegalPlacement(city, buildHash, isDistrict)
	local query = {};
	if isDistrict then
		query[CityOperationTypes.PARAM_DISTRICT_TYPE] = buildHash;
	else
		query[CityOperationTypes.PARAM_BUILDING_TYPE] = buildHash;
	end
	local plots = GetOperationPlots(city, query);
	return plots ~= nil and type(plots) == "table" and #plots > 0;
end

local function HasPlacementRequiredOptionExceptCommunity(city, buildQueue)
	for row in GameInfo.Districts() do
		if row.RequiresPlacement and row.DistrictType ~= "DISTRICT_NEIGHBORHOOD" then
			local canProduce = SafeCall(function()
				return buildQueue:CanProduce(row.Hash, true);
			end);
			if canProduce then
				local placed = SafeCall(function()
					return buildQueue:HasBeenPlaced(row.Hash);
				end);
				if not placed and HasLegalPlacement(city, row.Hash, true) then
					return true;
				end
			end
		end
	end
	for row in GameInfo.Buildings() do
		if row.RequiresPlacement then
			local canProduce = SafeCall(function()
				return buildQueue:CanProduce(row.Hash, true);
			end);
			if canProduce then
				local placed = SafeCall(function()
					return buildQueue:HasBeenPlaced(row.Hash);
				end);
				if not placed and HasLegalPlacement(city, row.Hash, false) then
					return true;
				end
			end
		end
	end
	return false;
end

local function TryBuildHash(city, buildHash)
	local buildQueue = city:GetBuildQueue();
	if buildQueue == nil then
		return false;
	end

	local canProduce = SafeCall(function()
		return buildQueue:CanProduce(buildHash, true);
	end);
	if not canProduce then
		return false;
	end

	local params = MakeBuildParams();
	local unitInfo     = GameInfo.Units[buildHash];
	local buildingInfo = GameInfo.Buildings[buildHash];
	local districtInfo = GameInfo.Districts[buildHash];
	local projectInfo = GameInfo.Projects and GameInfo.Projects[buildHash] or nil;
	local hasBeenPlaced = SafeCall(function()
		return buildQueue:HasBeenPlaced(buildHash);
	end);

	if IsExcludedDistrict(districtInfo) then
		return false;
	end

	if not m_settings.autoPlace and IsPlacementRequired(buildHash, hasBeenPlaced) then
		return false;
	end

	if unitInfo ~= nil then
		-- Only Builders are allowed in the unit phase.
		if not IsBuilderUnitInfo(unitInfo) then
			return false;
		end
		-- If the city already has a Builder, do not produce another one.
		if CityHasBuilder(city) then
			return false;
		end
		-- With auto-placement OFF, prefer any no-placement building; only when
		-- none exists may a Builder be used as the fallback.
		if not m_settings.autoPlace then
			if HasNoPlacementBuildingOption(buildQueue) then
				return false;
			end
			if HasPlacementRequiredOptionExceptCommunity(city, buildQueue) then
				return false;
			end
		end
		params[CityOperationTypes.PARAM_UNIT_TYPE] = buildHash;
	elseif districtInfo ~= nil then
		params[CityOperationTypes.PARAM_DISTRICT_TYPE] = buildHash;
		if districtInfo.RequiresPlacement and not hasBeenPlaced then
			if not m_settings.autoPlace then
				return false;
			end
			if not AddPlacement(params, city, buildHash, true) then
				return false;
			end
		end
	elseif buildingInfo ~= nil then
		params[CityOperationTypes.PARAM_BUILDING_TYPE] = buildHash;
		if buildingInfo.RequiresPlacement and not hasBeenPlaced then
			if not m_settings.autoPlace then
				return false;
			end
			if not AddPlacement(params, city, buildHash, false) then
				return false;
			end
		end
	elseif projectInfo ~= nil then
		params[CityOperationTypes.PARAM_PROJECT_TYPE] = buildHash;
	else
		return false;
	end

	if RequestCityBuild(city, params) then
		m_stats.production = m_stats.production + 1;
		Log("City " .. tostring(city:GetName()) .. " selected " .. tostring(buildHash));
		return true;
	end
	return false;
end

local function GetTurnsLeft(buildQueue, hash)
	local turns = SafeCall(function()
		return buildQueue:GetTurnsLeft(hash);
	end);
	if turns == nil then
		return 9999;
	end
	return turns;
end

local function TryCampusProject(city)
	local project = nil;
	if GameInfo.Projects ~= nil then
		project = GameInfo.Projects["PROJECT_ENHANCE_DISTRICT_CAMPUS"];
		if project == nil then
			for row in GameInfo.Projects() do
				if row.ProjectType == "PROJECT_ENHANCE_DISTRICT_CAMPUS" then
					project = row;
					break
				end
			end
		end
	end
	if project == nil then
		return false;
	end
	return TryBuildHash(city, project.Hash);
end

local function TryCategoryFallback(city, category)
	local buildQueue = city:GetBuildQueue();
	if buildQueue == nil then
		return false;
	end

	local candidates = {};
	local seen = {};

	if category == 1 then
		for row in GameInfo.Districts() do
			if row.DistrictType ~= "DISTRICT_NEIGHBORHOOD" then
				local canProduce = SafeCall(function()
					return buildQueue:CanProduce(row.Hash, true);
				end);
				if canProduce and not seen[row.Hash] then
					seen[row.Hash] = true;
					candidates[#candidates + 1] = { hash = row.Hash, turns = GetTurnsLeft(buildQueue, row.Hash) };
				end
			end
		end
		for row in GameInfo.Buildings() do
			if not row.IsWonder then
				local canProduce = SafeCall(function()
					return buildQueue:CanProduce(row.Hash, true);
				end);
				if canProduce and not seen[row.Hash] then
					seen[row.Hash] = true;
					candidates[#candidates + 1] = { hash = row.Hash, turns = GetTurnsLeft(buildQueue, row.Hash) };
				end
			end
		end
	elseif category == 2 then
		for row in GameInfo.Buildings() do
			if row.IsWonder then
				local canProduce = SafeCall(function()
					return buildQueue:CanProduce(row.Hash, true);
				end);
				if canProduce and not seen[row.Hash] then
					seen[row.Hash] = true;
					candidates[#candidates + 1] = { hash = row.Hash, turns = GetTurnsLeft(buildQueue, row.Hash) };
				end
			end
		end
	elseif category == 3 then
		if CityHasBuilder(city) then
			local canUseProject = m_settings.autoPlace;
			if not canUseProject then
				canUseProject = not HasNoPlacementBuildingOption(buildQueue)
					and not HasPlacementRequiredOptionExceptCommunity(city, buildQueue);
			end
			if canUseProject then
				return TryCampusProject(city);
			end
			return false;
		end
		local builder = GameInfo.Units["UNIT_BUILDER"];
		if builder ~= nil then
			local canProduce = SafeCall(function()
				return buildQueue:CanProduce(builder.Hash, true);
			end);
			if canProduce then
				candidates[#candidates + 1] = { hash = builder.Hash, turns = GetTurnsLeft(buildQueue, builder.Hash) };
			end
		end
	end

	-- Cheapest available item in this tier first.  This avoids stalling on a
	-- wonder/building the city cannot actually place.
	table.sort(candidates, function(a, b)
		return a.turns < b.turns;
	end);
	for i = 1, #candidates do
		if TryBuildHash(city, candidates[i].hash) then
			return true;
		end
	end
	return false;
end

local function TryCityRecommendations(city)
	local cityAI = city:GetCityAI();
	local recommendations = {};

	if cityAI ~= nil then
		local result = SafeCall(function()
			return cityAI:GetBuildRecommendations();
		end);
		if type(result) == "table" then
			recommendations = result;
		end
	end

	local sorted = {};
	for i = 1, #recommendations do
		sorted[#sorted + 1] = recommendations[i];
	end
	table.sort(sorted, function(a, b)
		return (a.BuildItemScore or 0) > (b.BuildItemScore or 0);
	end);

	-- Fixed priority: districts/buildings, then wonders, then Builders.
	-- Try AI recommendations first; if a tier has no usable recommendation,
	-- enumerate every currently buildable item in that tier.
	for category = 1, 3 do
		for i = 1, math.min(#sorted, 10) do
			local hash = sorted[i].BuildItemHash;
			if hash ~= nil and GetBuildCategory(hash) == category and TryBuildHash(city, hash) then
				return true;
			end
		end
		if TryCategoryFallback(city, category) then
			return true;
		end
	end
	return false;
end

local function TryCityFallback(city)
	local fallback = {
		"BUILDING_MONUMENT",
		"BUILDING_GRANARY",
		"BUILDING_WATER_MILL",
		"BUILDING_LIBRARY",
		"BUILDING_MARKET",
		"UNIT_BUILDER",
	};

	for i = 1, #fallback do
		local info = GameInfo.Buildings[fallback[i]] or GameInfo.Units[fallback[i]];
		if info ~= nil then
			if TryBuildHash(city, info.Hash) then
				return true;
			end
		end
	end
	return false;
end

local function ProcessCity(city)
	if city == nil then
		return;
	end

	local buildQueue = city:GetBuildQueue();
	if buildQueue == nil then
		return;
	end

	local queueSize = SafeCall(function()
		return buildQueue:GetSize();
	end);
	if queueSize ~= nil and queueSize > 0 then
		return;
	end

	local currentHash = SafeCall(function()
		return buildQueue:GetCurrentProductionTypeHash();
	end);
	if currentHash ~= nil and currentHash ~= 0 and currentHash ~= -1 then
		return;
	end

	if TryRepairCity(city) then
		return;
	end
	if TryCityRecommendations(city) then
		return;
	end
	TryCityFallback(city);
end

local function AutoCityProduction(playerID)
	local player = Players[playerID];
	if player == nil then
		return;
	end
	local cities = player:GetCities();
	if cities == nil then
		return;
	end
	for _, city in cities:Members() do
		if city ~= nil then
			SafeCall(function()
				ProcessCity(city);
			end);
		end
	end
end

-- ===========================================================================
-- Main loop
-- ===========================================================================

local function RunAutomation(reason)
	if m_running then
		return;
	end
	local playerID = GetLocalPlayerID();
	if playerID == nil then
		return;
	end
	local player = Players[playerID];
	if player == nil then
		return;
	end
	local isAlive = SafeCall(function()
		return player:IsAlive();
	end);
	if not isAlive then
		return;
	end

	m_running = true;
	if m_settings.future then
		local ok, errorMessage = pcall(function()
			TryFutureTech(playerID);
			TryFutureCivic(playerID);
		end);
		if not ok then
			LogError(errorMessage);
		end
	end
	if m_settings.production then
		local ok, errorMessage = pcall(function()
			AutoCityProduction(playerID);
		end);
		if not ok then
			LogError(errorMessage);
		end
	end
	m_running = false;

	UpdateStatus();
	Log("Automation pass complete (" .. tostring(reason) .. ").");
end

local function OnRunNow()
	RunAutomation("manual");
	UpdateStatus();
end

-- Small public hook, useful for other UI scripts and for diagnostics.
function AutoPilot_RunNow()
	OnRunNow();
end

-- ===========================================================================
-- Events
-- ===========================================================================

local function OnLocalPlayerTurnBegin()
	EnsureLaunchBarButton();
	RunAutomation("turn");
end

local function OnCityProductionCompleted(playerID, cityID)
	if playerID ~= GetLocalPlayerID() or not m_settings.production then
		return;
	end
	local player = Players[playerID];
	if player == nil or cityID == nil then
		return;
	end
	local city = SafeCall(function()
		return player:GetCities():FindID(cityID);
	end);
	if city ~= nil then
		SafeCall(function()
			ProcessCity(city);
		end);
	end
	UpdateStatus();
end

local function OnResearchCompleted(playerID)
	if playerID ~= GetLocalPlayerID() or not m_settings.future then
		return;
	end
	SafeCall(function()
		TryFutureTech(playerID, true);
	end);
	UpdateStatus();
end

local function OnCivicCompleted(playerID)
	if playerID ~= GetLocalPlayerID() or not m_settings.future then
		return;
	end
	SafeCall(function()
		TryFutureCivic(playerID, true);
	end);
	UpdateStatus();
end

local function OnLoadGameViewStateDone()
	EnsureLaunchBarButton();
	LoadSettings();
	SyncCheckboxes();
	UpdateStatus();
	RunAutomation("load");
end

local function OnGameDebugReturn(context, values)
	if context ~= RELOAD_CACHE_ID or values == nil then
		return;
	end
	if values.settings ~= nil then
		m_settings = values.settings;
	end
	if values.isHidden ~= nil and Controls ~= nil and Controls.Root ~= nil then
		if values.isHidden then
			ClosePanel();
		else
			OpenPanel();
		end
	end
	SyncCheckboxes();
	UpdateStatus();
end

local function OnShutdown()
	Events.LocalPlayerTurnBegin.Remove(OnLocalPlayerTurnBegin);
	Events.CityProductionCompleted.Remove(OnCityProductionCompleted);
	Events.ResearchCompleted.Remove(OnResearchCompleted);
	Events.CivicCompleted.Remove(OnCivicCompleted);
	Events.LoadGameViewStateDone.Remove(OnLoadGameViewStateDone);
	LuaEvents.GameDebug_Return.Remove(OnGameDebugReturn);

	SaveSettings();
	LuaEvents.GameDebug_AddValue(RELOAD_CACHE_ID, "settings", m_settings);
	if Controls ~= nil and Controls.Root ~= nil then
		LuaEvents.GameDebug_AddValue(RELOAD_CACHE_ID, "isHidden", Controls.Root:IsHidden());
	end
end

local function OnInit(isReload)
	m_uiReady = true;
	LoadSettings();
	SyncCheckboxes();
	UpdateStatus();

	Controls.OpenButton:RegisterCallback(Mouse.eLClick, OpenPanel);
	Controls.CloseButton:RegisterCallback(Mouse.eLClick, ClosePanel);
	Controls.RunNowButton:RegisterCallback(Mouse.eLClick, OnRunNow);
	Controls.ProductionCheck:RegisterCheckHandler(OnToggleProduction);
	Controls.FutureCheck:RegisterCheckHandler(OnToggleFuture);
	Controls.AutoPlaceCheck:RegisterCheckHandler(OnToggleAutoPlace);
	Controls.OpenButton:RegisterCallback(Mouse.eMouseEnter, function()
		UI.PlaySound("Main_Menu_Mouse_Over");
	end);
	Controls.CloseButton:RegisterCallback(Mouse.eMouseEnter, function()
		UI.PlaySound("Main_Menu_Mouse_Over");
	end);

	ContextPtr:SetHide(false);
	ClosePanel();
	EnsureLaunchBarButton();

	if isReload then
		LuaEvents.GameDebug_GetValues(RELOAD_CACHE_ID);
	end
end

local function Initialize()
	ContextPtr:SetInitHandler(OnInit);
	ContextPtr:SetShutdown(OnShutdown);
	ContextPtr:SetInputHandler(OnInputHandler, true);

	Events.LocalPlayerTurnBegin.Add(OnLocalPlayerTurnBegin);
	Events.CityProductionCompleted.Add(OnCityProductionCompleted);
	Events.ResearchCompleted.Add(OnResearchCompleted);
	Events.CivicCompleted.Add(OnCivicCompleted);
	Events.LoadGameViewStateDone.Add(OnLoadGameViewStateDone);
	LuaEvents.GameDebug_Return.Add(OnGameDebugReturn);
end

print(LOG_PREFIX .. "loaded");
Initialize();
