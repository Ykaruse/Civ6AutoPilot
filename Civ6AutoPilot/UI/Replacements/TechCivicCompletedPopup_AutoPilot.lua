-- ===========================================================================
-- Suppress the full-screen "Research/Civic Complete" popup for repeatable
-- Future Tech / Future Civic.  Regular one-time techs and civics keep the
-- normal popup.
-- ===========================================================================

include("TechCivicCompletedPopup");

local BASE_AddCompletedPopup = AddCompletedPopup;

function AddCompletedPopup(player, civic, tech, isByUser)
	if civic ~= nil then
		local civicInfo = GameInfo.Civics[civic];
		if civicInfo ~= nil and civicInfo.Repeatable then
			return;
		end
	end
	if tech ~= nil then
		local techInfo = GameInfo.Technologies[tech];
		if techInfo ~= nil and techInfo.Repeatable then
			return;
		end
	end

	return BASE_AddCompletedPopup(player, civic, tech, isByUser);
end
