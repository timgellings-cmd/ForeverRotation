-- Minimal WoW client mock for offline tests (Lua 5.1, like the game).
-- Only what the rotation code reads: units, health, mana, auras, spellbook,
-- wand. Not a full API: frames / UI files are not loaded.
local M = {}

local function install(W, clock)
	function GetTime() return clock.now end
	function wipe(t) for k in pairs(t) do t[k] = nil end return t end
	strsub, strlower, strupper, strfind, strmatch, gsub = string.sub, string.lower, string.upper, string.find, string.match, string.gsub
	format, tinsert, tremove = string.format, table.insert, table.remove
	function strtrim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end
	function GetLocale() return "enUS" end
	function GetBuildInfo() return "1.15.mock", "00000", "Jan 1 2026", 16001 end
	function CopyTable(t) local o = {} for k, v in pairs(t) do o[k] = v end return o end

	local function U(u) return W.units[u] end
	function UnitExists(u) return U(u) ~= nil end
	function UnitIsDead(u) return U(u) and U(u).dead or false end
	function UnitIsDeadOrGhost(u) return UnitIsDead(u) end
	function UnitCanAttack(_, u) return U(u) and U(u).hostile or false end
	function UnitReaction(_, u) if not U(u) then return nil end return U(u).hostile and 2 or 5 end
	function UnitHealth(u) if W.secretHealth then return W.SECRET end return U(u) and U(u).hp or 0 end
	function UnitHealthMax(u) return U(u) and 100 or 0 end
	function UnitPower(u) if u ~= "player" then return 0 end if W.secretMana then return W.SECRET end return W.mana end
	function UnitPowerMax(u) return u == "player" and 100 or 0 end
	function UnitLevel() return W.level end
	function UnitAffectingCombat() return W.inCombat end
	function UnitCastingInfo() return nil end
	function UnitChannelInfo() return nil end
	function UnitGUID(u) return U(u) and (U(u).guid or ("guid-" .. u)) or nil end
	function UnitIsUnit(a, b) return a == b end
	function IsInGroup() return W.group end
	function UnitThreatSituation() return W.threat end
	function HasWandEquipped() return W.wand end
	function UnitInRange() return true, true end
	function UnitGroupRolesAssigned(u) return U(u) and U(u).role or "NONE" end
	function UnitClassification() return "normal" end
	function UnitCreatureType() return "Humanoid" end
	function CheckInteractDistance() return true end
	function UnitRace() return "Human", "Human", 1 end
	function UnitFactionGroup() return "Alliance" end
	function UnitClass() return "Priest", "PRIEST", 5 end
	function IsPlayerSpell(id) return W.known[id] == true end
	function GetSpellBaseCooldown() return 0, 0 end
	function IsAutoRepeatSpell() return W.autoRepeat end
	-- A value the "client" hides: issecretvalue says so, like camelot.
	W.SECRET = setmetatable({}, { __tostring = function() return "SECRET" end })
	function issecretvalue(v) return v == W.SECRET end

	C_Spell = {
		GetSpellInfo = function(x)
			if type(x) == "number" then
				return W.names[x] and { name = W.names[x], spellID = x, maxRange = 30 } or nil
			end
			for id, n in pairs(W.names) do
				if n == x and W.known[id] then
					return { name = n, spellID = id, maxRange = 30 }
				end
			end
		end,
		GetOverrideSpell = function(id) return id end,
		IsSpellUsable = function(id) return W.known[id] == true, false end,
		GetSpellCooldown = function() return { startTime = 0, duration = 0 } end,
		IsSpellHelpful = function() return false end,
		IsSpellHarmful = function(id) return W.harm[id] == true end,
		GetSpellPowerCost = function() return {} end,
		IsSpellInRange = function() return true end,
	}
	-- W.auras[unit] = { { name =, spellId =, expirationTime =, filter = "HARMFUL" | "HELPFUL" } }
	local function aurasFor(unit, filter)
		local out = {}
		for _, a in ipairs(W.auras[unit] or {}) do
			if (filter or "HELPFUL"):find(a.filter, 1, true) then
				out[#out + 1] = a
			end
		end
		return out
	end
	C_UnitAuras = {
		GetAuraDataByIndex = function(unit, i, filter)
			if W.secretAuras then
				error("secret")
			end
			return aurasFor(unit, filter)[i]
		end,
		GetAuraDataBySpellName = function(unit, name, filter)
			if W.secretAuras then
				return nil
			end
			for _, a in ipairs(aurasFor(unit, filter)) do
				if a.name == name then
					return a
				end
			end
		end,
		GetPlayerAuraBySpellID = function(id)
			if W.secretAuras then
				return nil
			end
			for _, a in ipairs(W.auras.player or {}) do
				if a.spellId == id then
					return a
				end
			end
		end,
	}
end

-- Loads the addon files into a fresh namespace. repo = path to the addon.
function M.new(repo, files)
	local clock = { now = 1000 }
	local W = { known = {}, names = {}, harm = {}, units = {}, auras = {} }
	install(W, clock)
	local ns = {}
	for _, file in ipairs(files or { "Locale.lua", "API.lua", "Data.lua", "Lists.lua", "APL.lua", "Rotations.lua", "Diag.lua" }) do
		local chunk = assert(loadfile(repo .. "/" .. file))
		chunk("WoWForeverRot", ns)
	end
	ns.db = { role = "disc", barOnly = false, autoEnemies = 3, combatMode = "single", wandMana = 40 }
	local classToken = "PRIEST"
	function ns.ClassToken() return classToken, 5, "Priest" end

	local Pr = ns.Spell.Priest
	for key, id in pairs(Pr) do
		W.names[id] = key
	end
	for _, key in ipairs({ "Smite", "HolyFire", "MindBlast", "ShadowWordPain", "Shoot", "Penance", "MindFlay", "DevouringPlague", "ShadowWordDeath" }) do
		if Pr[key] then
			W.harm[Pr[key]] = true
		end
	end

	local T = { ns = ns, W = W, Pr = Pr, clock = clock }
	function T.setClass(token) classToken = token end
	function T.learn(list)
		for _, key in ipairs(list) do
			if Pr[key] then
				W.known[Pr[key]] = true
			end
		end
	end
	function T.forget() W.known = {} end
	function T.label(id) return W.names[id] or tostring(id) end
	function T.aura(unit, key, filter, remain)
		W.auras[unit] = W.auras[unit] or {}
		table.insert(W.auras[unit], {
			name = key,
			spellId = Pr[key],
			expirationTime = remain and (clock.now + remain) or nil,
			filter = filter or "HELPFUL",
		})
	end
	function T.reset()
		W.units = { player = { hp = 100 } }
		W.auras = {}
		W.inCombat, W.mana, W.wand, W.autoRepeat, W.group, W.threat, W.level = false, 100, true, false, false, nil, 60
		W.secretHealth, W.secretMana, W.secretAuras = false, false, false
		if ns.API.NoteAutoRepeat then
			ns.API.NoteAutoRepeat(false)
		end
		classToken = "PRIEST"
		clock.now = clock.now + 100
	end
	local function fresh()
		ns.InvalidateAPLCache()
		ns.API.InvalidateSpells(true)
		ns.API.WipeAuraScans()
		if ns.ClearRotationSpent then
			ns.ClearRotationSpent()
		end
	end
	function T.queue()
		fresh()
		local out = {}
		for i, id in ipairs(ns.BuildQueue()) do
			out[i] = T.label(id)
		end
		return table.concat(out, ", ")
	end
	function T.def()
		fresh()
		local id = ns.BuildDefense()
		return id and T.label(id) or "-"
	end
	return T
end

return M
