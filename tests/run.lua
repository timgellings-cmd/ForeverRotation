-- Offline tests for the Discipline list and the Priest regression baseline.
-- Run from the repo root with Lua 5.1 (the game's version):
--   lua5.1 tests/run.lua
--   lua5.1 tests/run.lua --update-golden   (rewrite tests/golden/*.txt)
-- Not loaded by the TOC; the game never sees this folder.
package.path = "./tests/?.lua;" .. package.path
local mock = require("wowmock")

local updateGolden = arg and arg[1] == "--update-golden"
local T = mock.new(".")
local ns, W, Pr = T.ns, T.W, T.Pr
local fails, passes = 0, 0

local function report(ok, name, detail)
	if ok then
		passes = passes + 1
	else
		fails = fails + 1
		print("FAIL " .. name .. "  " .. detail)
	end
end
-- got must start with want.
local function first(name, got, want)
	report(got:find(want, 1, true) == 1, name, "-> [" .. got .. "] want first [" .. want .. "]")
end
local function lacks(name, got, bad)
	report(not got:find(bad, 1, true), name, "-> [" .. got .. "] must not contain " .. bad)
end
local function same(name, got, want)
	report(got == want, name, "-> [" .. got .. "] want [" .. want .. "]")
end

local ALL = { "Smite", "LesserHeal", "Heal", "FlashHeal", "Renew", "PowerWordShield", "HolyFire", "MindBlast", "ShadowWordPain", "PrayerofHealing", "Shoot", "Fade", "InnerFire", "PowerWordFortitude" }
local function hostileFight()
	T.reset()
	W.inCombat = true
	W.units.target = { hp = 100, hostile = true }
end

-- Discipline -----------------------------------------------------------
ns.db.role = "disc"
T.learn(ALL)

hostileFight()
first("full HP: damage first", T.queue(), "HolyFire")
lacks("full HP: no heal", T.queue(), "Heal")

hostileFight(); W.units.player.hp = 60
first("60%: Shield first", T.queue(), "PowerWordShield")
T.aura("player", "WeakenedSoul", "HARMFUL", 10)
first("Weakened Soul: Heal instead", T.queue(), "Heal")
lacks("Weakened Soul: no Shield", T.queue(), "PowerWordShield")
W.units.player.hp = 30
first("30% + WS: Flash Heal", T.queue(), "FlashHeal")

hostileFight(); W.group = true; W.units.party1 = { hp = 65 }
T.aura("party1", "WeakenedSoul", "HARMFUL", 10)
first("party1 65% (lowest, WS): Heal", T.queue(), "Heal")

hostileFight(); W.units.player.hp = 85
first("85%: Renew", T.queue(), "Renew")
T.aura("player", "Renew", "HELPFUL", 12)
first("85% with Renew: damage", T.queue(), "HolyFire")

hostileFight(); W.group = true
W.units.player.hp = 69; W.units.party1 = { hp = 60 }; W.units.party2 = { hp = 68 }
for _, u in ipairs({ "player", "party1", "party2" }) do
	T.aura(u, "WeakenedSoul", "HARMFUL", 10)
end
first("3 hurt: Prayer of Healing", T.queue(), "PrayerofHealing")
W.units.party2.hp = 90
lacks("2 hurt: no Prayer of Healing", T.queue(), "PrayerofHealing")

hostileFight(); W.mana = 30
same("30% mana: wand only", T.queue(), "Shoot")
ns.API.NoteAutoRepeat(true); W.autoRepeat = true
lacks("already shooting: Shoot hidden", T.queue(), "Shoot")
W.autoRepeat = nil -- client answer unreadable -> event flag decides
lacks("shooting (event flag only): Shoot hidden", T.queue(), "Shoot")
ns.API.NoteAutoRepeat(false)
first("stopped shooting: Shoot back", T.queue(), "Shoot")
ns.db.wandMana = 0
first("wand floor 0 = off: Holy Fire", T.queue(), "HolyFire")
ns.db.wandMana = 40
W.secretMana = true
first("secret mana: no wand block", T.queue(), "HolyFire")

hostileFight(); W.mana = 30; W.wand = false
lacks("no wand equipped: no Shoot", T.queue(), "Shoot")

hostileFight(); W.units.target.hp = 15
same("target 15%: wand finisher", T.queue(), "Shoot")

hostileFight()
T.aura("target", "HolyFire", "HARMFUL", 8)
T.aura("target", "ShadowWordPain", "HARMFUL", 15)
same("HF + SWP up: guide order Smite, Mind Blast, Shoot", T.queue(), "Smite, MindBlast, Shoot")

-- Guide damage sequence: Holy Fire opener, one Smite, one Mind Blast,
-- Shadow Word: Pain, then wand until the mob dies.
hostileFight(); W.units.target.guid = "mob-1"
same("guide 1: Holy Fire opener", T.queue(), "HolyFire, Smite, MindBlast")
T.aura("target", "HolyFire", "HARMFUL", 8); ns.API.NoteSpellCast(Pr.HolyFire)
first("guide 2: Smite", T.queue(), "Smite")
W.units.target.hp = 85
ns.API.NoteSpellCast(Pr.Smite)
first("guide 3: Mind Blast", T.queue(), "MindBlast")
ns.API.NoteSpellCast(Pr.MindBlast)
first("guide 4: Shadow Word: Pain", T.queue(), "ShadowWordPain")
T.aura("target", "ShadowWordPain", "HARMFUL", 18); ns.API.NoteSpellCast(Pr.ShadowWordPain)
same("guide 5: wand until dead", T.queue(), "Shoot")
lacks("guide: no Holy Fire below 90%", T.queue(), "HolyFire")
T.clock.now = T.clock.now + 31
first("guide: Smite back after its 30 s hold", T.queue(), "Smite")
T.clock.now = T.clock.now - 31
W.units.target = { hp = 100, hostile = true, guid = "mob-2" }; W.auras.target = nil
same("guide: new target starts over", T.queue(), "HolyFire, Smite, MindBlast")
W.units.target.hp = 80
local okG, guideText = pcall(ns.DiscReport)
report(okG and guideText:find("target hp 80% < 90% (opener only)", 1, true) ~= nil, "diag: Holy Fire opener reason", tostring(guideText))

hostileFight(); W.units.player.hp = 60; W.secretHealth = true
lacks("secret health: no heal guess", T.queue(), "Heal")

-- Level 10: only some spells known.
T.forget(); T.learn({ "Smite", "LesserHeal", "Renew", "PowerWordShield", "ShadowWordPain", "MindBlast" })
hostileFight(); W.units.player.hp = 60
T.aura("player", "WeakenedSoul", "HARMFUL", 10)
local low = T.queue()
first("level 10 @60%: Lesser Heal", low, "LesserHeal")
for _, key in ipairs({ "FlashHeal", "HolyFire", "PrayerofHealing", "Shoot", "Penance" }) do
	lacks("level 10: unknown " .. key .. " skipped", low, key)
end
T.learn(ALL)
hostileFight(); W.units.player.hp = 60
T.aura("player", "WeakenedSoul", "HARMFUL", 10)
lacks("Heal learned: Lesser Heal gone", T.queue(), "LesserHeal")

T.reset(); W.units.target = { hp = 100, hostile = true }
first("pre-pull: Shield", T.queue(), "PowerWordShield")
T.reset(); W.group = true; W.units.target = { hp = 100, hostile = true }
W.units.party2 = { hp = 100, role = "TANK" }
T.aura("player", "WeakenedSoul", "HARMFUL", 10)
first("pre-pull: Shield on party tank despite own WS", T.queue(), "PowerWordShield")

T.reset(); W.inCombat = true; W.units.player.hp = 45
same("defense 45%: Shield", T.def(), "PowerWordShield")
T.reset()
same("defense no buffs: Inner Fire", T.def(), "InnerFire")
T.reset(); W.inCombat = true; W.group = true; W.threat = 3
T.aura("player", "InnerFire"); T.aura("player", "PowerWordFortitude")
same("defense group aggro: Fade", T.def(), "Fade")
W.group = false
same("defense solo aggro: no Fade", T.def(), "-")

-- Diagnostics -------------------------------------------------------------
hostileFight(); W.units.player.hp = 60; W.mana = 30
local ok, text = pcall(ns.DiscReport)
report(ok, "diag: report builds", tostring(text))
if ok then
	for _, needle in ipairs({ "== Wand (Shoot 5019) ==", "resolved Shoot (5019)", "HUD queue now:", "PowerWordShield", "mana below wand floor" }) do
		report(text:find(needle, 1, true) ~= nil, "diag: contains '" .. needle .. "'", "")
	end
end
hostileFight(); W.secretAuras = true; W.secretHealth = true; W.secretMana = true
ok, text = pcall(ns.DiscReport)
report(ok, "diag: report builds with secret values", tostring(text))
if ok then
	report(text:find("UNREADABLE", 1, true) ~= nil, "diag: shows unreadable auras", "")
	report(text:find("SECRET", 1, true) ~= nil, "diag: shows secret raw values", "")
end
T.reset(); T.setClass("MAGE")
ok, text = pcall(ns.DiscReport)
report(ok and text:find(ns.T("DIAG_PRIEST_ONLY"), 1, true) ~= nil, "diag: non-priest note", tostring(text))
T.reset()
if os.getenv("SHOW_DIAG") then
	hostileFight(); W.units.player.hp = 60
	print(ns.DiscReport())
end

-- Regression: Priest damage / heal must match the pre-Discipline baseline.
local lines = {}
T.learn({ "MindFlay", "DevouringPlague", "ShadowWordDeath", "GreaterHeal", "PrayerofMending", "DivineSpirit", "ShadowProtection" })
for _, role in ipairs({ "damage", "heal" }) do
	for _, hp in ipairs({ 100, 85, 60, 30 }) do
		for _, ws in ipairs({ false, true }) do
			for _, combat in ipairs({ false, true }) do
				for _, mana in ipairs({ 100, 20 }) do
					T.reset()
					ns.db.role = role
					W.inCombat, W.mana, W.group = combat, mana, true
					W.units.target = { hp = 100, hostile = true }
					W.units.player.hp = hp
					W.units.party1 = { hp = hp - 10 }
					if ws then
						T.aura("player", "WeakenedSoul", "HARMFUL", 10)
					end
					lines[#lines + 1] = table.concat({ role, hp, tostring(ws), tostring(combat), mana, "Q=" .. T.queue(), "D=" .. T.def() }, "\t")
				end
			end
		end
	end
end
local goldenPath = "tests/golden/priest_damage_heal.txt"
local got = table.concat(lines, "\n") .. "\n"
if updateGolden then
	local f = assert(io.open(goldenPath, "w"))
	f:write(got)
	f:close()
	print("golden updated: " .. goldenPath)
else
	local f = io.open(goldenPath, "r")
	local want = f and f:read("*a") or ""
	if f then
		f:close()
	end
	report(got == want, "regression: Priest damage/heal unchanged (" .. #lines .. " cases)", "see " .. goldenPath .. " (diff with --update-golden only if the change is intended)")
end
ns.db.role = "disc"

print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
