local ADDON, ns = ...
local L = ns.L

-- The window: your outfits, each row saying when it goes on by itself and what it is now (worn, the pieces that
-- differ, a piece in the bank, one missing), "Wear" on each, keys 1 to 9 under the mouse; a right click (or "...")
-- opens its card: its pieces in a strip (a click leaves one aside, or takes it again), wear, when (a situation),
-- make it again from what you wear (asked first), rename, its icon, take them from the bank.
-- Below, what you wear kept under a name, and the fishing pole in hand or your weapons back. A key (to bind) opens
-- a small card at the mouse to choose an outfit, or the pole, anywhere.

local W = Wanderer
local U = W and W.Util
local Skin = W and W.Skin

local WIDTH, ROWS, ROW_HEIGHT = 440, 5, 54
local STRIP_SQUARE, STRIP_GAP, STRIP_PER_ROW = 22, 3, 10
local STRIP_HINT = 16 -- the line under the pieces
local WHEN_WIDTH, WHEN_BUTTON = 266, 22
local ICON_CHOICE = 28
local POLE_ICON = "Interface\\Icons\\INV_Fishingpole_02"
local RENAME_ICON = "Interface\\Buttons\\UI-GuildButton-PublicNote-Up"
local BANKER = "Interface\\Minimap\\Tracking\\Banker"

local window, list, pole

local function Settings() return W and W.Settings and W.Settings("outfits") or nil end
ns.Settings = Settings

-- (Outfits off: neither its window nor its keys)
local function On()
	local settings = Settings()
	return settings and settings.enabled
end

-- Wanderer Bags, when it is there: what it offers to an outfit (its pieces taken from the bank).
local function Bags()
	return type(WandererBags) == "table" and WandererBags or nil
end

