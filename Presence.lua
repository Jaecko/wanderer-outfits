local _, ns = ...
local L = ns.L

-- Where Outfits shows itself, so it is found when it is useful, never in the way:
-- * A button "Outfits" on the character sheet, where you think about your gear (beside Wanderer's weights button
--   when it is there).
-- * A suggestion, once for each item and character, when you carry a piece made for a moment (a riding trinket, a
--   fishing hat, the Argent Dawn's trinkets) that no outfit takes yet: one click makes that outfit, the piece put on
--   for a moment to keep it, what you wore given back at once. An option, on; the notice's own menu mutes it too.
-- * A better piece put on by hand in place of one your outfits take: a notice offers to put it in them too (Wanderer's
--   own outfits; the game's manager keeps its sets itself), so an upgrade never leaves an outfit behind.
-- * A piece made for a moment still worn when you enter a dungeon or a ready check comes: said, one click undoes it.
-- * Without Wanderer Bags: their pieces never sold as junk; without its window (which says it already): your
--   outfits named in an item's tooltip.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Clean = U and U.Clean

-- Pieces made for a moment: item id -> { kind, slot }.
local MOMENT_PIECES = {
	[11122] = { kind = "mount", slot = 14 }, -- Carrot on a Stick
	[19972] = { kind = "fishing", slot = 1 }, -- Lucky Fishing Hat
	[19969] = { kind = "fishing", slot = 8 }, -- Nat Pagle's Extreme Anglin' Boots
	[12846] = { kind = "zone", slot = 14 }, -- Argent Dawn Commission
	[13209] = { kind = "zone", slot = 14 }, -- Seal of the Dawn
	[19812] = { kind = "zone", slot = 14 }, -- Rune of the Dawn
}
ns.MOMENT_PIECES = MOMENT_PIECES -- (tests)
local SCAN_DELAY = 3 -- seconds after the bags settle
local WEAR_WAIT = 4 -- seconds a piece is waited for before the outfit is made

local function Settings() return ns.Settings and ns.Settings() or nil end
local function On(key)
	local settings = Settings()
	return settings and settings.enabled and settings[key] ~= false or false
end
-- A notice's click (also later, from Wanderer's list of recent notices): only while Outfits is on.
local function WhileOn(action)
	return function()
		if On("enabled") then return action() end
		W.Print(L.EXT_TURNED_OFF:format(L.TITLE))
	end
end
-- (a notice still waiting its turn: dropped once Outfits is off)
local function Shown() return On("enabled") end

-- The character sheet's button ------------------------------------------------------------------------------------

local function SheetButton()
	local sheet = _G.CharacterFrame
	if not sheet or sheet.wandererOutfits then return end
	local page = _G.PaperDollFrame or sheet
	local column = _G.CharacterFrameInsetRight
	local button = Skin.GameButton(page, "WandererOutfitsSheetButton", L.TITLE, function() ns.Toggle() end, { L.TITLE, L.OPEN_DESC })
	sheet.wandererOutfits = button
	button:SetHeight(22)
	-- (above Wanderer's weights button when it shows, else where it would stand)
	local function Place()
		button:ClearAllPoints()
		local weights = sheet.wandererWeights
		if weights and weights:IsShown() then
			button:SetPoint("BOTTOM", weights, "TOP", 0, 4)
		elseif column then
			button:SetPoint("BOTTOM", column, "BOTTOM", 0, 8)
		else
			button:SetPoint("BOTTOMRIGHT", sheet, "BOTTOMRIGHT", -10, 10)
		end
		button:SetFrameLevel(((column or sheet):GetFrameLevel() or 1) + 20)
		button:SetShown(On("enabled"))
	end
	sheet:HookScript("OnShow", Place)
	Place()
	-- (Outfits turned off or on with the sheet open: the button follows at once)
	if ns.OnChanged then ns.OnChanged(function() button:SetShown(On("enabled")) end) end
end

-- Suggestions -------------------------------------------------------------------------------------------------------

-- The piece made for a moment, put on, kept in a new outfit for that moment (only its slot taken), then what you
-- wore there given back: nothing changes for you but a new outfit.
function ns.MakeFromPiece(id)
	local piece = MOMENT_PIECES[id]
	if not piece or InCombatLockdown() then return end
	-- (worn already, in its slot or the other one of a pair: a trinket in the first slot, kept there)
	local worn, slot, link = ns.Worn(), piece.slot, nil
	for wornSlot, wornLink in pairs(worn) do
		if not link and U.ItemID(wornLink) == id then slot, link = wornSlot, wornLink end
	end
	if not link then
		U.EachBagItem(function(_, _, info)
			if not link and Clean(info.itemID) == id then link = Clean(info.hyperlink) end
		end)
	end
	if not link then return end
	local before = worn[slot]
	-- (the game's manager may make the outfit a moment later: what you wore given back once it is there, or once
	-- it never came, never the piece left on without an outfit)
	local function Made(entry)
		if entry then
			local left = {}
			for _, other in ipairs(ns.SLOTS) do
				if other ~= slot then left[other] = true end
			end
			ns.DB().left[entry.name] = left
			ns.TellBags()
			-- (a zone outfit starts with no zone: the zones are yours to choose in its card, never the one you stand in)
			local when = ns.When(entry.name)
			if when and when.kind == "zone" then when.zones = {} end
		end
		-- (what you wore there given back; an empty slot left empty again)
		if not before then
			ns.TakeOff(slot)
		elseif not ns.Same(before, link) then
			ns.Put({ [slot] = before })
		end
		if not entry then return end
		ns.Changed()
		ns.ShowOutfit(entry.name)
	end
	local function Make() ns.CreateFor(piece.kind, Made) end
	if ns.Same(worn[slot], link) then return Make() end
	ns.Put({ [slot] = link })
	local waited = 0
	local function Wait()
		if ns.Same(ns.Worn()[slot], link) then return Make() end
		waited = waited + 0.5
		-- (the piece still on its way, hands busy with a cast: waited for, never left on without an outfit)
		if waited < WEAR_WAIT or ns.Dressing() then C_Timer.After(0.5, Wait) end
	end
	C_Timer.After(0.5, Wait)
end

-- Every outfit's pieces it takes, by item id.
local function Taken()
	local taken = {}
	for _, entry in ipairs(ns.Sets()) do
		for _, piece in ipairs(ns.Pieces(entry)) do
			if piece.id and not piece.left then taken[piece.id] = true end
		end
	end
	return taken
end

-- Pieces made for a moment you carry or wear, no outfit taking them, never suggested to this character: one notice.
function ns.Suggest()
	if not On("suggest") or ns.OtherSwaps() or InCombatLockdown() then return end
	local told = ns.DB().suggested or {}
	ns.DB().suggested = told
	local found = {}
	U.EachBagItem(function(_, _, info)
		local id = Clean(info.itemID)
		if id and MOMENT_PIECES[id] then found[id] = true end
	end)
	for _, link in pairs(ns.Worn()) do
		local id = U.ItemID(link)
		if id and MOMENT_PIECES[id] then found[id] = true end
	end
	local taken
	for id in pairs(found) do
		if not told[id] then
			taken = taken or Taken()
			if not taken[id] then
				told[id] = true
				local piece = MOMENT_PIECES[id]
				local name = U.ItemName(id) or ("#" .. id)
				W.Toast(L.SUGGEST_TITLE, L.SUGGEST_TEXT:format(name, L["WHEN_" .. piece.kind:upper()]),
					{ kind = "outfits", kindName = L.ADDON, icon = U.ItemIcon(id), hint = L.SUGGEST_HINT,
						onClick = WhileOn(function() ns.MakeFromPiece(id) end), still = Shown })
				return -- (one at a time: the next one later)
			end
		end
	end
end

-- An upgrade --------------------------------------------------------------------------------------------------------

-- Wanderer's own outfits taking this piece in this slot (and not leaving it aside): { set }.
local function OutfitsTaking(slot, link)
	local list = {}
	if ns.GameKeepsSets() then return list end
	for _, set in ipairs(ns.DB().sets) do
		local left = ns.LeftSlots(set.name)
		if set.slots and set.slots[slot] and not left[slot] and ns.Same(set.slots[slot], link) then list[#list + 1] = set end
	end
	return list
end

-- The new piece in those outfits instead of the old one.
function ns.ReplaceIn(sets, slot, link)
	for _, set in ipairs(sets) do set.slots[slot] = link end
	ns.Changed()
	ns.TellBags()
end

local seen -- what was worn, slot -> link (to know what a piece put on by hand replaced)
local function OnEquipment(slot)
	local worn = ns.Worn()
	local before = seen and seen[slot]
	seen = worn
	-- (Outfits off: nothing offered)
	if not (slot and before and On("enabled")) or ns.Dressing() or InCombatLockdown() then return end
	local now = worn[slot]
	if not now or ns.Same(now, before) then return end
	-- (a piece of another outfit: a change of outfits, not an upgrade)
	for _, set in ipairs(ns.DB().sets) do
		for _, link in pairs(set.slots or {}) do
			if ns.Same(link, now) then return end
		end
	end
	local sets = OutfitsTaking(slot, before)
	if not sets[1] then return end
	local names = {}
	for _, set in ipairs(sets) do names[#names + 1] = set.name end
	W.Toast(L.UPDATE_TITLE, L.UPDATE_TEXT:format(U.LinkName(now) or "?", U.LinkName(before) or "?", table.concat(names, ", ")),
		{ kind = "outfits", kindName = L.ADDON, icon = U.ItemIcon(U.ItemID(now)), hint = L.UPDATE_HINT,
			onClick = WhileOn(function() ns.ReplaceIn(sets, slot, now) end), still = Shown })
end
ns.OnEquipment = OnEquipment -- (tests)

-- A piece for a moment still worn --------------------------------------------------------------------------------

-- Entering a dungeon or a ready check: a piece made for a moment you still wear (not put on by a moment now) said.
function ns.StillWorn()
	if not On("suggest") then return end
	local state = ns.SituationState()
	for slot, link in pairs(ns.Worn()) do
		local id = U.ItemID(link)
		if id and MOMENT_PIECES[id] and not (state.applied[slot] and ns.Same(state.applied[slot], link)) then
			-- (undone only when the last change put it there: never a change of other slots, the weapons...)
			W.Toast(L.STILL_WORN_TITLE, L.STILL_WORN_TEXT:format(U.LinkName(link) or "?"),
				{ kind = "outfits", kindName = L.ADDON, icon = U.ItemIcon(id), hint = ns.CanUndo(slot) and L.STILL_WORN_UNDO or L.STILL_WORN_CHOOSE,
					onClick = WhileOn(function() if ns.CanUndo(slot) then ns.Undo() else ns.Choose() end end), still = Shown })
			return
		end
	end
end

-- Without Wanderer Bags -----------------------------------------------------------------------------------------------

local pieces -- item id -> { outfit names }, read again when the outfits change
local function Pieces()
	pieces = pieces or ns.PieceMap()
	return pieces
end
local function BagsThere() return type(WandererBags) == "table" end
-- (its own squares say it: only while its window has the bags, not turned off nor left to another bags addon)
local function BagsSayIt()
	if not BagsThere() then return false end
	local settings = W.Settings and W.Settings("bags")
	return settings and settings.enabled and not (W.Yields and W.Yields("bags")) and true or false
end

local function InitWithoutBags()
	ns.OnChanged(function() pieces = nil end)
	-- (an outfit's piece is never junk)
	if W.AddJunkRule then
		W.AddJunkRule(function(id)
			if On("enabled") and not BagsThere() and id and Pieces()[id] then return false end
		end)
	end
	U.OnItemTooltip(function(tooltip, id)
		if not (On("enabled") and id and not BagsSayIt()) then return false end
		local names = Pieces()[id]
		if not names then return false end
		local c = Skin.COLORS.label
		tooltip:AddLine(L.IN_OUTFITS:format(table.concat(names, ", ")), c[1], c[2], c[3], true)
		return true
	end)
end

function ns.InitPresence()
	SheetButton()
	-- (the sheet made later: the button with its first opening)
	if not _G.CharacterFrame and _G.ToggleCharacter then hooksecurefunc("ToggleCharacter", SheetButton) end
	local suggest = U.Debounce(SCAN_DELAY, ns.Suggest)
	local events = CreateFrame("Frame")
	for _, event in ipairs({ "BAG_UPDATE_DELAYED", "PLAYER_ENTERING_WORLD", "PLAYER_EQUIPMENT_CHANGED", "READY_CHECK" }) do
		pcall(events.RegisterEvent, events, event)
	end
	events:SetScript("OnEvent", function(_, event, slot)
		if event == "PLAYER_EQUIPMENT_CHANGED" then return OnEquipment(slot) end
		if event == "READY_CHECK" then return ns.StillWorn() end
		if event == "PLAYER_ENTERING_WORLD" then
			seen = ns.Worn()
			-- (a moment later: a situation's own change first)
			if Clean(U.Safe(IsInInstance)) then C_Timer.After(SCAN_DELAY, ns.StillWorn) end
		end
		suggest()
	end)
	InitWithoutBags()
end
