--[[
* jobnag.lua - upkeep reminders for whatever job you are actually on.
*
* Reads your main job and level every frame and nags for that job's own
* upkeep. Nothing to switch, nothing to configure per job - change job at a
* moogle and the reminders change with you.
*
* TWO KINDS OF REMINDER
*   BUFF   something that should be up and is not (Hasso, Utsusemi, Protect).
*          Red once the ability is off cooldown, amber while it is recasting
*          so you can see how long you are stuck.
*   READY  something sitting off cooldown and unused (Meditate, Chakra).
*          Amber after a grace period, so a freshly spent ability does not
*          flash at you the moment it comes back.
*
* Both are gated on the level that actually grants the ability, so nothing is
* ever suggested that you cannot do.
*
* NOT DUPLICATED HERE: cdchime already nags for DRG Jump, WAR Berserk, PUP
* maneuvers and idle pets. Adding those again would double up.
*
* Its own module because cdchime.lua's d3d_present closure is at Lua's
* 60-upvalue ceiling - one more file-scope local in there breaks the addon.
*
* Commands: /nag        what it is watching right now
*           /nag off    silence it     /nag on     bring it back
*           /nag speak  say the red ones out loud
--]]

require('common');
local imgui = require('imgui');
local chat = require('chat');
local settings = require('settings');

local defaults = T{ enabled = true, speak = true, grace = 6.0 };   -- on, and spoken, out of the box
local cfg = settings.load(defaults, 'jobnag');
local function Save() settings.save('jobnag'); end

----------------------------------------------------------------------------
-- What each job should be keeping up. Levels are HORIZON levels.
--   buffs  { buff name, ability that applies it, level, [alternative buff] }
--   ready  { ability, level, grace seconds, severity }
----------------------------------------------------------------------------
local JOBS = {
    SAM = {
        buffs = { { 'Hasso', 'Hasso', 25, 'Seigan' } },
        ready = { { 'Meditate', 30, 6, 'warn' },
                  { 'Third Eye', 15, 8, 'text' },
                  { 'Meikyo Shisui', 1, 25, 'text' } },
    },
    NIN = {
        -- Shadows are the whole job. Ichi covers you until Ni is learned.
        buffs = { { 'Copy Image', 'Utsusemi: Ni', 37, 'Copy Image (3)' } },
        ready = { { 'Yonin', 40, 10, 'text' }, { 'Innin', 40, 10, 'text' } },
    },
    THF = {
        ready = { { 'Sneak Attack', 15, 4, 'warn' },
                  { 'Trick Attack', 30, 4, 'text' },
                  { 'Flee', 25, 30, 'text' } },
    },
    WAR = {
        -- Berserk is cdchime's already; these are the ones it does not cover.
        ready = { { 'Aggressor', 45, 8, 'warn' },
                  { 'Warcry', 35, 8, 'text' },
                  { 'Mighty Strikes', 1, 30, 'text' } },
    },
    MNK = {
        -- Horizon levels: Focus 15, Dodge 25, Chakra 35, Counterstance 45.
        -- Boost is the one that matters: red and spoken the moment it sits
        -- unused in a fight, because a 30 second recast you forget is DPS
        -- left on the floor every half minute.
        buffs = { { 'Counterstance', 'Counterstance', 45 } },
        -- Focus is the accuracy buff: loud too, and silent while it is up.
        ready = { { 'Boost', 5, 2, 'crit' }, { 'Focus', 15, 4, 'crit' },
                  { 'Dodge', 25, 12, 'text' }, { 'Chakra', 35, 10, 'text' } },
    },
    RNG = {
        ready = { { 'Sharpshot', 20, 8, 'warn' }, { 'Barrage', 30, 8, 'text' },
                  { 'Scavenge', 25, 30, 'text' } },
    },
    BST = {
        ready = { { 'Reward', 12, 6, 'warn' }, { 'Call Beast', 23, 20, 'text' } },
    },
    PUP = {
        -- Maneuvers and idle pets are cdchime's job; this is the rest.
        ready = { { 'Repair', 40, 10, 'text' }, { 'Activate', 1, 15, 'text' } },
    },
    DRG = {
        -- Jump is cdchime's already.
        ready = { { 'Ancient Circle', 35, 20, 'text' } },
    },
    PLD = {
        buffs = { { 'Defense Boost', 'Defender', 10 } },
        ready = { { 'Sentinel', 30, 8, 'warn' }, { 'Shield Bash', 15, 8, 'text' } },
    },
    DRK = {
        ready = { { 'Last Resort', 15, 8, 'warn' }, { 'Weapon Bash', 30, 8, 'text' },
                  { 'Souleater', 30, 10, 'text' } },
    },
};

