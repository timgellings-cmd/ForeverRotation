local addonName, ns = ...
local API = ns.API

-- /wfr disc: read-only report of what the client exposes for the Discipline
-- list (secret values, spell resolve, wand, heal unit, why each step is
-- refused). Never casts, never touches saved settings, no combat log.

local function hidden(value)
	if value == nil then
		return false
	end
	if issecretvalue and issecretvalue(value) then
		return true
	end
	if canaccessvalue and not canaccessvalue(value) then
		return true
	end
	return false
end

local function show(value)
	if value == nil then
		return "nil"
	end
	if hidden(value) then
		return "SECRET"
	end
	if type(value) == "number" then
		if value == math.floor(value) then
			return tostring(value)
		end
		return string.format("%.1f", value)
	end
	if type(value) == "table" then
		return "table"
	end
	return tostring(value)
end

-- pcall a Blizzard API and show up to 4 return values.
local function raw(fn, ...)
	if type(fn) ~= "function" then
		return "n/a"
	end
	local function pack(...)
		return select("#", ...), { ... }
	end
	local n, out = pack(pcall(fn, ...))
	if not out[1] then
		return "error"
	end
	local parts = {}
	for i = 2, math.min(5, math.max(2, n)) do
		parts[#parts + 1] = show(out[i])
	end
	return table.concat(parts, ", ")
end

local function yes(value)
	return value and "yes" or "no"
end

local function spellText(id)
	if not id then
		return "?"
	end
	local name = API.SpellName(id) or API.HintName(id) or "?"
	return name .. " (" .. tostring(id) .. ")"
end

local function auraText(spellID, unit, filter)
	local ok, found, remain, unreadable = pcall(API.FindAura, spellID, unit, filter)
	if not ok then
		return "error"
	end
	if found then
		if remain and remain < 9000 then
			return string.format("up %.0fs", remain)
		end
		return "up"
	end
	if unreadable then
		return "UNREADABLE"
	end
	return "missing"
end

local function addonMeta(field, fallback)
	local getMeta = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
	if getMeta then
		local ok, value = pcall(getMeta, addonName, field)
		if ok and type(value) == "string" and not hidden(value) and value ~= "" then
			return value
		end
	end
	return fallback
end

local function healUnitFor(id, opt)
	local helpful = API.IsHelpful(id, opt)
	if opt.unit then
		return opt.unit, helpful
	end
	if helpful and opt.smart then
		return API.SmartHealUnit(opt), helpful
	end
	if helpful then
		return API.HealUnit(opt), helpful
	end
	return "player", helpful
end

-- First gate that refuses a step, mirroring API.StepOk. The final verdict
-- always comes from StepOk itself; this only names the reason.
local function explain(step, rotation)
	local opt = step.opt or {}
	if not ns.IsStepEnabled(step) then
		return "OFF", "disabled in list"
	end
	local id = API.Resolve(step.id)
	if not id then
		return "--", "not known (level / talent / name)"
	end
	local verdict = API.StepOk(step.id, opt)
	local notes = {}
	local unit, helpful = healUnitFor(id, opt)
	if opt.nodebuff then
		local debuff = opt.nodebuff == true and id or opt.nodebuff
		local dUnit = opt.unit or ((helpful and opt.heal) and unit or "target")
		local state = auraText(debuff, dUnit, "HARMFUL")
		if state ~= "missing" then
			notes[#notes + 1] = spellText(debuff) .. " on " .. dUnit .. ": " .. state
		end
	end
	if opt.nobuff then
		local bUnit = opt.heal and (opt.unit or unit) or "player"
		local state = auraText(id, bUnit, "HELPFUL")
		if state ~= "missing" then
			notes[#notes + 1] = "buff on " .. bUnit .. ": " .. state
		end
	end
	if verdict then
		if rotation and ns.db.barOnly ~= false and ns.SpellOnBar and not ns.SpellOnBar(id) then
			return "BAR", "OK but not on an action bar (bar-only is on)"
		end
		return "OK", (#notes > 0) and table.concat(notes, "; ") or "ready"
	end
	local function why(reason)
		if #notes > 0 then
			reason = reason .. " [" .. table.concat(notes, "; ") .. "]"
		end
		return "no", reason
	end
	if opt.ifUnknown and API.Known(opt.ifUnknown) then
		return why("replaced by " .. spellText(API.Resolve(opt.ifUnknown)))
	end
	if opt.wandMana and API.WandManaBlock() then
		return why("mana below wand floor " .. tostring(ns.db.wandMana) .. "%")
	end
	if opt.wand and not API.WandReady(id) then
		return why("no wand equipped or already shooting")
	end
	if opt.aggro and not API.HasAggro() then
		return why("no group aggro")
	end
	if opt.groupHurt then
		local hurt = API.GroupHurt(opt.groupHp)
		if hurt < (tonumber(opt.groupHurt) or 3) then
			return why(string.format("%d hurt <= %d%%, need %d", hurt, tonumber(opt.groupHp) or 70, tonumber(opt.groupHurt) or 3))
		end
	end
	if opt.hostile and not API.Hostile() then
		return why("no hostile target")
	end
	if opt.skipLow and API.Hostile() then
		local floorHp = (API.IsRaidmob and API.IsRaidmob()) and 5 or 20
		if API.Health("target") < floorHp then
			return why(string.format("target below %d%% (finish with wand)", floorHp))
		end
	end
	local hold = API.HoldRemain(id)
	if hold > 0.2 then
		return why(string.format("hold %.1fs after last cast", hold))
	end
	local needHp = opt.hp
	if not needHp and (opt.heal or API.IsHealSpell(id, opt)) then
		needHp = 99
	end
	if needHp then
		local hp
		if opt.unit or (helpful and opt.smart) then
			hp = API.Health(unit)
		elseif helpful or opt.heal then
			hp = API.HealHealth(opt)
		else
			hp = API.Health("player")
		end
		if hp > needHp then
			return why(string.format("%s hp %.0f%% > %d%%", unit, hp, needHp))
		end
	end
	if opt.hpMin then
		local hpUnit = opt.unit or "player"
		local hp = API.Health(hpUnit)
		if hp < opt.hpMin then
			return why(string.format("%s hp %.0f%% < %d%% (opener only)", hpUnit, hp, opt.hpMin))
		end
	end
	if opt.combat and not API.InCombat() then
		return why("not in combat")
	end
	if opt.nocombat and API.InCombat() then
		return why("in combat")
	end
	if #notes > 0 then
		return why("aura gate")
	end
	local cd = API.Cooldown(id)
	if cd > 0.2 then
		return why(string.format("cooldown %.1fs", cd))
	end
	return why("not usable (mana / range / client says no)")
end

local function stepLines(out, list, rotation)
	for i, step in ipairs(list or {}) do
		local ok, mark, reason = pcall(explain, step, rotation)
		if not ok then
			mark, reason = "ERR", tostring(mark)
		end
		local resolved = API.Resolve(step.id)
		out[#out + 1] = string.format("%2d %-4s %-20s %s -> %s", i, mark, step.key or "?", resolved and spellText(resolved) or tostring(step.id), reason or "")
	end
end

local function queueText(ids)
	local parts = {}
	for _, id in ipairs(ids or {}) do
		parts[#parts + 1] = spellText(id)
	end
	return #parts > 0 and table.concat(parts, " | ") or "(empty)"
end

function ns.DiscReport()
	local out = {}
	local function add(line)
		out[#out + 1] = line
	end
	local token = ns.ClassToken and ns.ClassToken() or "?"
	add("Forever Rotation " .. addonMeta("Version", "?") .. " - /wfr disc")
	add("client (version, build, date, interface): " .. raw(GetBuildInfo) .. " | locale " .. raw(GetLocale) .. " | addon TOC interface " .. addonMeta("Interface", "16001"))
	add("class " .. tostring(token) .. " | level " .. raw(UnitLevel, "player") .. " | role " .. tostring(ns.db.role) .. " | list " .. tostring(ns.ActiveSpec and ns.ActiveSpec()) .. " | mode " .. tostring(ns.ResolveCombatMode and ns.ResolveCombatMode()))
	if token ~= "PRIEST" then
		add(ns.T("DIAG_PRIEST_ONLY"))
		return table.concat(out, "\n")
	end

	add("")
	add("== Resources ==")
	add("mana raw " .. raw(UnitPower, "player", 0) .. " / " .. raw(UnitPowerMax, "player", 0) .. " | pct " .. show(API.ManaPct()) .. " | wand floor " .. tostring(ns.db.wandMana) .. "% | floor active " .. yes(API.WandManaBlock()))
	add("in combat " .. yes(API.InCombat()) .. " | group " .. raw(IsInGroup) .. " | threat " .. raw(UnitThreatSituation, "player") .. " | aggro " .. yes(API.HasAggro()))

	add("")
	add("== Units ==")
	for _, unit in ipairs({ "player", "target", "focus", "mouseover", "party1", "party2", "party3", "party4" }) do
		if UnitExists and select(2, pcall(UnitExists, unit)) then
			add(string.format("%-9s hp raw %s / %s | hp %.0f%% | friendly %s | hostile-target %s | role %s",
				unit, raw(UnitHealth, unit), raw(UnitHealthMax, unit), API.Health(unit),
				yes(API.UnitFriendly and API.UnitFriendly(unit)),
				unit == "target" and yes(API.Hostile()) or "-",
				raw(UnitGroupRolesAssigned, unit)))
		end
	end
	local smart = API.SmartHealUnit({})
	local lowUnit, lowHp = API.LowestFriendly()
	add("heal unit (smart) " .. smart .. " | lowest " .. tostring(lowUnit) .. string.format(" %.0f%%", lowHp or 100) .. " | tank unit " .. API.TankUnit() .. " | party <= 70%: " .. API.GroupHurt(70))
	local Pr = ns.Spell.Priest
	add("on " .. smart .. ": Weakened Soul " .. auraText(Pr.WeakenedSoul, smart, "HARMFUL") .. " | Shield " .. auraText(Pr.PowerWordShield, smart, "HELPFUL") .. " | Renew " .. auraText(Pr.Renew, smart, "HELPFUL"))
	add("on target: Holy Fire " .. auraText(Pr.HolyFire, "target", "HARMFUL") .. " | SW:Pain " .. auraText(Pr.ShadowWordPain, "target", "HARMFUL"))

	add("")
	add("== Wand (Shoot 5019) ==")
	local shoot = API.Resolve(Pr.Shoot)
	add("IsPlayerSpell " .. raw(IsPlayerSpell, Pr.Shoot) .. " | resolved " .. (shoot and spellText(shoot) or "NOT FOUND") .. " | on bar " .. yes(shoot and ns.SpellOnBar and ns.SpellOnBar(shoot)))
	add("HasWandEquipped " .. raw(HasWandEquipped) .. " | C_Spell.IsAutoRepeatSpell " .. raw(C_Spell and C_Spell.IsAutoRepeatSpell, shoot or Pr.Shoot) .. " | IsAutoRepeatSpell(name) " .. raw(IsAutoRepeatSpell, API.SpellName(shoot or Pr.Shoot) or "Shoot") .. " | event flag " .. yes(API.autoRepeat))
	add("usable " .. raw(C_Spell and C_Spell.IsSpellUsable, shoot or Pr.Shoot) .. " | wand ready " .. yes(API.WandReady(Pr.Shoot)))

	add("")
	add("== Rotation (disc) ==  OK = suggestable, -- = unknown, OFF = unchecked, BAR = not on bar")
	stepLines(out, ns.GetAPL(token, "disc"), true)
	add("")
	add("== Defense (disc) ==")
	stepLines(out, ns.GetDef(token, "disc"), false)

	add("")
	if ns.ActiveSpec and ns.ActiveSpec() == "disc" then
		local okQ, q = pcall(ns.BuildQueue)
		add("HUD queue now: " .. (okQ and queueText(q) or ("error " .. tostring(q))))
		local okD, d = pcall(ns.BuildDefense)
		add("defense now: " .. (okD and (d and spellText(d) or "(none)") or ("error " .. tostring(d))))
	else
		add("HUD queue: role is not Discipline (" .. tostring(ns.db.role) .. ") - switch with /wfr role")
	end
	return table.concat(out, "\n")
end

local function reportFrame()
	if ns.DiagFrame then
		return ns.DiagFrame
	end
	local f = CreateFrame("Frame", "WoWForeverRotDiag", UIParent, "BackdropTemplate")
	f:SetSize(720, 480)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:EnableMouse(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", f.StartMoving)
	f:SetScript("OnDragStop", f.StopMovingOrSizing)
	f:SetBackdrop({
		bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
		edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
		tile = true,
		tileSize = 8,
		edgeSize = 12,
		insets = { left = 3, right = 3, top = 3, bottom = 3 },
	})
	f:SetBackdropColor(0, 0, 0, 0.92)
	local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("TOPLEFT", 12, -10)
	title:SetText(ns.T("DIAG_TITLE"))
	f.title = title
	local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	hint:SetPoint("BOTTOMLEFT", 12, 10)
	hint:SetTextColor(0.7, 0.7, 0.7)
	f.hint = hint
	local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
	close:SetPoint("TOPRIGHT", -2, -2)
	local scroll = CreateFrame("ScrollFrame", "WoWForeverRotDiagScroll", f, "UIPanelScrollFrameTemplate")
	scroll:SetPoint("TOPLEFT", 12, -32)
	scroll:SetPoint("BOTTOMRIGHT", -32, 30)
	local edit = CreateFrame("EditBox", nil, scroll)
	edit:SetMultiLine(true)
	edit:SetFontObject("ChatFontSmall")
	edit:SetWidth(660)
	edit:SetAutoFocus(false)
	edit:SetMaxLetters(0)
	edit:SetScript("OnEscapePressed", function()
		f:Hide()
	end)
	scroll:SetScrollChild(edit)
	f.edit = edit
	if UISpecialFrames then
		table.insert(UISpecialFrames, "WoWForeverRotDiag")
	end
	ns.DiagFrame = f
	return f
end

function ns.ShowDiscReport()
	local ok, text = pcall(ns.DiscReport)
	if not ok then
		ns.Print("disc report error: " .. tostring(text))
		return
	end
	local okFrame, f = pcall(reportFrame)
	if not okFrame or not f then
		-- No window: fall back to chat, line by line.
		for line in string.gmatch(text, "[^\n]+") do
			print(line)
		end
		return
	end
	f.title:SetText(ns.T("DIAG_TITLE"))
	f.hint:SetText(ns.T("DIAG_HINT"))
	f.edit:SetText(text)
	f:Show()
	f.edit:SetFocus()
	f.edit:HighlightText()
end
