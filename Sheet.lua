local _, ns = ...
local L = ns.L

-- Wanderer's character sheet, in place of the game's while it shows your equipment: your character large in the
-- middle (turned with a drag, a little closer with the wheel), your pieces in two columns on its sides and your
-- weapons under it (each with its name in its quality's color, its item level, a quiet word when it is broken or
-- nearly), your name, level, class and guild above with your item level; beside, three pages: your
-- characteristics as the game groups them (its own words under the mouse), your outfits (worn, chosen, made from
-- what you wear) and your titles. A piece works as the game's: a click or a drag takes it, an item dropped on it
-- (or on your character) is put on; a right click, or Alt under the mouse, shows the pieces of your bags that fit
-- there. The game's sheet stays open out of sight (Skin.AsideGameWindow): its other pages (reputation, currency...)
-- are a click away at the foot, and a link gives the game's whole sheet back for this character (another one above
-- it brings Wanderer's back). The game's key (C) and its window's life are untouched: closed by the game, this one
-- goes with it; closed here, the game's closes too. Inspecting another player stays the game's.
-- Its look follows the calm of the finest character sheets: your character alone in a soft light between two dark
-- sides, each piece a square with its words on a dark band fading toward your character (its item level next to
-- the square, its enchant beyond, mirrored on the right), an empty place only its outline, and a few slow breaths
-- (your character, a piece just changed, the pieces that fit) instead of anything that moves on its own.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin
local Safe, Clean = U and U.Safe, U and U.Clean
-- (a game function this client may lack: nil then)
local function API(name) return rawget(_G, name) end