----------------------------------------------------------------------------
-- Resource lookups, resolved once by NAME so a renumbering cannot break them
----------------------------------------------------------------------------
local timerIds, buffIds, resolved = {}, {}, false

local function Resolve()
    local res = AshitaCore:GetResourceManager();
    local wantA, wantB = {}, {};
    for _, spec in pairs(JOBS) do
        for _, b in ipairs(spec.buffs or {}) do
            wantB[b[1]] = true; wantA[b[2]] = true;
            if (b[4]) then wantB[b[4]] = true; end
        end
        for _, r in ipairs(spec.ready or {}) do wantA[r[1]] = true; end
    end
    for id = 0, 2048 do
        local ok, a = pcall(function () return res:GetAbilityById(id); end);
        if (ok) and (a ~= nil) and (a.RecastTimerId ~= nil) and (a.Name ~= nil) then
            local n = a.Name[1];
            if (n ~= nil) and (wantA[n]) then timerIds[n] = a.RecastTimerId; end
        end
    end
    for id = 0, 1024 do
        local ok, st = pcall(function () return res:GetStatusIconByIndex(id); end);
        if (ok) and (st ~= nil) and (st.Name ~= nil) then
            local n = st.Name[1];
            if (n ~= nil) and (wantB[n]) then buffIds[n] = id; end
        end
    end
    resolved = true;
end

--[[
* Seconds until usable. 0 = ready, nil = the character does not have it.
* An absent recast slot means never used this session, which is ready.
--]]
local function Recast(name)
    local tid = timerIds[name];
    if (tid == nil) then return nil; end
    local ok, v = pcall(function ()
        local mm = AshitaCore:GetMemoryManager():GetRecast();
        for x = 0, 31 do
            if (mm:GetAbilityTimerId(x) == tid) then
                return mm:GetAbilityTimer(x) / 60.0;
            end
        end
        return 0;
    end);
    if (not ok) then return nil; end
    return v;
end

local function HasBuff(name)
    local id = buffIds[name];
    if (id == nil) then return false; end
    local ok, found = pcall(function ()
        local pl = AshitaCore:GetMemoryManager():GetPlayer();
        if (pl == nil) then return false; end
        for _, b in pairs(pl:GetBuffs()) do
            if (b == id) then return true; end
        end
        return false;
    end);
    return (ok and found) or false;
end

----------------------------------------------------------------------------
-- Current job, straight from the client
----------------------------------------------------------------------------
local function Job()
    -- pcall returns (ok, job, level); the level must be captured here or
    -- every "lvl >= minLvl" below compares a number with nil and throws
    -- inside d3d_present.
    local ok, j, lvl = pcall(function ()
        local p = AshitaCore:GetMemoryManager():GetPlayer();
        if (p == nil) then return nil, 0; end
        local job = AshitaCore:GetResourceManager():GetString('jobs', p:GetMainJob());
        if (type(job) == 'string') then job = job:gsub('%z', ''); end
        return job, p:GetMainJobLevel();
    end);
    if (not ok) or (j == nil) then return nil, 0; end
    return j, tonumber(lvl) or 0;
end

local function Engaged()
    local ok, eng = pcall(function ()
        local ent = GetPlayerEntity();
        return (ent ~= nil) and (ent.Status == 1);
    end);
    return (ok and eng) or false;
end

----------------------------------------------------------------------------
-- State
----------------------------------------------------------------------------
local engagedSince, readySince, lastSpoke = 0, {}, {};

local function Speak(msg)
    if (not cfg.speak) then return; end
    local now = os.clock();
    if ((now - (lastSpoke[msg] or -99)) < 20) then return; end
    lastSpoke[msg] = now;
    if (_G.cdchimeSpeak ~= nil) then pcall(_G.cdchimeSpeak, msg); end
end