-- What you wear kept under a name: an outfit of that name already there is replaced only once you said yes.
function ns.AskSave(name)
	name = type(name) == "string" and strtrim(name) or ""
	if name == "" then return end
	local function Save()
		if not ns.SaveSet(name) then return end
		Skin.Play("confirm")
		-- (the game's manager may add a new one a moment later: its card opened once it is there)
		ns.AwaitSet(name, function(entry) if entry then ns.ShowOutfit(entry.name) end end)
	end
	for _, set in ipairs(ns.Sets()) do
		if set.name == name then return Skin.Ask(L.SAVE_REPLACE_ASK:format(name), Save) end
	end
	Save()
end

-- An outfit's card opened beside its row (the window opened first): just made, its pieces to choose, its moment.
function ns.ShowOutfit(name)
	ns.Open()
	local sets = ns.Sets()
	for index, set in ipairs(sets) do
		if set.name == name then
			-- (its row in sight: the list scrolled to it)
			if list.offset > index - 1 or list.offset + list.count < index then
				list.offset = index - 1
				ns.Changed()
			end
			for _, row in ipairs(list.rows) do
				if row.entry and row.entry.name == name then
					local open = ns.OutfitCard()
					if not (open and open:IsShown() and open.entry and open.entry.name == name) then ns.OpenCard(row, row.entry) end
					return
				end
			end
		end
	end
end

-- An outfit for a moment, chosen in a menu: made from what you wear, its card opened to choose its pieces.
function ns.MomentMenu(owner)
	U.Menu(owner, function(_, menu)
		menu:CreateTitle(L.FOR_MOMENT_TITLE)
		for _, kind in ipairs(ns.SITUATIONS) do
			menu:CreateButton(L["WHEN_" .. kind:upper()], function()
				-- (the game's manager may make it a moment later: shown once it is there)
				ns.CreateFor(kind, function(entry)
					if not entry then return end
					Skin.Play("confirm")
					ns.ShowOutfit(entry.name)
				end)
			end)
		end
	end)
end

-- Asked while Outfits is off (its key, its slash): said each time, never a silent key.
local function SayOff() W.Print(L.EXT_TURNED_OFF:format(L.TITLE)) end

local function Color(text, role)
	local c = Skin.COLORS[role] or Skin.COLORS.muted
	text:SetTextColor(c[1], c[2], c[3])
end

-- What an outfit is now, in a few words and a color: a piece missing, in the bank, the pieces that differ, else
-- how many pieces.
local function StateLine(entry, summary)
	local function Names(pieces, slots)
		local words = {}
		for _, piece in ipairs(pieces) do words[#words + 1] = slots and ns.SlotName(piece.slot) or ns.PieceName(piece) end
		return table.concat(words, ", ")
	end
	if summary.missing[1] then return L.ROW_MISSING:format(Names(summary.missing)), "bad" end
	if summary.bank[1] then return L.ROW_IN_BANK:format(Names(summary.bank)), "blue" end
	if not entry.equipped and summary.bags[1] then return L.ROW_DIFFERS:format(Names(summary.bags, true)), "soft" end
	return L.ROW_PIECES:format(summary.total), "muted"
end

-- When an outfit goes on by itself, in a few words ("On a mount", "In Eastern Plaguelands"), or nil.
function ns.WhenWords(name)
	local when = ns.When(name)
	if not when then return nil end
	if when.kind == "zone" then
		local zones = {}
		for zone in pairs(when.zones or {}) do zones[#zones + 1] = zone end
		table.sort(zones)
		return zones[1] and L.WHEN_IN:format(table.concat(zones, ", ")) or L.WHEN_ZONE
	end
	return L["WHEN_" .. when.kind:upper()]
end

-- The card of an outfit ---------------------------------------------------------------------------------------

local card, strip, renameBox, icons, whenBox

-- Its pieces in a strip, head to ranged: plain when worn, a gold edge when to put on, faded with the banker's sign
-- in the bank, greyed with a red edge when missing; a slot it leaves out stays empty.
local function MakeStrip()
	strip = CreateFrame("Frame", nil, card)
	strip:SetSize(STRIP_PER_ROW * STRIP_SQUARE + (STRIP_PER_ROW - 1) * STRIP_GAP, 2 * STRIP_SQUARE + STRIP_GAP + STRIP_HINT)
	strip.hint = Skin.Text(strip, "GameTooltipTextSmall", "muted")
	strip.hint:SetPoint("BOTTOMLEFT", strip, "BOTTOMLEFT", 0, 0)
	strip.hint:SetText(L.STRIP_HINT)
	strip.squares = {}
	for index, slot in ipairs(ns.SLOTS) do
		local square = Skin.Icon(strip, STRIP_SQUARE)
		local column, line = (index - 1) % STRIP_PER_ROW, math.floor((index - 1) / STRIP_PER_ROW)
		square:SetPoint("TOPLEFT", strip, "TOPLEFT", column * (STRIP_SQUARE + STRIP_GAP), -line * (STRIP_SQUARE + STRIP_GAP))
		square:EnableMouse(true)
		square.bank = square:CreateTexture(nil, "OVERLAY")
		square.bank:SetSize(10, 10)
		square.bank:SetPoint("BOTTOMRIGHT", square, "BOTTOMRIGHT", 1, -1)
		square.bank:SetTexture(BANKER)
		square.slot = slot
		Skin.ItemTooltip(square, function(self) return self.link or self.id end, "ANCHOR_BOTTOM")
		-- (a click: this piece left aside by the outfit, or taken again)
		square:SetScript("OnMouseUp", function(self, button)
			if button ~= "LeftButton" or not (self.piece and card and card.entry) then return end
			Skin.Play("click")
			ns.ToggleLeft(card.entry, self.slot)
			ns.FillCard()
		end)
		strip.squares[slot] = square
	end
	strip:Hide()
end

local function PaintStrip(summary)
	local bySlot = {}
	for _, piece in ipairs(summary.pieces) do bySlot[piece.slot] = piece end
	local gold, bad = Skin.COLORS.gold, Skin.COLORS.bad
	for slot, square in pairs(strip.squares) do
		local piece = bySlot[slot]
		square.link, square.id = piece and piece.link, piece and piece.id
		square.piece = piece
		square.bank:SetShown(piece ~= nil and piece.state == "bank")
		if not piece then
			square:Set(nil)
			square:SetAlpha(0.35)
		else
			square:Set(piece.id and U.ItemIcon(piece.id), piece.id and U.ItemQuality(piece.id))
			-- (left aside: faint and grey, it is not part of it)
			square:SetAlpha(piece.left and 0.25 or (piece.state == "bank" and 0.5 or 1))
			if square.texture.SetDesaturated then square.texture:SetDesaturated(piece.left or piece.state == "missing") end
			if not piece.left and piece.state == "bags" then square.edges.Color(gold[1], gold[2], gold[3], 0.9) end
			if not piece.left and piece.state == "missing" then square.edges.Color(bad[1], bad[2], bad[3], 0.9) end
		end
	end
end

-- Its new name, written in the card (Enter keeps it, Escape lets it be).
local function MakeRename()
	renameBox = CreateFrame("Frame", nil, card)
	renameBox:SetSize(266, 24)
	renameBox.input = Skin.CreateInput(renameBox, "WandererOutfitsRename", 30, {
		hint = L.NAME_PROMPT,
		onEnter = function(input)
			local entry = card.entry
			if entry then ns.RenameSet(entry.id, input:GetText()) end
			input:ClearFocus()
			card.mode = nil
			ns.FillCard()
		end,
		onEscape = function(input)
			input:ClearFocus()
			card.mode = nil
			ns.FillCard()
		end,
	})
	renameBox.input:SetAllPoints()
	renameBox:Hide()
end

-- Its icon, chosen among its pieces' and a few of the game's.
local function MakeIcons()
	icons = CreateFrame("Frame", nil, card)
	icons:SetSize(266, ICON_CHOICE)
	icons.buttons = {}
	icons:Hide()
end

local function PaintIcons(entry)
	local choices = ns.IconChoices(entry)
	local gold = Skin.COLORS.gold
	for index, icon in ipairs(choices) do
		local button = icons.buttons[index]
		if not button then
			button = CreateFrame("Button", nil, icons)
			button:SetSize(ICON_CHOICE, ICON_CHOICE)
			button:SetPoint("TOPLEFT", icons, "TOPLEFT", (index - 1) * (ICON_CHOICE + 4), 0)
			button.square = Skin.Icon(button, ICON_CHOICE)
			button.square:SetAllPoints()
			button:SetScript("OnClick", function(self)
				Skin.Play("mark")
				if card.entry then ns.SetIcon(card.entry, self.icon) end
				card.mode = nil
				ns.FillCard()
			end)
			icons.buttons[index] = button
		end
		button.icon = icon
		button.square:Set(icon)
		if icon == entry.icon then button.square.edges.Color(gold[1], gold[2], gold[3], 0.95) end
		button:Show()
	end
	for index = #choices + 1, #icons.buttons do icons.buttons[index]:Hide() end
end

-- When it goes on by itself: one button per situation (the chosen one checked), "Never", and for zones the zone
-- you are in added or taken away.
local function MakeWhen()
	whenBox = CreateFrame("Frame", nil, card)
	whenBox:SetSize(WHEN_WIDTH, WHEN_BUTTON)
	whenBox.buttons = {}
	whenBox.zones = Skin.Text(whenBox, "GameTooltipTextSmall", "soft")
	whenBox.zones:SetWidth(WHEN_WIDTH)
	whenBox.zones:SetJustifyH("LEFT")
	whenBox:Hide()
end

local function WhenButton(index)
	local button = whenBox.buttons[index]
	if not button then
		button = Skin.SmallButton(whenBox, "", function(self) if self.run then self.run() end end, nil, WHEN_BUTTON)
		Skin.Tooltip(button, function(self) return self.tip end)
		whenBox.buttons[index] = button
	end
	return button
end

-- Its buttons laid in lines; the height it took.
local function PaintWhen(entry)
	local when = ns.When(entry.name)
	local chosen = when and when.kind or "never"
	local specs = {}
	for _, kind in ipairs(ns.SITUATIONS) do
		specs[#specs + 1] = { kind = kind, label = L["WHEN_" .. kind:upper()], tip = L["WHEN_" .. kind:upper() .. "_DESC"] }
	end
	specs[#specs + 1] = { kind = "never", label = L.WHEN_NEVER, tip = L.WHEN_NEVER_DESC }
	local here = U.Clean(U.Safe(GetRealZoneText))
	if chosen == "zone" and here then
		local has = when.zones and when.zones[here]
		specs[#specs + 1] = { label = (has and L.ZONE_REMOVE or L.ZONE_ADD):format(here), zone = here }
	end
	local x, y = 0, 0
	for index, spec in ipairs(specs) do
		local button = WhenButton(index)
		local on = spec.kind ~= nil and spec.kind == chosen
		button:SetLabel(on and (Skin.GlyphText("check", "gold", 10) .. " " .. spec.label) or spec.label)
		button:Fit()
		button.tip = spec.tip
		button.run = function()
			Skin.Play("click")
			if spec.zone then
				ns.ToggleZone(entry, spec.zone)
			else
				ns.SetWhen(entry, spec.kind ~= "never" and spec.kind or nil)
			end
			ns.FillCard()
		end
		local width = button:GetWidth() or 60
		if x > 0 and x + width > WHEN_WIDTH then x, y = 0, y + WHEN_BUTTON + 4 end
		button:ClearAllPoints()
		button:SetPoint("TOPLEFT", whenBox, "TOPLEFT", x, -y)
		button:Show()
		x = x + width + 4
	end
	for index = #specs + 1, #whenBox.buttons do whenBox.buttons[index]:Hide() end
	local height = y + WHEN_BUTTON
	-- (the zones chosen, under the buttons)
	local words = chosen == "zone" and ns.WhenWords(entry.name) or nil
	whenBox.zones:ClearAllPoints()
	whenBox.zones:SetPoint("TOPLEFT", whenBox, "TOPLEFT", 0, -(height + 6))
	whenBox.zones:SetText(words or "")
	whenBox.zones:SetShown(words ~= nil)
	if words then height = height + 6 + math.ceil(U.Measure(whenBox.zones, "GetStringHeight", 12)) end
	whenBox:SetHeight(height)
	return height
end

-- The outfit as it is now (drawn again after a change: found again by its id, its name first).
local function Current(entry)
	for _, set in ipairs(ns.Sets()) do
		if set.id == entry.id and set.name == entry.name then return set end
	end
	for _, set in ipairs(ns.Sets()) do
		if set.id == entry.id then return set end
	end
end

function ns.FillCard()
	if not (card and card.entry) then return end
	local entry = Current(card.entry)
	if not entry then return card:Hide() end
	card.entry = entry
	local summary = ns.Summary(entry)
	local now, role
	if entry.equipped then
		now, role = L.CHIP_WORN, "good"
	elseif summary.missing[1] then
		now, role = L.STATE_MISSING:format(#summary.missing), "bad"
	elseif summary.bank[1] then
		now, role = L.STATE_BANK:format(#summary.bank), "blue"
	elseif summary.bags[1] then
		now, role = L.STATE_DIFFERS:format(#summary.bags), "soft"
	else
		now, role = L.ROW_PIECES:format(summary.total), "muted"
	end
	-- The block under the heading: the pieces, or the name being written, or the icons to choose from.
	local body, height = strip, strip:GetHeight()
	if card.mode == "rename" then
		body, height = renameBox, 24
	elseif card.mode == "icon" then
		PaintIcons(entry)
		body, height = icons, ICON_CHOICE
	elseif card.mode == "when" then
		body, height = whenBox, PaintWhen(entry)
	else
		PaintStrip(summary)
	end
	for _, frame in ipairs({ strip, renameBox, icons, whenBox }) do
		if frame ~= body then frame:Hide() end
	end
	local id = entry.id
	local tiles = {
		{ sign = { file = entry.icon }, label = entry.equipped and L.CHIP_WORN or L.ACT_WEAR, tip = L.CARD_WEAR_TIP, on = entry.equipped,
			run = function() ns.WearSet(id) end },
		{ sign = { glyph = "bell" }, label = L.WHEN, tip = L.WHEN_TIP, on = card.mode == "when", stay = true, run = function()
			card.mode = card.mode ~= "when" and "when" or nil
			ns.FillCard()
		end },
		{ sign = { glyph = "reload" }, label = L.CARD_AGAIN, tip = L.ACT_UPDATE, run = function() ns.AskSave(entry.name) end },
		{ sign = { file = RENAME_ICON }, label = L.CARD_RENAME_TILE, tip = L.CARD_RENAME_TIP, on = card.mode == "rename", stay = true, run = function()
			card.mode = card.mode ~= "rename" and "rename" or nil
			ns.FillCard()
			if card.mode == "rename" then
				renameBox.input:SetText(entry.name)
				renameBox.input:SetFocus()
				if renameBox.input.HighlightText then renameBox.input:HighlightText() end
			end
		end },
		{ sign = { glyph = "grid" }, label = L.CARD_ICON, tip = L.CARD_ICON_TIP, on = card.mode == "icon", stay = true, run = function()
			card.mode = card.mode ~= "icon" and "icon" or nil
			ns.FillCard()
		end },
	}
	local rows = {}
	local bags = Bags()
	-- At the banker, with Wanderer Bags: its pieces waiting there, taken in one click.
	if bags and summary.bank[1] and type(bags.TakeFromBank) == "function" and type(bags.AtBank) == "function" and bags.AtBank() then
		local wants = {}
		for _, piece in ipairs(summary.bank) do if piece.id then wants[piece.id] = (wants[piece.id] or 0) + 1 end end
		rows[#rows + 1] = { main = true, text = L.CARD_TAKE_BANK:format(#summary.bank), run = function() bags.TakeFromBank(wants) end }
	end
	rows[#rows + 1] = { text = L.CARD_REMOVE, role = "bad", run = function()
		card:Hide()
		Skin.Ask(L.REMOVE_ASK:format(entry.name), function() ns.DeleteSet(id) end)
	end }
	-- (when it goes on by itself, said with what it is now)
	local whenWords = ns.WhenWords(entry.name)
	if whenWords then now = whenWords .. "  ·  " .. now end
	card:Fill({ title = entry.name, titleColor = "gold", icon = entry.icon, now = now, body = body, bodyHeight = height,
		tiles = tiles, rows = rows, keys = L.CARD_KEYS, minWidth = strip:GetWidth() })
	Color(card.now, role)
end

-- Beside its row; again on the same outfit: closed.
local function OpenCard(owner, entry)
	if not card then
		card = Skin.Card("WandererOutfitsCard", true)
		card.onHide = function(self)
			self.entry, self.mode = nil, nil
			if renameBox then renameBox.input:ClearFocus() end
		end
		MakeStrip()
		MakeRename()
		MakeIcons()
		MakeWhen()
	end
	if card:IsShown() and card.entry and card.entry.id == entry.id and card.owner == owner then return card:Hide() end
	card.valid = nil
	card.entry, card.mode = entry, nil
	ns.FillCard()
	card:Present(owner)
	-- (its row showing another outfit, after a scroll: the card goes)
	card.valid = function() return owner.entry ~= nil and owner.entry.id == entry.id end
end
ns.OpenCard = OpenCard
ns.OutfitCard = function() return card end -- (tests)

-- The window ---------------------------------------------------------------------------------------------------

-- A row's own pieces, made once: its number (its key), what it is now under its name, the "Worn" chip, its "...".
local function Decorate(row)
	if row.state then return end
	row.number = Skin.Text(row.icon, "GameTooltipTextSmall", "muted")
	row.number:SetPoint("TOPLEFT", row.icon, "TOPLEFT", 3, -2)
	row.state = Skin.Text(row, "GameTooltipTextSmall", "muted")
	if row.state.SetWordWrap then row.state:SetWordWrap(false) end
	row.worn = Skin.Chip(row)
	row.worn:SetPoint("RIGHT", row, "RIGHT", -10, 0)
	-- (left of the Wear button's column, where the "Worn" chip stands too)
	row.menu = Skin.RowMore(row, function(owner) if owner.entry then OpenCard(owner, owner.entry) end end, row.action)
end

local function Draw()
	if not (window and window:IsShown()) then return end
	if not On() then return window:Hide() end
	local sets = ns.Sets()
	window.sets = sets
	local offset = list:Clamp(#sets)
	-- (the bags read once for every row; the name's room: the Wear column and the "⋯")
	local bagIndex = ns.BagIndex()
	local inset = 6 + 70 + 4 + Skin.ROW_MORE + 4
	for index, row in ipairs(list.rows) do
		local set = sets[offset + index]
		if set then
			local summary = ns.Summary(set, bagIndex)
			row:Fill({ id = set.id, name = set.name, icon = set.icon, equipped = set.equipped, color = set.equipped and Skin.COLORS.gold or nil,
				tip = { set.name, L.ROW_TIP } }, set.equipped, {}, nil, nil, not set.equipped and L.ACT_WEAR or nil, function() ns.WearSet(set.id) end)
			Decorate(row)
			-- Two lines: its name, then what it is now.
			row.name:ClearAllPoints()
			row.name:SetPoint("LEFT", row.icon, "RIGHT", 10, 8)
			row.name:SetPoint("RIGHT", row, "RIGHT", -inset, 8)
			local text, role = StateLine(set, summary)
			-- (when it goes on by itself, first)
			local whenWords = ns.WhenWords(set.name)
			if whenWords then text = Skin.Colorize(whenWords, "gold") .. "  ·  " .. text end
			row.state:ClearAllPoints()
			row.state:SetPoint("TOPLEFT", row.name, "BOTTOMLEFT", 0, -4)
			row.state:SetPoint("RIGHT", row, "RIGHT", -inset, 0)
			row.state:SetText(text)
			Color(row.state, role)
			row.state:Show()
			row.number:SetText(offset + index <= 9 and tostring(offset + index) or "")
			row.worn:Set(set.equipped and L.CHIP_WORN or nil, "gold")
		else
			row:Fill(nil)
			if row.state then
				row.state:Hide()
				row.worn:Set(nil)
			end
		end
	end
	list.empty:SetShown(#sets == 0)
	pole:SetText(U.HasFishingPole() and L.WEAPONS_BACK or L.POLE_IN_HAND)
	window.undo:SetShown(ns.CanUndo())
	pole:Fit()
	window.where:SetText(ns.GameKeepsSets() and L.KEPT_BY_GAME or L.KEPT_BY_WANDERER)
	if card and card:IsShown() and card.mode ~= "rename" then ns.FillCard() end
end

-- Keys 1 to 9 while the mouse is over the window: the outfit of that number worn. Never in a fight (the game keeps
-- the keys then); every other key goes on to the game.
local function Keys(on)
	on = on and not InCombatLockdown()
	if window.EnableKeyboard then pcall(window.EnableKeyboard, window, on and true or false) end
	if on and window.SetPropagateKeyboardInput then pcall(window.SetPropagateKeyboardInput, window, true) end
end

local function OnKey(self, key)
	if InCombatLockdown() then return end
	local index = tonumber(type(key) == "string" and (key:match("^NUMPAD(%d)$") or key) or "")
	local set = index and index >= 1 and self:IsMouseOver() and self.sets and self.sets[index] or nil
	if self.SetPropagateKeyboardInput then pcall(self.SetPropagateKeyboardInput, self, set == nil) end
	if set then
		Skin.Play("click")
		ns.WearSet(set.id)
	end
end

local function Create()
	window = Skin.CreateWindow("WandererOutfitsWindow", "MEDIUM")
	Skin.Sounds(window, Skin.SOUNDS.open, Skin.SOUNDS.close)
	Skin.Dress(window, { "CENTER", UIParent, "CENTER", 0, 40 }, "outfitsPos")
	-- (a cog to its settings page)
	local _, title, margin = Skin.Header(window, "Wanderer", L.TITLE, { settings = "ext:outfits" })
	list = Skin.Table(window, {
		width = WIDTH - margin * 2, rows = ROWS, rowHeight = ROW_HEIGHT, action = 70, nameTitle = L.COL_OUTFIT, columns = {},
		onClick = function(entry, mouse)
			if mouse == "RightButton" then
				for _, row in ipairs(list.rows) do
					if row.entry == entry then return OpenCard(row, entry) end
				end
				return
			end
			ns.WearSet(entry.id)
		end,
		onDraw = Draw,
	})
	list:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -12)
	list.empty:SetText(L.EMPTY)
	window.where = Skin.Text(window, "GameTooltipTextSmall", "muted")
	window.where:SetPoint("TOPLEFT", list, "BOTTOMLEFT", 0, -6)
	window.where:SetPoint("RIGHT", list, "RIGHT", 0, 0)
	window.where:SetJustifyH("LEFT")
	window.where:SetHeight(28)
	window.where:SetJustifyV("TOP")
	local save = Skin.Button(window, L.SAVE, function()
		-- (a name already used: replacing that outfit is asked first)
		-- (with a controller nothing is typed: a free name already written, kept or changed)
		local name = ""
		if U.UsingPad and U.UsingPad() then
			local used, number = {}, #ns.Sets() + 1
			for _, entry in ipairs(ns.Sets()) do used[entry.name] = true end
			while used[L.PAD_NAME:format(number)] do number = number + 1 end
			name = L.PAD_NAME:format(number)
		end
		Skin.AskText(L.NAME_PROMPT, name, function(typed) ns.AskSave(typed) end, 30)
	end, "main")
	save:SetPoint("BOTTOMLEFT", window, "BOTTOMLEFT", margin, margin)
	Skin.Tooltip(save, L.SAVE_DESC)
	-- (a secondary action: a quiet button; the help in the heading, the foot left to the two buttons)
	-- (an outfit for a moment: the way most outfits are worth making)
	local moment = Skin.SmallButton(window, L.FOR_MOMENT, function(self) ns.MomentMenu(self) end, L.FOR_MOMENT_DESC)
	moment:SetPoint("LEFT", save, "RIGHT", 8, 0)
	pole = Skin.SmallButton(window, L.POLE_IN_HAND, function() ns.TogglePole() end, L.POLE_DESC)
	pole:SetPoint("LEFT", moment, "RIGHT", 6, 0)
	-- (the last change undone, at the far right: shown only when there is one)
	window.undo = Skin.GlyphButton(window, "undo", 18, L.UNDO_DESC, function() ns.Undo() end)
	window.undo:SetPoint("BOTTOMRIGHT", window, "BOTTOMRIGHT", -margin, margin + 4)
	Skin.Help(window, L.HELP_TIP, "HEADING")
	window:SetSize(WIDTH, margin * 2 + 30 + 12 + list:GetHeight() + 6 + 28 + 12 + 36)
	window:SetScript("OnKeyDown", OnKey)
	window:SetScript("OnEvent", function(_, event) Keys(event == "PLAYER_REGEN_ENABLED") end)
	window:HookScript("OnShow", function(self)
		self:SetScale(Skin.FitScale(self))
		pcall(self.RegisterEvent, self, "PLAYER_REGEN_DISABLED")
		pcall(self.RegisterEvent, self, "PLAYER_REGEN_ENABLED")
		Keys(true)
		Draw()
	end)
	window:HookScript("OnHide", function(self)
		pcall(self.UnregisterEvent, self, "PLAYER_REGEN_DISABLED")
		pcall(self.UnregisterEvent, self, "PLAYER_REGEN_ENABLED")
		Keys(false)
		if card then card:Hide() end
	end)
	Skin.Get(window):Layout()
end

function ns.Toggle()
	if not On() then return SayOff() end
	if not window then Create() end
	window:SetShown(not window:IsShown())
end

function ns.Open()
	if not window then Create() end
	window:Show()
end
ns.Window = function() return window end -- (tests)

-- Choosing an outfit anywhere: a card at the mouse ----------------------------------------------------------------
-- One tile per outfit (its icon, its name, the one worn in gold, keys 1 to 9), and the pole last (in hand, or your
-- weapons back). Escape or a click elsewhere closes it.

local switcher
local MAX_OUTFITS = 8 -- (and the pole: nine keys)

local function PoleIcon()
	if U.HasFishingPole() then return U.Clean(U.Safe(GetInventoryItemTexture, "player", INVSLOT_MAINHAND or 16)) or POLE_ICON end
	local found = ns.PoleInBags()
	return found and found.link and U.ItemIcon(U.ItemID(found.link)) or POLE_ICON
end

function ns.FillSwitcher()
	if not switcher then return end
	local sets, tiles, worn = ns.Sets(), {}, nil
	for index, set in ipairs(sets) do
		if index > MAX_OUTFITS then break end
		if set.equipped then worn = set.name end
		tiles[#tiles + 1] = { sign = { file = set.icon }, label = set.name, tip = set.equipped and L.SWITCH_WORN_TIP or L.SWITCH_WEAR_TIP,
			on = set.equipped, run = function() ns.WearSet(set.id) end }
	end
	-- The pole: shown when there is one, in hand or in the bags.
	local inHand = U.HasFishingPole()
	if inHand or ns.PoleInBags() then
		tiles[#tiles + 1] = { sign = { file = PoleIcon() }, label = inHand and L.POLE_TILE_IN_HAND or L.POLE_TILE,
			tip = inHand and L.POLE_TILE_BACK_TIP or L.POLE_DESC, on = inHand and true or false, run = function() ns.TogglePole() end }
	end
	-- (the last change undone; more outfits than tiles: said, and the window a click away)
	local rows = {}
	if ns.CanUndo() then rows[#rows + 1] = { text = L.UNDO, sign = "undo", run = function() ns.Undo() end } end
	if #sets > MAX_OUTFITS then
		rows[#rows + 1] = { text = L.SWITCH_MORE:format(#sets - MAX_OUTFITS), sign = "chevron", run = function() switcher:Hide() ns.Open() end }
	end
	switcher:Fill({ title = L.TITLE, now = worn and L.SWITCH_NOW:format(worn) or (sets[1] and L.SWITCH_NONE or L.EMPTY),
		tiles = tiles, perRow = 5, minWidth = 266, keys = tiles[1] and L.SWITCH_KEYS:format(#tiles) or "", rows = rows[1] and rows or nil })
end

-- The card at the mouse, or closed when it is open.
function ns.Choose()
	if not On() then return SayOff() end
	if not switcher then switcher = Skin.Card("WandererOutfitsSwitcher", false) end
	if switcher:IsShown() then return switcher:Hide() end
	ns.FillSwitcher()
	switcher:Present(nil)
end
ns.Switcher = function() return switcher end -- (tests)

-- Init -----------------------------------------------------------------------------------------------------

BINDING_HEADER_WANDEREROUTFITS = "Wanderer Outfits"
BINDING_NAME_WANDEREROUTFITS_TOGGLE = L.TITLE
BINDING_NAME_WANDEREROUTFITS_POLE = L.BINDING_POLE
BINDING_NAME_WANDEREROUTFITS_CHOOSE = L.BINDING_CHOOSE
BINDING_NAME_WANDEREROUTFITS_UNDO = L.UNDO
function WandererOutfits_Toggle() ns.Toggle() end
function WandererOutfits_Pole() if On() then ns.TogglePole() else SayOff() end end
function WandererOutfits_Choose() ns.Choose() end
function WandererOutfits_Undo() if On() then ns.Undo() else SayOff() end end

function ns.Init()
	if not (W and W.RegisterExtension) then return end
	-- (built on Wanderer's API 15: an older Wanderer is only asked to update, nothing of it is called)
	if (W.API or 1) < 15 then return W.Print(L.NEEDS_WANDERER) end
	W.RegisterExtension({
		key = "outfits",
		addon = ADDON,
		slash = "/woutfits",
		title = L.ADDON,
		news = L.NEWS_LINES,
		-- (the situations: on, but nothing happens until an outfit is tied to one)
		defaults = { enabled = true, situations = true, suggest = true, poleOnCast = true, weaponsOnMount = true },
		launcher = { label = L.TITLE, open = function() ns.Toggle() end },
		refresh = function() ns.Changed() end,
		-- (as every page: the switch, its window, what is done for you)
		options = function(o)
			local enabled = o.Checkbox("outfits", "enabled", L.ENABLE, L.ENABLE_DESC, ns.Changed)
			local on = o.IsOn("outfits", "enabled")
			o.Under(o.Button(L.TITLE, L.OPEN, L.OPEN_DESC, function()
				o.CloseSettings()
				ns.Open()
			end), enabled, on)
			-- (an option whose job another addon does, ItemRack: greyed, with its name)
			local function Yield(widget) return o.Yield(widget, "gearSwap") end
			o.Header(L.SECTION_AUTOMATIONS)
			-- (Naowh Forever's sets changing your gear themselves: the situations step aside, and say so)
			if ns.NaowhSwaps() then
				o.Under(o.Checkbox("outfits", "situations", L.SITUATIONS_ASIDE, L.WEAPONS_ON_MOUNT_ASIDE_DESC), enabled, function() return false end)
			else
				o.Under(Yield(o.Checkbox("outfits", "situations", L.SITUATIONS, L.SITUATIONS_DESC, ns.Changed)), enabled, on)
			end
			o.Under(o.Checkbox("outfits", "suggest", L.SUGGEST, L.SUGGEST_DESC), enabled, on)
			local onCast = o.Checkbox("outfits", "poleOnCast", L.POLE_ON_CAST, L.POLE_ON_CAST_DESC)
			o.Under(Yield(onCast), enabled, on)
			-- (it acts on Wanderer's fishing double click: greyed while that is off, saying so)
			o.Needs(onCast, function()
				local fishing = W.Settings("fishing")
				return fishing and fishing.doubleClick and true or false
			end, L.FISHING_DOUBLE_CLICK)
			-- (Naowh Forever's gear sets changing your gear themselves: this one steps aside, and says so)
			if ns.NaowhSwaps() then
				o.Under(o.Checkbox("outfits", "weaponsOnMount", L.WEAPONS_ON_MOUNT_ASIDE, L.WEAPONS_ON_MOUNT_ASIDE_DESC), enabled,
					function() return false end)
			else
				local onMount = o.Checkbox("outfits", "weaponsOnMount", L.WEAPONS_ON_MOUNT, L.WEAPONS_ON_MOUNT_DESC)
				o.Under(Yield(onMount), enabled, on)
				-- (the pole on cast already gives your weapons back on a mount: greyed then, saying so)
				o.Needs(onMount, function()
					local settings = Settings()
					return not (settings and settings.poleOnCast)
				end, L.MOUNT_IN_POLE_ON_CAST)
			end
		end,
	})
	SLASH_WANDEREROUTFITS1 = "/woutfits"
	SlashCmdList.WANDEREROUTFITS = function(text)
		text = (text or ""):lower()
		-- (what Outfits sees of the pole and your weapons, said in the chat: /woutfits debug)
		if text:find("debug", 1, true) then return ns.PoleDebug() end
		if text:find("pole", 1, true) then return WandererOutfits_Pole() end
		if text:find("choose", 1, true) then return WandererOutfits_Choose() end
		if text:find("undo", 1, true) then return WandererOutfits_Undo() end
		ns.Toggle()
	end
	ns.InitSets()
	ns.InitSituations()
	ns.InitPresence()
	ns.OnChanged(Draw)
	-- (Outfits turned off with the card at the mouse open: it goes, as the window does)
	ns.OnChanged(function()
		if not (switcher and switcher:IsShown()) then return end
		if On() then ns.FillSwitcher() else switcher:Hide() end
	end)
	-- For Wanderer Bags: your outfits' pieces (never sold, their own section), those waiting in the bank.
	WandererOutfits = { Pieces = function() return ns.PieceMap() end, BankPieces = function() return ns.BankPieces() end,
		Toggle = function() ns.Toggle() end, Choose = function() ns.Choose() end }
	ns.TellBags()
end

if W and W.WhenLoaded then W.WhenLoaded(ADDON, ns.Init) elseif W and W.Print then W.Print(L.NEEDS_WANDERER) end
