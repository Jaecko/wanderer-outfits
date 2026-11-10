local _, ns = ...
local L = ns.L

-- Outfits: what you wear, kept under a name and put back in one click. The
-- game's own equipment manager holds them when this client has it (they stay
-- yours in its window too); else Wanderer keeps them for each character and
-- dresses you piece by piece, out of a fight (asked in one, done once it
-- ends). An outfit may leave some of its pieces aside (a riding outfit: only
-- its trinket and its boots): those slots are never touched by it. The
-- fishing pole: in hand on a word, your weapons back after (or when you
-- mount, an option). The situations that put an outfit on by themselves:
-- Situations.lua.

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean

local SLOTS = { 1, 2, 3, 15, 5, 4, 19, 9, 10, 6, 7, 8, 11, 12, 13, 14, 16, 17, 18 } -- the worn slots, head to ranged
local MAIN_HAND, OFF_HAND = INVSLOT_MAINHAND or 16, INVSLOT_OFFHAND or 17
local STEP = 0.3 -- seconds between two pieces
local PASSES = 3 -- a piece refused is asked again this many times
local BUSY_WAIT = 15 -- seconds at most the pieces wait for a cast (skinning, gathering) or a loot window to end

local function DB()
	WandererOutfitsDB = type(WandererOutfitsDB) == "table" and WandererOutfitsDB or {}
	local db = WandererOutfitsDB
	-- (sets: Wanderer's own outfits; left: outfit name -> the slots it leaves aside; when: outfit name -> its
	-- situation, Situations.lua)
	for _, part in ipairs({ "sets", "left", "when", "told" }) do
		if type(db[part]) ~= "table" then db[part] = {} end
	end
	return db
end
ns.DB = DB

-- The game's own manager, when this client has it.
local function GameSets()
	local api = C_EquipmentSet
	return api and api.GetEquipmentSetIDs and api.GetEquipmentSetInfo and api.UseEquipmentSet and api.SaveEquipmentSet
		and api.CreateEquipmentSet and api.DeleteEquipmentSet and api or nil
end
function ns.GameKeepsSets() return GameSets() ~= nil end

-- What is worn now: slot -> item link.
local function Worn()
	local worn = {}
	for _, slot in ipairs(SLOTS) do
		local link = Clean(Safe(GetInventoryItemLink, "player", slot))
		if link then worn[slot] = link end
	end
	return worn
end
ns.Worn = Worn

-- The same piece: its item and its suffix ("of the Eagle", "of the Monkey"), whatever the link's passing fields
-- (an enchant, a level) say.
local function Piece(link) return link:match("item:(%-?%d+):[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:(%-?%d*)") end
local function Same(a, b)
	if a == nil or b == nil then return false end
	local id, suffix = Piece(a)
	local id2, suffix2 = Piece(b)
	if not (id and id2) then return U.ItemID(a) == U.ItemID(b) end
	return id == id2 and (tonumber(suffix) or 0) == (tonumber(suffix2) or 0)
end
ns.Same = Same