local function Nags()
    local out = {};
    local job, lvl = Job();
    if (job == nil) then return out, job, lvl; end
    local spec = JOBS[job];
    if (spec == nil) then return out, job, lvl; end

    if (not Engaged()) then
        engagedSince = 0; readySince = {};
        return out, job, lvl;
    end
    if (engagedSince == 0) then engagedSince = os.clock(); end
    local fighting = os.clock() - engagedSince;

    -- buffs that should be up
    for _, b in ipairs(spec.buffs or {}) do
        local name, ability, minLvl, alt = b[1], b[2], b[3], b[4];
        if (lvl >= minLvl) and (fighting >= 4) then
            if (not HasBuff(name)) and ((alt == nil) or (not HasBuff(alt))) then
                local r = Recast(ability);
                if (r ~= nil) and (r <= 0) then
                    out[#out + 1] = { ability:upper() .. ' IS DOWN', 'crit' };
                    Speak(ability .. ' is down');
                elseif (r ~= nil) then
                    out[#out + 1] = { ('%s down - %ds'):fmt(ability, math.ceil(r)), 'warn' };
                end
            end
        end
    end

    -- abilities sitting unused
    for _, a in ipairs(spec.ready or {}) do
        local name, minLvl, grace, sev = a[1], a[2], a[3] or cfg.grace, a[4] or 'text';
        if (lvl >= minLvl) then
            local r = Recast(name);
            if (r ~= nil) and (r <= 0) and (not HasBuff(name)) then
                if (readySince[name] == nil) then readySince[name] = os.clock(); end
                if ((os.clock() - readySince[name]) >= grace) and (fighting >= grace) then
                    out[#out + 1] = { name .. ' ready', sev };
                    if (sev == 'warn') or (sev == 'crit') then Speak(name); end
                end
            else
                readySince[name] = nil;
            end
        end
    end

    return out, job, lvl;
end

----------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------
ashita.events.register('command', 'jobnag_cmd_cb', function (e)
    local args = e.command:args();
    if (#args == 0) or (args[1] ~= '/nag') then return; end
    e.blocked = true;
    local sub = args[2] and args[2]:lower() or 'list';

    if (sub == 'off') or (sub == 'on') then
        cfg.enabled = (sub == 'on'); Save();
        print(chat.header('jobnag'):append(chat.message('Reminders '))
            :append(cfg.enabled and chat.success('ON') or chat.error('OFF')));
        return;
    end
    if (sub == 'speak') then
        cfg.speak = (cfg.speak == false); Save();
        print(chat.header('jobnag'):append(chat.message('Spoken reminders '))
            :append(cfg.speak and chat.success('ON') or chat.error('OFF')));
        return;
    end

    if (not resolved) then Resolve(); end
    local _, job, lvl = Nags();
    local spec = JOBS[job or ''];
    print(chat.header('jobnag'):append(chat.message(
        ('%s%d - %s'):fmt(job or '??', lvl or 0,
            spec and 'watching' or 'nothing set up for this job'))));
    if (spec == nil) then return; end
    for _, b in ipairs(spec.buffs or {}) do
        if (lvl >= b[3]) then
            print(chat.header('jobnag'):append(chat.message(
                ('   %-16s %s'):fmt(b[2], HasBuff(b[1]) and 'UP' or 'down'))));
        end
    end
    for _, a in ipairs(spec.ready or {}) do
        if (lvl >= a[2]) then
            local r = Recast(a[1]);
            print(chat.header('jobnag'):append(chat.message(
                ('   %-16s %s'):fmt(a[1],
                    (r == nil) and 'not learned' or ((r <= 0) and 'READY' or ('%ds'):fmt(math.ceil(r)))))));
        end
    end
end);

----------------------------------------------------------------------------
-- Window
----------------------------------------------------------------------------
ashita.events.register('d3d_present', 'jobnag_present_cb', function ()
    if (cfg.enabled == false) then return; end
    if (not resolved) then Resolve(); end

    local list = Nags();
    if (#list == 0) then return; end

    local th = _G.cdchimeTheme;
    if (th ~= nil) and (not th.Enabled('cdchime_jobnag')) then return; end

    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing);
    if (th ~= nil) then
        th.Push('cdchime_jobnag');
    else
        imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 8.0);
        imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 2.0);
        imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 14.0, 10.0 });
        imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.13, 0.06, 0.06, 0.90 });
        imgui.PushStyleColor(ImGuiCol_Border, { 1.0, 0.55, 0.35, 0.9 });
    end

    if (imgui.Begin('cdchime_jobnag', true, flags)) then
        local scale = (th ~= nil) and th.Scale('cdchime_jobnag') or 1.0;
        if (th ~= nil) and (scale ~= 1.0) then th.PushScale(scale); end
        for _, n in ipairs(list) do
            local col;
            if (n[2] == 'crit') then
                col = (th ~= nil) and th.Col('crit') or { 1.0, 0.42, 0.36, 1.0 };
            elseif (n[2] == 'warn') then
                col = (th ~= nil) and th.Col('warn') or { 1.0, 0.85, 0.40, 1.0 };
            else
                col = (th ~= nil) and th.Col('text') or { 1.0, 1.0, 1.0, 0.95 };
            end
            imgui.TextColored(col, n[1]);
        end
        if (th ~= nil) and (scale ~= 1.0) then th.PopScale(); end
    end
    imgui.End();

    if (th ~= nil) then
        th.Pop();
    else
        imgui.PopStyleColor(2);
        imgui.PopStyleVar(3);
    end
end);

return { Nags = Nags };
