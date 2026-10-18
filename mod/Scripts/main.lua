--[[
    OT2FCLite - minimal build for stability testing + first real injection
    UE4SS 3.0.1 | OCTOPATH TRAVELER II v1.1.0 | UE 4.27 | module: Majesty

    Design goals
      * register NO hooks until Mods/OT2FCLite/arm.txt exists (so a plain UE4SS run can
        be tested first, with this mod installed but inert)
      * one single hook: post-hook on
            UFieldCommandUtil::GetPartyFieldCommand(bool, AKSCharacterBase*, bool&, TArray<MJFieldCommandType>&)
      * only "safe" game calls are used (verified working):
            UKSCharacterFunction::GetCharacterFieldCommandType(EPlayableCharacterID) -> TArray
            UPartySaveDataUtil::CheckInParty(EPlayableCharacterID) -> bool
            UTimeZoneUtility::GetCurrentTimeZoneType() -> ETimeZoneType
        NOT used (crashed once at the title screen): CanExecFieldCommand / out-param calls
      * each traveller has exactly two commands, ordered [day, night] (verified on this save):
            Hikari eBattle/eBribery, Ochette eMonster/ePlacate, Castti eHear/eDose,
            Partitio ePurchase/eHire, Temenos eLead/eReveal, Osvald eSearch/eRob,
            Throne eSteal/eAssassinate, Agnea eLure/eBeg

    Files (polled every 2s):
      arm.txt          - presence registers the hook
      autoarm.txt      - registers the hook automatically once actually in the field
      inject.txt       - "1" enables injection
      max_inject.txt   - how many off-party entries (default 1)
      mode.txt         - "append" (party + off-party) or "offparty" (replace with off-party only)
      ownerfix.txt     - 0 off (default) / 1 substitute player actor / 2 spawn the real character,
                         used only when AFieldCommandFlowBase::GetFieldCommandOwner returns nothing
      request_report   - touch to write fc_lite_report.txt
    Keys: F6 toggle inject, F7 report
]]

local MOD_DIR = "Mods/OT2FCLite"

local FC_NAME = {
    [0]="eGeneric",[1]="ePurchase",[2]="eSteal",[3]="eBattle",[4]="eMonster",[5]="eLure",
    [6]="eSearch",[7]="eHire",[8]="eReveal",[9]="eHear",[10]="eLead",[11]="eBribery",
    [12]="eBeg",[13]="eRob",[14]="eAssassinate",[15]="eDose",[16]="ePlacate",
}
local CHAR_NAME = {[1]="Hikari",[2]="Ochette",[3]="Castti",[4]="Partitio",
                   [5]="Temenos",[6]="Osvald",[7]="Throne",[8]="Agnea"}
local TZ_NAME = {[0]="NONE",[1]="MORNING",[2]="DAYTIME",[3]="EVENING",[4]="NIGHT"}