-- The very copy: the same item with the same enchant, gems and suffix (two copies of a ring told apart).
local function Exact(a, b)
	if a == nil or b == nil then return false end
	local fa, fb = a:match("item:([%-%d:]+)"), b:match("item:([%-%d:]+)")
	if not (fa and fb) then return Same(a, b) end
	local function Fields(text)
		local list = {}
		for field in (text .. ":"):gmatch("([^:]*):") do list[#list + 1] = tonumber(field) or 0 end
		return list
	end
	local la, lb = Fields(fa), Fields(fb)
	for index = 1, 7 do
		if (la[index] or 0) ~= (lb[index] or 0) then return false end
	end
	return true
end
ns.Exact = Exact

-- The slots an outfit leaves aside (by its name): slot -> true.
local function Left(name) return name and DB().left[name] or nil end
function ns.LeftSlots(name) return Left(name) or {} end

-- A piece left aside, or taken again (a click on it in the outfit's card).
function ns.ToggleLeft(entry, slot)
	if not (entry and entry.name and slot) then return end
	local left = DB().left
	local mine = left[entry.name] or {}
	mine[slot] = not mine[slot] or nil
	left[entry.name] = next(mine) and mine or nil
	ns.Changed()
	-- (a piece left aside is no longer the outfit's for Wanderer Bags, and back again: read there anew)
	ns.TellBags()
end

-- The outfits: { { id, name, icon, equipped } }, the game's or Wanderer's.
function ns.Sets()
	local list = {}
	local api = GameSets()
	if api then
		for _, id in ipairs(Safe(api.GetEquipmentSetIDs) or {}) do
			local name, icon, _, equipped = Safe(api.GetEquipmentSetInfo, id)
			name, icon = Clean(name), Clean(icon)
			if name then list[#list + 1] = { id = id, name = name, icon = icon, equipped = Clean(equipped) and true or false } end
		end
		-- (one that leaves pieces aside: worn when every piece it takes is)
		-- (the bags read once for all of them)
		local index
		for _, entry in ipairs(list) do
			if Left(entry.name) then
				index = index or ns.BagIndex()
				entry.equipped = ns.AllWorn(entry, index)
			end
		end
		return list
	end
	local worn = Worn()
	for index, set in ipairs(DB().sets) do
		local equipped, any, left = true, false, Left(set.name) or {}
		for slot, link in pairs(set.slots or {}) do
			if not left[slot] then
				any = true
				if not Same(worn[slot], link) then equipped = false end
			end
		end
		list[#list + 1] = { id = index, name = set.name, icon = set.icon, equipped = equipped and any }
	end
	return list
end

ns.SLOTS = SLOTS

-- Each slot's name, as the game says it (a piece without one: its own name).
local SLOT_WORDS = { [1] = "HEADSLOT", [2] = "NECKSLOT", [3] = "SHOULDERSLOT", [4] = "SHIRTSLOT", [5] = "CHESTSLOT", [6] = "WAISTSLOT",
	[7] = "LEGSSLOT", [8] = "FEETSLOT", [9] = "WRISTSLOT", [10] = "HANDSSLOT", [11] = "FINGER0SLOT", [12] = "FINGER1SLOT",
	[13] = "TRINKET0SLOT", [14] = "TRINKET1SLOT", [15] = "BACKSLOT", [16] = "MAINHANDSLOT", [17] = "SECONDARYHANDSLOT",
	[18] = "RANGEDSLOT", [19] = "TABARDSLOT" }
function ns.SlotName(slot)
	local word = SLOT_WORDS[slot] and _G[SLOT_WORDS[slot]]
	return type(word) == "string" and word ~= "" and word or nil
end

-- A piece's name: from its link, else from the game.
function ns.PieceName(piece)
	return U.LinkName(piece.link) or (piece.id and U.ItemName(piece.id)) or ns.SlotName(piece.slot) or "?"
end

-- Your bank holds it (as last seen): Wanderer Bags' memory of it, else the game's own count with the bank.
local function BankHas(id)
	if not id then return false end
	local marks = type(WandererBags) == "table" and type(WandererBags.Marks) == "table" and WandererBags.Marks
	if marks and type(marks.BankHas) == "function" then
		-- (none there, or a bank Wanderer Bags never saw: the game's own count still asked)
		local ok, count = pcall(marks.BankHas, id)
		if ok and type(count) == "number" and count > 0 then return true end
	end
	local count = C_Item and C_Item.GetItemCount or _G.GetItemCount
	if not count then return false end
	local all, carried = Clean(Safe(count, id, true)), Clean(Safe(count, id))
	return type(all) == "number" and type(carried) == "number" and all > carried
end
ns.BankHas = BankHas

-- What your bags hold, read once for many outfits: by item, by piece ("id:suffix"), and the items whose link says
-- no suffix (matched by their item alone, as Same does).
local function PieceKey(link)
	local id, suffix = Piece(link)
	return id and (id .. ":" .. (tonumber(suffix) or 0)) or nil
end
function ns.BagIndex()
	local index = { byId = {}, byPiece = {}, loose = {} }
	U.EachBagItem(function(_, _, info)
		local id, link = Clean(info.itemID), Clean(info.hyperlink)
		if id then index.byId[id] = true end
		local key = link and PieceKey(link)
		if key then index.byPiece[key] = true elseif id then index.loose[id] = true end
	end)
	return index
end

-- In your bags: the same piece (a link: its item and suffix), else the same item.
local function InIndex(index, piece)
	if piece.link then
		local key = PieceKey(piece.link)
		if key then return index.byPiece[key] == true or index.loose[U.ItemID(piece.link)] == true end
		return index.byId[U.ItemID(piece.link)] == true
	end
	return piece.id ~= nil and index.byId[piece.id] == true
end

-- An outfit's pieces by slot: slot -> { id, link } (the game's sets know only the items, Wanderer's their links).
local function SetSlots(entry)
	local slots = {}
	local api = GameSets()
	if api then
		local ids = api.GetItemIDs and Safe(api.GetItemIDs, entry.id)
		for slot, id in pairs(type(ids) == "table" and ids or {}) do
			id = Clean(id)
			if type(slot) == "number" and type(id) == "number" and id > 0 then slots[slot] = { id = id } end
		end
		return slots
	end
	local set = DB().sets[entry.id]
	for slot, link in pairs(set and set.slots or {}) do slots[slot] = { id = U.ItemID(link), link = link } end
	return slots
end

-- An outfit's pieces, head to ranged, each with where it is now: "worn", "bags" (to put on), "bank" or "missing".
-- index: the bags already read (ns.BagIndex), for many outfits at once.
local PAIR = { [11] = 12, [12] = 11, [13] = 14, [14] = 13, [16] = 17, [17] = 16 } -- (rings, trinkets, one-handed weapons)
local function WornIn(worn, slot, piece)
	if piece.link then return Same(worn[slot], piece.link) end
	return worn[slot] ~= nil and U.ItemID(worn[slot]) == piece.id
end
function ns.Pieces(entry, index)
	local worn, list = Worn(), {}
	index = index or ns.BagIndex()
	local slots = SetSlots(entry)
	local left = Left(entry.name) or {}
	for _, slot in ipairs(SLOTS) do
		local piece = slots[slot]
		if piece then
			local state
			if WornIn(worn, slot, piece) then state = "worn" end
			if not state and InIndex(index, piece) then state = "bags" end
			-- (worn in the other slot of its pair, a trinket swapped: on you, only to put in its place)
			if not state and PAIR[slot] and WornIn(worn, PAIR[slot], piece) then state = "bags" end
			if not state then state = BankHas(piece.id) and "bank" or "missing" end
			list[#list + 1] = { slot = slot, id = piece.id, link = piece.link, state = state, left = left[slot] == true }
		end
	end
	return list
end

-- What an outfit is now: { pieces, total, bags = { pieces to put on }, bank = { in the bank }, missing = { } } (the
-- pieces it leaves aside counted nowhere).
function ns.Summary(entry, index)
	local pieces = ns.Pieces(entry, index)
	local summary = { pieces = pieces, total = 0, bags = {}, bank = {}, missing = {} }
	for _, piece in ipairs(pieces) do
		if not piece.left then
			summary.total = summary.total + 1
			if summary[piece.state] then table.insert(summary[piece.state], piece) end
		end
	end
	return summary
end

-- Every piece it takes worn now.
function ns.AllWorn(entry, index)
	local summary = ns.Summary(entry, index)
	if summary.total == 0 then return false end
	for _, piece in ipairs(summary.pieces) do
		if not piece.left and piece.state ~= "worn" then return false end
	end
	return true
end

-- Every outfit's pieces: item id -> { outfit names } (for Wanderer Bags: never sold, their own section). A slot
-- an outfit leaves aside is not its piece (an outfit for a moment keeps all you wore, most of it left aside).
function ns.PieceMap()
	local map = {}
	for _, entry in ipairs(ns.Sets()) do
		local left = Left(entry.name) or {}
		for slot, piece in pairs(SetSlots(entry)) do
			if piece.id and not left[slot] then
				map[piece.id] = map[piece.id] or {}
				local list, known = map[piece.id], false
				for _, name in ipairs(list) do if name == entry.name then known = true end end
				if not known then list[#list + 1] = entry.name end
			end
		end
	end
	return map
end

-- The outfits whose missing pieces wait in the bank: { { name, id, ids = { [item id] = how many } } }.
function ns.BankPieces()
	local list, index = {}, ns.BagIndex()
	for _, entry in ipairs(ns.Sets()) do
		local ids, any = {}, false
		for _, piece in ipairs(ns.Pieces(entry, index)) do
			if piece.state == "bank" and piece.id and not piece.left then
				ids[piece.id], any = (ids[piece.id] or 0) + 1, true
			end
		end
		if any then list[#list + 1] = { name = entry.name, id = entry.id, ids = ids } end
	end
	return list
end

-- Wanderer Bags told that the outfits changed (their pieces read again there).
local function TellBags()
	if type(WandererBags) == "table" and type(WandererBags.OutfitsChanged) == "function" then pcall(WandererBags.OutfitsChanged) end
end
ns.TellBags = TellBags

-- A new icon for an outfit (the game's manager keeps its name with it).
function ns.SetIcon(entry, icon)
	if not (entry and icon) then return end
	local api = GameSets()
	if api then
		if api.ModifyEquipmentSet then Safe(api.ModifyEquipmentSet, entry.id, entry.name, icon) end
	else
		local set = DB().sets[entry.id]
		if set then set.icon = icon end
	end
	ns.Changed()
end

-- Icons to choose for an outfit: its own pieces' (chest, weapons, head, shoulders, legs), then a few of the game's.
local GENERIC_ICONS = { "Interface\\Icons\\INV_Chest_Cloth_17", "Interface\\Icons\\INV_Shirt_White_01", "Interface\\Icons\\INV_Fishingpole_02" }
function ns.IconChoices(entry)
	local list, seen = {}, {}
	local slots = SetSlots(entry)
	for _, slot in ipairs({ 5, 16, 17, 1, 3, 7, 18, 15 }) do
		local piece = slots[slot]
		local icon = piece and piece.id and U.ItemIcon(piece.id)
		if icon and not seen[icon] and #list < 5 then list[#list + 1], seen[icon] = icon, true end
	end
	for _, icon in ipairs(GENERIC_ICONS) do
		if not seen[icon] then list[#list + 1], seen[icon] = icon, true end
	end
	return list
end

-- Said when an outfit could not be put on whole: which pieces are in your bank, which were not found (a piece in
-- your bags refused, for want of room or level: the plain line).
local function SayLeft(pieces)
	local bank, lost = {}, {}
	for _, piece in ipairs(pieces) do
		local name = piece.link or ns.PieceName(piece)
		if piece.state == "bank" then bank[#bank + 1] = name elseif piece.state == "missing" then lost[#lost + 1] = name end
	end
	local parts = {}
	if bank[1] then parts[#parts + 1] = L.MSG_IN_BANK:format(table.concat(bank, ", ")) end
	if lost[1] then parts[#parts + 1] = L.MSG_NOT_FOUND:format(table.concat(lost, ", ")) end
	if not parts[1] then return W.Print(L.MSG_NOT_ALL) end
	W.Print(L.MSG_NOT_ALL_NAMED:format(table.concat(parts, "; ")))
end
ns.SayLeft = SayLeft

-- An icon for an outfit: its chest's, else its main hand's, else its head's.
local function IconOf(slots)
	for _, slot in ipairs({ 5, MAIN_HAND, 1 }) do
		local link = slots[slot]
		local icon = link and U.ItemIcon(U.ItemID(link))
		if icon then return icon end
	end
	return "Interface\\Icons\\INV_Chest_Cloth_17"
end

-- What you wear, kept under a name (a name already used: that outfit made again).
function ns.SaveSet(name)
	name = type(name) == "string" and strtrim(name) or ""
	if name == "" then return false end
	local api = GameSets()
	if api then
		if api.ClearIgnoredSlotsForSave then Safe(api.ClearIgnoredSlotsForSave) end
		for _, set in ipairs(ns.Sets()) do
			if set.name == name then
				Safe(api.SaveEquipmentSet, set.id)
				return true
			end
		end
		Safe(api.CreateEquipmentSet, name, IconOf(Worn()))
		return true
	end
	local sets = DB().sets
	local slots = Worn()
	for _, set in ipairs(sets) do
		if set.name == name then
			set.slots, set.icon = slots, IconOf(slots)
			ns.Changed()
			TellBags()
			return true
		end
	end
	sets[#sets + 1] = { name = name, slots = slots, icon = IconOf(slots) }
	ns.Changed()
	TellBags()
	return true
end

-- An outfit just saved, by its name: done(entry) once it is there (at once for Wanderer's own), done(nil) if it never
-- came. The game's manager may add it only a moment later (with EQUIPMENT_SETS_CHANGED): looked for every FIND_STEP,
-- FIND_WAIT at most.
local FIND_STEP, FIND_WAIT = 0.2, 3
function ns.AwaitSet(name, done)
	local function Find()
		for _, set in ipairs(ns.Sets()) do
			if set.name == name then return set end
		end
	end
	local entry = Find()
	if entry then return done(entry) end
	local waited = 0
	local function Wait()
		local found = Find()
		if found then return done(found) end
		waited = waited + FIND_STEP
		if waited < FIND_WAIT then return C_Timer.After(FIND_STEP, Wait) end
		done(nil)
	end
	C_Timer.After(FIND_STEP, Wait)
end

-- What is kept under an outfit's name (the pieces it leaves aside, its situation): moved with a new name, let go
-- with it.
local function MoveName(old, new)
	if not old or old == new then return end
	local db = DB()
	for _, part in ipairs({ "left", "when", "told" }) do
		if new then db[part][new] = db[part][old] end
		db[part][old] = nil
	end
end

local function NameOf(id)
	for _, set in ipairs(ns.Sets()) do
		if set.id == id then return set.name end
	end
end

function ns.DeleteSet(id)
	MoveName(NameOf(id), nil)
	local api = GameSets()
	if api then
		Safe(api.DeleteEquipmentSet, id)
	else
		table.remove(DB().sets, id)
	end
	ns.Changed()
	TellBags()
end

function ns.RenameSet(id, name)
	name = type(name) == "string" and strtrim(name) or ""
	if name == "" then return end
	-- (a name another outfit has: refused, never its moment and its pieces left aside taken over)
	for _, set in ipairs(ns.Sets()) do
		if set.name == name and set.id ~= id then return W.Print(L.RENAME_TAKEN:format(name)) end
	end
	MoveName(NameOf(id), name)
	local api = GameSets()
	if api then
		if api.ModifyEquipmentSet then
			local _, icon = Safe(api.GetEquipmentSetInfo, id)
			Safe(api.ModifyEquipmentSet, id, name, Clean(icon))
		end
	else
		local set = DB().sets[id]
		if set then set.name = name end
	end
	ns.Changed()
	TellBags()
end

-- Dressing, piece by piece ------------------------------------------------------------------------------------

local wanted -- slot -> link, while dressing
local passes = 0
local generation = 0 -- one chain of pieces at a time
local later -- asked in a fight: done when it ends
local inFight = false -- this chain may go on in a fight (your weapons only: the game lets them change then)
local sayKey -- this chain's pieces left out are said once for this key (a situation: once a session), nil: each time
local said = {} -- keys already said, this session

-- The bag places holding this piece, not taken yet in this pass: bag, slot (nil: none in the bags). The very copy
-- first (its enchant, its gems), else the same item.
local function InBags(link, taken)
	local exact, same
	U.EachBagItem(function(bag, slot, info)
		if exact or taken[bag .. ":" .. slot] then return end
		local here = Clean(info.hyperlink)
		if not here then return end
		if Exact(here, link) then exact = { bag, slot } elseif not same and Same(here, link) then same = { bag, slot } end
	end)
	local found = exact or same
	if found then return found[1], found[2] end
end

local function PickupContainer(bag, slot)
	local pickup = C_Container and C_Container.PickupContainerItem
	if pickup then Safe(pickup, bag, slot) end
end

-- One piece on: taken from its own place in the bags (two identical rings or trinkets each from their own), else
-- by its name as the game finds it. Never with something already held by the mouse (an item, a spell, gold...):
-- the next pass tries again.
local function CursorBusy()
	if GetCursorInfo then return Clean(Safe(GetCursorInfo)) ~= nil end
	return Clean(Safe(CursorHasItem)) and true or false
end
ns.CursorBusy = CursorBusy -- (tests)

local function Equip(link, slot, taken)
	if CursorBusy() then return end
	local bag, place = InBags(link, taken)
	if bag and EquipCursorItem then
		taken[bag .. ":" .. place] = true
		PickupContainer(bag, place)
		if Clean(Safe(CursorHasItem)) then
			Safe(EquipCursorItem, slot)
			-- (refused: the piece back where it was)
			if Clean(Safe(CursorHasItem)) then Safe(ClearCursor) end
			return
		end
	end
	Safe(C_Item and C_Item.EquipItemByName or EquipItemByName, link, slot)
end

-- Busy hands: a cast or a channel (skinning, gathering, fishing) or a loot window open; the game refuses gear then.
-- (a fishing line is no busy hands: putting your weapons on just ends it, as you asked)
local function HandsBusy()
	if Clean(Safe(UnitCastingInfo, "player")) ~= nil then return true end
	local channel = Clean(Safe(UnitChannelInfo, "player"))
	if channel ~= nil and not U.IsFishingSpell(select(8, Safe(UnitChannelInfo, "player"))) then return true end
	return (Clean(Safe(GetNumLootItems)) or 0) > 0
end

local pending -- the chain whose next pass is already timed (one loop per chain, never two)
local function Later(chain)
	pending = chain
	C_Timer.After(STEP, function()
		if pending == chain then pending = nil end
		ns.DressStep(chain)
	end)
end

local busySince -- (when this chain began to wait for busy hands: once per chain, BUSY_WAIT in all)
local function Dress(mine)
	if not wanted or (mine and mine ~= generation) then return end
	if InCombatLockdown() and not inFight then return end -- (PLAYER_REGEN_ENABLED comes back here)
	-- Everything on already: done, nothing to wait for.
	local worn = Worn()
	local missing = false
	for slot, link in pairs(wanted) do
		if not Same(worn[slot], link) then missing = true break end
	end
	if not missing then
		wanted, busySince = nil, nil
		ns.Changed()
		return
	end
	-- Hands busy: the pieces wait (no pass counted, nothing said), a while at most.
	if HandsBusy() and (not busySince or GetTime() - busySince < BUSY_WAIT) then
		busySince = busySince or GetTime()
		return Later(generation)
	end
	local left = false
	local taken = {} -- the bag places used in this pass
	local last = passes + 1 > PASSES
	local missed = {} -- (the last pass: the pieces still not on, and where they are)
	for slot, link in pairs(wanted) do
		if not Same(worn[slot], link) then
			left = true
			if last then
				local id = U.ItemID(link)
				local state = InBags(link, {}) and "bags" or (BankHas(id) and "bank") or "missing"
				missed[#missed + 1] = { slot = slot, id = id, link = link, state = state }
			end
			Equip(link, slot, taken)
		end
	end
	passes = passes + 1
	if not left or passes > PASSES then
		wanted = nil
		-- (a piece in the bank, sold, or no room in the bags for the one it replaces: named; once for a situation)
		if left and not (sayKey and said[sayKey]) then
			if sayKey then said[sayKey] = true end
			SayLeft(missed)
		end
		ns.Changed()
		return
	end
	Later(generation)
end
ns.DressStep = Dress

-- A new chain of pieces: the old one lets go.
local function Want(slots, fight)
	wanted, passes, generation, later, inFight = slots, 0, generation + 1, nil, fight and true or false
	busySince, pending, sayKey = nil, nil, nil
end

-- What a change replaced (slot -> link, false: empty), for "Undo": the last change only.
local lastChange
local function Remember(slots)
	local worn, before = Worn(), {}
	for slot in pairs(slots) do before[slot] = worn[slot] or false end
	if next(before) then lastChange = before end
end
-- slot: that slot changed by it (nil: any change).
function ns.CanUndo(slot) return lastChange ~= nil and (slot == nil or lastChange[slot] ~= nil) end

-- Pieces put on (slot -> link), as one chain; fight: weapons only, so it may go on in a fight; key: what is left
-- out said once for it (a situation), else each time.
function ns.Put(slots, fight, key)
	if not next(slots) then return end
	Remember(slots)
	Want({}, fight)
	sayKey = key
	for slot, link in pairs(slots) do wanted[slot] = link end
	Dress()
end

-- The last change undone: what it replaced put back (an empty slot emptied again). Undone again: redone.
function ns.Undo()
	local before = lastChange
	if not before then return W.Print(L.MSG_NO_UNDO) end
	if InCombatLockdown() then
		later = function() ns.Undo() end
		return W.Print(L.MSG_COMBAT)
	end
	local put, off = {}, {}
	for slot, link in pairs(before) do
		if link then put[slot] = link else off[#off + 1] = slot end
	end
	local worn = Worn()
	local after = {}
	for slot in pairs(before) do after[slot] = worn[slot] or false end
	for _, slot in ipairs(off) do ns.TakeOff(slot) end
	ns.Put(put)
	lastChange = after
end
function ns.Dressing() return wanted ~= nil end

-- A piece taken off into the bags (its slot was empty before a moment dressed it); never with something held.
function ns.TakeOff(slot)
	if InCombatLockdown() or CursorBusy() or not (PickupInventoryItem and PutItemInBackpack) then return end
	-- (a chain still going on never puts it back: a slow answer from the server, a suggestion's piece taken off at once)
	if wanted then
		wanted[slot] = nil
		if not next(wanted) then wanted = nil end
	end
	Safe(PickupInventoryItem, slot)
	if Clean(Safe(CursorHasItem)) then
		Safe(PutItemInBackpack)
		-- (no room: the piece stays where it was)
		if Clean(Safe(CursorHasItem)) then Safe(ClearCursor) end
	end
end

-- An outfit's pieces it takes, as links (slot -> link): Wanderer's keep their links; the game's know their items
-- only, found worn or in the bags (a piece nowhere left out: said when it is worn).
function ns.OutfitLinks(entry)
	local links, left, worn = {}, Left(entry.name) or {}, nil
	for slot, piece in pairs(SetSlots(entry)) do
		if not left[slot] then
			local link = piece.link
			if not link and piece.id then
				worn = worn or Worn()
				if U.ItemID(worn[slot]) == piece.id then
					link = worn[slot]
				else
					U.EachBagItem(function(_, _, info)
						if not link and Clean(info.itemID) == piece.id then link = Clean(info.hyperlink) end
					end)
				end
			end
			if link then links[slot] = link end
		end
	end
	return links
end

function ns.WearSet(id)
	local api = GameSets()
	-- (one that leaves pieces aside: dressed here, piece by piece, those slots untouched)
	local name = NameOf(id)
	if api and Left(name) then
		if InCombatLockdown() then
			later = function() ns.WearSet(id) end
			return W.Print(L.MSG_COMBAT)
		end
		return ns.Put(ns.OutfitLinks({ id = id, name = name }))
	end
	if api then
		if InCombatLockdown() then
			later = function() ns.WearSet(id) end
			return W.Print(L.MSG_COMBAT)
		end
		local slots = {}
		for slot in pairs(SetSlots({ id = id })) do slots[slot] = true end
		Remember(slots)
		Safe(api.UseEquipmentSet, id)
		-- (a moment later, what the game could not put on: named, the bank's apart)
		C_Timer.After(1.5, function()
			if InCombatLockdown() then return end
			local summary = ns.Summary({ id = id })
			if summary.bank[1] or summary.missing[1] then
				local left = {}
				for _, piece in ipairs(summary.bank) do left[#left + 1] = piece end
				for _, piece in ipairs(summary.missing) do left[#left + 1] = piece end
				SayLeft(left)
			end
		end)
		return
	end
	local set = DB().sets[id]
	if not set then return end
	if InCombatLockdown() then W.Print(L.MSG_COMBAT) end
	ns.Put(ns.OutfitLinks({ id = id, name = set.name }))
end

-- The fishing pole ---------------------------------------------------------------------------------------------

-- A pole in your bags: bag, slot, link (nil: none).
local function PoleInBags()
	local found
	U.EachBagItem(function(bag, slot, info)
		if found then return end
		if U.IsFishingPole(Clean(info.itemID)) then found = { bag = bag, slot = slot, link = Clean(info.hyperlink) } end
	end)
	return found
end

ns.PoleInBags = PoleInBags

-- The pole in hand (your weapons remembered), or your weapons back. Said when nothing can be done (quiet: not).
function ns.TogglePole(quiet)
	if InCombatLockdown() then
		-- (your weapons back: the game lets them change in a fight; the pole waits for its end)
		if U.HasFishingPole() then return ns.WeaponsBack(quiet) end
		if quiet then return false end
		later = function() ns.TogglePole() end
		return W.Print(L.MSG_COMBAT)
	end
	local db = DB()
	if U.HasFishingPole() then return ns.WeaponsBack() end
	local pole = PoleInBags()
	if not pole then
		if not quiet then W.Print(L.MSG_NO_POLE) end
		return false
	end
	-- (what you held, kept for this character: a reload or a logout does not lose it)
	db.beforePole = { [MAIN_HAND] = Clean(Safe(GetInventoryItemLink, "player", MAIN_HAND)), [OFF_HAND] = Clean(Safe(GetInventoryItemLink, "player", OFF_HAND)) }
	Want({ [MAIN_HAND] = pole.link })
	Dress()
	return true
end

-- Your weapons back as they were (main hand, off hand or a two-handed one; the ranged slot never touched). In a
-- fight too, as the game lets weapons change then. A weapon no longer in your bags (sold, banked) is not looked
-- for: named. quiet: nothing said when there is nothing to do.
function ns.WeaponsBack(quiet)
	local db = DB()
	local before = db.beforePole
	if not (before and U.HasFishingPole()) then
		if not quiet then W.Print(L.MSG_NO_WEAPONS) end
		return false
	end
	db.beforePole, db.poleByCast = nil, nil
	local slots, gone = {}, {}
	for _, slot in ipairs({ MAIN_HAND, OFF_HAND }) do
		local link = before[slot]
		if link then
			-- (the very piece, else the same item: a link may change its passing fields)
			local found = InBags(link, {}) and link
			if not found then
				local id = U.ItemID(link)
				U.EachBagItem(function(_, _, info)
					if not found and id and Clean(info.itemID) == id then found = Clean(info.hyperlink) end
				end)
			end
			if found then
				slots[slot] = found
			else
				local id = U.ItemID(link)
				gone[#gone + 1] = { slot = slot, id = id, link = link, state = BankHas(id) and "bank" or "missing" }
			end
		end
	end
	if gone[1] then SayLeft(gone) end
	if not next(slots) then
		if not gone[1] and not quiet then W.Print(L.MSG_NO_WEAPONS) end
		ns.poleNote = "nothing to put back"
		return false
	end
	Want(slots, true)
	Dress()
	return true
end

-- Naowh Forever's gear sets, when they change your gear by themselves (a set for riding, or for resting): what
-- Outfits would change on a mount steps aside then, so both never dress you at the same moment.
function ns.NaowhSwaps()
	local naowh = _G.NaowhForever
	local sets = type(naowh) == "table" and naowh.GearSets
	if type(sets) ~= "table" or type(sets.On) ~= "function" then return false end
	local ok, on = pcall(sets.On)
	if not (ok and on) then return false end
	local settings = naowh.QoLSettings
	if type(settings) == "table" and type(settings.Get) == "function" then
		local okMounted, mounted = pcall(settings.Get, "gearMounted")
		local okResting, resting = pcall(settings.Get, "gearResting")
		if okMounted and okResting then
			return (type(mounted) == "string" and mounted ~= "") or (type(resting) == "string" and resting ~= "") or false
		end
	end
	return true
end

-- Another addon changing your gear by itself (ItemRack): what Outfits would change on its own steps aside.
function ns.OtherSwaps() return W and W.Yields and W.Yields("gearSwap") or nil end

-- Your weapons back by themselves (an option): when you mount (unless Naowh Forever or another addon dresses you then).
local function BackOnMount()
	local db = DB()
	if not (db.beforePole and U.HasFishingPole()) or ns.NaowhSwaps() or ns.OtherSwaps() then return end
	ns.WeaponsBack(true)
end

-- Fishing over, the option on: your weapons back by themselves. Over when no line has been cast for a while, when
-- you walked away from where you fished, when you mount, swim, enter a fight or leave the zone. Watched once a
-- second while the pole is in hand with weapons remembered (the timer runs only then).
local IDLE_BACK = 45 -- seconds without a line
local MOVED_BACK = 25 -- yards from where you fished
local watch = { on = false, last = 0, ended = nil }
ns.PoleWatch = watch -- (tests)

local function AutoBack()
	local settings = ns.Settings and ns.Settings()
	return settings and settings.enabled and settings.poleOnCast and true or false
end
-- (your weapons back when you mount: that option alone, or with the pole on cast)
local function OnMount()
	local settings = ns.Settings and ns.Settings()
	return settings and settings.enabled and (settings.weaponsOnMount or settings.poleOnCast) and true or false
end

-- (Wanderer's own list of the fishing spells)
local function Fishing()
	return U.IsFishingSpell(select(8, Safe(UnitChannelInfo, "player")))
end

local function Here()
	local y, x, _, map = Safe(UnitPosition, "player")
	return Clean(x), Clean(y), Clean(map)
end

-- Watched from now (where you stand, a line just seen): once a second until it is over.
local ticker
local function Watch()
	watch.on, watch.last, watch.since = true, GetTime(), GetTime()
	watch.x, watch.y, watch.map = Here()
	if not ticker and C_Timer and C_Timer.NewTicker then ticker = C_Timer.NewTicker(1, function() ns.TickPole() end) end
end

-- Over (why: a word for /woutfits debug).
local function Over(why)
	watch.on, watch.ended = false, why
	if not (DB().beforePole and U.HasFishingPole()) then return end
	if ns.OtherSwaps() then
		watch.ended = why .. ", left to " .. tostring(ns.OtherSwaps())
		return
	end
	ns.WeaponsBack(true)
end

local function Check()
	if not watch.on then return end
	if not (DB().beforePole and U.HasFishingPole() and OnMount()) then
		watch.on = false
		return
	end
	local now = GetTime()
	if Fishing() then
		watch.last = now
		watch.x, watch.y, watch.map = Here()
		return
	end
	if Clean(Safe(IsMounted)) then return Over("mounted") end
	-- (the rest only with the pole on cast: the mount alone with its own option)
	if not AutoBack() then return end
	if Clean(Safe(IsSwimming)) then return Over("swimming") end
	if InCombatLockdown() then return Over("fight") end
	if now - watch.last > IDLE_BACK then return Over("no line for " .. IDLE_BACK .. " s") end
	local x, y, map = Here()
	if watch.map and map and map ~= watch.map then return Over("another map") end
	if x and y and watch.x and watch.y and math.sqrt((x - watch.x) ^ 2 + (y - watch.y) ^ 2) > MOVED_BACK then return Over("walked away") end
end

-- Once a second: the pole in hand with weapons remembered and an option on starts the watch by itself (whatever
-- put the pole there: the double click, the key, the window; after a reload too), then fishing is watched.
local function Tick()
	if not watch.on and DB().beforePole and OnMount() and U.HasFishingPole() then Watch() end
	Check()
	-- (over: the timer stops until the next watch)
	if not watch.on and ticker then
		ticker:Cancel()
		ticker = nil
	end
end
ns.TickPole = Tick -- (tests)

-- What Outfits sees of the pole, in the chat (/woutfits debug): to tell what happens in the game.
function ns.PoleDebug()
	local settings = ns.Settings and ns.Settings() or {}
	local fishing = W.Settings and W.Settings("fishing") or {}
	local before = DB().beforePole
	local hand = Clean(Safe(GetInventoryItemID, "player", MAIN_HAND))
	local function Where(link)
		if not link then return "-" end
		local id = U.ItemID(link)
		local here = InBags(link, {}) and "in bags" or (BankHas(id) and "in bank" or "not found")
		return link .. " (" .. here .. ")"
	end
	local x, y, map = Here()
	local now = GetTime()
	local lines = {
		("options: outfits %s, pole on cast %s, weapons on mount %s, double click %s"):format(tostring(settings.enabled),
			tostring(settings.poleOnCast), tostring(settings.weaponsOnMount), tostring(fishing.doubleClick)),
		("main hand: %s, a pole: %s, fishing now: %s"):format(tostring(hand), tostring(U.HasFishingPole()), tostring(Fishing())),
		("remembered: main %s, off %s"):format(Where(before and before[MAIN_HAND]), Where(before and before[OFF_HAND])),
		("watch: %s, %s s since a line, place %s, %s yd away"):format(tostring(watch.on), watch.on and tostring(math.floor(now - watch.last)) or "-",
			x and "known" or "unknown", (x and watch.x) and tostring(math.floor(math.sqrt((x - watch.x) ^ 2 + (y - watch.y) ^ 2))) or "-"),
		("last end: %s; last ask from Wanderer: %s; another addon: %s; Naowh sets: %s"):format(tostring(watch.ended),
			tostring(ns.poleAsk), tostring(ns.OtherSwaps()), tostring(ns.NaowhSwaps())),
		("note: %s; map %s"):format(tostring(ns.poleNote), tostring(map)),
		"moments: " .. (ns.SituationWords and ns.SituationWords() or "-"),
	}
	for _, line in ipairs(lines) do W.Print("Outfits: " .. line) end
end
ns.CheckPole = Check -- (tests)

function ns.InitSets()
	-- What changed: the window drawn again.
	local changed = U.Signal()
	ns.OnChanged, ns.Changed = changed.On, changed.Fire
	local events = CreateFrame("Frame")
	for _, event in ipairs({ "PLAYER_REGEN_ENABLED", "PLAYER_REGEN_DISABLED", "PLAYER_EQUIPMENT_CHANGED", "EQUIPMENT_SETS_CHANGED",
		"PLAYER_MOUNT_DISPLAY_CHANGED", "ZONE_CHANGED_NEW_AREA", "LOOT_OPENED", "PLAYER_ENTERING_WORLD" }) do
		pcall(events.RegisterEvent, events, event)
	end
	events:SetScript("OnEvent", function(_, event)
		-- Fishing over: a fight (your weapons back at once), another zone; a catch: still fishing.
		if watch.on and AutoBack() and (event == "PLAYER_REGEN_DISABLED" or event == "ZONE_CHANGED_NEW_AREA") then
			Over(event == "PLAYER_REGEN_DISABLED" and "fight" or "another zone")
		end
		if event == "LOOT_OPENED" and watch.on and Clean(Safe(IsFishingLoot)) then watch.last = GetTime() end
		if event == "PLAYER_REGEN_DISABLED" then return end
		if event == "PLAYER_REGEN_ENABLED" and later then
			local asked, chain = later, generation
			later = nil
			asked()
			-- (an outfit stopped by the fight goes on, unless what was asked began another)
			if not (wanted and generation == chain) then return end
		end
		-- (a chain stopped by the fight goes on; one whose next pass is timed already is left to it)
		if event == "PLAYER_REGEN_ENABLED" and wanted then
			if pending ~= generation then Dress() end
			return
		end
		-- (your weapons back in hand by yourself: the ones remembered are let go)
		if event == "PLAYER_EQUIPMENT_CHANGED" and not wanted and not U.HasFishingPole() then
			DB().beforePole, DB().poleByCast = nil, nil
			watch.on = false
		end
		-- The pole in hand, weapons remembered, the option on (after a reload too): watched until fishing is over.
		if (event == "PLAYER_EQUIPMENT_CHANGED" or event == "PLAYER_ENTERING_WORLD") and not watch.on and OnMount()
			and DB().beforePole and U.HasFishingPole() then
			Watch()
		end
		if event == "PLAYER_MOUNT_DISPLAY_CHANGED" then
			local settings = ns.Settings()
			if settings and settings.enabled and settings.weaponsOnMount and Clean(Safe(IsMounted)) then BackOnMount() end
		end
		ns.Changed()
	end)
	-- Wanderer's double click without a pole in hand (the option on): the pole taken on the first click, so the second
	-- casts with it ("first", true when taken); no second click in time: your weapons back ("cancel"); the double
	-- click already done ("now", or an older Wanderer: nothing said), the pole in hand for the next one, and said.
	function ns.OnNoPole(stage)
		ns.poleAsk = tostring(stage) .. " at " .. math.floor(GetTime())
		local settings = ns.Settings()
		if not (settings and settings.enabled and settings.poleOnCast) or ns.OtherSwaps() then return false end
		if stage == "cast" then
			if DB().beforePole then Watch() end
			return true
		end
		if stage == "cancel" then
			-- (a short click that was not the start of a double click: as it was, once the pole is in hand)
			local tries = 0
			local function Undo()
				if not DB().poleByCast or Fishing() then return end
				if not U.HasFishingPole() then
					tries = tries + 1
					if tries <= 4 then C_Timer.After(0.5, Undo) end
					return
				end
				watch.on = false
				ns.WeaponsBack(true)
			end
			Undo()
			return true
		end
		if U.HasFishingPole() or InCombatLockdown() then return false end
		local took = ns.TogglePole(true) and true or false
		if took then
			DB().poleByCast = true
			if stage ~= "first" then W.Print(L.POLE_THEN_CAST) end
		end
		return took
	end
	W.OnFishingNoPole(ns.OnNoPole)
end
