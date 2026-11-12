local _, ns = ...
local L = ns.L

-- The situations: an outfit tied to a moment goes on by itself when it comes, and what it changed comes back when
-- it ends. Only what you tied (an outfit's card, "When"); nothing by default.
-- * Fishing: the pole in hand (your hat, your gloves; the hands stay the pole's).
-- * Riding: on a mount (a riding trinket, spurs, gloves).
-- * Some zones you chose (a trinket against the undead, gear against fire).
-- * In a dungeon or a raid.
-- * In town or at an inn (the clothes you like to be seen in).
-- When two hold at once, the first of this list wins (two outfits for the same moment: worn together). Only the slots an outfit takes are touched, and only those it
-- put on are given back: a piece you changed yourself meanwhile is yours, never taken back. Never in a fight (done
-- once it ends); Shift held when a moment comes lets it pass; another addon changing your gear by itself (ItemRack,
-- Naowh Forever's sets) and the option goes quiet.

local W = Wanderer
local U = W and W.Util
local Safe, Clean = U and U.Safe, U and U.Clean

local KINDS = { "fishing", "mount", "zone", "instance", "rest" } -- the order they win in
ns.SITUATIONS = KINDS
local RANK = {}
for index, kind in ipairs(KINDS) do RANK[kind] = index end
local HANDS = { [16] = true, [17] = true } -- (the pole's while fishing)
local SETTLE = 0.4 -- seconds a change waits (a mount's display, a zone's name, come in bursts)
-- An outfit made for a moment takes these slots of what you wear (nil: all); the others are left aside, a click
-- away in its card. In town: all but the weapons.
local TAKES = { mount = { 13, 14, 10, 8 }, fishing = { 1, 10, 8 }, zone = { 13, 14 }, rest = "clothes" }
local WEAPONS = { [16] = true, [17] = true, [18] = true }

local function Settings() return ns.Settings and ns.Settings() or nil end

-- On: the option, nobody else dressing you by itself.
function ns.SituationsOn()
	local settings = Settings()
	if not (settings and settings.enabled and settings.situations ~= false) then return false end
	return not (ns.OtherSwaps() or ns.NaowhSwaps())
end

-- An outfit's situation: { kind, zones } or nil.
function ns.When(name) return name and ns.DB().when[name] or nil end

-- Its situation chosen (nil: none). A zone kind starts with the zone you are in.
function ns.SetWhen(entry, kind)
	if not (entry and entry.name) then return end
	local when = ns.DB().when
	if not kind then
		when[entry.name] = nil
	else
		local old = when[entry.name]
		local zones = old and old.zones or {}
		if kind == "zone" and not next(zones) then
			local here = Clean(Safe(GetRealZoneText))
			if here then zones[here] = true end
		end
		when[entry.name] = { kind = kind, zones = zones }
	end
	ns.Changed()
end

-- A zone added to (or taken from) an outfit's zones.
function ns.ToggleZone(entry, zone)
	local when = entry and ns.When(entry.name)
	if not (when and zone) then return end
	when.zones = when.zones or {}
	when.zones[zone] = not when.zones[zone] or nil
	ns.Changed()
end

-- A new outfit for a moment: the slots that moment wants taken, the others left aside, its moment set.
local function FinishFor(entry, kind)
	local name = entry.name
	local takes, left = TAKES[kind], {}
	if takes then
		local keep = {}
		if takes == "clothes" then
			for _, slot in ipairs(ns.SLOTS) do keep[slot] = not WEAPONS[slot] end
		else
			for _, slot in ipairs(takes) do keep[slot] = true end
		end
		for _, slot in ipairs(ns.SLOTS) do
			if not keep[slot] then left[slot] = true end
		end
	end
	ns.DB().left[name] = next(left) and left or nil
	ns.SetWhen(entry, kind)
	-- (Wanderer Bags read the new outfit before its slots were left aside: told again)
	ns.TellBags()
end

-- An outfit for a moment, made from what you wear (named after it; a second one: "Name 2"), the slots that moment
-- usually wants taken, the others left aside, its moment set. Its entry, or nil. The game's manager may add it only
-- a moment later (with EQUIPMENT_SETS_CHANGED): waited for a short while (ns.AwaitSet), then made the same way.
-- done(entry), when given: called once, as soon as it is made (at once when it is there), or with nil when it never came.
function ns.CreateFor(kind, done)
	local word = L["WHEN_" .. kind:upper()]
	local taken = {}
	for _, set in ipairs(ns.Sets()) do taken[set.name] = true end
	local name, number = word, 1
	while taken[name] do
		number = number + 1
		name = word .. " " .. number
	end
	if not ns.SaveSet(name) then
		if done then done(nil) end
		return nil
	end
	local made
	ns.AwaitSet(name, function(entry)
		if entry then
			made = entry
			FinishFor(entry, kind)
		end
		if done then done(entry) end
	end)
	return made
end

-- Whether a situation holds now.
local function Holds(when)
	local kind = when.kind
	if kind == "fishing" then return U.HasFishingPole() end
	if kind == "mount" then return Clean(Safe(IsMounted)) and true or false end
	if kind == "rest" then return Clean(Safe(IsResting)) and true or false end
	if kind == "instance" then
		local inside, what = Safe(IsInInstance)
		return Clean(inside) and (Clean(what) == "party" or Clean(what) == "raid") or false
	end
	if kind == "zone" then
		local zones = when.zones or {}
		local zone, sub = Clean(Safe(GetRealZoneText)), Clean(Safe(GetSubZoneText))
		return (zone ~= nil and zones[zone] == true) or (sub ~= nil and zones[sub] == true)
	end
	return false
end

-- The outfit for now (its entry, its kind), or nil.
function ns.SituationNow()
	local best, bestRank
	for _, entry in ipairs(ns.Sets()) do
		local when = ns.When(entry.name)
		local rank = when and RANK[when.kind]
		if rank and (not bestRank or rank < bestRank) and Holds(when) then best, bestRank = entry, rank end
	end
	return best, bestRank and KINDS[bestRank] or nil
end

-- What is kept for this character (a reload loses nothing): the outfit on for a situation, what it put on and
-- what it replaced (slot -> link, false: the slot was empty), the one let pass with Shift.
local function State()
	local db = ns.DB()
	if type(db.situation) ~= "table" then db.situation = {} end
	local state = db.situation
	state.base = type(state.base) == "table" and state.base or {}
	state.applied = type(state.applied) == "table" and state.applied or {}
	return state
end
ns.SituationState = State

-- A piece you changed yourself in a slot a situation dressed: yours, never given back.
local function Respect()
	local state, worn = State(), ns.Worn()
	for slot, link in pairs(state.applied) do
		if not ns.Same(worn[slot], link) then
			state.applied[slot], state.base[slot] = nil, nil
		end
	end
end

-- Looked at again: the outfit of the moment on, or what the last one changed given back.
local function Evaluate()
	if ns.Dressing() or InCombatLockdown() then return end -- (looked at again when that is over)
	local state = State()
	Respect()
	local entry, kind
	if ns.SituationsOn() then entry, kind = ns.SituationNow() end
	-- (other outfits for the same moment holding now: worn with it, a hat's and a pair of boots' for fishing; the
	-- first one's slots first)
	local together = {}
	if entry then
		for _, other in ipairs(ns.Sets()) do
			local when = other.name ~= entry.name and ns.When(other.name)
			if when and when.kind == kind and Holds(when) then together[#together + 1] = other end
		end
	end
	local name = entry and entry.name or nil
	for _, other in ipairs(together) do name = name .. " + " .. other.name end
	if name ~= state.skipped then state.skipped = nil end
	if name == state.name then return end
	-- Shift held as the moment comes (the controller's own Shift too): it passes (until it ends).
	if name and U and U.IsSkipping and U.IsSkipping() then
		state.skipped = name
		return
	end
	if name and name == state.skipped then return end
	local links = entry and ns.OutfitLinks(entry) or {}
	for _, other in ipairs(together) do
		for slot, link in pairs(ns.OutfitLinks(other)) do
			if links[slot] == nil then links[slot] = link end
		end
	end
	if kind == "fishing" then
		for slot in pairs(HANDS) do links[slot] = nil end
	end
	local worn, want = ns.Worn(), {}
	-- What the last one put on and this one does not take: given back.
	local off = {}
	for slot, before in pairs(state.base) do
		if not links[slot] then
			-- (the slot was empty: the piece taken off, as it was)
			if before then want[slot] = before elseif state.applied[slot] then off[#off + 1] = slot end
			state.base[slot], state.applied[slot] = nil, nil
		end
	end
	for _, slot in ipairs(off) do ns.TakeOff(slot) end
	-- What this one takes: what is worn there kept first (unless an earlier one changed it already), then put on.
	for slot, link in pairs(links) do
		if state.base[slot] == nil then state.base[slot] = worn[slot] or false end
		if not ns.Same(worn[slot], link) then want[slot] = link end
		state.applied[slot] = link
	end
	state.name = name
	ns.Put(want, false, name and ("situation:" .. name) or "situation")
	-- The first time an outfit goes on by itself: said once, so you know it works and why.
	if entry then
		local told = ns.DB().told or {}
		ns.DB().told = told
		if not told[entry.name] then
			told[entry.name] = true
			W.Toast(L.TOLD_TITLE:format(entry.name), L.TOLD_TEXT:format(ns.WhenWords(entry.name) or ""),
				{ kind = "outfits", kindName = L.ADDON, icon = entry.icon })
		end
	end
end
ns.EvaluateSituations = Evaluate -- (tests)

-- What Outfits sees of the moments (/woutfits debug).
function ns.SituationWords()
	local state = State()
	local entry, kind = ns.SituationNow()
	local inside, what = Safe(IsInInstance)
	return ("on %s; now %s (%s); worn by a moment: %s; mounted %s, resting %s, instance %s %s, zone %s / %s, pole %s"):format(
		tostring(ns.SituationsOn()), tostring(entry and entry.name), tostring(kind), tostring(state.name),
		tostring(Clean(Safe(IsMounted))), tostring(Clean(Safe(IsResting))), tostring(Clean(inside)), tostring(Clean(what)),
		tostring(Clean(Safe(GetRealZoneText))), tostring(Clean(Safe(GetSubZoneText))), tostring(U.HasFishingPole()))
end

function ns.InitSituations()
	local waiting = false
	local function Soon()
		if waiting then return end
		waiting = true
		C_Timer.After(SETTLE, function()
			waiting = false
			Evaluate()
		end)
	end
	local events = CreateFrame("Frame")
	for _, event in ipairs({ "PLAYER_MOUNT_DISPLAY_CHANGED", "ZONE_CHANGED_NEW_AREA", "ZONE_CHANGED", "ZONE_CHANGED_INDOORS",
		"PLAYER_UPDATE_RESTING", "PLAYER_ENTERING_WORLD", "PLAYER_EQUIPMENT_CHANGED", "PLAYER_REGEN_ENABLED" }) do
		pcall(events.RegisterEvent, events, event)
	end
	events:SetScript("OnEvent", Soon)
	-- (a chain of pieces over: what it changed may make another moment, or end one)
	ns.OnChanged(Soon)
end