-- command type -> owning traveller (derived from this save's real per-character data)
--   Hikari eBattle/eBribery, Ochette eMonster/ePlacate, Castti eHear/eDose, Partitio ePurchase/eHire,
--   Temenos eLead/eReveal, Osvald eSearch/eRob, Throne eSteal/eAssassinate, Agnea eLure/eBeg
local FC_OWNER = {
    [1] = 4,  [2] = 7,  [3] = 1,  [4] = 2,  [5] = 8,  [6] = 6,  [7] = 4,  [8] = 5,
    [9] = 3, [10] = 5, [11] = 1, [12] = 8, [13] = 6, [14] = 7, [15] = 3, [16] = 2,
}

local function log(fmt, ...)
    local m = (select('#', ...) > 0) and string.format(fmt, ...) or fmt
    print("[OT2FCLite] " .. m .. "\n")
end
local function readFile(p) local f = io.open(p, "r") if not f then return nil end local d = f:read("*a") f:close() return d end
local function writeFile(p, t) local f = io.open(p, "w") if not f then return false end f:write(t) f:close() return true end
local function P(v)
    if v == nil then return nil end
    if type(v) == "userdata" then
        local ok, raw = pcall(function() return v:get() end)
        if ok then return raw end
    end
    return v
end
local function fcStr(v) local n = tonumber(P(v)) if not n then return "?" end return FC_NAME[n] or ("fc" .. n) end
local function toList(a)
    local out = {}
    a = P(a)
    if a == nil then return out end
    if type(a) == "table" then
        for i = 1, #a do out[#out + 1] = tonumber(P(a[i])) end
        return out
    end
    if type(a) == "userdata" then
        local ok = pcall(function()
            local n = a:GetArrayNum()
            for i = 1, n do out[#out + 1] = tonumber(P(a[i])) end
        end)
        if ok then return out end
    end
    return out
end
local function cdo(n) return StaticFindObject("/Script/Majesty.Default__" .. n) end
local function cdoAny(mod, n) return StaticFindObject("/Script/" .. mod .. ".Default__" .. n) end

-- ---------------------------------------------------------------- console
-- Drive the game's own console dispatcher instead of calling UFunctions on
-- objects found by name (that killed the Lua thread once). All params of
-- UKismetSystemLibrary::ExecuteConsoleCommand are by-value, so this is safe.
local lastPc = nil
-- forward declarations (assigned further below; the console helpers call them)
local trace
local try
-- NOTE: FindFirstOf() returns a wrapper around a NULL object when nothing matches,
-- and any method call on that wrapper throws. FindAllOf() + length check is safe.
local function firstOfSafe(cls)
    local t = FindAllOf(cls)
    if type(t) ~= "table" then return nil end
    for _, o in pairs(t) do return o end
    return nil
end
local function ensureCheatManager()
    local pc = firstOfSafe("KSPlayerControllerBP_C") or firstOfSafe("PlayerController")
    if pc == nil then
        trace("console: no PlayerController instance yet")
        return nil, nil
    end
    lastPc = pc
    local cm = firstOfSafe("KSCheatManager")
    if cm == nil then
        local cls = StaticFindObject("/Script/Majesty.KSCheatManager")
        if cls ~= nil then
            local made = nil
            local ok = pcall(function() made = StaticConstructObject(cls, pc, 0, 0, 0, nil, false, false, nil) end)
            if ok and made ~= nil then
                cm = made
                local okA = pcall(function() pc.CheatManager = made end)
                trace("console: constructed KSCheatManager, attached=%s", tostring(okA))
            else
                trace("console: construct failed ok=%s", tostring(ok))
            end
        end
    end
    return pc, cm
end

local function cmdConsole(cmd)
    cmd = (string.gsub(cmd or "", "[\r\n]+$", ""))
    local okAll, errAll = pcall(function()
        local pc, cm = ensureCheatManager()
        trace("console: pc=%s cm=%s cmd='%s'", tostring(pc ~= nil), tostring(cm ~= nil), tostring(cmd))
        if pc == nil then return end
        local lib = cdoAny("Engine", "KismetSystemLibrary")
        if lib == nil then trace("console: KismetSystemLibrary not found"); return end
        local ok, err = pcall(function() lib:ExecuteConsoleCommand(pc, cmd, pc) end)
        trace("console: ExecuteConsoleCommand ok=%s err=%s", tostring(ok), tostring(err))
    end)
    if not okAll then trace("console: FAILED %s", tostring(errAll)) end
end

local function vecOf(a)
    a = P(a)
    if a == nil then return nil end
    local ok, v = pcall(function() return a:K2_GetActorLocation() end)
    if not ok or v == nil then return nil end
    return tonumber(P(v.X)), tonumber(P(v.Y)), tonumber(P(v.Z))
end
local function npcInfo()
    local npcs = FindAllOf("KSFieldNPCCharacter_C")
    local player = nil
    local ksf = cdo("KSCharacterFunction")
    if ksf then player = P(try("GetPlayerObject", function() return ksf:GetPlayerObject() end)) end
    local px, py = vecOf(player)
    local best, bestD, bestLabel, bx, by, bz = nil, nil, nil, nil, nil, nil
    local npcCount = 0
    if type(npcs) == "table" then
        for _, a in pairs(npcs) do
            npcCount = npcCount + 1
            local x, y, z = vecOf(a)
            local lbl = nil
            pcall(function()
                local comp = a:GetComponentByClass(StaticFindObject("/Script/Majesty.NpcPropertyComponent"))
                if comp and comp:IsValid() then
                    local f = comp:GetNpcLabel()
                    local okS, s = pcall(function() return f:ToString() end)
                    lbl = okS and tostring(s) or tostring(P(f))
                end
            end)
            if x and y and lbl then
                local d = (px and py) and ((x - px) ^ 2 + (y - py) ^ 2) or 0
                if bestD == nil or d < bestD then
                    best, bestD, bestLabel, bx, by, bz = a, d, lbl, x, y, z
                end
            end
        end
    end
    return best, bestLabel, bx, by, bz, bestD, npcCount
end

-- open the game's own field-command menu (the no-arg entry point calls
-- GetPartyFieldCommand internally - exactly where our hook lives)
local function cmdOpenMenu()
    local util = cdo("FieldCommandUtil")
    if util == nil then trace("openmenu: FieldCommandUtil not found"); return end
    local npc, label, x, y, z, d, cnt = npcInfo()
    trace("openmenu: npcs=%s nearest=%s at (%s,%s,%s) dist2=%s", tostring(cnt), tostring(label),
        tostring(x), tostring(y), tostring(z), tostring(d))
    local ok, err = pcall(function() util:OpenFieldCommandMenu() end)
    trace("openmenu: FieldCommandUtil:OpenFieldCommandMenu ok=%s err=%s", tostring(ok), tostring(err))
end

-- hand a list we built ourselves to the menu widget (also tests whether a plain
-- Lua table converts to TArray<MJFieldCommandType>)
local function cmdShowMenu(listStr)
    local npc, label = npcInfo()
    local ui = cdo("LibUI")
    if npc == nil or ui == nil then
        trace("showmenu: npc=%s ui=%s", tostring(npc ~= nil), tostring(ui ~= nil)); return
    end
    local list = {}
    for w in string.gmatch(listStr or "", "%d+") do list[#list + 1] = tonumber(w) end
    local names = {}
    for _, v in ipairs(list) do names[#names + 1] = fcStr(v) end
    trace("showmenu: npc=%s list=[%s]", tostring(label), table.concat(names, ","))
    local ok, err = pcall(function() ui:OpenFieldCommandMenu(npc, false, list) end)
    trace("showmenu: LibUI:OpenFieldCommandMenu ok=%s err=%s", tostring(ok), tostring(err))
end

-- Drive a field command directly (bypassing the menu) to prove that an OFF-PARTY
-- traveller's command can really be carried out. Only runs when the game itself says
-- the command is valid for that NPC (CanExecFieldCommand) - injecting an unsupported
-- command made the game retry in a loop and fatal error earlier.
local function cmdTestExec(arg)
    local t = tonumber(string.match(arg or "", "%d+"))
    if t == nil then trace("exec: no type number"); return end
    local util = cdo("FieldCommandUtil")
    if util == nil then trace("exec: no FieldCommandUtil"); return end

    -- scan every NPC in the level and keep the ones that accept this command
    local npcs = FindAllOf("KSFieldNPCCharacter_C")
    local fit, fitLabel = {}, nil
    if type(npcs) == "table" then
        for _, a in pairs(npcs) do
            local lbl = nil
            pcall(function()
                local comp = a:GetComponentByClass(StaticFindObject("/Script/Majesty.NpcPropertyComponent"))
                if comp and comp:IsValid() then
                    local f = comp:GetNpcLabel()
                    local okS, s = pcall(function() return f:ToString() end)
                    lbl = okS and tostring(s) or nil
                end
            end)
            if lbl ~= nil then
                local can = P(try("CanExecFieldCommand", function() return util:CanExecFieldCommand(FName(lbl), t) end))
                if can == true then
                    fit[#fit + 1] = a
                    if fitLabel == nil then fitLabel = lbl end
                end
            end
        end
    end
    trace("exec: type=%s NPCs accepting it=%d (first=%s)", fcStr(t), #fit, tostring(fitLabel))
    if #fit == 0 then trace("exec: no NPC accepts %s - aborting", fcStr(t)); return end

    local mgr = firstOfSafe("FieldCommandManager")
    if mgr == nil then
        local cls = StaticFindObject("/Script/Majesty.FieldCommandManager")
        mgr = cls and P(try("GetInstance", function() return cls:GetInstance() end))
    end
    trace("exec: manager=%s target=%s", tostring(mgr ~= nil), tostring(fitLabel))
    if mgr == nil then return end
    local ok1, e1 = pcall(function() mgr:SetStartParam(fit[1], t) end)
    trace("exec: SetStartParam ok=%s err=%s", tostring(ok1), tostring(e1))
    local ok2, e2 = pcall(function() mgr:StartFieldCommand() end)
    trace("exec: StartFieldCommand ok=%s err=%s", tostring(ok2), tostring(e2))
    ExecuteWithDelay(4000, function()
        trace("exec: 4s later, still alive; writing report")
        pcall(report)
    end)
end
function try(label, fn)
    local ok, r = pcall(fn)
    if not ok then log("%s -> ERROR %s", label, tostring(r)) return nil end
    return r
end

local S = {
    armed = false, inject = false, maxInject = 1, mode = "append",
    calls = 0, lastList = {}, lastCand = {}, lastResult = {}, trace = {},
    ownerFix = 0, ownerCalls = 0, flowType = nil, hookTarget = "none", bpProbe = false, inRebuild = false, flowLog = false,
    catMatch = true, autoInject = true, applyDelay = 1100, showOff = true,
    swapKey = false, expHook = true, expRatio = 100, expCalls = 0, expCalls2 = 0, mirroring = false,
    shareJp = false, jpRatio = 100, jpCalls = 0, lastMirrorClock = nil, lastJpClock = nil, lastWidget = nil, partyList = {}, offList = {}, offCount = 0,
}
function trace(fmt, ...)
    local m = (select('#', ...) > 0) and string.format(fmt, ...) or fmt
    S.trace[#S.trace + 1] = os.date("%H:%M:%S ") .. m
    if #S.trace > 40 then table.remove(S.trace, 1) end
    log("TRACE %s", m)
end

local function charFcTypes(id)
    local u = cdo("KSCharacterFunction")
    if not u then return {} end
    return toList(try("GetCharacterFieldCommandType(" .. id .. ")", function() return u:GetCharacterFieldCommandType(id) end))
end
local function inParty(id)
    local u = cdo("PartySaveDataUtil")
    if not u then return nil end
    return P(try("CheckInParty", function() return u:CheckInParty(id) end))
end
local function timeZone()
    local u = cdo("TimeZoneUtility")
    if not u then return nil end
    return tonumber(P(try("GetCurrentTimeZoneType", function() return u:GetCurrentTimeZoneType() end)))
end

-- Which category does a command belong to? Uses the game's own safe predicates
-- (UFieldCommandUtil::IsItemFc / IsInformationFc / IsFollowFc / IsSwoonFc: one enum in,
-- bool out, safe to call anytime).
local function fcCategory(t)
    local u = cdo("FieldCommandUtil")
    if u == nil then return "?" end
    local function q(fn)
        local ok, r = pcall(fn)
        if ok and P(r) == true then return true end
        return false
    end
    if q(function() return u:IsItemFc(t) end) then return "item" end
    if q(function() return u:IsInformationFc(t) end) then return "info" end
    if q(function() return u:IsFollowFc(t) end) then return "follow" end
    if q(function() return u:IsSwoonFc(t) end) then return "swoon" end
    return "battle"
end

-- off-party candidates: every traveller has exactly two commands ordered [day, night].
-- With matchCategory we only propose commands whose category the NPC already accepts -
-- injecting an unsupported command makes the game retry in a loop and then fatal error.
local function candidates(current, matchCategory)
    local have, allowed = {}, {}
    for _, v in ipairs(current) do
        local n = tonumber(v)
        have[n] = true
        allowed[fcCategory(n)] = true
    end
    local tz = timeZone()
    local isDay = (tz == 1 or tz == 2 or tz == nil)
    local out = {}
    for id = 1, 8 do
        if inParty(id) ~= true then
            local types = charFcTypes(id)
            local t = tonumber(isDay and types[1] or types[2])
            if t and t ~= 0 and not have[t] then
                local cat = fcCategory(t)
                if (not matchCategory) or allowed[cat] then
                    out[#out + 1] = t
                    have[t] = true
                    trace("cand char%d %-9s -> %-12s (%s)", id, CHAR_NAME[id] or "?", fcStr(t), cat)
                else
                    trace("cand char%d %-9s -> skip %-12s (%s not offered by this NPC)", id,
                        CHAR_NAME[id] or "?", fcStr(t), cat)
                end
            end
        end
    end
    local s = {}
    for _, v in ipairs(out) do s[#s + 1] = fcStr(v) end
    trace("candidates(match=%s)=[%s]", tostring(matchCategory), table.concat(s, ","))
    return out
end

local substituteOwner   -- forward declaration (assigned below)

local function listStr(l)
    local s = {}
    for i = 1, #l do if l[i] ~= nil then s[#s + 1] = fcStr(l[i]) end end
    return table.concat(s, ",")
end

-- Write a command set into the live menu. The array cannot grow, so we overwrite its
-- entries; then we keep the widget's own lookup maps in sync, because the cursor and
-- decide logic resolves panels/labels through them (a missing key leaves the menu
-- unresponsive - confirmed in game).
local function applyList(w, list, len)
    if w == nil or list == nil then return end
    local cmd = nil
    pcall(function() cmd = w.CurrentCommand end)
    cmd = P(cmd)
    if type(cmd) ~= "userdata" then trace("apply: no TArray"); return end

    local wrote = 0
    for i = 1, len do
        local t = list[i]
        if t ~= nil then
            local okW = pcall(function() cmd[i] = t end)
            if okW then wrote = wrote + 1 end
        end
    end

    -- panel visuals
    local panels = 0
    local panelOf = {}
    for i = 1, len do
        local panel = nil
        pcall(function() panel = w["FC" .. i] end)
        panelOf[i] = panel
        if panel ~= nil and list[i] ~= nil then
            local okP = pcall(function() w:SetupCommandPanel(panel, list[i]) end)
            if okP then panels = panels + 1 end
        end
    end

    -- AllCommandList: TMap<MJFieldCommandType, panel>
    local maps = 0
    local allMap = nil
    pcall(function() allMap = P(w.AllCommandList) end)
    trace("apply: allMap type=%s textMap type=%s", type(allMap), type(textMap))
    if allMap ~= nil and type(allMap) == "userdata" then
        for i = 1, len do
            if list[i] ~= nil and panelOf[i] ~= nil then
                local okM, errM = pcall(function() allMap:Add(list[i], panelOf[i]) end)
                if okM then maps = maps + 1 elseif i == 1 then trace("apply: AllCommandList:Add failed: %s", tostring(errM)) end
            end
        end
    end

    -- TextID: TMap<MJFieldCommandType, FName>
    local texts = 0
    local textMap = nil
    pcall(function() textMap = P(w.TextID) end)
    local du = cdo("FieldCommandDataUtility")
    if textMap ~= nil and type(textMap) == "userdata" and du ~= nil then
        for i = 1, len do
            local t = list[i]
            if t ~= nil then
                local lbl = try("GetFieldCommandNameLabel", function() return du:GetFieldCommandNameLabel(t) end)
                if lbl ~= nil then
                    local okT, errT = pcall(function() textMap:Add(t, lbl) end)
                    if okT then texts = texts + 1 elseif i == 1 then trace("apply: TextID:Add failed: %s", tostring(errT)) end
                end
            end
        end
    end

    local now = {}
    pcall(function() for i = 1, cmd:GetArrayNum() do now[#now + 1] = fcStr(cmd[i]) end end)
    trace("apply: wrote %d, panels %d, allMap %d, textMap %d -> [%s]",
        wrote, panels, maps, texts, table.concat(now, ","))
end

-- F5: switch between the party set and the off-party set.
-- Because the injection happens in the pre-body hook, the switch is done by closing the
-- open menu and asking the game to open it again - the game then rebuilds everything.
local function flipMenu()
    S.showOff = not S.showOff
    trace("flip -> next open will show %s", S.showOff and "OFF-PARTY" or "PARTY")
    local w = S.lastWidget
    if w ~= nil then pcall(function() w:Close(false) end) end
    ExecuteWithDelay(450, function()
        local util = cdo("FieldCommandUtil")
        if util ~= nil then
            local ok, err = pcall(function() util:OpenFieldCommandMenu() end)
            trace("flip: reopen ok=%s err=%s", tostring(ok), tostring(err))
        end
    end)
end

local function installHook()
    -- Two very different hook mechanisms in UE4SS:
    --   native ("/Script/...")  -> UFunction::FuncPtr hooking   [broke this game: Fatal Error]
    --   blueprint ("/Game/...") -> script hook via ProcessInternal [being tested]
    if S.hookTarget == "none" then
        S.armed = true
        log("no hook requested (hookTarget=none) - running as a pure utility mod")
        return
    end

    -- Two very different hook mechanisms in UE4SS:
    --   native ("/Script/...")  -> UFunction::FuncPtr hooking   [broke this game: Fatal Error]
    --   blueprint ("/Game/...") -> script hook via ProcessInternal [stable, but the menu
    --                              widget cannot be left in a consistent state]
    if S.hookTarget == "bp" then
        local bpath = "/Game/UserInterface/FieldCommand/BP/FieldCommandMenu.FieldCommandMenu_C:Open"
        local okb, errb = pcall(function()
            RegisterHook(bpath, function(self, TargetChara, DrawLeft, CommandList)
                S.calls = S.calls + 1
                local list = toList(P(CommandList))
                local names = {}
                for _, v in ipairs(list) do names[#names + 1] = fcStr(v) end
                S.lastList = list
                trace("BP Hook FieldCommandMenu:Open fired #%d target=%s drawLeft=%s list(%d)=[%s]",
                    S.calls, tostring(P(TargetChara)), tostring(P(DrawLeft)), #list, table.concat(names, ","))
                -- PRE or POST? If the panel array is already built, the body already ran.
                local pl = nil
                pcall(function() pl = P(w.CommandList) end)
                local plen, cur, st = -1, -1, -1
                if type(pl) == "userdata" then pcall(function() plen = pl:GetArrayNum() end)
                elseif type(pl) == "table" then plen = #pl end
                pcall(function() cur = tonumber(P(w.CurrentCursor)) end)
                pcall(function() st = tonumber(P(w.State)) end)
                trace("probe: panelArrayLen=%s cursor=%s state=%s -> body %s",
                    tostring(plen), tostring(cur), tostring(st), (plen and plen > 0) and "ALREADY RAN (post)" or "not run yet (PRE)")
                if not S.inject then return end

                -- experiment: mutate the widget's own command array, then rebuild the panels
                local w = P(self)
                if w == nil then trace("bp: no widget"); return end
                local cmd = nil
                pcall(function() cmd = w.CurrentCommand end)
                cmd = P(cmd)
                trace("bp: CurrentCommand type=%s", type(cmd))
                local before = -1
                if type(cmd) == "table" then
                    before = #cmd
                    local s = {}
                    for i = 1, #cmd do s[#s + 1] = fcStr(cmd[i]) end
                    trace("bp: CurrentCommand(lua table, %d)=[%s]", before, table.concat(s, ","))
                elseif type(cmd) == "userdata" then
                    local okN = pcall(function() before = cmd:GetArrayNum() end)
                    local s = {}
                    pcall(function() for i = 1, before do s[#s + 1] = fcStr(cmd[i]) end end)
                    trace("bp: CurrentCommand(TArray ok=%s, %s)=[%s]", tostring(okN), tostring(before), table.concat(s, ","))
                end

                local extra = candidates(list, S.catMatch)
                S.lastCand = extra
                if type(cmd) ~= "userdata" then trace("bp: CurrentCommand is not a TArray"); return end
                local len = 0
                pcall(function() len = cmd:GetArrayNum() end)
                if len <= 0 then trace("bp: empty command array"); return end

                -- remember both sets so a hotkey can switch between them on the live menu
                S.lastWidget = w
                S.partyList = {}
                for i = 1, len do S.partyList[i] = tonumber(list[i]) end
                S.offList = {}
                if S.mode == "offparty" then
                    for i = 1, len do S.offList[i] = extra[i] end
                else
                    -- keep party entries that have no off-party counterpart, fill the rest
                    local fill = 1
                    for i = 1, len do
                        S.offList[i] = tonumber(list[i])
                        if extra[fill] ~= nil then S.offList[i] = extra[fill] fill = fill + 1 end
                    end
                end
                S.offCount = 0
                for i = 1, len do if S.offList[i] ~= nil then S.offCount = S.offCount + 1 end end

                if S.offCount == 0 then
                    trace("bp: no off-party command valid for this NPC - menu left untouched")
                    return
                end
                if S.autoInject and S.showOff then
                    -- *** the clean way ***
                    -- Verified in game: this /Game/ hook callback runs BEFORE the blueprint body,
                    -- and the body works off the widget's CurrentCommand property (the incoming
                    -- parameter is only a copy). Rewriting the PROPERTY here makes the game build
                    -- panels, AllCommandList and TextID from our list itself - fully consistent,
                    -- and the menu stays operable.
                    local prop = nil
                    pcall(function() prop = P(w.CurrentCommand) end)
                    local wrote = 0
                    if type(prop) == "userdata" then
                        for i = 1, len do
                            local t = S.offList[i]
                            if t ~= nil then
                                local okW = pcall(function() prop[i] = t end)
                                if okW then wrote = wrote + 1 end
                            end
                        end
                    end
                    local arr = P(CommandList)
                    if type(arr) == "userdata" then
                        for i = 1, len do
                            local t = S.offList[i]
                            if t ~= nil then pcall(function() arr[i] = t end) end
                        end
                    end
                    trace("pre-inject: wrote %d entries -> [%s] (press F5 for the party set)",
                        wrote, listStr(S.offList))
                    local widget = w
                    ExecuteWithDelay(1300, function()
                        local now = {}
                        pcall(function()
                            local c2 = P(widget.CurrentCommand)
                            if type(c2) == "userdata" then
                                for i = 1, c2:GetArrayNum() do now[#now + 1] = fcStr(c2[i]) end
                            end
                        end)
                        trace("pre-inject verify: menu contents=[%s]", table.concat(now, ","))
                    end)
                else
                    trace("bp: showing the PARTY set (no injection); F5 switches to off-party")
                end
                ExecuteWithDelay(1200, function() pcall(report) end)
            end)
        end)
        S.armed = true
        log("BP hook -> %s %s (armed)", tostring(okb), tostring(errb))

        -- Observe (and optionally fix) who the game picks to perform the action.
        -- The flow blueprint is a /Game/ asset, so this is a stable script hook.
        if not S.flowLog then log("flow hook skipped (flowLog=0)") return end
        local fpath = "/Game/FieldCommand/BPv2/Flow/BP_FCv2_FieldCommandFlowBase.BP_FCv2_FieldCommandFlowBase_C:SetupFlow"
        local okf, errf = pcall(function()
            RegisterHook(fpath, function(self, targetNpc, TargetPlayer)
                local tp = P(TargetPlayer)
                local valid = false
                if tp ~= nil and type(tp) == "userdata" then
                    pcall(function() valid = tp:IsValid() end)
                end
                trace("FLOW SetupFlow: npc=%s TargetPlayer=%s valid=%s",
                    tostring(P(targetNpc)), tostring(tp), tostring(valid))
                S.lastFlow = P(self)
                if (not valid) and S.ownerFix > 0 and S.lastFlow ~= nil then
                    local ksf = cdo("KSCharacterFunction")
                    local p = ksf and P(try("GetPlayerObject", function() return ksf:GetPlayerObject() end))
                    if p ~= nil then
                        local okS = pcall(function() S.lastFlow:SetTargetPlayer(p) end)
                        trace("FLOW: forced SetTargetPlayer(player) ok=%s", tostring(okS))
                    end
                end
            end)
        end)
        log("flow hook -> %s %s", tostring(okf), tostring(errf))
        return
    end

    local path = "/Script/Majesty.FieldCommandUtil:GetPartyFieldCommand"
    local ok, err = pcall(function()
        RegisterHook(path,
            function() end,                     -- pre: do nothing
            function(_, AvaiableOnly, TargetChara, CanUseCommand, FieldCommandList)
                S.calls = S.calls + 1
                local arr = P(FieldCommandList)
                local list = toList(arr)
                S.lastList = list
                local names = {}
                for _, v in ipairs(list) do names[#names + 1] = fcStr(v) end
                trace("hook#%d party list(%d)=[%s] paramType=%s", S.calls, #list, table.concat(names, ","), type(arr))
                -- PRE or POST? If the panel array is already built, the body already ran.
                local pl = nil
                pcall(function() pl = P(w.CommandList) end)
                local plen, cur, st = -1, -1, -1
                if type(pl) == "userdata" then pcall(function() plen = pl:GetArrayNum() end)
                elseif type(pl) == "table" then plen = #pl end
                pcall(function() cur = tonumber(P(w.CurrentCursor)) end)
                pcall(function() st = tonumber(P(w.State)) end)
                trace("probe: panelArrayLen=%s cursor=%s state=%s -> body %s",
                    tostring(plen), tostring(cur), tostring(st), (plen and plen > 0) and "ALREADY RAN (post)" or "not run yet (PRE)")
                if not S.inject then return end

                local extra = candidates(list)
                S.lastCand = extra
                if #extra == 0 then trace("inject: no candidate"); return end
                if type(FieldCommandList) ~= "userdata" then
                    trace("inject: cannot write back (param type %s)", type(FieldCommandList)); return
                end

                local newList = {}
                if S.mode == "offparty" then
                    -- replace the whole list with the off-party group
                    local n = 0
                    for _, t in ipairs(extra) do
                        if n >= S.maxInject then break end
                        newList[#newList + 1] = t; n = n + 1
                    end
                else
                    for _, v in ipairs(list) do newList[#newList + 1] = tonumber(v) end
                    local n = 0
                    for _, t in ipairs(extra) do
                        if n >= S.maxInject then break end
                        newList[#newList + 1] = t; n = n + 1
                    end
                end

                local okSet, errSet = pcall(function() FieldCommandList:set(newList) end)
                local back = toList(P(FieldCommandList))
                local bn = {}
                for _, v in ipairs(back) do bn[#bn + 1] = fcStr(v) end
                S.lastResult = back
                trace("inject mode=%s setOk=%s err=%s -> [%s]", S.mode, tostring(okSet), tostring(errSet), table.concat(bn, ","))
            end)
    end)
    S.armed = true
    log("hook %s -> %s (armed)", path, ok and "installed" or ("FAILED: " .. tostring(err)))

    ------------------------------------------------------------------
    -- Optional safety net for the "who executes it?" problem.
    -- Only registered when ownerfix.txt != 0, so a pure observation run keeps
    -- exactly ONE hook (GetPartyFieldCommand) and nothing else.
    ------------------------------------------------------------------
    if S.ownerFix == 0 then
        log("owner hook skipped (ownerFix=0) - observation-only mode")
        return
    end
    local opath = "/Script/Majesty.FieldCommandFlowBase:GetFieldCommandOwner"
    local ok2, err2 = pcall(function()
        RegisterHook(opath,
            function(self)
                local t = nil
                pcall(function() t = self:get().m_FieldCommandType end)
                S.flowType = tonumber(P(t))
            end,
            function(_, ret)
                local owner = P(ret)
                local valid = false
                if owner ~= nil and type(owner) == "userdata" then
                    pcall(function() valid = owner:IsValid() end)
                end
                if S.ownerFix == 0 then
                    if S.ownerCalls < 10 then
                        S.ownerCalls = S.ownerCalls + 1
                        trace("owner(type=%s) -> %s (fix=off)", fcStr(S.flowType),
                            valid and tostring(owner:GetFullName()) or "NONE")
                    end
                    return nil
                end
                if valid then
                    trace("owner(type=%s) -> %s (ok, no fix needed)", fcStr(S.flowType), tostring(owner:GetFullName()))
                    return nil
                end
                local sub = substituteOwner(S.flowType)
                trace("owner(type=%s) -> NONE; substituting %s (fix=%d)", fcStr(S.flowType),
                    sub and tostring(sub:GetFullName()) or "FAILED", S.ownerFix)
                if sub then return sub end
                return nil
            end)
    end)
    log("hook %s -> %s (owner fix mode %d)", opath, ok2 and "installed" or ("FAILED: " .. tostring(err2)), S.ownerFix)
end

-- Build a stand-in actor for the off-party traveller that owns FCType
local spawned = {}
function substituteOwner(fcType)
    local charId = FC_OWNER[tonumber(fcType) or -1]
    if not charId then return nil end
    if S.ownerFix == 1 then
        local ksf = cdo("KSCharacterFunction")
        local p = ksf and P(try("GetPlayerObject", function() return ksf:GetPlayerObject() end))
        if p and type(p) == "userdata" then return p end
        return nil
    end
    if S.ownerFix == 2 then
        if spawned[charId] then
            local a = spawned[charId]
            local ok, v = pcall(function() return a:IsValid() end)
            if ok and v then return a end
        end
        local ksf = cdo("KSCharacterFunction")
        if not ksf then return nil end
        local player = P(try("GetPlayerObject", function() return ksf:GetPlayerObject() end))
        local loc = nil
        if player then pcall(function() loc = player:K2_GetActorLocation() end) end
        local actor = nil
        local ok = pcall(function() actor = ksf:SpawnPlayerCharacter(charId, loc, 0) end)
        if ok and actor ~= nil and type(actor) == "userdata" then
            spawned[charId] = actor
            trace("spawned actor for char %d (%s): %s", charId, CHAR_NAME[charId] or "?", tostring(actor:GetFullName()))
            return actor
        end
        trace("spawn failed for char %d", charId)
    end
    return nil
end

local function charIdOf(a)
    local ok, id = pcall(function() return a.CharacterID end)
    if ok and id ~= nil then return tonumber(P(id)) end
    return nil
end

-- Field actor inventory: this answers "does an off-party traveller have a field actor?"
-- (property reads only - no function calls, so this is safe anywhere)
local function actorInventory()
    local out, nz, maxId = {}, 0, 0
    -- PartyCharaPropertyComponent::GetPlayerID() is the reliable way to learn which
    -- traveller a field actor belongs to (CharacterID is 0 for field party actors).
    local ppcClass = StaticFindObject("/Script/Majesty.PartyCharaPropertyComponent")
    local party = FindAllOf("KSPartyCharacter_C")
    if type(party) == "table" then
        for _, a in pairs(party) do
            local id = charIdOf(a)
            local pidx, pid = nil, nil
            pcall(function() pidx = tonumber(P(a.PartyIndex)) end)
            if ppcClass ~= nil then
                pcall(function()
                    local comp = a:GetComponentByClass(ppcClass)
                    if comp and comp:IsValid() then pid = tonumber(P(comp:GetPlayerID())) end
                end)
            end
            if pid and pid ~= 0 then nz = nz + 1 if pid > maxId then maxId = pid end end
            out[#out + 1] = string.format("KSPartyCharacter propPlayerID=%s(%s) CharacterID=%s partyIndex=%s",
                tostring(pid), CHAR_NAME[pid] or "-", tostring(id), tostring(pidx))
        end
    end
    local players = FindAllOf("KSPlayerCharacter_C")
    local pcnt = 0
    if type(players) == "table" then
        for _, a in pairs(players) do
            pcnt = pcnt + 1
            local pid = nil
            if ppcClass ~= nil then
                pcall(function()
                    local comp = a:GetComponentByClass(ppcClass)
                    if comp and comp:IsValid() then pid = tonumber(P(comp:GetPlayerID())) end
                end)
            end
            out[#out + 1] = string.format("KSPlayerCharacter propPlayerID=%s(%s) %s",
                tostring(pid), CHAR_NAME[pid] or "-", tostring(a:GetFullName()))
        end
    end
    local partner = FindAllOf("KSPartnerCharacter_C")
    local rcnt = 0
    if type(partner) == "table" then for _ in pairs(partner) do rcnt = rcnt + 1 end end
    return out, nz, maxId, pcnt, rcnt
end

local function report()
    local r = {}
    r[#r + 1] = "OT2FCLite report " .. os.date("%Y-%m-%d %H:%M:%S")
    r[#r + 1] = string.format("armed=%s inject=%s mode=%s maxInject=%d hookCalls=%d",
        tostring(S.armed), tostring(S.inject), S.mode, S.maxInject, S.calls)
    r[#r + 1] = "tz=" .. (TZ_NAME[timeZone() or 0] or "?")
    local pl, pn = toList(try("GetMainMemberCharacterIDs", function() return cdo("PartySaveDataUtil"):GetMainMemberCharacterIDs() end)), {}
    for _, v in ipairs(pl) do pn[#pn + 1] = tostring(v) end
    r[#r + 1] = "mainParty=[" .. table.concat(pn, ",") .. "]"
    r[#r + 1] = ""
    r[#r + 1] = "--- field actor inventory (does an off-party traveller have an actor?) ---"
    local inv, nz, maxId, pcnt, rcnt = actorInventory()
    for _, l in ipairs(inv) do r[#r + 1] = "  " .. l end
    r[#r + 1] = string.format("  summary: party actors with CharacterID!=0 = %d (maxId=%d), player actors = %d, partner actors = %d",
        nz, maxId, pcnt, rcnt)
    local npc, nlabel, nx, ny, nzpos, nd, npcCount = npcInfo()
    r[#r + 1] = string.format("  inField=%s (party ids!=0: %d, field npcs: %d)",
        tostring(nz > 0 or (npcCount or 0) > 30), nz, npcCount or -1)
    -- every field-character actor class, with its CharacterID: shows whether reserve travellers
    -- are actually spawned in the level (property reads only)
    local counts = {}
    local fe = FindAllOf("KSFieldCharacter_C")
    local total = 0
    if type(fe) == "table" then
        for _, a in pairs(fe) do
            total = total + 1
            local cn = "?"
            pcall(function() cn = tostring(a:GetClass():GetFName():ToString()) end)
            local key = string.format("%s id=%s", cn, tostring(charIdOf(a)))
            counts[key] = (counts[key] or 0) + 1
        end
    end
    local keys = {}
    for k in pairs(counts) do keys[#keys + 1] = k end
    table.sort(keys)
    r[#r + 1] = string.format("  field characters total=%d", total)
    for _, k in ipairs(keys) do r[#r + 1] = string.format("    %s x%d", k, counts[k]) end
    r[#r + 1] = string.format("  ownerFix=%d ownerCalls=%d", S.ownerFix, S.ownerCalls)
    r[#r + 1] = string.format("  nearestNpcLabel=%s pos=(%s, %s, %s) dist2=%s",
        tostring(nlabel), tostring(nx), tostring(ny), tostring(nzpos), tostring(nd))
    local plx, ply, plz = vecOf((function() local ksf = cdo("KSCharacterFunction") if ksf then return P(try("p", function() return ksf:GetPlayerObject() end)) end end)())
    r[#r + 1] = string.format("  playerPos=(%s, %s, %s)", tostring(plx), tostring(ply), tostring(plz))
    r[#r + 1] = ""
    for id = 1, 8 do
        local t = charFcTypes(id); local n = {}
        for _, v in ipairs(t) do n[#n + 1] = fcStr(v) end
        r[#r + 1] = string.format("  %d %-9s inParty=%-5s fc=[%s]", id, CHAR_NAME[id] or "?", tostring(inParty(id)), table.concat(n, ","))
    end
    local n = {}
    for _, v in ipairs(S.lastList) do n[#n + 1] = fcStr(v) end
    r[#r + 1] = "lastPartyList=[" .. table.concat(n, ",") .. "]"
    n = {}
    for _, v in ipairs(S.lastResult) do n[#n + 1] = fcStr(v) end
    r[#r + 1] = "lastInjectedList=[" .. table.concat(n, ",") .. "]"
    r[#r + 1] = "-- trace --"
    for _, l in ipairs(S.trace) do r[#r + 1] = "  " .. l end
    writeFile(MOD_DIR .. "/fc_lite_report.txt", table.concat(r, "\n") .. "\n")
    log("report written")
end

local function readCfg()
    local c = readFile(MOD_DIR .. "/inject.txt")
    if c then local w = (string.find(c, "1") ~= nil) if w ~= S.inject then S.inject = w log("cfg inject=%s", tostring(w)) end end
    local m = readFile(MOD_DIR .. "/mode.txt")
    if m then local w = string.match(m, "%a+") if w and w ~= S.mode then S.mode = w log("cfg mode=%s", w) end end
    local x = readFile(MOD_DIR .. "/max_inject.txt")
    if x then local v = tonumber(string.match(x, "%-?%d+")) if v and v ~= S.maxInject then S.maxInject = v log("cfg maxInject=%d", v) end end
    local bp = readFile(MOD_DIR .. "/bp_probe.txt")
    if bp then local w = (string.find(bp, "1") ~= nil) if w ~= S.bpProbe then S.bpProbe = w log("cfg bpProbe=%s", tostring(w)) end end
    local dv = readFile(MOD_DIR .. "/defaultview.txt")
    if dv then local w = (string.find(dv, "party") ~= nil) and false or (string.find(dv, "off") ~= nil)
        if w ~= nil and w ~= S.showOff then S.showOff = w log("cfg showOff=%s", tostring(w)) end end
    local ad = readFile(MOD_DIR .. "/applydelay.txt")
    if ad then local v = tonumber(string.match(ad, "%d+")) if v and v ~= S.applyDelay then S.applyDelay = v log("cfg applyDelay=%d", v) end end
    local cm = readFile(MOD_DIR .. "/catmatch.txt")
    if cm then local w = (string.find(cm, "1") ~= nil) if w ~= S.catMatch then S.catMatch = w log("cfg catMatch=%s", tostring(w)) end end
    local ai = readFile(MOD_DIR .. "/autoinject.txt")
    if ai then local w = (string.find(ai, "1") ~= nil) if w ~= S.autoInject then S.autoInject = w log("cfg autoInject=%s", tostring(w)) end end
    local fl = readFile(MOD_DIR .. "/flowlog.txt")
    if fl then local w = (string.find(fl, "1") ~= nil) if w ~= S.flowLog then S.flowLog = w log("cfg flowLog=%s", tostring(w)) end end
    local ht = readFile(MOD_DIR .. "/hooktarget.txt")
    if ht then local w = string.match(ht, "%a+") if w and w ~= S.hookTarget then S.hookTarget = w log("cfg hookTarget=%s", w) end end
    local o = readFile(MOD_DIR .. "/ownerfix.txt")
    if o then local v = tonumber(string.match(o, "%d+")) if v and v ~= S.ownerFix then S.ownerFix = v log("cfg ownerFix=%d", v) end end
    local sj = readFile(MOD_DIR .. "/sharejp.txt")
    if sj then local w = (string.find(sj, "1") ~= nil) if w ~= S.shareJp then S.shareJp = w log("cfg shareJp=%s", tostring(w)) end end
    local jr = readFile(MOD_DIR .. "/jpratio.txt")
    if jr then local v = tonumber(string.match(jr, "%d+")) if v and v ~= S.jpRatio then S.jpRatio = v log("cfg jpRatio=%d", v) end end
    local eh = readFile(MOD_DIR .. "/exphook.txt")
    if eh then local w = (string.find(eh, "1") ~= nil) if w ~= S.expHook then S.expHook = w log("cfg expHook=%s", tostring(w)) end end
    local er = readFile(MOD_DIR .. "/expratio.txt")
    if er then local v = tonumber(string.match(er, "%d+")) if v and v ~= S.expRatio then S.expRatio = v log("cfg expRatio=%d", v) end end
    local sk = readFile(MOD_DIR .. "/swapkey.txt")
    if sk then local w = (string.find(sk, "1") ~= nil) if w ~= S.swapKey then S.swapKey = w log("cfg swapKey=%s", tostring(w)) end end
end

-- ==========================================================================
-- Party hot-swap (F5)
--   The in-menu injection was rewritten to display correctly, but the widget's
--   internal lookup maps (AllCommandList / TextID) cannot be read or written from
--   Lua, so the rewritten menu could not be operated. This path avoids the widget:
--   we call the game's own debug command so the benched travellers actually join the
--   party - after which field actors, the path action menu and support skills all
--   behave natively. Trade-off: the party composition really changes (save first!).
-- ==========================================================================
local function currentParty()
    local u = cdo("PartySaveDataUtil")
    if u == nil then return {} end
    return toList(try("GetMainMemberCharacterIDs", function() return u:GetMainMemberCharacterIDs() end))
end

local function partySwap()
    local cur = currentParty()
    local inset = {}
    for _, v in ipairs(cur) do inset[tonumber(v)] = true end
    local reserve = {}
    for id = 1, 8 do if not inset[id] then reserve[#reserve + 1] = id end end
    if #reserve < 4 then
        trace("swap: no full reserve party (current=[%s])", table.concat(cur, ","))
        return
    end
    local cmd = string.format("MJSetParty %d %d %d %d", reserve[1], reserve[2], reserve[3], reserve[4])
    trace("swap: current=[%s] -> '%s'", table.concat(cur, ","), cmd)
    cmdConsole(cmd)
    ExecuteWithDelay(2500, function()
        local now = currentParty()
        trace("swap: party is now [%s]", table.concat(now, ","))
        pcall(report)
    end)
end

-- Forward declarations: these helpers are defined further down (shared-EXP section) but
-- are called from the party-swap code above. Without this, `charLevel` resolved to a nil
-- global and pressing F5 threw an error that killed the keybind callback.
local charLevel, charExp, activeIds, benchedIds

-- Direct route (the same data the Cheat Engine tables edit):
--   AKSSaveDataManager -> GetGameSaveData() -> UMJSaveData.PlayerParty.MainMemberID[]
-- then ask the game to refresh the party so field actors and path actions follow.
local function partySwapViaSaveData()
    local mgr = firstOfSafe("KSSaveDataManagerBP_C") or firstOfSafe("KSSaveDataManager")
    trace("swap2: saveDataManager=%s", tostring(mgr ~= nil))
    if mgr == nil then return end
    local sd = P(try("GetGameSaveData", function() return mgr:GetGameSaveData() end))
    trace("swap2: saveData type=%s", type(sd))
    if sd == nil or type(sd) ~= "userdata" then return end

    local pp, main = nil, nil
    pcall(function() pp = P(sd.PlayerParty) end)
    trace("swap2: PlayerParty type=%s", type(pp))
    if pp ~= nil then pcall(function() main = P(pp.MainMemberID) end) end
    trace("swap2: MainMemberID type=%s", type(main))
    if type(main) ~= "userdata" then return end

    local n = 0
    pcall(function() n = main:GetArrayNum() end)
    local cur = {}
    pcall(function() for i = 1, n do cur[#cur + 1] = tonumber(P(main[i])) end end)
    trace("swap2: MainMemberID(%d)=[%s]  (0-based indices)", n, table.concat(cur, ","))

    -- PlayerParty.MainMemberID stores 0-based character indices, while
    -- UPartySaveDataUtil::GetMainMemberCharacterIDs() reports index+1. Verified on this save:
    -- stored [3,7,2,6] <-> reported [4,8,3,7].
    --
    -- Entries below 8 are the eight travellers; 8+ are story guests (EPlayableCharacterID
    -- eGUEST_000 = 9). We only swap the traveller slots and leave guest slots untouched,
    -- so F5 stays safe during chapters that force a temporary companion into the party.
    local travSlots = {}
    for i = 1, n do
        local v = cur[i]
        if v ~= nil and v < 8 then travSlots[#travSlots + 1] = i end
    end
    local inset = {}
    for _, i in ipairs(travSlots) do inset[(cur[i] or 0) + 1] = true end
    -- Only ever swap in travellers that actually exist in this save (level >= 1).
    -- Unrecruited slots read level 0, and putting those in the party would corrupt it.
    local reserve = {}
    for id = 1, 8 do
        if not inset[id] then
            local lv = charLevel(id)
            if lv ~= nil and lv >= 1 then
                reserve[#reserve + 1] = id
            else
                trace("swap2: char %d not recruited (level=%s) - excluded", id, tostring(lv))
            end
        end
    end
    trace("swap2: active=[%s] reserve=[%s] travellerSlots=%d guestSlots=%d",
        (function() local s = {} for _, i in ipairs(travSlots) do s[#s + 1] = tostring((cur[i] or 0) + 1) end return table.concat(s, ",") end)(),
        table.concat(reserve, ","), #travSlots, n - #travSlots)
    if #reserve < #travSlots then
        trace("swap2: ABORT - only %d reserve traveller(s) for %d slot(s)", #reserve, #travSlots)
        return
    end

    local wrote = 0
    for k, i in ipairs(travSlots) do
        local ok = pcall(function() main[i] = reserve[k] - 1 end)   -- store 0-based
        if ok then wrote = wrote + 1 end
    end
    local after = {}
    pcall(function() for i = 1, n do after[#after + 1] = tostring((tonumber(P(main[i])) or 0) + 1) end end)
    trace("swap2: wrote %d -> active becomes [%s]", wrote, table.concat(after, ","))

    local ksf = cdo("KSCharacterFunction")
    local pc = firstOfSafe("KSPlayerControllerBP_C") or firstOfSafe("PlayerController")
    if ksf ~= nil then
        local okR, errR = pcall(function() ksf:RefreshPartyAfterChangeMember(pc) end)
        trace("swap2: RefreshPartyAfterChangeMember ok=%s err=%s", tostring(okR), tostring(errR))
    end
    local psu = cdo("PartySaveDataUtil")
    if psu ~= nil then
        local okU, errU = pcall(function() psu:UpdateCurrentPartySet() end)
        trace("swap2: UpdateCurrentPartySet ok=%s err=%s", tostring(okU), tostring(errU))
    end
    ExecuteWithDelay(2500, function()
        trace("swap2: party is now [%s]", table.concat(currentParty(), ","))
        pcall(report)
    end)
end

-- ==========================================================================
-- Shared EXP for the benched travellers
--   The game grants EXP through the blueprint library helper
--       ULibCharacter_C::AddCharacterExp(int32 CharacterID, int32 AddExp,
--                                        UObject* WorldContext, bool& LevelUp)
--   Blueprint hooks are the stable kind on this game, so we hook it and mirror the
--   same gain onto the travellers who are not currently in the active party.
--   A recursion guard stops our own mirrored calls from being mirrored again.
--   Config: exphook.txt (0/1, default 1), expratio.txt (percent, default 100)
-- ==========================================================================
function charLevel(id)
    local u = cdo("CharacterSaveDataUtil")
    if u == nil then return nil end
    return tonumber(P(try("GetLevel_FromSaveCharacterData", function() return u:GetLevel_FromSaveCharacterData(id) end)))
end
function charExp(id)
    local u = cdo("CharacterSaveDataUtil")
    if u == nil then return nil end
    return tonumber(P(try("GetExp_FromSaveCharacterData", function() return u:GetExp_FromSaveCharacterData(id) end)))
end
function activeIds()
    local out = {}
    for _, v in ipairs(currentParty()) do out[#out + 1] = tonumber(P(v)) end
    return out
end
-- travellers that are not on the field AND actually exist in this save
function benchedIds()
    local inset = {}
    for _, v in ipairs(activeIds()) do inset[v] = true end
    local out = {}
    for id = 1, 8 do
        if not inset[id] then
            local lv = charLevel(id)
            if lv ~= nil and lv >= 1 then out[#out + 1] = id end
        end
    end
    return out
end
local function libCharacter()
    local c = StaticFindObject("/Game/Library/LibCharacter.Default__LibCharacter_C")
    if c ~= nil then return c end
    return firstOfSafe("LibCharacter_C")
end
-- Granting EXP: ULibCharacter_C::AddCharacterExp has an out-param (bool& LevelUp) and
-- blueprint calls with out-params cannot be marshalled from Lua (verified: ok=false).
-- Use the parameter-free pair instead:
--   UCharacterGrowTableUtility::CalcLevelFromTotalExp(exp) -> level
--   UCharacterSaveDataUtil::SetCharacterLevelAndExp(id, level, totalExp)
local function setTotalExp(id, newTotal)
    local u = cdo("CharacterSaveDataUtil")
    local g = cdo("CharacterGrowTableUtility")
    if u == nil then return false, nil end
    local lv = nil
    if g ~= nil then
        lv = tonumber(P(try("CalcLevelFromTotalExp", function() return g:CalcLevelFromTotalExp(newTotal) end)))
    end
    if lv == nil or lv < 1 then lv = 1 end
    local ok = pcall(function() u:SetCharacterLevelAndExp(id, lv, newTotal) end)
    return ok, lv
end

-- add EXP on top of a character's current total
local function grantExp(id, amount, worldContext)
    local cur = charExp(id)
    if cur == nil then return false end
    return setTotalExp(id, cur + amount)
end

-- Mirror one batch of EXP/JOINT to the benched travellers.
-- IMPORTANT: the game calls the grant once PER ACTIVE MEMBER (verified: 4 calls of 8 EXP),
-- so without de-duplication the bench would receive it 4 times. We mirror at most once per
-- short window, which corresponds to one battle result.
local function mirrorExpOnce(amount, worldContext)
    local t = os.clock()
    if S.lastMirrorClock ~= nil and (t - S.lastMirrorClock) < 1.5 then
        trace("EXP mirror skipped (same batch, %.2fs after last)", t - S.lastMirrorClock)
        return 0
    end
    S.lastMirrorClock = t
    local bench = benchedIds()
    if #bench == 0 then return 0 end
    local give = math.floor(amount * (S.expRatio / 100))
    if give <= 0 then return 0 end
    local done, before, after = 0, {}, {}
    for _, bid in ipairs(bench) do
        before[bid] = charExp(bid)
        if grantExp(bid, give, worldContext) then done = done + 1 end
        after[bid] = charExp(bid)
    end
    local detail = {}
    for _, bid in ipairs(bench) do
        detail[#detail + 1] = string.format("%s:%s->%s", CHAR_NAME[bid] or bid,
            tostring(before[bid]), tostring(after[bid]))
    end
    trace("EXP mirrored %d x %d to [%s]  (%s)", done, give, table.concat(bench, ","),
        table.concat(detail, " "))
    return done
end

-- JP works the same way, except the library function has no out-param so it can be called
-- directly: ULibCharacter_C::AddJobPoint(int32 CharacterID, int32 AddPoint, UObject* WorldContext)
local function charJp(id)
    local u = cdo("CharacterSaveDataUtil")
    if u == nil then return nil end
    return tonumber(P(try("GetJobPoint_FromSaveCharacterData", function() return u:GetJobPoint_FromSaveCharacterData(id) end)))
end
local function mirrorJpOnce(amount, worldContext)
    local t = os.clock()
    if S.lastJpClock ~= nil and (t - S.lastJpClock) < 1.5 then
        trace("JP mirror skipped (same batch)")
        return 0
    end
    S.lastJpClock = t
    local lib = libCharacter()
    if lib == nil then return 0 end
    local bench = benchedIds()
    if #bench == 0 then return 0 end
    local give = math.floor(amount * (S.jpRatio / 100))
    if give <= 0 then return 0 end
    local done, detail = 0, {}
    local u = cdo("CharacterSaveDataUtil")
    for _, bid in ipairs(bench) do
        local before = charJp(bid)
        local ok = pcall(function() lib:AddJobPoint(bid, give, worldContext) end)
        local after = charJp(bid)
        -- Fallback: if AddJobPoint did not take (Lua marshalling of the library call can fail
        -- on some UE4SS builds), write the value directly with the native setter, which has
        -- no output parameters and is therefore safe to call.
        if before ~= nil and (after == nil or after == before) and u ~= nil then
            local ok2 = pcall(function() u:SetCharacterJobPoint(bid, before + give) end)
            if ok2 then ok = true end
            after = charJp(bid)
        end
        if ok and after ~= nil and before ~= nil and after ~= before then done = done + 1 end
        detail[#detail + 1] = string.format("%s:%s->%s", CHAR_NAME[bid] or bid,
            tostring(before), tostring(after))
    end
    trace("JP mirrored %d x %d to [%s]  (%s)", done, give, table.concat(bench, ","), table.concat(detail, " "))
    return done
end

local function installExpHook()
    local path = "/Game/Library/LibCharacter.LibCharacter_C:AddCharacterExp"
    local ok, err = pcall(function()
        RegisterHook(path, function(self, CharacterID, AddExp, WorldContext, LevelUp)
            local id  = tonumber(P(CharacterID))
            local exp = tonumber(P(AddExp))
            if id == nil or exp == nil then return end
            if S.expCalls < 30 then
                S.expCalls = S.expCalls + 1
                trace("EXP hook #%d char=%s(%s) add=%s mirroring=%s", S.expCalls, tostring(id),
                    CHAR_NAME[id] or "-", tostring(exp), tostring(S.mirroring))
            end
            if S.mirroring or exp <= 0 then return end
            local isAct = false
            for _, v in ipairs(activeIds()) do if v == id then isAct = true break end end
            if not isAct then return end
            local wc = P(WorldContext)
            S.mirroring = true
            mirrorExpOnce(exp, wc)      -- de-duplicated: once per battle
            S.mirroring = false
        end)
    end)
    log("exp hook -> %s %s", tostring(ok), tostring(err))

    -- JP: ULibCharacter_C::AddJobPoint(int32, int32, UObject*) - no out-param, safe to call
    local jpath = "/Game/Library/LibCharacter.LibCharacter_C:AddJobPoint"
    local okj = pcall(function()
        RegisterHook(jpath, function(self, CharacterID, AddPoint, WorldContext)
            local id  = tonumber(P(CharacterID))
            local jp  = tonumber(P(AddPoint))
            if id == nil or jp == nil or jp <= 0 then return end
            if not S.shareJp then return end
            if S.jpCalls < 20 then
                S.jpCalls = S.jpCalls + 1
                trace("JP hook #%d char=%s(%s) add=%s", S.jpCalls, tostring(id), CHAR_NAME[id] or "-", tostring(jp))
            end
            if S.mirroring then return end
            local isAct = false
            for _, v in ipairs(activeIds()) do if v == id then isAct = true break end end
            if not isAct then return end
            local wc = P(WorldContext)
            S.mirroring = true
            mirrorJpOnce(jp, wc)
            S.mirroring = false
        end)
    end)
    log("jp hook -> %s", tostring(okj))

    -- secondary: the battle result screen reports the gained EXP per member
    local rpath = "/Game/UserInterface/Battle/Result/BP/BattleResultCharaExpWidget.BattleResultCharaExpWidget_C:SetupExp"
    local ok2 = pcall(function()
        RegisterHook(rpath, function(self, CurrentExp, NeedExp, LevelMax, GetExp)
            if S.expCalls2 < 20 then
                S.expCalls2 = S.expCalls2 + 1
                trace("RESULT SetupExp cur=%s need=%s max=%s gained=%s",
                    tostring(P(CurrentExp)), tostring(P(NeedExp)), tostring(P(LevelMax)), tostring(P(GetExp)))
            end
        end)
    end)
    log("result widget hook -> %s", tostring(ok2))
    return ok
end

readCfg()
-- The shared-EXP hook is registered lazily from the poll loop: the blueprint library is
-- not in memory at load time and UE4SS refuses to hook a function that does not exist yet.
if not S.expHook then log("exp hook disabled by config (exphook=0)") end
pcall(function() RegisterKeyBind(Key.F6, {}, function() S.inject = not S.inject log("inject=%s", tostring(S.inject)) end) end)
pcall(function() RegisterKeyBind(Key.F7, {}, report) end)
-- F5 party swap is OPT-IN (swapkey.txt = 1)
if S.swapKey then
    pcall(function() RegisterKeyBind(Key.F5, {}, function() pcall(partySwapViaSaveData) end) end)
    log("F5 party swap BOUND (swapkey=1)")
else
    log("F5 party swap NOT bound (swapkey=0)")
end

-- diagnostics for the shared-EXP feature
local function cmdLevels()
    local g = cdo("CharacterGrowTableUtility")
    local parts = {}
    for id = 0, 8 do
        local e = charExp(id)
        local lvCalc = nil
        if g ~= nil and e ~= nil then
            lvCalc = tonumber(P(try("CalcLevelFromTotalExp", function() return g:CalcLevelFromTotalExp(e) end)))
        end
        parts[#parts + 1] = string.format("id%d:lv=%s(calc=%s),exp=%s", id, tostring(charLevel(id)),
            tostring(lvCalc), tostring(e))
    end
    trace("levels| %s", table.concat(parts, "  "))
    trace("levels| active=[%s] benched=[%s]", table.concat(activeIds(), ","), table.concat(benchedIds(), ","))
end

local function cmdGrantExp(n)
    local bench = benchedIds()
    if #bench == 0 then trace("grantexp: no benched traveller found"); return end
    local id = bench[1]
    local before, lvBefore = charExp(id), charLevel(id)
    local ok = grantExp(id, n, P(firstOfSafe("KSPlayerControllerBP_C") or firstOfSafe("PlayerController")))
    local after, lvAfter = charExp(id), charLevel(id)
    trace("grantexp: %s(id=%d) +%d ok=%s  exp %s->%s  level %s->%s", CHAR_NAME[id] or "?", id, n,
        tostring(ok), tostring(before), tostring(after), tostring(lvBefore), tostring(lvAfter))
end

-- simulate one battle result: the game grants once per active member, so call the mirror
-- four times in a row and confirm only the first one actually writes
local function cmdTestMirror(amount)
    local wc = P(firstOfSafe("KSPlayerControllerBP_C") or firstOfSafe("PlayerController"))
    trace("testmirror: 4 consecutive mirror calls with %d (simulating one battle)", amount)
    for i = 1, 4 do
        local n = mirrorExpOnce(amount, wc)
        trace("testmirror: call %d -> mirrored %d character(s)", i, n)
    end
    ExecuteWithDelay(1500, function() cmdLevels() end)
end

local function poll()
    -- schedule the next tick FIRST so a failure below can never kill the loop
    ExecuteWithDelay(2000, poll)
    local ok, err = pcall(function()
        readCfg()
        S.tick = (S.tick or 0) + 1
        -- The EXP library helper only exists in memory once the game has loaded its
        -- blueprints, and UE4SS refuses to hook a function that is not in memory yet,
        -- so retry until it takes.
        if S.expHook and not S.expArmed and (S.tick % 3 == 1) and (S.expTries or 0) < 40 then
            S.expTries = (S.expTries or 0) + 1
            if installExpHook() then
                S.expArmed = true
                log("exp hook armed on attempt %d", S.expTries)
            end
        end
        -- arm on request; with autoarm.txt present, wait until we are actually in the field
        -- (never register hooks during title screen / save loading)
        if not S.armed then
            if readFile(MOD_DIR .. "/arm.txt") ~= nil then
                installHook()
            elseif readFile(MOD_DIR .. "/autoarm.txt") ~= nil then
                local _, nz, _, _, _ = actorInventory()
                local _, _, _, _, _, _, npcCount = npcInfo()
                -- in a town/field the level holds many NPCs; the title screen holds only a handful
                if nz and nz > 0 or (npcCount and npcCount > 30) then
                    trace("autoarm: looks like a field (party ids!=0: %s, npcs=%s) -> arming",
                        tostring(nz), tostring(npcCount))
                    installHook()
                end
            end
        end
        if readFile(MOD_DIR .. "/request_report") ~= nil then
            os.remove(MOD_DIR .. "/request_report")
            report()
        end
        if readFile(MOD_DIR .. "/cmd_levels.txt") ~= nil then
            os.remove(MOD_DIR .. "/cmd_levels.txt")
            cmdLevels()
        end
        local ge = readFile(MOD_DIR .. "/cmd_grantexp.txt")
        if ge ~= nil then
            os.remove(MOD_DIR .. "/cmd_grantexp.txt")
            cmdGrantExp(tonumber(string.match(ge, "%d+")) or 1000)
        end
        local tm = readFile(MOD_DIR .. "/cmd_testmirror.txt")
        if tm ~= nil then
            os.remove(MOD_DIR .. "/cmd_testmirror.txt")
            cmdTestMirror(tonumber(string.match(tm, "%d+")) or 100)
        end
        local cc = readFile(MOD_DIR .. "/cmd_console.txt")
        if cc ~= nil then
            os.remove(MOD_DIR .. "/cmd_console.txt")
            cmdConsole(cc)
            ExecuteWithDelay(1500, function() pcall(report) end)
        end
        if readFile(MOD_DIR .. "/cmd_openmenu.txt") ~= nil then
            os.remove(MOD_DIR .. "/cmd_openmenu.txt")
            cmdOpenMenu()
            ExecuteWithDelay(1500, function() pcall(report) end)
        end
        if readFile(MOD_DIR .. "/cmd_swap.txt") ~= nil then
            os.remove(MOD_DIR .. "/cmd_swap.txt")
            partySwap()
        end
        -- cmd_swap2.txt is handled by fastPoll() below (150 ms) so that the gamepad
        -- helper feels instant; keep only one owner of that file.
        if readFile(MOD_DIR .. "/cmd_flip.txt") ~= nil then os.remove(MOD_DIR .. "/cmd_flip.txt") flipMenu() end
        local te = readFile(MOD_DIR .. "/cmd_test_exec.txt")
        if te ~= nil then
            os.remove(MOD_DIR .. "/cmd_test_exec.txt")
            cmdTestExec(te)
        end        local sm = readFile(MOD_DIR .. "/cmd_show_menu.txt")
        if sm ~= nil then
            os.remove(MOD_DIR .. "/cmd_show_menu.txt")
            cmdShowMenu(sm)
            ExecuteWithDelay(1500, function() pcall(report) end)
        end
    end)
    if not ok then log("poll error (loop continues): %s", tostring(err)) end
end
pcall(function() ExecuteWithDelay(2000, poll) end)

-- ------------------------------------------------------------------
-- Fast trigger loop (150 ms) so the gamepad helper feels instant.
-- It only looks at one file, so the cost is negligible.
-- ------------------------------------------------------------------
local function fastPoll()
    ExecuteWithDelay(150, fastPoll)
    pcall(function()
        if S.swapping then return end
        if readFile(MOD_DIR .. "/cmd_swap2.txt") ~= nil then
            os.remove(MOD_DIR .. "/cmd_swap2.txt")
            S.swapping = true
            log("swap triggered by file (gamepad helper)")
            partySwapViaSaveData()
            ExecuteWithDelay(3500, function() S.swapping = false end)
        end
    end)
end
pcall(function() ExecuteWithDelay(1500, fastPoll) end)

log("ready. armed=%s inject=%s mode=%s maxInject=%d (create %s/arm.txt to register the hook)",
    tostring(S.armed), tostring(S.inject), S.mode, S.maxInject, MOD_DIR)