local WIDTH, HEIGHT = 1120, 680
local SIDE = 280 -- the pages beside
local COLUMN = 236 -- a column of pieces
local SQUARE, SLOT_ROW, SLOT_GAP = 42, 50, 4
local TOP = 112 -- (under the heading and the tabs)
local GAME_TOP, GAME_RULE = 54, 7 -- (the game look: the heading in the game's bar, a line of its actions, the rule, the tabs)
local HANDS_GAP = 16
local ZOOM_LEAST, ZOOM_MOST, ZOOM_STEP = 0.8, 1.2, 0.08 -- (a little closer or further, never a close-up)
local TURN_STEP = 0.25 -- (a controller's cross, per press)
local FACING = 0.35 -- (a little turned at first: three quarters read better than a full face)
local BAND = 0.5 -- the dark band under a piece's words, at its square
local SIDES, FLOOR, LIGHT = 0.42, 0.34, 0.07 -- the stage's dark sides and floor, the light behind your character
local EMPTY_ALPHA = 0.4 -- an empty place's outline
local BLACK = { 0, 0, 0 }
local LOW_WEAR = 25 -- percent: a piece this worn is said
local FIT_PER_ROW, FIT_SQUARE = 6, 34
local LEFT_SLOTS = { 1, 2, 3, 15, 5, 4, 19, 9 }
local RIGHT_SLOTS = { 10, 6, 7, 8, 11, 12, 13, 14 }
local HAND_SLOTS = { 16, 17, 18 }
local FIGHT_SLOTS = { [0] = true, [16] = true, [17] = true, [18] = true } -- (what the game lets you change in a fight)
-- (pieces the kit's list of kinds leaves out: a shirt, a tabard, ammunition)
local MORE_KINDS = { INVTYPE_BODY = { 4 }, INVTYPE_TABARD = { 19 }, INVTYPE_AMMO = { 0 } }
-- The game's other pages, in its order (each shown only when the game has it).
local PAGES = { "ReputationFrame", "TokenFrame", "SkillsFrame", "PVPRankFrame", "StatisticsFrame" }
local PAGE_WORDS = { ReputationFrame = "REPUTATION", TokenFrame = "CURRENCY", SkillsFrame = "SKILLS", PVPRankFrame = "PVP",
	StatisticsFrame = "STATISTICS" }
-- The fields the game's characteristics write on their frame (read back for their own tooltip).
local FIELDS = { "tooltip", "tooltip2", "tooltip3", "tooltipLabel", "onEnterFunc", "UpdateTooltip", "numericValue", "damage",
	"attackSpeed", "offhandDamage", "offhandAttackSpeed", "bonusDamage", "dps", "minModifier", "speed", "runSpeed",
	"flightSpeed", "swimSpeed", "unit", "wasSwimming" }
local RESISTANCES = { "ARCANE_RESIST", "FIRE_RESIST", "FROST_RESIST", "NATURE_RESIST", "SHADOW_RESIST" }

local window, placeGame, reopen, probe, flyout
local hooked = false
local leaving = false -- (Wanderer's sheet hidden by the game's, or for the game's: nothing more to close)
local slots = {} -- the rows of the pieces
local pages = {} -- the pages beside: stats, outfits, titles
local stats -- the characteristics read last (kept through a fight)
local hovered -- the piece under the mouse (Alt: what fits there)
local drawSoon
local enchants, enchantCount = {}, 0 -- a piece's enchant words by its link (false: none)

local function Settings() return ns.Settings and ns.Settings() or nil end
local function DB() return ns.DB() end

-- Wanderer's sheet wanted: Outfits on, its setting on, and the game's not chosen for this character.
local function On()
	local settings = Settings()
	return settings and settings.enabled and settings.sheet ~= false and true or false
end
local function GameChosen() return DB().sheetGame == true end
local function Game() return rawget(_G, "CharacterFrame") end
local function Doll() return rawget(_G, "PaperDollFrame") end
-- The game's sheet open on your equipment.
local function DollShown()
	local sheet, doll = Game(), Doll()
	return sheet ~= nil and sheet:IsShown() and doll ~= nil and doll:IsShown() and true or false
end
local function Away() return On() and not GameChosen() and DollShown() end
ns.SheetAway = Away

local function Fighting()
	return InCombatLockdown() or Clean(Safe(UnitAffectingCombat, "player")) and true or false
end

-- A few words at the window's foot (a refusal, a full bag), gone after a while.
local saidAt = 0
local function Say(text, role)
	if not (window and text) then return end
	saidAt = saidAt + 1
	local mine = saidAt
	window.said:SetText(Skin.Colorize(text, role or "bad"))
	window.said:Show()
	C_Timer.After(6, function() if saidAt == mine and window then window.said:SetText("") end end)
end
ns.SheetSaid = function() return window and window.said:GetText() or "" end -- (tests)

-- Slow breaths: a text, a square or your character comes up from nothing (after a delay), easing out. One driver,
-- asleep when nothing comes; everything shown at once when the window goes.
local breathing, breather = {}, nil
local function SetSeen(region, alpha)
	-- (a model's own alpha: the frame's does not reach the character on every client)
	if region.SetModelAlpha then pcall(region.SetModelAlpha, region, alpha) else region:SetAlpha(alpha) end
end
local function Breathe(_, elapsed)
	local any = false
	for region, breath in pairs(breathing) do
		breath.t = breath.t + elapsed
		if breath.t >= 0 then
			local share = math.min(1, breath.t / breath.long)
			SetSeen(region, 1 - (1 - share) * (1 - share))
			if share >= 1 then breathing[region] = nil end
		end
		any = any or breathing[region] ~= nil
	end
	if not any then breather:SetScript("OnUpdate", nil) end
end
local function BreatheIn(region, long, delay)
	if not region then return end
	SetSeen(region, 0)
	breathing[region] = { t = -(delay or 0), long = long }
	if not breather then breather = CreateFrame("Frame") end
	breather:SetScript("OnUpdate", Breathe)
end
local function BreatheAll()
	for region in pairs(breathing) do SetSeen(region, 1) end
	breathing = {}
	if breather then breather:SetScript("OnUpdate", nil) end
end
ns.SheetBreathing = function() return next(breathing) ~= nil end -- (tests)

-- A place's name, as the game says it.
local function SlotName(slot)
	return ns.SlotName(slot) or ""
end

-- Pieces -----------------------------------------------------------------------------------------------------

-- The game's empty picture for a place (the outline of a helm, a ring...).
local function EmptyIcon(slot)
	local key = ns.SLOT_KEYS and ns.SLOT_KEYS[slot]
	if not (key and API("GetInventorySlotInfo")) then return nil end
	local _, icon = Safe(API("GetInventorySlotInfo"), key)
	return Clean(icon)
end

-- Its wear in a few words: broken, or this worn (nil: nothing worth a word).
local function WearWords(slot)
	if Clean(Safe(API("GetInventoryItemBroken"), "player", slot)) then return L.SLOT_BROKEN end
	local current, most = Safe(GetInventoryItemDurability, slot)
	current, most = Clean(current), Clean(most)
	if not (current and most and most > 0) then return nil end
	if current <= 0 then return L.SLOT_BROKEN end
	local share = math.floor(current / most * 100)
	if share <= LOW_WEAR then return L.SLOT_WORN:format(share) end
end
ns.WearWords = WearWords -- (tests)

-- Its enchant in the game's own words (its tooltip's enchant line, "Enchanted:" left out); nil: none, or not known
-- yet (asked again at the next drawing). Kept by link: a link carries its enchant.
local function EnchantWords(slot, link)
	local id = link and link:match("item:%d+:(%d*)")
	if not id or id == "" or id == "0" then return nil end
	if enchants[link] ~= nil then return enchants[link] or nil end
	local tips = rawget(_G, "C_TooltipInfo")
	local data = tips and tips.GetInventoryItem and Clean(Safe(tips.GetInventoryItem, "player", slot))
	if type(data) ~= "table" then return nil end
	local kinds = rawget(_G, "Enum") and Enum.TooltipDataLineType
	local kind = kinds and kinds.ItemEnchantmentPermanent
	-- (the game's "Enchanted: %s", cut around its %s)
	local format = rawget(_G, "ENCHANTED_TOOLTIP_LINE")
	local before, after
	if type(format) == "string" then before, after = format:match("^(.-)%%s(.-)$") end
	local words
	for _, line in ipairs(U.TooltipLines(data.lines)) do
		local text = line.text
		local wrapped = before ~= nil and #text > #before + #after and text:sub(1, #before) == before
			and (after == "" or text:sub(-#after) == after)
		if wrapped then text = text:sub(#before + 1, #text - #after) end
		if (kind and line.type == kind) or wrapped then
			words = strtrim(text)
			break
		end
	end
	if enchantCount >= 200 then enchants, enchantCount = {}, 0 end
	enchants[link], enchantCount = words or false, enchantCount + 1
	return words
end
ns.EnchantWords = EnchantWords -- (tests)

-- The dark band under a piece's words: as wide as its words, from under its square toward your character.
local function FitBand(row)
	local widest = 0
	for _, text in ipairs({ row.name, row.line }) do
		widest = math.max(widest, math.min(row.textWidth, U.Measure(text, "GetStringWidth", 0) or 0))
	end
	row.band:SetWidth(SQUARE / 2 + 10 + widest + 36)
	row.band:Show()
end

-- A piece's place drawn. changed (a drawing while the window was already shown): words that changed come up slowly.
local function FillSlot(row, changed)
	local slot = row.slot
	local link = Clean(Safe(GetInventoryItemLink, "player", slot))
	local icon = Clean(Safe(GetInventoryItemTexture, "player", slot))
	local before = row.link
	row.link = link
	row.icon.texture:SetVertexColor(1, 1, 1)
	if row.icon.texture.SetDesaturated then row.icon.texture:SetDesaturated(false) end
	if not (link or icon) then
		-- (an empty place: only its outline, quiet; its name under the mouse)
		row.icon:Set(EmptyIcon(slot), nil)
		row.icon:SetAlpha(EMPTY_ALPHA)
		row.name:SetText("")
		row.line:SetText("")
		row.band:Hide()
		return
	end
	row.icon:SetAlpha(1)
	local quality = Clean(Safe(API("GetInventoryItemQuality"), "player", slot))
	row.icon:Set(icon or (link and U.ItemIcon(U.ItemID(link))), quality)
	row.name:SetText(U.LinkName(link) or Clean((Safe(C_Item and C_Item.GetItemInfo or API("GetItemInfo"), link))) or SlotName(slot))
	row.name:SetTextColor(U.QualityColor(quality or 1))
	-- Under it: its item level beside the square, its enchant beyond (in green), its wear last (in red); the right
	-- column reads from its square too, so its words go the other way.
	local parts = {}
	local level = link and U.ItemLevel(link)
	if level and level > 0 then parts[#parts + 1] = L.SLOT_LEVEL:format(level) end
	local enchant = EnchantWords(slot, link)
	if enchant then parts[#parts + 1] = Skin.Colorize(enchant, "good") end
	local wear = WearWords(slot)
	if wear then parts[#parts + 1] = Skin.Colorize(wear, "bad") end
	if row.side == "right" then
		for index = 1, math.floor(#parts / 2) do parts[index], parts[#parts + 1 - index] = parts[#parts + 1 - index], parts[index] end
	end
	row.line:SetText(table.concat(parts, U.SEPARATOR))
	FitBand(row)
	if changed and link ~= before then
		BreatheIn(row.name, 0.3)
		BreatheIn(row.line, 0.3, 0.05)
	end
	-- (as the game's own square: red when broken or of no use now, grey while it moves)
	if wear == L.SLOT_BROKEN or Clean(Safe(API("GetInventoryItemEquippedUnusable"), "player", slot)) then
		row.icon.texture:SetVertexColor(0.9, 0.25, 0.25)
	end
	if Clean(Safe(API("IsInventoryItemLocked"), slot)) and row.icon.texture.SetDesaturated then row.icon.texture:SetDesaturated(true) end
end

-- A piece taken (a click or a drag), or what the mouse holds put there: the game's own way. In a fight only what
-- the game allows then (your weapons).
local function Take(slot)
	if Fighting() and not FIGHT_SLOTS[slot] then return Say(L.IN_FIGHT) end
	Safe(PickupInventoryItem, slot)
end
ns.SheetTake = Take -- (tests)

-- What fits a place among your bags: the game's own list when it has one, else the pieces of that kind. Best first.
local function Fitting(slot)
	local fits
	if API("GetInventoryItemsForSlot") then
		local found = {}
		if pcall(API("GetInventoryItemsForSlot"), slot, found) then
			fits = {}
			for _, id in pairs(found) do
				id = Clean(id)
				if id then fits[id] = true end
			end
		end
	end
	local list = {}
	U.EachBagItem(function(bag, place, info)
		local link, id = Clean(info.hyperlink), Clean(info.itemID)
		local ok = false
		if fits then
			ok = fits[id] == true
		else
			local kind = U.ItemEquipKind(id or link)
			for _, where in ipairs(kind and (U.EQUIP_SLOTS[kind] or MORE_KINDS[kind]) or {}) do
				if where == slot then ok = true end
			end
		end
		if ok then
			list[#list + 1] = { bag = bag, place = place, link = link, id = id, icon = Clean(info.iconFileID) or U.ItemIcon(id),
				quality = Clean(info.quality), level = link and U.ItemLevel(link) or 0, name = U.LinkName(link) or U.ItemName(id) or "" }
		end
	end)
	table.sort(list, function(a, b)
		if (a.level or 0) ~= (b.level or 0) then return (a.level or 0) > (b.level or 0) end
		return a.name < b.name
	end)
	return list
end
ns.SheetFitting = Fitting -- (tests)

-- A piece of your bags put on there (the game asks itself before binding it).
local function PutOn(slot, piece)
	if Fighting() and not FIGHT_SLOTS[slot] then return Say(L.IN_FIGHT) end
	if ns.CursorBusy() then return end
	Safe(C_Container and C_Container.PickupContainerItem, piece.bag, piece.place)
	if Clean(Safe(CursorHasItem)) then Safe(EquipCursorItem, slot) end
end
ns.SheetPutOn = PutOn -- (tests)

-- The piece of a place put away in your bags (the first with room), as the game's flyout does.
local function ToBags(slot)
	if Fighting() and not FIGHT_SLOTS[slot] then return Say(L.IN_FIGHT) end
	if ns.CursorBusy() then return end
	local container = C_Container or {}
	local target
	for bag = 0, NUM_BAG_SLOTS or 4 do
		local free, kind = Safe(container.GetContainerNumFreeSlots, bag)
		free, kind = Clean(free), Clean(kind)
		if not target and (free or 0) > 0 and (kind or 0) == 0 then target = bag end
	end
	if not target then return Say(rawget(_G, "ERR_INV_FULL") or L.BAGS_FULL) end
	Safe(PickupInventoryItem, slot)
	if not Clean(Safe(CursorHasItem)) then return end
	if target == 0 then
		Safe(PutItemInBackpack)
	else
		local inventory = Clean(Safe(container.ContainerIDToInventoryID or rawget(_G, "ContainerIDToInventoryID"), target))
		if inventory then Safe(API("PutItemInBag"), inventory) end
	end
end
ns.SheetToBags = ToBags -- (tests)

-- What fits a place: a card beside it, your bag's pieces as squares (the game's tooltip on each, a click puts it
-- on), and the piece worn put away. Again on the same place: closed. byAlt: opened by Alt under the mouse (it goes
-- once Alt is let go, unless the mouse is on it).
local function FitSquare(card, index)
	local square = card.grid.squares[index]
	if square then return square end
	square = CreateFrame("Button", nil, card.grid)
	square:SetSize(FIT_SQUARE, FIT_SQUARE)
	square.icon = Skin.Icon(square, FIT_SQUARE)
	square.icon:SetAllPoints()
	-- (its item level at its foot, on a little dark: to compare at a glance with the piece worn)
	square.shade = square:CreateTexture(nil, "OVERLAY")
	square.shade:SetPoint("BOTTOMLEFT", square, "BOTTOMLEFT", 1, 1)
	square.shade:SetPoint("BOTTOMRIGHT", square, "BOTTOMRIGHT", -1, 1)
	square.shade:SetHeight(12)
	square.shade:SetColorTexture(1, 1, 1, 1)
	square.shade:SetGradient("VERTICAL", CreateColor(0, 0, 0, 0.75), CreateColor(0, 0, 0, 0))
	square.level = Skin.Text(square, "GameTooltipTextSmall", "text")
	square.level:SetPoint("BOTTOM", square, "BOTTOM", 0, 2)
	square.level:SetJustifyH("CENTER")
	square:RegisterForClicks("LeftButtonUp")
	square:SetScript("OnEnter", function(self)
		if not self.piece then return end
		GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
		if not Safe(GameTooltip.SetBagItem, GameTooltip, self.piece.bag, self.piece.place) and self.piece.link then
			GameTooltip:SetHyperlink(self.piece.link)
		end
		GameTooltip:Show()
	end)
	square:SetScript("OnLeave", function() GameTooltip:Hide() end)
	square:SetScript("OnClick", function(self)
		if not self.piece then return end
		-- (Shift links it, Ctrl tries it on: never put on then)
		if U.ItemClick(self.piece.link) then return end
		Skin.Play("click")
		local slot = card.slot
		card:Hide()
		PutOn(slot, self.piece)
	end)
	card.grid.squares[index] = square
	return square
end

-- again: drawn again where it is (your bags changed), never closed.
function ns.ShowFitting(row, byAlt, again)
	if not (row and row.slot) then return end
	if not flyout then
		flyout = Skin.Card("WandererOutfitsFitting", true)
		flyout.grid = CreateFrame("Frame", nil, flyout)
		flyout.grid.squares = {}
		flyout.onHide = function(self) self.slot, self.byAlt = nil, nil end
	end
	local card = flyout
	if card:IsShown() and card.slot == row.slot and not again then
		if byAlt then return end
		Skin.Play("click")
		return card:Hide()
	end
	local slot = row.slot
	local pieces = Fitting(slot)
	for index, piece in ipairs(pieces) do
		local square = FitSquare(card, index)
		square.piece = piece
		square.icon:Set(piece.icon, piece.quality)
		local level = piece.level or 0
		square.level:SetText(level > 1 and tostring(level) or "")
		square.shade:SetShown(level > 1)
		square:ClearAllPoints()
		local column, line = (index - 1) % FIT_PER_ROW, math.floor((index - 1) / FIT_PER_ROW)
		square:SetPoint("TOPLEFT", card.grid, "TOPLEFT", column * (FIT_SQUARE + 4), -line * (FIT_SQUARE + 4))
		square:Show()
		-- (opened: the squares come one after the other, a breath each; drawn again: at once)
		if not again then BreatheIn(square, 0.2, (index - 1) * 0.025) end
	end
	for index = #pieces + 1, #card.grid.squares do
		card.grid.squares[index].piece = nil
		card.grid.squares[index]:Hide()
	end
	local lines = math.ceil(#pieces / FIT_PER_ROW)
	local width = FIT_PER_ROW * (FIT_SQUARE + 4) - 4
	card.grid:SetSize(width, math.max(1, lines * (FIT_SQUARE + 4) - 4))
	local rows = {}
	if row.link then rows[1] = { text = L.TO_BAGS, run = function() ToBags(slot) end } end
	local icon = Clean(Safe(GetInventoryItemTexture, "player", slot)) or EmptyIcon(slot)
	card:Fill({ title = SlotName(slot), icon = icon, quality = row.link and Clean(Safe(API("GetInventoryItemQuality"), "player", slot)) or nil,
		now = pieces[1] and L.FITTING_COUNT:format(#pieces) or L.FITTING_NONE, body = pieces[1] and card.grid or nil,
		bodyHeight = card.grid:GetHeight(), minWidth = width, rows = rows[1] and rows or nil })
	-- (its title in gold: the place, not an item)
	local gold = Skin.COLORS.gold
	card.name:SetTextColor(gold[1], gold[2], gold[3])
	card.slot = slot
	if not again then card.byAlt = byAlt and true or nil end
	card:Present(row)
	card.valid = function() return window ~= nil and window:IsShown() end
end
ns.Fitting = function() return flyout end -- (tests)

local function SlotEnter(self)
	hovered = self
	GameTooltip:SetOwner(self, self.side == "right" and "ANCHOR_LEFT" or "ANCHOR_RIGHT")
	local shown = self.link and Clean(Safe(GameTooltip.SetInventoryItem, GameTooltip, "player", self.slot))
	if not shown then GameTooltip:SetText(SlotName(self.slot)) end
	GameTooltip:Show()
	if IsAltKeyDown and IsAltKeyDown() then ns.ShowFitting(self, true) end
end

local function SlotLeave(self)
	if hovered == self then hovered = nil end
	GameTooltip:Hide()
	if API("ResetCursor") then API("ResetCursor")() end
end

local function SlotClick(self, mouse)
	if mouse == "RightButton" then
		-- (Shift and the right button: the game's socketing, when it has some)
		if self.link and IsModifiedClick and Clean(Safe(IsModifiedClick, "SOCKETITEM")) and API("SocketInventoryItem") then
			return Safe(API("SocketInventoryItem"), self.slot)
		end
		-- (the card plays its own sound as it opens)
		return ns.ShowFitting(self, false)
	end
	if self.link and U.ItemClick(self.link) then return end
	Take(self.slot)
end

-- A row of a piece: its square, its name, a line under it, on a dark band fading toward your character; on the
-- right column the square is on the right and everything mirrored.
local function MakeSlot(parent, slot, side, width)
	local row = CreateFrame("Button", nil, parent)
	row:SetSize(width, SLOT_ROW)
	row.slot, row.side = slot, side
	row.icon = Skin.Icon(row, SQUARE)
	row.name = Skin.Text(row, "GameTooltipText", "text")
	row.line = Skin.Text(row, "GameTooltipTextSmall", "soft")
	row.textWidth = width - SQUARE - 12
	for _, text in ipairs({ row.name, row.line }) do
		if text.SetWordWrap then text:SetWordWrap(false) end
		text:SetWidth(row.textWidth)
	end
	row.band = row:CreateTexture(nil, "BACKGROUND")
	row.band:SetHeight(SQUARE + 4)
	Skin.FadingRule(row.band, BAND, side == "right", BLACK)
	row.band:Hide()
	if side == "right" then
		row.icon:SetPoint("RIGHT", row, "RIGHT", 0, 0)
		row.band:SetPoint("RIGHT", row.icon, "CENTER", 0, 0)
		row.name:SetPoint("BOTTOMRIGHT", row.icon, "LEFT", -10, 1)
		row.line:SetPoint("TOPRIGHT", row.icon, "LEFT", -10, -3)
		row.name:SetJustifyH("RIGHT")
		row.line:SetJustifyH("RIGHT")
	else
		row.icon:SetPoint("LEFT", row, "LEFT", 0, 0)
		row.band:SetPoint("LEFT", row.icon, "CENTER", 0, 0)
		row.name:SetPoint("BOTTOMLEFT", row.icon, "RIGHT", 10, 1)
		row.line:SetPoint("TOPLEFT", row.icon, "RIGHT", 10, -3)
		row.name:SetJustifyH("LEFT")
		row.line:SetJustifyH("LEFT")
	end
	-- (under the mouse: the square lights a little, the band deepens; no box drawn over your character)
	row.hover = row.icon:CreateTexture(nil, "OVERLAY")
	if Skin.GameWindows() then
		-- (the game look: the light of the game's own item squares)
		row.hover:SetAllPoints(row.icon)
		row.hover:SetTexture("Interface\\Buttons\\ButtonHilight-Square")
		row.hover:SetBlendMode("ADD")
	else
		row.hover:SetPoint("TOPLEFT", row.icon, "TOPLEFT", 1, -1)
		row.hover:SetPoint("BOTTOMRIGHT", row.icon, "BOTTOMRIGHT", -1, 1)
		row.hover:SetColorTexture(1, 1, 1, 0.12)
	end
	row.hover:Hide()
	row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
	row:RegisterForDrag("LeftButton")
	row:SetScript("OnClick", SlotClick)
	row:SetScript("OnDragStart", function(self) Take(self.slot) end)
	row:SetScript("OnReceiveDrag", function(self) Take(self.slot) end)
	row:SetScript("OnEnter", function(self)
		self.hover:Show()
		Skin.FadingRule(self.band, BAND + 0.2, self.side == "right", BLACK)
		SlotEnter(self)
	end)
	row:SetScript("OnLeave", function(self)
		self.hover:Hide()
		Skin.FadingRule(self.band, BAND, self.side == "right", BLACK)
		SlotLeave(self)
	end)
	-- (a controller: its top button is the right click, what fits there)
	row.padRight, row.padRightWord = true, L.PAD_FITTING
	slots[#slots + 1] = row
	return row
end
ns.SheetSlots = function() return slots end -- (tests)

-- Your character ------------------------------------------------------------------------------------------------

local function MakeModel(parent)
	local ok, model = pcall(CreateFrame, "PlayerModel", nil, parent)
	if not ok then model = CreateFrame("Frame", nil, parent) end
	model:EnableMouse(true)
	model:EnableMouseWheel(true)
	model.facing, model.zoom = FACING, 1
	function model:Look()
		if self.SetUnit then pcall(self.SetUnit, self, "player") end
		if self.SetPortraitZoom then pcall(self.SetPortraitZoom, self, 0) end
		if self.SetCamDistanceScale then pcall(self.SetCamDistanceScale, self, self.zoom) end
		if self.SetFacing then pcall(self.SetFacing, self, self.facing) end
		self:Light()
	end
	-- A soft warm light from the front, above and to the side, over an even ground light: the character reads
	-- whole, its armor modelled, never a spotlight. (the newer clients take the light as one table, the older as
	-- numbers; neither: the game's own light)
	function model:Light()
		if not self.SetLight then return end
		local vector, color = rawget(_G, "CreateVector3D"), rawget(_G, "CreateColor")
		if vector and color and pcall(self.SetLight, self, true, { omnidirectional = false, point = vector(-0.5, 0.5, -0.7),
			ambientIntensity = 0.75, ambientColor = color(1, 0.97, 0.92), diffuseIntensity = 0.8, diffuseColor = color(1, 0.96, 0.9) }) then
			return
		end
		pcall(self.SetLight, self, true, false, -0.5, 0.5, -0.7, 0.75, 1, 0.97, 0.92, 0.8, 1, 0.96, 0.9)
	end
	-- (an item held by the mouse, dropped on your character: put on, as the game's sheet does)
	local function Drop()
		if not Clean(Safe(CursorHasItem)) then return false end
		Safe(API("AutoEquipCursorItem"))
		return true
	end
	local function Stop(self) self.from = nil end
	model:SetScript("OnMouseDown", function(self, button)
		if button ~= "LeftButton" or Drop() then return end
		self.from = GetCursorPosition()
	end)
	model:SetScript("OnMouseUp", Stop)
	model:SetScript("OnHide", Stop)
	model:SetScript("OnReceiveDrag", Drop)
	model:SetScript("OnUpdate", function(self)
		if not self.from then return end
		if IsMouseButtonDown and not IsMouseButtonDown("LeftButton") then return Stop(self) end
		local at = GetCursorPosition()
		self.facing = self.facing + (at - self.from) * 0.012
		self.from = at
		if self.SetFacing then pcall(self.SetFacing, self, self.facing) end
	end)
	model:SetScript("OnMouseWheel", function(self, delta)
		self.zoom = Skin.Within(self.zoom - delta * ZOOM_STEP, ZOOM_LEAST, ZOOM_MOST)
		if self.SetCamDistanceScale then pcall(self.SetCamDistanceScale, self, self.zoom) end
	end)
	-- A controller: the cross's left and right turn it, the right stick brings it closer.
	model.padAdjust = function(self, delta)
		self.facing = self.facing + delta * TURN_STEP
		if self.SetFacing then pcall(self.SetFacing, self, self.facing) end
	end
	model.padWheel = true
	model.padTip = true
	Skin.Tooltip(model, function()
		if not (U.UsingPad and U.UsingPad()) then return L.MODEL_TIP end
		return Skin.PadKeys and Skin.PadKeys({ { "PADDLEFT PADDRIGHT", "TURN" }, { "PADRSTICKAXIS", "ZOOM" } }) or L.MODEL_TIP_PAD
	end)
	return model
end

-- Characteristics -----------------------------------------------------------------------------------------------

-- The frame the game's own characteristics are written on, out of sight: each one read from it, as the game does
-- for its sheet.
local function Probe()
	if probe then return probe end
	probe = CreateFrame("Frame", nil, window)
	probe:SetSize(1, 1)
	probe:SetAlpha(0)
	probe:EnableMouse(false)
	probe:SetPoint("TOPLEFT", window, "TOPLEFT", 0, 0)
	probe.Label = probe:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	probe.Value = probe:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
	probe.Background = probe:CreateTexture(nil, "BACKGROUND")
	probe.Icon = probe:CreateTexture(nil, "ARTWORK")
	return probe
end

-- One characteristic as the game writes it: its words, its value, what its tooltip needs (nil: the game hides it).
local function ReadStat(info, unit, hideAt, id)
	local frame = Probe()
	for _, key in ipairs(FIELDS) do frame[key] = nil end
	frame.Label:SetText("")
	frame.Value:SetText("")
	frame:Show()
	local ok, value = pcall(info.updateFunc, frame, unit, id)
	if not ok or not frame:IsShown() then return nil end
	if value == nil then value = frame.numericValue end
	if hideAt ~= nil and not U.IsSecret(value) and value == hideAt then return nil end
	local label = Clean(frame.Label:GetText())
	label = type(label) == "string" and label:gsub("%s*[:：]%s*$", "") or ""
	local entry = { name = label, value = frame.Value:GetText() or "", fields = {} }
	for _, key in ipairs(FIELDS) do entry.fields[key] = frame[key] end
	return entry
end

-- Whether a characteristic suits you, as the game decides (your specialization's main one, your role, its own test).
local function Suits(stat, spec, role)
	if stat.primary and spec then
		local primary = select(6, Safe(API("C_SpecializationInfo").GetSpecializationInfo, spec, false, false, nil, Clean(Safe(UnitSex, "player"))))
		if Clean(primary) and stat.primary ~= Clean(primary) then return false end
	end
	if stat.roles then
		local found = false
		for _, wanted in pairs(stat.roles) do if wanted == role then found = true end end
		if not found then return false end
	end
	if stat.showFunc then
		local ok, show = pcall(stat.showFunc)
		if ok and not show then return false end
	end
	return true
end

-- The game's groups of characteristics: your attributes first, then the others in its order, your pet's after
-- when you have one, then the resistances. Each a heading and its lines.
function ns.ReadStats()
	local list = {}
	local categories, infos = rawget(_G, "PAPERDOLL_STATCATEGORIES"), rawget(_G, "PAPERDOLL_STATINFO")
	if type(categories) == "table" and type(infos) == "table" then
		local spec, role
		if API("C_SpecializationInfo") and API("C_SpecializationInfo").GetSpecialization then
			spec = Clean(Safe(API("C_SpecializationInfo").GetSpecialization))
			if spec and API("GetSpecializationRoleEnum") then role = Clean(Safe(API("GetSpecializationRoleEnum"), spec)) end
		end
		local order = {}
		for _, category in ipairs(categories) do
			local primary = false
			for _, stat in ipairs(category.stats or {}) do if stat.stat == "STRENGTH" or stat.stat == "INTELLECT" then primary = true end end
			if primary and (category.unit or "player") == "player" then table.insert(order, 1, category) else order[#order + 1] = category end
		end
		local pet = Clean(Safe(UnitExists, "pet")) and (not API("HasPetUI") or Clean(Safe(API("HasPetUI")))) and true or false
		for _, category in ipairs(order) do
			local unit = category.unit or "player"
			if unit == "player" or (unit == "pet" and pet) then
				local lines = {}
				for _, stat in ipairs(category.stats or {}) do
					local info = infos[stat.stat]
					if info and info.updateFunc and Suits(stat, spec, role) then
						local entry = ReadStat(info, unit, stat.hideAt, stat.id)
						if entry then lines[#lines + 1] = entry end
					end
				end
				if lines[1] then
					local heading = category.categoryName or ""
					if unit == "pet" then heading = L.PET_STATS:format(heading) end
					list[#list + 1] = { header = heading }
					for _, entry in ipairs(lines) do list[#list + 1] = entry end
				end
			end
		end
		-- (the resistances, as the game's sheet adds them after its groups)
		local lines = {}
		for _, key in ipairs(RESISTANCES) do
			local info = infos[key]
			local entry = info and info.updateFunc and ReadStat(info, "player")
			if entry then lines[#lines + 1] = entry end
		end
		if lines[1] then
			list[#list + 1] = { header = rawget(_G, "STAT_CATEGORY_RESISTANCE") or L.RESISTANCES }
			for _, entry in ipairs(lines) do list[#list + 1] = entry end
		end
		return list
	end
	-- (a game without its sheet's lists: your attributes and your armor, from the game's own numbers)
	list[1] = { header = rawget(_G, "STAT_CATEGORY_ATTRIBUTES") or L.TAB_STATS }
	for index = 1, 5 do
		local _, effective = Safe(UnitStat, "player", index)
		local name = rawget(_G, "SPELL_STAT" .. index .. "_NAME")
		if name and Clean(effective) then list[#list + 1] = { name = name, value = tostring(Clean(effective)), fields = {} } end
	end
	local _, armor = Safe(UnitArmor, "player")
	if Clean(armor) then list[#list + 1] = { name = rawget(_G, "ARMOR") or "", value = tostring(Clean(armor)), fields = {} } end
	return list
end

-- A characteristic's tooltip: the game's own (its words and its numbers), shown from the row under the mouse.
local function StatTip(row)
	local entry = row.entry
	if not (entry and entry.fields) then return end
	for _, key in ipairs(FIELDS) do row[key] = entry.fields[key] end
	if type(row.onEnterFunc) == "function" and pcall(row.onEnterFunc, row) then return end
	local tip = rawget(_G, "PaperDollStatTooltip")
	if type(tip) == "function" and row.tooltip and pcall(tip, row) then return end
	if row.tooltip then Skin.ShowTip(row, { { row.tooltip, 1, 1, 1 }, row.tooltip2, row.tooltip3 }, "ANCHOR_RIGHT") end
end

-- Pages beside ---------------------------------------------------------------------------------------------------

-- The game look: a characteristic's row as the game's sheet draws it (its group's title on the game's bar, in
-- white as written; every other line of a group on the game's line ground). even: the line's place in its group.
local function GameStatRow(row, entry, even)
	if not row.gameBack then
		row.gameBack = row:CreateTexture(nil, "BACKGROUND", nil, -1)
		row.gameBack:SetAllPoints()
		if type(row.header) == "table" and row.header.SetFontObject then row.header:SetFontObject(Skin.FontFor("GameFontHighlight")) end
	end
	row.gameBack:Hide()
	if not entry then return end
	if entry.header then
		if Skin.GameAtlas(row.gameBack, "UI-Character-Info-Title") then row.gameBack:Show() end
		row.header:SetText(entry.header)
		row.header:SetTextColor(Skin.RGB("text"))
		row.header:ClearAllPoints()
		row.header:SetPoint("CENTER", row, "CENTER", 0, 0)
	elseif even and Skin.GameAtlas(row.gameBack, "UI-Character-Info-Line-Bounce") then
		row.gameBack:Show()
	end
end

local function DrawStats()
	local page = pages.stats
	if not (page and page:IsShown()) then return end
	-- (in a fight the numbers wait for its end: the game's own are hidden values then)
	if not Fighting() or not stats then stats = ns.ReadStats() end
	local list = page.list
	local offset = list:Clamp(#stats)
	local game = Skin.GameWindows()
	-- (the game look: each line's place in its group, for the game's ground on every other one)
	local even = {}
	if game then
		local count = 0
		for index, entry in ipairs(stats) do
			if entry.header then count = 0 else count = count + 1 end
			even[index] = count % 2 == 0
		end
	end
	for index, row in ipairs(list.rows) do
		local entry = stats[offset + index]
		row:Fill(entry, false, entry and { value = entry.value } or nil)
		if entry and not entry.header then
			local c, v = Skin.COLORS.label, Skin.COLORS.text
			row.name:SetTextColor(c[1], c[2], c[3])
			row.cells.value:SetTextColor(v[1], v[2], v[3])
		end
		if game then GameStatRow(row, entry, even[offset + index]) end
	end
	page.note:SetShown(Fighting())
end

-- Your titles: none first, then those you know (the game's own list and order), yours in gold.
function ns.Titles()
	local list = { { id = -1, name = rawget(_G, "PLAYER_TITLE_NONE") or L.NO_TITLE } }
	local known = {}
	for index = 1, Clean(Safe(API("GetNumTitles"))) or 0 do
		if Clean(Safe(API("IsTitleKnown"), index)) then
			local name = Clean(Safe(API("GetTitleName"), index))
			if type(name) == "string" and strtrim(name) ~= "" then known[#known + 1] = { id = index, name = strtrim(name) } end
		end
	end
	table.sort(known, function(a, b) return a.name < b.name end)
	for _, entry in ipairs(known) do list[#list + 1] = entry end
	return list
end

local function DrawTitles()
	local page = pages.titles
	if not (page and page:IsShown()) then return end
	local titles = ns.Titles()
	local current = Clean(Safe(API("GetCurrentTitle"))) or -1
	local list = page.list
	local offset = list:Clamp(#titles)
	for index, row in ipairs(list.rows) do
		local entry = titles[offset + index]
		local chosen = entry ~= nil and (entry.id == current or (entry.id == -1 and current <= 0))
		if entry then entry.color = chosen and Skin.COLORS.gold or Skin.COLORS.text end
		row:Fill(entry, chosen)
	end
end

local function DrawOutfits()
	local page = pages.outfits
	if not (page and page:IsShown()) then return end
	local sets = ns.Sets()
	local list = page.list
	local offset = list:Clamp(#sets)
	for index, row in ipairs(list.rows) do
		local set = sets[offset + index]
		if set then
			-- (its tooltip: its name, when it goes on by itself, what a click does; never a hole in the list)
			local tip = { set.name }
			local whenWords = ns.WhenWords(set.name)
			if whenWords then tip[#tip + 1] = whenWords end
			tip[#tip + 1] = (U.UsingPad and U.UsingPad()) and L.ROW_TIP_PAD or L.ROW_TIP
			row:Fill({ id = set.id, name = set.name, icon = set.icon, equipped = set.equipped, color = set.equipped and Skin.COLORS.gold or nil, tip = tip },
				set.equipped, {}, set.equipped and L.CHIP_WORN or nil, "gold", not set.equipped and L.ACT_WEAR or nil, function() ns.WearSet(set.id) end)
		else
			row:Fill(nil)
		end
	end
	list.empty:SetShown(#sets == 0)
	-- (an outfit's card open: drawn again with it)
	local card = ns.OutfitCard and ns.OutfitCard()
	if card and card:IsShown() and card.mode ~= "rename" then ns.FillCard() end
end

local function DrawSide()
	DrawStats()
	DrawOutfits()
	DrawTitles()
end

-- The page chosen (kept for this character).
local function ShowPage(key)
	if not pages[key] then key = "stats" end
	DB().sheetPage = key
	for name, page in pairs(pages) do page:SetShown(name == key) end
	if window and window.tabs then window.tabs:Select(key) end
	DrawSide()
end
ns.SheetPage = ShowPage -- (tests)

-- An outfit's card beside its row on the outfits page (just made, its pieces to choose).
local function ShowOutfitHere(name)
	if not (window and window:IsShown()) then return ns.ShowOutfit(name) end
	ShowPage("outfits")
	local list = pages.outfits.list
	for index, set in ipairs(ns.Sets()) do
		if set.name == name then
			if list.offset > index - 1 or list.offset + list.count < index then
				list.offset = index - 1
				DrawOutfits()
			end
			for _, row in ipairs(list.rows) do
				if row.entry and row.entry.name == name then return ns.OpenCard(row, row.entry) end
			end
		end
	end
end

-- The heading ----------------------------------------------------------------------------------------------------

local function DrawHeading()
	local name = Clean(Safe(API("UnitPVPName"), "player")) or Clean(Safe(UnitName, "player")) or ""
	window.title:SetText(name)
	local guild = Clean(Safe(GetGuildInfo, "player"))
	window.kicker:SetText(U.Upper(guild or "Wanderer"))
	local level = Clean(Safe(UnitLevel, "player")) or 0
	local effective = Clean(Safe(UnitEffectiveLevel, "player"))
	local levelWords = tostring(level)
	if effective and effective ~= level and rawget(_G, "EFFECTIVE_LEVEL_FORMAT") then levelWords = API("EFFECTIVE_LEVEL_FORMAT"):format(effective, level) end
	local parts = { L.LEVEL_LINE:format(levelWords) }
	local race = Clean(Safe(UnitRace, "player"))
	if race then parts[#parts + 1] = race end
	local className, class = Safe(UnitClass, "player")
	className, class = Clean(className), Clean(class)
	if className then
		local r, g, b = U.ClassColor(class)
		parts[#parts + 1] = r and U.Colorize(className, r, g, b) or className
	end
	window.who:SetText(table.concat(parts, "  ·  "))
	-- Your item level, as the game shows it (from level 10, as the game does).
	local _, equipped = Safe(GetAverageItemLevel)
	equipped = Clean(equipped)
	local least = C_PaperDollInfo and C_PaperDollInfo.GetMinItemLevel and Clean(Safe(C_PaperDollInfo.GetMinItemLevel)) or 0
	local shown = equipped and level >= (rawget(_G, "MIN_PLAYER_LEVEL_FOR_ITEM_LEVEL_DISPLAY") or 10)
	window.itemLevel:SetShown(shown and true or false)
	if shown then window.itemLevel.number:SetText(tostring(math.floor(math.max(least, equipped)))) end
end

-- The links to the game's other pages, at the foot: those the game has now.
local function DrawPages()
	local sheet = Game()
	local previous
	for _, link in ipairs(window.pages) do
		local frame = rawget(_G, link.page)
		local shown = frame ~= nil and not frame.hidden
		if shown and link.page == "TokenFrame" then
			if sheet and type(sheet.ShouldShowCurrencyTab) == "function" then
				local ok, has = pcall(sheet.ShouldShowCurrencyTab, sheet)
				shown = ok and has and true or false
			elseif C_CurrencyInfo and C_CurrencyInfo.GetCurrencyListSize then
				shown = (Clean(Safe(C_CurrencyInfo.GetCurrencyListSize)) or 0) > 0
			end
		end
		link:SetShown(shown)
		if shown then
			link:ClearAllPoints()
			if previous then link:SetPoint("LEFT", previous, "RIGHT", 6, 0) else link:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", window.margin, window.margin) end
			previous = link
		end
	end
end

-- still: drawn as the window opens (it comes in a breath already: nothing more moves).
local function Draw(still)
	if not (window and window:IsShown()) then return end
	DrawHeading()
	for _, row in ipairs(slots) do FillSlot(row, still ~= true) end
	DrawPages()
	DrawSide()
end
ns.DrawSheet = Draw

-- The game's sheet ------------------------------------------------------------------------------------------------

-- Wanderer's sheet or the game's, as wanted now: called whenever the game's opens, closes or changes its page.
local function Sync()
	if not hooked then return end
	if placeGame then placeGame() end
	if Away() then
		if not window then ns.CreateSheet() end
		if window:IsShown() then
			Draw()
		else
			-- (the game's sheet plays its own sound as it opens)
			window.quiet = true
			window:Show()
			window.quiet = nil
		end
	elseif window and window:IsShown() then
		leaving = true
		window.quiet = true
		window:Hide()
		leaving = false
	end
	if reopen then reopen:SetShown(On() and GameChosen() and DollShown()) end
end
ns.SheetSync = Sync

-- The link above the game's sheet, back to Wanderer's.
local function Reopen()
	local sheet = Game()
	if reopen or not sheet then return end
	reopen = Skin.SmallButton(UIParent, Skin.GlyphText("chevron", "label") .. " " .. L.SHEET_LINK, function() ns.SheetUseWanderer() end,
		L.SHEET_LINK_DESC)
	reopen:SetFrameStrata("HIGH")
	reopen:SetPoint("BOTTOMRIGHT", sheet, "TOPRIGHT", 0, 4)
	reopen:Hide()
end

local function Hook()
	local sheet, doll = Game(), Doll()
	if hooked or not (sheet and doll and Skin.AsideGameWindow) then return end
	hooked = true
	placeGame = Skin.AsideGameWindow(sheet, Away)
	sheet:HookScript("OnShow", Sync)
	sheet:HookScript("OnHide", Sync)
	doll:HookScript("OnShow", Sync)
	doll:HookScript("OnHide", Sync)
	Reopen()
	Sync()
end
ns.HookSheet = Hook -- (tests)

-- The game's whole sheet, for this character from now on (Wanderer's a link away above it).
function ns.SheetUseGame()
	DB().sheetGame = true
	Sync()
end

-- Wanderer's sheet again, for this character: shown at once when the game's is open.
function ns.SheetUseWanderer()
	DB().sheetGame = nil
	local sheet = Game()
	if sheet and sheet:IsShown() and not DollShown() and API("ToggleCharacter") then Safe(API("ToggleCharacter"), "PaperDollFrame", true) end
	Sync()
end

-- One of the game's pages (reputation, currency...): the game's sheet comes back on it.
function ns.SheetOpenPage(page)
	if API("ToggleCharacter") then Safe(API("ToggleCharacter"), page) end
	Sync()
end

-- The window -----------------------------------------------------------------------------------------------------

local EVENTS = { "PLAYER_EQUIPMENT_CHANGED", "UPDATE_INVENTORY_DURABILITY", "ITEM_LOCK_CHANGED", "KNOWN_TITLES_UPDATE",
	"PLAYER_GUILD_UPDATE", "PLAYER_LEVEL_UP", "GET_ITEM_INFO_RECEIVED", "MODIFIER_STATE_CHANGED", "PLAYER_REGEN_ENABLED",
	"PLAYER_REGEN_DISABLED", "COMBAT_RATING_UPDATE", "PLAYER_DAMAGE_DONE_MODS", "UNIT_PET", "BAG_UPDATE_DELAYED",
	"PLAYER_AVG_ITEM_LEVEL_UPDATE", "SPELL_POWER_CHANGED" }
local UNIT_EVENTS = { "UNIT_STATS", "UNIT_AURA", "UNIT_RESISTANCES", "UNIT_ATTACK_SPEED", "UNIT_DAMAGE", "UNIT_RANGEDDAMAGE",
	"UNIT_ATTACK_POWER", "UNIT_RANGED_ATTACK_POWER", "UNIT_MAXHEALTH", "UNIT_MAXPOWER", "UNIT_NAME_UPDATE", "UNIT_MODEL_CHANGED",
	"UNIT_INVENTORY_CHANGED" }

local function Listen(on)
	local events = window.events
	for _, event in ipairs(EVENTS) do pcall(on and events.RegisterEvent or events.UnregisterEvent, events, event) end
	for _, event in ipairs(UNIT_EVENTS) do
		if on then pcall(events.RegisterUnitEvent, events, event, "player", "pet") else pcall(events.UnregisterEvent, events, event) end
	end
end

local function OnEvent(_, event, unit)
	if event == "MODIFIER_STATE_CHANGED" then
		-- (Alt under a piece: what fits there; let go away from the card: it goes)
		local alt = IsAltKeyDown and IsAltKeyDown()
		if alt and hovered and hovered:IsVisible() then return ns.ShowFitting(hovered, true) end
		if not alt and flyout and flyout:IsShown() and flyout.byAlt and not U.IsMouseOver(flyout) then flyout:Hide() end
		return
	end
	-- (your pet's model or bags are not yours: only your own change dresses your character again)
	if event == "PLAYER_EQUIPMENT_CHANGED" or ((event == "UNIT_MODEL_CHANGED" or event == "UNIT_INVENTORY_CHANGED") and unit == "player") then
		window.model:Look()
	end
	-- A piece put on: the card of what fits goes; your bags changed: it is drawn again where it is.
	if flyout and flyout:IsShown() then
		if event == "PLAYER_EQUIPMENT_CHANGED" then
			flyout:Hide()
		elseif event == "BAG_UPDATE_DELAYED" and flyout.owner then
			ns.ShowFitting(flyout.owner, nil, true)
		end
	end
	drawSoon()
end

local function MakePage(key, spec)
	local page = CreateFrame("Frame", nil, window)
	page:SetPoint("TOPLEFT", window.side, "TOPLEFT", 0, 0)
	page:SetPoint("BOTTOMRIGHT", window.side, "BOTTOMRIGHT", 0, 0)
	page.list = Skin.Table(page, spec)
	page.list:SetPoint("TOPLEFT", page, "TOPLEFT", 0, 0)
	page:Hide()
	pages[key] = page
	return page
end

function ns.CreateSheet()
	if window then return window end
	window = Skin.CreateWindow("WandererOutfitsSheet", "MEDIUM")
	Skin.Sounds(window, Skin.SOUNDS.open, Skin.SOUNDS.close)
	-- (opened silently by the character key, yet by the player: the controller comes to it, Wanderer's Pad.lua)
	window.padTakes = true
	Skin.Dress(window, { "CENTER", UIParent, "CENTER", 0, 30 }, "outfitsSheetPos")
	-- (the game look: the heading in the game's bar, so all under it comes up, and the window as much shorter)
	local game = Skin.GameWindows()
	local top, ruleTop = game and GAME_TOP or TOP, game and GAME_RULE or 66
	window:SetSize(WIDTH, HEIGHT - (TOP - top))
	local kicker, title, margin = Skin.Header(window, "Wanderer", "", { settings = "ext:outfits" }, "GameFontNormalHuge")
	window.kicker, window.title, window.margin = kicker, title, margin
	window.who = Skin.Text(window, "GameTooltipText", "soft")
	-- (the game look: the title's place, level with the cog and the help)
	if game then window.who:SetPoint("LEFT", window, "TOPLEFT", margin, -14)
	else window.who:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -5) end
	-- Your item level, at the heading's right: the game's own words under the mouse.
	local level = CreateFrame("Frame", nil, window)
	level:SetSize(150, 44)
	level:SetPoint("TOPRIGHT", window, "TOPRIGHT", -margin, -(margin + 16))
	level.number = Skin.Text(level, "GameFontNormalHuge", "gold")
	level.number:SetPoint("TOPRIGHT", level, "TOPRIGHT", 0, 0)
	level.caps = Skin.Caps(level, L.ITEM_LEVEL)
	level.caps:SetPoint("TOPRIGHT", level.number, "BOTTOMRIGHT", 0, -3)
	level:EnableMouse(true)
	level.padTip = true
	level:SetScript("OnEnter", function(self)
		local infos = rawget(_G, "PAPERDOLL_STATINFO")
		local entry = infos and infos.ITEMLEVEL and ReadStat(infos.ITEMLEVEL, "player")
		if entry and entry.fields.tooltip then
			Skin.ShowTip(self, { { entry.fields.tooltip, 1, 1, 1 }, entry.fields.tooltip2 }, "ANCHOR_BOTTOMLEFT")
		else
			Skin.ShowTip(self, L.ITEM_LEVEL, "ANCHOR_BOTTOMLEFT")
		end
	end)
	level:SetScript("OnLeave", function() GameTooltip:Hide() end)
	window.itemLevel = level
	-- The help, and the game's own sheet a click away (for this character from now on).
	local help = Skin.Help(window, L.SHEET_HELP, "HEADING")
	if help then help:HookScript("OnEnter", function(self) if U.UsingPad and U.UsingPad() then Skin.ShowTip(self, L.SHEET_HELP_PAD, "ANCHOR_BOTTOM") end end) end
	window.game = Skin.SmallButton(window, Skin.GlyphText("move", "label") .. " " .. L.GAME_WINDOW, function() ns.SheetUseGame() end,
		L.SHEET_GAME_DESC, 20)
	window.game:SetPoint("RIGHT", help or window.cog or window.closeButton, "LEFT", -8, 0)
	-- (the game look: the item level on the heading's line too, left of that button, its words before the number)
	if game then
		level:ClearAllPoints()
		level:SetSize(150, 24)
		level:SetPoint("RIGHT", window.game, "LEFT", -16, 0)
		level.number:ClearAllPoints()
		level.number:SetPoint("RIGHT", level, "RIGHT", 0, 0)
		level.caps:ClearAllPoints()
		level.caps:SetPoint("RIGHT", level.number, "LEFT", -6, 0)
	end
	local rule = Skin.Rule(window, false, 0.16)
	-- (the game look: the game's own divider, from its options' list)
	if game then Skin.GameAtlas(rule, "Options_HorizontalDivider") end
	rule:SetPoint("TOPLEFT", window, "TOPLEFT", margin, -(margin + ruleTop))
	rule:SetPoint("TOPRIGHT", window, "TOPRIGHT", -margin, -(margin + ruleTop))
	-- The pieces and your character.
	local area = WIDTH - margin * 2 - SIDE - 24
	local stage = CreateFrame("Frame", nil, window)
	stage:SetPoint("TOPLEFT", window, "TOPLEFT", margin, -(margin + top))
	stage:SetSize(area, 8 * SLOT_ROW + 7 * SLOT_GAP)
	window.stage = stage
	for index, slot in ipairs(LEFT_SLOTS) do
		MakeSlot(stage, slot, "left", COLUMN):SetPoint("TOPLEFT", stage, "TOPLEFT", 0, -(index - 1) * (SLOT_ROW + SLOT_GAP))
	end
	for index, slot in ipairs(RIGHT_SLOTS) do
		MakeSlot(stage, slot, "right", COLUMN):SetPoint("TOPRIGHT", stage, "TOPRIGHT", 0, -(index - 1) * (SLOT_ROW + SLOT_GAP))
	end
	-- The stage's ground, inside this window only: its two sides darker behind your pieces, fading toward the
	-- middle, a soft floor under your character's feet and a faint warm light behind it. No frame, no box: your
	-- character stands in the window's own dark.
	-- (from the rule under the heading to the window's foot: no edge of their own to be seen; x: from the window's
	-- left)
	local function Ground(sub, x, width)
		local texture = window:CreateTexture(nil, "BACKGROUND", nil, sub)
		texture:SetPoint("TOPLEFT", window, "TOPLEFT", x, -(margin + ruleTop + 1))
		texture:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", x, 1)
		texture:SetWidth(width)
		return texture
	end
	local left = Ground(1, 1, COLUMN + margin + 48)
	Skin.FadingRule(left, SIDES, false, BLACK)
	local right = Ground(1, margin + area + 12 - (COLUMN + 60), COLUMN + 60)
	Skin.FadingRule(right, SIDES, true, BLACK)
	local middle, half = margin + math.floor(area / 2), math.floor((area - COLUMN * 2) / 2) + 60
	local glowLeft = Ground(2, middle - half, half)
	Skin.FadingRule(glowLeft, LIGHT, true, Skin.COLORS.kicker)
	local glowRight = Ground(2, middle, half)
	Skin.FadingRule(glowRight, LIGHT, false, Skin.COLORS.kicker)
	-- (the game look: no warm light of Wanderer's own behind your character, as the game's sheet)
	if game then
		glowLeft:Hide()
		glowRight:Hide()
	end
	local floor = window:CreateTexture(nil, "BACKGROUND", nil, 3)
	floor:SetPoint("BOTTOMLEFT", stage, "BOTTOMLEFT", COLUMN - 40, -8)
	floor:SetPoint("BOTTOMRIGHT", stage, "BOTTOMRIGHT", -(COLUMN - 40), -8)
	floor:SetHeight(110)
	floor:SetColorTexture(1, 1, 1, 1)
	floor:SetGradient("VERTICAL", CreateColor(0, 0, 0, FLOOR), CreateColor(0, 0, 0, 0))
	window.ground = { left = left, right = right, glowLeft = glowLeft, glowRight = glowRight, floor = floor }
	window.model = MakeModel(stage)
	window.model:SetPoint("TOPLEFT", stage, "TOPLEFT", COLUMN + 12, 0)
	window.model:SetPoint("BOTTOMRIGHT", stage, "BOTTOMRIGHT", -(COLUMN + 12), 0)
	-- Your weapons under it (and the ammunition, when this game has its place).
	local hands = {}
	for _, slot in ipairs(HAND_SLOTS) do hands[#hands + 1] = slot end
	local ammo = API("GetInventorySlotInfo") and Clean(Safe(API("GetInventorySlotInfo"), "AMMOSLOT"))
	if ammo then hands[#hands + 1] = ammo end
	local handWidth = math.min(COLUMN, math.floor((area - (#hands - 1) * HANDS_GAP) / #hands))
	local handsWidth = #hands * handWidth + (#hands - 1) * HANDS_GAP
	for index, slot in ipairs(hands) do
		MakeSlot(window, slot, "left", handWidth):SetPoint("TOPLEFT", stage, "BOTTOMLEFT",
			math.floor((area - handsWidth) / 2) + (index - 1) * (handWidth + HANDS_GAP), -16)
	end
	-- The pages beside, under their tabs, past a thin rule.
	local side = CreateFrame("Frame", nil, window)
	side:SetPoint("TOPRIGHT", window, "TOPRIGHT", -margin, -(margin + top))
	side:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -margin, margin)
	side:SetWidth(SIDE)
	window.side = side
	local down = Skin.Rule(window, true, 0.14)
	down:SetPoint("TOPRIGHT", side, "TOPLEFT", -12, 26)
	down:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -(margin + SIDE + 12), margin)
	local tabRule = Skin.Rule(window, false, 0.16)
	if game then Skin.GameAtlas(tabRule, "Options_HorizontalDivider") end
	tabRule:SetPoint("BOTTOMLEFT", side, "TOPLEFT", 0, 8)
	tabRule:SetPoint("BOTTOMRIGHT", side, "TOPRIGHT", 0, 8)
	window.tabs = Skin.Tabs(window, { { "stats", L.TAB_STATS }, { "outfits", L.TITLE }, { "titles", L.TAB_TITLES } }, ShowPage)
	window.tabs.fit = SIDE
	window.tabs:SetPoint("BOTTOMLEFT", tabRule, "TOPLEFT", 0, 0)
	local height = HEIGHT - margin * 2 - TOP -- (the same in both looks: the window as much shorter as its top)
	local statsPage = MakePage("stats", { width = SIDE, rows = 30, rowHeight = 22, titles = false, icon = false,
		columns = { { key = "value", width = 96, justify = "RIGHT" } }, onClick = function() end, onDraw = DrawStats })
	statsPage.list:Fit(height - 18)
	statsPage.note = Skin.Text(statsPage, "GameTooltipTextSmall", "muted")
	statsPage.note:SetPoint("TOPLEFT", statsPage.list, "BOTTOMLEFT", 6, -4)
	statsPage.note:SetText(L.STATS_AFTER_FIGHT)
	statsPage.note:Hide()
	for _, row in ipairs(statsPage.list.rows) do
		row:HookScript("OnEnter", StatTip)
		-- (a characteristic is read, never clicked: no sound, nothing done)
		row:RegisterForClicks()
		row.padTip = true
	end
	local outfitsPage = MakePage("outfits", { width = SIDE, rows = 12, rowHeight = 40, titles = false, columns = {}, action = 62,
		padRight = true, padRightWord = L.PAD_CARD,
		onClick = function(entry, mouse)
			if mouse == "RightButton" then
				for _, row in ipairs(pages.outfits.list.rows) do
					if row.entry == entry then return ns.OpenCard(row, entry) end
				end
				return
			end
			ns.WearSet(entry.id)
		end,
		onDraw = DrawOutfits })
	outfitsPage.list:Fit(height - 30)
	outfitsPage.list.empty:SetText(L.SHEET_NO_OUTFIT)
	local save = Skin.SmallButton(outfitsPage, L.SAVE, function() ns.AskSaveName(function(entry) ShowOutfitHere(entry.name) end) end, L.SAVE_DESC)
	save:SetPoint("BOTTOMLEFT", outfitsPage, "BOTTOMLEFT", 0, 0)
	local all = Skin.SmallButton(outfitsPage, L.TITLE .. " " .. Skin.GlyphText("chevron", "label"), function() ns.Open() end, L.OPEN_DESC)
	all:SetPoint("BOTTOMRIGHT", outfitsPage, "BOTTOMRIGHT", 0, 0)
	local titlesPage = MakePage("titles", { width = SIDE, rows = 20, rowHeight = 26, titles = false, icon = false, columns = {},
		onClick = function(entry)
			Safe(API("SetCurrentTitle"), entry.id)
			C_Timer.After(0.2, DrawTitles)
		end,
		onDraw = DrawTitles })
	titlesPage.list:Fit(height)
	-- The game's other pages, at the foot (each in the game's own word), and what was said.
	window.pages = {}
	for _, page in ipairs(PAGES) do
		local info = rawget(_G, "characterFrameDisplayInfo")
		local words = info and info[page] and info[page].title or rawget(_G, PAGE_WORDS[page]) or page
		local link = Skin.SmallButton(window, words .. " " .. Skin.GlyphText("chevron", "label"), function() ns.SheetOpenPage(page) end,
			L.GAME_PAGE_DESC, 20)
		link.page = page
		link:Hide()
		window.pages[#window.pages + 1] = link
	end
	window.said = Skin.Text(window, "GameTooltipTextSmall", "muted")
	window.said:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -(margin + SIDE + 24), margin + 4)
	window.said:SetJustifyH("RIGHT")
	window.events = CreateFrame("Frame", nil, window)
	window.events:SetScript("OnEvent", OnEvent)
	drawSoon = U.Debounce(0.1, Draw)
	window:HookScript("OnShow", function(self)
		self:SetScale(Skin.FitScale(self))
		Listen(true)
		self.model:Look()
		-- (your character comes a little after the window, slowly: the time for its model to be dressed)
		BreatheIn(self.model, 0.45, 0.1)
		ShowPage(DB().sheetPage or "stats")
		Draw(true)
	end)
	window:HookScript("OnHide", function()
		Listen(false)
		BreatheAll()
		hovered = nil
		if flyout then flyout:Hide() end
		local card = ns.OutfitCard and ns.OutfitCard()
		if card and card:IsShown() and card.owner and pages.outfits and card.owner:GetParent() == pages.outfits.list then card:Hide() end
		-- Closed here (its cross, Escape): the game's sheet closes with it.
		if leaving then return end
		local sheet = Game()
		if sheet and sheet:IsShown() and U.IsOffScreen(sheet) then
			if HideUIPanel then Safe(HideUIPanel, sheet) else sheet:Hide() end
		end
	end)
	Skin.Get(window):Layout()
	return window
end
ns.Sheet = function() return window end -- (tests)

-- (Init only, once Wanderer's check has passed)
function ns.InitSheet()
	if not (Skin.AsideGameWindow and Skin.Card and Skin.Tabs and U.ItemClick) then return end
	Hook()
	-- (the game's sheet made later: hooked at its first opening)
	if not hooked and API("ToggleCharacter") then
		hooksecurefunc("ToggleCharacter", function() if not hooked then Hook() end end)
	end
	-- (a setting changed, Outfits turned off: the sheet wanted now is the one shown)
	ns.OnChanged(function()
		Sync()
		if window and window:IsShown() then drawSoon() end
	end)
end
