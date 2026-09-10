--[[
* cdchime - "Ready" popup for ALL ability cooldowns, automatically.
*
* Watches every ability recast slot the game tracks - ALL cooldowns, no
* minimum. When any cooldown finishes, a toast shows "<name> ready" for a
* few seconds, and clears instantly when you use the ability. Use
* /cdchime mute <name> for anything too chatty. Popups only; spoken alerts
* are optional and play from voice clips that ship with the addon.
*
* Spells are opt-in (Utsusemi: Ni by default) since most spell recasts are
* too short/frequent to be useful AL.alerts.
*
* Usage: /cdchime list          - show tracked cooldowns
*        /cdchime config        - palette, frame, per-window on/off + scale
*        /cdchime layout        - drag every window into place
*        /cdchime mute <name>   - never popup for that ability
*        /cdchime unmute <name>
*        /cdchime addspell <name>
* Read-only recast watching; informational only.
*
* LOOK (2026-08-21): every window's styling now comes from theme.lua - one
* palette shared by the popups, the placeholder window and (via "Match timer
* bars") the recast bars. Settings: <char>\cdtheme.lua.
--]]

addon.name      = 'heaphchimes';
addon.author    = 'Heaph';   -- creation assisted by ADA
addon.version   = '1.5';
addon.desc      = 'Cooldown popups, maneuver tiles, buff/recast timers, RNG range tracker.';

require('common');
local imgui = require('imgui');
local chat = require('chat');
local d3d8 = require('d3d8');
local ffi = require('ffi');
local d3d8_device = d3d8.get_device();

-- MERGED (2026-08-19): the former standalone 'cdtimers' addon (buff tiles,
-- recast bars, native-status-row hide, /cdtimers config) now lives in
-- timers.lua next to this file and is loaded here. It registers its own
-- event callbacks under 'timers_*' names, keeps its /cdtimers commands, and
-- its settings file is config\addons\cdchime\<char>\cdtimers.lua.
local theme = require('theme');   -- shared palette + per-window styling (/cdchime config)
require('petcast');               -- automaton nuke cadence timer (/petcast)
require('timers');
require('jobnag');    -- per-job upkeep reminders (/nag), auto-detects the job.
                      -- Its own module because this file's d3d_present is at
                      -- the 60-upvalue ceiling.
require('phtimer');   -- placeholder respawn timers (/ph). Uses cdchime's TTS via _G.cdchimeSpeak.
require('nmwindow');  -- NM repop WINDOW timers (/nm). Persists on os.time() so a
                      -- 50-minute window survives a reload.

--[[
* MANEUVER ICONS (2026-08-16). The game ships the real status icons; we pull
* them from the client's own resource manager and hand D3D textures to imgui.
* Same path statustimers/HXUI use, so it needs no external art.
*
* Status effect IDs are contiguous from Fire = 300 (verified against the
* tTimers ability-duration table, which maps ability 141..148 -> 300..307,
* and matches the server's `element = maneuver - FireManeuver`).
--]]
local MANEUVER_STATUS = {
    ['Fire Maneuver']    = 300, ['Ice Maneuver']   = 301,
    ['Wind Maneuver']    = 302, ['Earth Maneuver'] = 303,
    ['Thunder Maneuver'] = 304, ['Water Maneuver'] = 305,
    ['Light Maneuver']   = 306, ['Dark Maneuver']  = 307,
};
local MANEUVER_BY_ID = {};
for n, i in pairs(MANEUVER_STATUS) do MANEUVER_BY_ID[i] = n; end
local ICON_SIZE_TOAST = 28;   -- toast runs at PushScale(2.0)
local ICON_SIZE_RISK  = 20;   -- risk board runs at PushScale(1.5)
local ICON_SIZE_ACTIVE = 48;  -- active-maneuver tiles (icon + burned-in timer)
local TILE_GAP = 3;           -- pixels between tiles
local TIMER_SCALE = 2.0;      -- font scale for the countdown digits
-- imgui ships no bold face. Stamping the string on all 8 sides in dark and
-- laying the colour on top fattens the strokes and makes the digits legible
-- over any icon art. Widen these offsets to 2 for an even heavier weight.
local OUTLINE = {
    { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 },
    { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 },
};
-- Maneuvers last 60s (USER-confirmed; 15s recast). FALLBACK ONLY - the real
-- expiry comes from the game (see ManeuverTimers below).
local MANEUVER_DURATION = 60.0;

--[[
* REAL buff timers, straight from the client.
*
* Anchoring the countdown to the "overload chance" CHAT line runs ~2s slow:
* the chat arrives after the buff actually lands, so a modelled 60s countdown
* reads high for its whole life (observed 59 against the game's 57).
*
* The client stores an absolute expiry per status slot. Convert it the way
* statustimers does: subtract the Vana'diel epoch offset (in 1/60s units),
* handle the triennial rollover, then divide by 60 for seconds.
--]]
local VANA_BASE_STAMP = 0x3C307D70;
local INFINITE_DURATION = 0x7FFFFFFF;
local utcPtr = ashita.memory.find(
    'FFXiMain.dll', 0, '8B0D????????8B410C8B49108D04808D04808D04808D04C1C3', 2, 0);

local function GameUtcStamp()
    if (utcPtr == nil) or (utcPtr == 0) then return nil; end
    local p = ashita.memory.read_uint32(utcPtr);
    if (p == 0) then return nil; end
    p = ashita.memory.read_uint32(p);
    if (p == 0) then return nil; end
    return ashita.memory.read_uint32(p + 0x0C);
end

-- Returns { [statusId] = { secs, secs, ... } } sorted longest-first, or nil
-- when the signature scan failed (then we fall back to the modelled
-- countdown). A LIST, not one value: stacking three Wind gives three separate
-- buff slots all under status 302, each with its own expiry. Keeping only the
-- max made all three tiles show the same number.
local function ManeuverTimers()
    local stamp = GameUtcStamp();
    if (stamp == nil) then return nil; end
    local pl = AshitaCore:GetMemoryManager():GetPlayer();
    if (pl == nil) then return nil; end
    local icons = pl:GetStatusIcons();
    local timers = pl:GetStatusTimers();
    if (icons == nil) or (timers == nil) then return nil; end
    local comparand = (stamp - VANA_BASE_STAMP) * 60;
    local out = {};
    for j = 0, 31 do
        local id = icons[j + 1];
        if (id ~= nil) and (id >= 300) and (id <= 307) then
            local raw = timers[j + 1];
            if (raw ~= nil) and (raw ~= INFINITE_DURATION) then
                local left = raw - comparand;
                while (left < -2147483648) do left = left + 0xFFFFFFFF; end
                left = left / 60;
                if (left < 0) then left = 0; end
                out[id] = out[id] or {};
                table.insert(out[id], left);
            end
        end
    end
    for _, lst in pairs(out) do
        table.sort(lst, function (a, b) return a > b; end);
    end
    return out;
end

-- Seconds left on ONE status effect (largest if stacked), or nil if absent /
-- clock unavailable. Same read as ManeuverTimers, any id. Used to re-anchor
-- the Berserk clock from the real buff after a reload.
local function StatusLeft(wantId)
    local stamp = GameUtcStamp();
    if (stamp == nil) then return nil; end
    local pl = AshitaCore:GetMemoryManager():GetPlayer();
    if (pl == nil) then return nil; end
    local icons, timers = pl:GetStatusIcons(), pl:GetStatusTimers();
    if (icons == nil or timers == nil) then return nil; end
    local comparand = (stamp - VANA_BASE_STAMP) * 60;
    local best = nil;
    for j = 0, 31 do
        if (icons[j + 1] == wantId) then
            local raw = timers[j + 1];
            if (raw ~= nil and raw ~= INFINITE_DURATION) then
                local left = raw - comparand;
                while (left < -2147483648) do left = left + 0xFFFFFFFF; end
                left = left / 60;
                if (left < 0) then left = 0; end
                if (best == nil or left > best) then best = left; end
            end
        end
    end
    return best;
end

-- id -> imgui image handle. `false` = tried and failed, so a missing icon is
-- not re-decoded every single frame.
local iconCache = {};
local function StatusIcon(id)
    if (id == nil) then return nil; end
    local hit = iconCache[id];
    if (hit ~= nil) then return hit or nil; end
    iconCache[id] = false;
    local icon = AshitaCore:GetResourceManager():GetStatusIconByIndex(id);
    if (icon ~= nil) then
        local tex = ffi.new('IDirect3DTexture8*[1]');
        if (ffi.C.D3DXCreateTextureFromFileInMemoryEx(d3d8_device, icon.Bitmap,
                icon.ImageSize, 0xFFFFFFFF, 0xFFFFFFFF, 1, 0,
                ffi.C.D3DFMT_A8R8G8B8, ffi.C.D3DPOOL_MANAGED,
                ffi.C.D3DX_DEFAULT, ffi.C.D3DX_DEFAULT, 0xFF000000,
                nil, nil, tex) == ffi.C.S_OK) then
            -- gc_safe_release keeps the texture alive as long as the cache does
            local ptr = d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', tex[0]));
            iconCache[id] = { ptr = ptr, img = tonumber(ffi.cast('uint32_t', ptr)) };
        end
    end
    return iconCache[id] or nil;
end

-- Draws the maneuver's icon inline and leaves the cursor on the same line.
-- Returns false for anything that is not a maneuver, so ordinary cooldown
-- AL.toasts render exactly as before.
-- Main job 18 is Puppetmaster. Every maneuver/pet widget below is useless
-- on anything else, and several of them were firing on THF because their
-- only guards (a shared recast slot, a combat timer, a stale lastCast) are
-- not job-specific. One gate, checked per frame so it follows job changes.
-- Global, NOT local: a file-scope local referenced from the big
-- d3d_present closure would be its 61st upvalue and Lua caps that
-- at 60. Globals resolve via _ENV, which is already an upvalue.
-- Enemy nameplate toggle, driven by /cdchime plates (bound to N).
--
-- The Nameplate plugin exposes 'mode hidenpc' (hide all non-player plates)
-- and 'mode all', but /bind can only ever issue ONE fixed command, so the
-- alternating has to live somewhere. Here.
--
-- Global for the same reason as cdchimeIsPup: the render closure is at Lua's
-- 60-upvalue limit and a new file-scope local breaks the addon outright.
cdchimeNameplates = true;

function cdchimeTogglePlates()
    cdchimeNameplates = not cdchimeNameplates;
    AshitaCore:GetChatManager():QueueCommand(1,
        cdchimeNameplates and '/nameplate mode all' or '/nameplate mode hidenpc');
    print(chat.header('cdchime'):append(chat.message('Enemy nameplates '))
        :append(chat.success(cdchimeNameplates and 'SHOWN' or 'HIDDEN')));
end

function cdchimeIsPup()
    local pl = AshitaCore:GetMemoryManager():GetPlayer();
    return (pl ~= nil) and (pl:GetMainJob() == 18);
end

local function DrawManeuverIcon(name, size)
    local e = StatusIcon(MANEUVER_STATUS[name]);
    if (e == nil) then return false; end
    imgui.Image(e.img, { size, size }, { 0, 0 }, { 1, 1 });
    imgui.SameLine();
    return true;
end

local POPUP_SECONDS = 5;
local RISK_THRESHOLD = 10;   -- risk board: always show maneuvers at/above this overload %
-- EXACT SERVER MODEL (LandSandBoat source, 2026-08-15). Replaces the old
-- empirical fit of 0.186%/sec (713 readouts) - that regression was biased low
-- because readings only happen at press time and the reported chance CLAMPS
-- AT 0, so long gaps got truncated samples.
--
--   burden[element]  0..255, one counter per element, decays on the standard
--                    3-second effect tick:
--                      burden -= 1 + BURDEN_DECAY mods        (status_effect_container.cpp)
--   thresh           = 30 + OVERLOAD_THRESH  (Pup. Dastanas +5 -> 35)
--   reported chance  = clamp(burden - thresh + 5, 0, 255)     (automaton_entity.cpp)
--
-- Chance moves 1:1 with burden, so decay is 1 point / 3 sec = 0.3333 %/sec.
local DECAY_PER_SEC = 1 / 3;
-- Burden ADDED per maneuver (era module getAddBurdenValue), for reference:
--   Dark:  8 on Valoredge/Sharpshot, else 14
--   Other: statDiff = master stat - pet stat
--          >=4 -> 14 | 0..3 -> 19-statDiff | <0 -> 20
-- So a press adds 14 POINTS at statDiff>=4, not the ~11 the old fit assumed.
--
-- SAFE BAND: addBurden() only rolls when burden > thresh, but the reported
-- chance is burden-thresh+5. A readout of 1-5% therefore means burden is at
-- or below the threshold and the real risk is ZERO. 6% is the first number
-- that can actually overload you.
-- (RISK_THRESHOLD is 10, comfortably above that band, so the risk board can
-- never flag a maneuver that is incapable of overloading.)
local JUMP_PERIOD = 7.0;     -- seconds between "use Jump" nags while engaged
local JUMP_SHOW = 2.5;       -- visible portion of each nag cycle
local JUMP_NAG_AFTER = 10.0; -- grace: red nag only if Jump sits ready this long
local MAN_NAG_AFTER = 15.0;  -- maneuver timer sat ready this long unused -> nag
local MAN_NAG_PERIOD = 15.0; -- repeat interval while still unused
local PET_NAG_AFTER = 5.0;   -- engaged this long with pet out but idle -> nag
local PET_NAG_PERIOD = 5.0;  -- repeat interval while pet stays idle
local BUFF_NAG_AFTER = 10.0; -- engaged this long with <3 maneuver buffs -> nag
local BUFF_NAG_PERIOD = 12.0;-- repeat interval while understacked
local TP_NAG_PERIOD = 10.0;  -- repeat interval while TP sits at 1000+ unspent
local speakOn = true;        -- TTS: speak what the popups show (/cdchime say on|off)

-- GENERIC ALERTS (2026-08-19): a popup channel other addons/profiles can use
-- instead of chat. /cdchime alert <key> <text> shows a STICKY line until
-- /cdchime clear <key> (or AL.ALERT_MAX as a safety net); /cdchime toast
-- <text> shows a one-shot line for AL.TOAST_SECS. A leading '!' in the text
-- makes the line red. RNG.lua uses this for sweet-spot / Velocity Shot /
-- Scavenge so nothing hits the chat log.
local AL = {            -- ONE table: keeps present_cb under LuaJIT's 60-upvalue cap
    ALERT_MAX = 30,
    TOAST_SECS = 4,
    alerts = T{},          -- [key] = { text=, at=, id= }  id -> accent colour
    toasts = T{},          -- list of { text=, at=, id= }
    timers = T{},          -- [key] = { name=, endsAt= }  /cdchime timer countdowns
    range = { on = false, lo = 0, hi = 0, untilAt = 0 },
};

-- MERGED WINDOWS (2026-08-21): each popup can be routed into a shared host
-- window (Alerts, Group A, Group B) from /cdchime config instead of opening
-- its own. It becomes a coloured line there, keeping its accent via `id`.
-- Returns true when the line was handed to a host, so the caller skips its
-- own draw.
AL.groups = { cdchime_groupa = T{}, cdchime_groupb = T{} };

local function NagLine(id, text, secs)
    local target = theme.MergeTarget(id);
    if (target == '') then return false; end
    if (target == 'cdchime_alerts') then
        -- Sticky for a few seconds so a flashing nag does not strobe the line.
        AL.alerts[id] = { text = text, at = os.clock(), id = id, hold = secs or 3 };
        return true;
    end
    local bucket = AL.groups[target];
    if (bucket == nil) then return false; end
    bucket:append({ text = text, id = id });
    return true;
end

-- Draw one group window: the lines routed to it this frame.
local function DrawGroup(gid)
    local bucket = AL.groups[gid];
    if (bucket == nil) or (#bucket == 0) then return; end
    if (not theme.Enabled(gid)) then return; end
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing);
    theme.Push(gid);
    if (imgui.Begin(gid, true, flags)) then
        -- theme.PushScale, not the file-local PushScale: this function is
        -- defined above that local, so the name would resolve as a nil global.
        theme.PushScale(theme.Scale(gid));
        for _, ln in ipairs(bucket) do
            local text = ln.text;
            local col = theme.Accent(ln.id);
            if (text:sub(1, 1) == '!') then col = theme.Col('crit'); text = text:sub(2); end
            imgui.TextColored(col, text);
        end
        theme.PopScale();
    end
    imgui.End();
    theme.Pop();
end

-- RANGE TRACKER (2026-08-19): per-frame distance-to-target readout for RNG.
-- The job profile knows the weapon's sweet-spot window (it includes both
-- hitboxes) and arms this with /cdchime range <lo> <hi> [secs] on every shot
-- or WS; this side reads the live distance every frame and keeps the 'range'
-- alert current: "Too Close: 3.4" / "Too Far: 9.8", cleared inside the
-- window. It disarms by itself `secs` after the last arm (default 10), which
-- is the profile's "no attack for 10s" rule. /cdchime range off clears it.

local speakVol = 80;         -- TTS volume 0-100 (/cdchime volume N)

-- Maneuver identity problem: ALL eight maneuvers share ONE recast timer id,
-- so the timer alone can't tell us which maneuver was used. Horizon's
-- "<name> Maneuver overload chance is N%" chat line CAN - we watch it to
-- learn both the specific maneuver name and its overload chance.
local maneuverTimerId = nil;
local lastManeuver = nil;          -- name of the maneuver most recently used
local maneuverChance = T{};        -- [maneuver name] = {chance, at} - last overload % + when seen
-- Press times live SEPARATELY from maneuverChance on purpose. CurChance()
-- deletes a maneuverChance entry once its decayed overload % reaches 0, and
-- at the real decay rate (1/3 per sec) a 14% reading is gone in ~42s - well
-- before the 60s maneuver actually expires. Sharing one table made the
-- active-maneuver timers vanish. This one is only ever overwritten.
local maneuverAt = T{};            -- [maneuver name] = os.clock() of last press
local usePops = T{};               -- [maneuver name] = {chance, at} - popup on USE

-- Jump nag: while engaged with /DRG and Jump sitting ready, flash a reminder.
local jumpTimerId = nil;    -- Jump's recast timer id
local zerkTimerId = nil;    -- Berserk's recast timer id (/WAR)
local zerkNagOn = false;    -- polled: engaged + /WAR + Berserk ready + buff down
local zerkReadyAt = 0;      -- when Berserk last became usable
local zerkUsedAt = -999;    -- os.clock() when we last USED Berserk (chat-confirmed)
local ZERK_DURATION = 185;  -- 3min buff + margin; no nagging while it's up
local ZERK_RECAST = 300;    -- 5min recast - the nag only fires past this

local layout = false;       -- /cdchime layout: show every window for dragging
local jumpNagOn = false;    -- polled: engaged + /DRG + Jump off cooldown
local jumpCycleAt = 0;      -- start of the current nag cycle
local jumpReadyAt = 0;      -- when Jump last came off cooldown
local isEngaged = false;    -- polled: player entity status == engaged
local maneuverIdleAt = 0;   -- when the shared maneuver timer last became ready
local combatStartAt = 0;    -- when the player last became engaged
local petNagOn = false;     -- polled: engaged + pet out but NOT fighting
local manBuffCount = -1;    -- polled: active maneuver buffs (-1 = not applicable)
local activeManeuvers = T{};-- polled: {name, count, at} per element currently up
local tpReadyAt = 0;        -- when TP last crossed 1000

local abilityNames = T{};   -- [recastTimerId] = ability name
local tracked = T{};        -- [recastTimerId] = { prev, popup, popupAt }
local muted = T{};          -- [lowercase name] = true
local spellWatch = T{};     -- [spellId] = { name, prev, popup, popupAt }
local next_poll = 0;

-- Speak a phrase from the clips that ship with the addon (voice\<slug>.mp3,
-- recorded once in the Yan voice). Playback is the Windows MCI call in
-- winmm.dll, the same library other approved overlays use for sounds. Nothing
-- runs outside the game and nothing is written or sent anywhere.
-- Per-phrase debounce so render-loop calls don't machine-gun the voice.
-- MUST be defined above every handler that calls it (Lua upvalue capture).
local lastSpoken = T{};
local voiceDir = ('%s/voice/'):fmt(addon.path);
pcall(ffi.cdef, [[ int mciSendStringA(const char* cmd, char* ret, unsigned int retLen, void* hwnd); ]]);
local winmm = nil;
pcall(function () winmm = ffi.load('winmm'); end);
local mciRet = ffi.new('char[128]');
local function Mci(cmd)
    if (winmm == nil) then return nil; end
    local rc = winmm.mciSendStringA(cmd, mciRet, 128, nil);
    if (rc ~= 0) then return nil; end
    return ffi.string(mciRet);
end
local clipQueue = T{};
local clipOpen = false;      -- an alias is open on the device
local clipAlias = 'heaphvoice';
local function Slug(text)
    return (text:lower():gsub('[^a-z0-9]+', '_'):gsub('^_+', ''):gsub('_+$', ''));
end
-- mp3 first (the shipped set), then wav (what the Windows-voice fallback in
-- voice\make-voice-lines.ps1 writes).
local function ClipPath(text)
    local base = voiceDir .. Slug(text);
    for _, ext in ipairs({ '.mp3', '.wav' }) do
        local f = io.open(base .. ext, 'rb');
        if (f ~= nil) then f:close(); return base .. ext; end
    end
    return nil;
end
local function StopClip()
    if (clipOpen) then Mci('close ' .. clipAlias); clipOpen = false; end
end
local function StartClip(path)
    StopClip();
    local kind = (path:sub(-4):lower() == '.wav') and 'waveaudio' or 'mpegvideo';
    if (Mci(('open "%s" type %s alias %s'):fmt(path, kind, clipAlias)) == nil) then return false; end
    clipOpen = true;
    Mci(('setaudio %s volume to %d'):fmt(clipAlias, math.floor(speakVol * 10)));
    Mci('play ' .. clipAlias);
    return true;
end
-- called every frame: move to the next queued clip once the current one ends
local function PumpVoice()
    if (clipOpen) then
        local mode = Mci('status ' .. clipAlias .. ' mode');
        if (mode == nil or mode == 'stopped') then StopClip(); else return; end
    end
    if (#clipQueue == 0) then return; end
    local path = table.remove(clipQueue, 1);
    if (not StartClip(path)) then PumpVoice(); end
end
local function QueueClip(path)
    if (#clipQueue >= 4) then table.remove(clipQueue, 1); end
    clipQueue[#clipQueue + 1] = path;
end
local function Speak(text)
    if (not speakOn) or (text == nil) then return; end
    local now = os.clock();
    if (lastSpoken[text] ~= nil) and ((now - lastSpoken[text]) < 3.0) then return; end
    lastSpoken[text] = now;
    text = text:gsub('[\r\n]', ' ');
    local any = false;
    -- "Fire Maneuver used, 14 percent" is two clips; most lines are one
    for part in text:gmatch('[^,]+') do
        local path = ClipPath(part:gsub('^%s+', ''):gsub('%s+$', ''));
        if (path ~= nil) then QueueClip(path); any = true; end
    end
    if (not any) then
        local chime = ClipPath('Reminder');
        if (chime ~= nil) then QueueClip(chime); end
    end
end
_G.cdchimeSpeak = Speak;   -- phtimer.lua speaks through this

local function AddSpell(name)
    local res = AshitaCore:GetResourceManager();
    for id = 0, 1024 do
        local s = res:GetSpellById(id);
        if (s ~= nil) and (s.Name[1] ~= nil) and (string.lower(s.Name[1]) == string.lower(name)) then
            spellWatch[id] = { name = s.Name[1], prev = 0, popup = false };
            return s.Name[1];
        end
    end
    return nil;
end

ashita.events.register('d3d_present', 'voice_pump_cb', function ()
    PumpVoice();
end);
ashita.events.register('unload', 'voice_unload_cb', function ()
    clipQueue = T{}; StopClip();
end);
ashita.events.register('load', 'load_cb', function ()
    Speak('Voice ready');
    -- Berserk's clock is chat-anchored, so a reload forgets it. Assume the
    -- worst case (just expired, 2 min of recast left) rather than "ready":
    -- the per-tick re-anchor below corrects it the moment the buff is seen.
    zerkUsedAt = os.clock() - 180;   -- 180 = real buff length
    local res = AshitaCore:GetResourceManager();
    for id = 0, 2048 do
        local a = res:GetAbilityById(id);
        if (a ~= nil) and (a.Name[1] ~= nil) and (a.RecastTimerId ~= nil) and (a.RecastTimerId ~= 0) then
            abilityNames[a.RecastTimerId] = a.Name[1];
            if (a.Name[1]:find(' Maneuver') ~= nil) then
                maneuverTimerId = a.RecastTimerId;
            end
            if (a.Name[1] == 'Jump') then
                jumpTimerId = a.RecastTimerId;
            end
            if (a.Name[1] == 'Berserk') then
                zerkTimerId = a.RecastTimerId;
            end
        end
    end
    AddSpell('Utsusemi: Ni');
end);

-- Watch chat for Horizon's per-use overload readout to identify maneuvers.
ashita.events.register('text_in', 'zerk_watch_cb', function (e)
    -- "Heaph uses Berserk." - our own use starts the 3-minute buff window.
    local who = e.message:match('^(%a+) uses Berserk%.');
    if (who ~= nil) then
        local me = GetPlayerEntity();
        if (me ~= nil) and (who == me.Name) then
            zerkUsedAt = os.clock();
        end
    end
end);

-- CUSTOM POPUPS (2026-08-21): user-defined chat triggers. Each is a plain
-- Lua pattern tested against every incoming line; a match fires a popup
-- instead of making you watch the chat log. Captures from the pattern are
-- substituted into the text as $1..$9, so
--   /cdchime trigger add tod | (%a+) was defeated | $1 DOWN
-- turns the kill line into a popup naming the mob. Read-only; nothing is
-- sent and nothing is automated.
ashita.events.register('text_in', 'cdchime_trigger_cb', function (e)
    local trg = theme.cfg.triggers;
    if (trg == nil) then return; end
    local msg = e.message;
    if (msg == nil) or (msg == '') then return; end
    for name, t in pairs(trg) do
        if (t.pattern ~= nil) and (t.pattern ~= '') then
            local ok, c1, c2, c3 = pcall(string.match, msg, t.pattern);
            if (ok) and (c1 ~= nil) then
                local text = t.text or name;
                -- $1..$3 <- captures. string.match returns the whole match
                -- when the pattern has no captures, which is a fine $1.
                -- gsub reads '%' in a replacement as an escape, so a capture
                -- holding one ("14%") would throw; double it first.
                local function cap(v) return (tostring(v):gsub('%%', '%%%%')); end
                text = text:gsub('%$1', cap(c1));
                if (c2 ~= nil) then text = text:gsub('%$2', cap(c2)); end
                if (c3 ~= nil) then text = text:gsub('%$3', cap(c3)); end
                if (t.sticky) then
                    AL.alerts['trg_' .. name] = { text = text, at = os.clock(),
                        id = t.id, hold = t.secs or 10 };
                else
                    AL.toasts:append({ text = text, at = os.clock(), id = t.id });
                end
                if (t.speak) then Speak(text); end
            end
        end
    end
end);

ashita.events.register('text_in', 'text_in_cb', function (e)
    local who, name, chance = e.message:match("(%a+)'s (%a+ Maneuver) overload chance is (%d+)%%");
    if (name ~= nil) then
        -- Only OUR maneuvers: party PUPs print the exact same line shape.
        local me = GetPlayerEntity();
        if (me == nil) or (who ~= me.Name) then return; end
        lastManeuver = name;
        maneuverChance[name] = { chance = tonumber(chance), at = os.clock() };
        maneuverAt[name] = os.clock();   -- never pruned; drives the tile timers
        -- Popup on USE too (not just on refresh): shows the maneuver you
        -- just hit and its overload risk. Repeat presses refresh the timer.
        usePops[name] = { chance = tonumber(chance), at = os.clock() };
        local c = tonumber(chance);
        if (c > 0) then
            Speak(('%s used, %d percent'):fmt(name, c));
        else
            Speak(name .. ' used');
        end
    end
end);

local function Ready(entry, name)
    if (name ~= nil) and (muted[string.lower(name)]) then return; end
    entry.popup = true;
    entry.popupAt = os.clock();
    if (name ~= nil) then
        Speak(name .. ' ready');
    end
end

-- Text scaling, both engines: 4.2 has SetWindowFontScale; 4.3 uses
-- PushFont with a scaled size (pattern from the 4.3 Chains addon).
-- Call only between Begin/End.
local function PushScale(s)
    if (imgui.SetWindowFontScale ~= nil) then
        imgui.SetWindowFontScale(s);
    else
        imgui.PushFont(imgui.GetFont(), imgui.GetFontSize() * s);
    end
end
local function PopScale()
    if (imgui.SetWindowFontScale ~= nil) then
        imgui.SetWindowFontScale(1.0);
    else
        imgui.PopFont();
    end
end

-- Current overload chance for a maneuver, decayed from the last readout at
-- the measured DECAY_PER_SEC. Entries that reach 0 are dropped.
local function CurChance(name, now)
    local c = maneuverChance[name];
    if (c == nil) then return nil; end
    local v = c.chance - DECAY_PER_SEC * (now - c.at);
    if (v <= 0) then
        maneuverChance[name] = nil;
        return nil;
    end
    return math.floor(v + 0.5);
end

ashita.events.register('d3d_present', 'present_cb', function ()
    local now = os.clock();
    if (now >= next_poll) then
        next_poll = now + 0.4;
        local mm = AshitaCore:GetMemoryManager():GetRecast();

        for x = 0, 31 do
            local id = mm:GetAbilityTimerId(x);
            if (id ~= nil) and (id ~= 0) then
                local timer = mm:GetAbilityTimer(x);
                local t = tracked[id];
                if (t == nil) then
                    t = { prev = timer, popup = false };
                    tracked[id] = t;
                end
                if (t.prev > 0) and (timer == 0) then
                    -- Maneuver timer: label with the SPECIFIC maneuver last
                    -- used (from the overload chat line), not the shared id.
                    if (id == maneuverTimerId) and (lastManeuver ~= nil) then
                        t.label = lastManeuver;
                    else
                        t.label = abilityNames[id];
                    end
                    Ready(t, t.label);
                end
                if (timer > 0) then t.popup = false; end
                t.prev = timer;
                -- Maneuver-idle tracking: shared timer at 0 = a maneuver is
                -- ready and unused; any use puts it back on cooldown.
                if (id == maneuverTimerId) then
                    if (timer == 0) then
                        if (maneuverIdleAt == 0) then maneuverIdleAt = now; end
                    else
                        maneuverIdleAt = 0;
                    end
                end
            end
        end
        for spellId, e in pairs(spellWatch) do
            local timer = mm:GetSpellTimer(spellId);
            if (e.prev > 0) and (timer == 0) then Ready(e, e.name); end
            if (timer > 0) then e.popup = false; end
            e.prev = timer;
        end

        local ent = GetPlayerEntity();
        isEngaged = (ent ~= nil) and (ent.Status == 1);
        if (isEngaged) then
            if (combatStartAt == 0) then combatStartAt = now; end
        else
            combatStartAt = 0;
        end

        -- Pet-idle check: player fighting, pet summoned, pet NOT fighting.
        petNagOn = false;
        if (isEngaged) and (ent.PetTargetIndex ~= nil) and (ent.PetTargetIndex > 0) then
            local petStatus = AshitaCore:GetMemoryManager():GetEntity():GetStatus(ent.PetTargetIndex);
            petNagOn = (petStatus ~= nil) and (petStatus ~= 1);
        end

        -- Maneuver buffs are status ids 300-307, one entry per active
        -- maneuver. Read them UNCONDITIONALLY: maneuvers are up whether or
        -- not you are engaged, so gating this on combat made the icon board
        -- vanish the moment you stopped fighting (buffcount -1).
        local player = AshitaCore:GetMemoryManager():GetPlayer();
        local nMan, seen = 0, {};
        if (player ~= nil) then
            for _, b in pairs(player:GetBuffs()) do
                if (b ~= nil) and (b >= 300) and (b <= 307) then
                    nMan = nMan + 1;
                    local nm = MANEUVER_BY_ID[b];
                    if (nm ~= nil) then seen[nm] = (seen[nm] or 0) + 1; end
                end
            end
        end
        -- Real per-buff expiry when the client gives it to us; the press-time
        -- model is only a fallback if the signature scan came up empty.
        --
        -- Store an ABSOLUTE deadline, not "seconds left". This block only
        -- runs on the 0.4s poll, so a stored remaining-time would freeze
        -- between polls and then jump - that lag was the ~0.5s the game's own
        -- buff bar was ahead by. A deadline lets the render tick it smoothly
        -- every frame off a fresh os.clock().
        -- ONE ROW PER BUFF INSTANCE, not one per element with a count. Three
        -- stacked Wind are three independent buffs with three expiries, and
        -- each tile must carry its own.
        local realLeft = ManeuverTimers();
        activeManeuvers = T{};
        for nm, c in pairs(seen) do
            local lst = realLeft and realLeft[MANEUVER_STATUS[nm]] or nil;
            for k = 1, c do
                local l = lst and lst[k] or nil;
                activeManeuvers:append({
                    name = nm, at = maneuverAt[nm],
                    deadline = (l ~= nil) and (now + l) or nil,
                });
            end
        end
        -- Newest press first, BUT the comparator must be a total order or the
        -- row visibly shuffles: table.sort is not stable, this list is rebuilt
        -- every poll (0.4s), and ties are common - two maneuvers pressed in
        -- the same second, or several with at=nil all collapsing to 0. Name
        -- is the tiebreak, so tile order is deterministic frame to frame.
        -- Longest-remaining first, tiebroken by name then press time. Must be
        -- a TOTAL order: table.sort is unstable and this list is rebuilt every
        -- poll, so any tie lets the tiles swap places 2.5x a second.
        table.sort(activeManeuvers, function (a, b)
            local da, db = a.deadline or 0, b.deadline or 0;
            if (da ~= db) then return da > db; end
            if (a.name ~= b.name) then return a.name < b.name; end
            return (a.at or 0) > (b.at or 0);
        end);

        -- manBuffCount stays combat-gated on purpose: it drives the
        -- "understacked maneuvers" NAG, which should only scold you mid-fight.
        manBuffCount = -1;
        if (isEngaged) and (player ~= nil) and (player:GetMainJob() == 18)
            and (ent.PetTargetIndex ~= nil) and (ent.PetTargetIndex > 0) then
            manBuffCount = nMan;
        end

        -- TP tracking: mark the moment TP crosses 1000 (WS ready).
        local tp = AshitaCore:GetMemoryManager():GetParty():GetMemberTP(0);
        if (tp ~= nil) and (tp >= 1000) then
            if (tpReadyAt == 0) then tpReadyAt = now; end
        else
            tpReadyAt = 0;
        end

        -- Jump nag state: /DRG subjob + engaged + Jump off cooldown.
        jumpNagOn = false;
        if (jumpTimerId ~= nil) then
            local ready = true;
            for x = 0, 31 do
                if (mm:GetAbilityTimerId(x) == jumpTimerId) then
                    ready = (mm:GetAbilityTimer(x) == 0);
                    break;
                end
            end
            local player = AshitaCore:GetMemoryManager():GetPlayer();
            jumpNagOn = ready and (player ~= nil) and (player:GetSubJob() == 14) and isEngaged;
            if (ready) then
                if (jumpReadyAt == 0) then jumpReadyAt = now; end
            else
                jumpReadyAt = 0;
            end
        end

        -- Berserk nag: /WAR subjob (job id 1) + engaged + off cooldown AND
        -- the buff is NOT already up. Berserk is ~60% uptime (3min duration,
        -- 5min recast), so a dropped Berserk is real damage lost.
        -- Berserk state is driven ENTIRELY by the chat line "<you> uses
        -- Berserk" plus known timings. The recast-timer API proved
        -- unreliable for this subjob ability - it reported ready during the
        -- cooldown, which is what made the nag fire early and repeatedly.
        --   0-180s   buff up
        --   180-300s buff gone, still on cooldown  -> stay quiet
        --   300s+    genuinely usable              -> nag
        zerkNagOn = false;
        do
            local player = AshitaCore:GetMemoryManager():GetPlayer();
            -- Buff up -> we KNOW when it was used: now - (180 - remaining).
            local zLeft = StatusLeft(56);   -- 56 = Berserk status id
            if (zLeft ~= nil) then
                local usedAt = now - (180 - zLeft);
                if (usedAt > zerkUsedAt) then zerkUsedAt = usedAt; end
            end
            local since = now - zerkUsedAt;
            local ready = (since >= ZERK_RECAST);
            -- "In combat" = engaged OR shooting (the RNG profile arms the range
            -- tracker on every /ra and WS; it stays armed 10s after the last).
            local inCombat = isEngaged or AL.range.on;
            zerkNagOn = ready and (player ~= nil)
                and (player:GetSubJob() == 1) and inCombat;
            if (zerkNagOn) then
                if (zerkReadyAt == 0) then zerkReadyAt = now; end
            else
                zerkReadyAt = 0;
            end
        end

        for _, t in pairs(tracked) do
            if (t.popup) and (t.popupAt ~= nil) and ((now - t.popupAt) > POPUP_SECONDS) then t.popup = false; end
        end
        for _, e in pairs(spellWatch) do
            if (e.popup) and (e.popupAt ~= nil) and ((now - e.popupAt) > POPUP_SECONDS) then e.popup = false; end
        end
    end

    local lines = T{};
    for id, t in pairs(tracked) do
        if (t.popup) then
            local name = t.label or abilityNames[id] or 'Ability';
            lines:append({ name = name, chance = CurChance(name, now) });
        end
    end
    for name, u in pairs(usePops) do
        if ((now - u.at) > POPUP_SECONDS) then
            usePops[name] = nil;
        else
            lines:append({ name = name, chance = u.chance, used = true });
        end
    end
    for _, e in pairs(spellWatch) do
        if (e.popup) then
            lines:append({ name = e.name });
        end
    end
    -- Blink: smooth pulse ~2x/sec shared by border and text
    -- LAYOUT MODE: draw every window at once with sample text so they can be
    -- dragged into place. Same window IDs, so positions carry to the real
    -- AL.alerts. Nothing else renders while this is on.
    if (layout) then
        local demo = {
            { 'cdchime_toast',  'Fire Maneuver 21%', { 1.00, 1.00, 1.00 } },
            { 'cdchime_risk',   'Overload risk 24%', { 1.00, 0.88, 0.40 } },
            { 'cdchime_maneuvers', 'Maneuvers 3/3',  { 0.65, 0.85, 1.00 } },
            { 'cdchime_tpnag',  'TP Ready!',         { 0.55, 1.00, 0.60 } },
            { 'cdchime_jump',   'JUMP Ready!',       { 1.00, 0.55, 0.45 } },
            { 'cdchime_zerk',   'BERSERK Ready!',    { 1.00, 0.70, 0.35 } },
            { 'cdchime_mannag', 'Maneuver waiting!', { 1.00, 0.80, 0.45 } },
            { 'cdchime_petnag', 'Pet not engaged!',  { 0.85, 0.60, 1.00 } },
            { 'cdchime_buffnag','Maneuvers 1/3!',    { 0.55, 0.90, 1.00 } },
        };
        local lflags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoScrollbar,
            ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing);
        for _, d in ipairs(demo) do
            -- Draw with the live theme so what you position is what you get.
            theme.Push(d[1]);
            if (imgui.Begin(d[1], true, lflags)) then
                PushScale(theme.Scale(d[1]));
                imgui.TextColored(theme.TextCol(d[1]), d[2]);
                PopScale();
                imgui.TextColored(theme.Col('dim'), 'drag me - /cdchime layout to finish');
            end
            imgui.End();
            theme.Pop();
        end
        return;
    end

    -- Group buckets are rebuilt every frame: a nag routed to a group only
    -- shows while it is actually flashing, exactly as its own window would.
    for _, b in pairs(AL.groups) do
        while (#b > 0) do table.remove(b); end
    end

    local pulse = 0.45 + 0.55 * math.abs(math.sin(now * 4.0));
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing);

    if (#lines > 0) and (theme.Enabled('cdchime_toast')) then
        theme.Push('cdchime_toast', pulse);
        if (imgui.Begin('cdchime_toast', true, flags)) then
            PushScale(theme.Scale('cdchime_toast'));
            local ta = 0.55 + 0.45 * pulse;
            for _, line in pairs(lines) do
                -- USE popups read "<name> used"; ready popups are just the name.
                local label = line.used and (line.name .. ' used') or line.name;
                DrawManeuverIcon(line.name, ICON_SIZE_TOAST);
                imgui.TextColored(theme.Col('text', ta), label);
                -- Maneuvers show their last overload chance, color-coded:
                -- green <10, yellow 10-24, red 25+
                if (line.chance ~= nil) then
                    local c = line.chance;
                    local col = theme.Col('good', ta);
                    if (c >= 25) then col = theme.Col('crit', ta);
                    elseif (c >= 10) then col = theme.Col('warn', ta); end
                    imgui.SameLine();
                    imgui.TextColored(col, ('%d%%'):fmt(c));
                end
            end
            PopScale();
        end
        imgui.End();
        theme.Pop();
    end

    -- RANGE TRACKER: refresh the 'range' alert every frame while armed.
    if (AL.range.on) then
        if (now > AL.range.untilAt) then
            AL.range.on = false; AL.alerts['range'] = nil;
        else
            local tgt = AshitaCore:GetMemoryManager():GetTarget();
            local ent = AshitaCore:GetMemoryManager():GetEntity();
            local ti = (tgt ~= nil) and tgt:GetTargetIndex(0) or 0;
            local d2 = (ti ~= nil and ti ~= 0 and ent ~= nil) and ent:GetDistance(ti) or 0;
            if (d2 == nil or d2 <= 0) then
                AL.alerts['range'] = nil;
            else
                local dist = math.sqrt(d2);
                if (dist > 25) then
                    AL.alerts['range'] = { text = ('!Too Far: %.1f'):fmt(dist), at = now };
                elseif (dist < AL.range.lo) then
                    AL.alerts['range'] = { text = ('Too Close: %.1f'):fmt(dist), at = now };
                elseif (dist > AL.range.hi) then
                    AL.alerts['range'] = { text = ('Too Far: %.1f'):fmt(dist), at = now };
                else
                    AL.alerts['range'] = nil;
                end
            end
        end
    end

    -- GENERIC ALERTS window: sticky AL.alerts + one-shot AL.toasts from /cdchime
    -- alert|toast. Expire stale ones, then draw if anything is left.
    do
        for k, a in pairs(AL.alerts) do
            -- Merged nag lines carry their own short hold; plain alerts use
            -- the long sticky window.
            if ((now - a.at) > (a.hold or AL.ALERT_MAX)) then AL.alerts[k] = nil; end
        end
        local keep = T{};
        for _, t in ipairs(AL.toasts) do
            if ((now - t.at) <= AL.TOAST_SECS) then keep:append(t); end
        end
        AL.toasts = keep;
        -- Countdowns from /cdchime timer: when one lands it becomes a sticky
        -- alert for ten seconds and is read aloud (a name with no recorded
        -- clip falls back to the Reminder chime).
        for k, t in pairs(AL.timers) do
            if (now >= t.endsAt) then
                AL.timers[k] = nil;
                AL.alerts['timer_' .. k] = { text = '!' .. t.name .. ' is up', at = now, hold = 10 };
                Speak(t.name);
            end
        end
        local n = #AL.toasts;
        for _ in pairs(AL.alerts) do n = n + 1; end
        for _ in pairs(AL.timers) do n = n + 1; end
        if (n > 0) and (theme.Enabled('cdchime_alerts')) then
            theme.Push('cdchime_alerts', pulse);
            if (imgui.Begin('cdchime_alerts', true, flags)) then
                PushScale(theme.Scale('cdchime_alerts'));
                local function line(text, id)
                    -- A merged nag keeps its own accent, so Jump still reads
                    -- red and Berserk amber inside the shared window.
                    local col = (id ~= nil) and theme.Accent(id) or theme.TextCol('cdchime_alerts');
                    if (text:sub(1, 1) == '!') then col = theme.Col('crit'); text = text:sub(2); end
                    imgui.TextColored(col, text);
                end
                local keys = T{};
                for k in pairs(AL.alerts) do keys:append(k); end
                table.sort(keys);
                for _, k in ipairs(keys) do line(AL.alerts[k].text, AL.alerts[k].id); end
                for _, t in ipairs(AL.toasts) do line(t.text, t.id); end
                local live = T{};
                for _, t in pairs(AL.timers) do live:append(t); end
                table.sort(live, function (a, b) return a.endsAt < b.endsAt; end);
                for _, t in ipairs(live) do
                    local left = math.max(0, math.floor(t.endsAt - now));
                    local txt;
                    if (left >= 3600) then
                        txt = ('%d:%02d:%02d  %s'):fmt(math.floor(left / 3600), math.floor(left / 60) % 60, left % 60, t.name);
                    else
                        txt = ('%d:%02d  %s'):fmt(math.floor(left / 60), left % 60, t.name);
                    end
                    if (left <= 10) then txt = '!' .. txt; end
                    line(txt);
                end
                PopScale();
            end
            imgui.End();
            theme.Pop();
        end
    end

    -- Risk board: a quiet always-on window listing every maneuver whose last
    -- known overload chance is at/above RISK_THRESHOLD. Movable; no border pulse.
    local risky = T{};
    for name in pairs(maneuverChance) do
        local c = CurChance(name, now);
        if (c ~= nil) and (c >= RISK_THRESHOLD) then
            risky:append({ name = name, chance = c });
        end
    end
    if (#risky > 0) and (theme.Enabled('cdchime_risk')) then
        table.sort(risky, function (a, b) return a.chance > b.chance; end);
        theme.Push('cdchime_risk');
        if (imgui.Begin('cdchime_risk', true, flags)) then
            PushScale(theme.Scale('cdchime_risk'));
            imgui.TextColored(theme.TextCol('cdchime_risk', 0.9), 'Overload risk');
            for _, r in ipairs(risky) do
                local col = theme.Col('warn');
                if (r.chance >= 25) then col = theme.Col('crit'); end
                DrawManeuverIcon(r.name, ICON_SIZE_RISK);
                imgui.TextColored(theme.Col('text'), r.name);
                imgui.SameLine();
                imgui.TextColored(col, ('%d%%'):fmt(r.chance));
            end
            PopScale();
        end
        imgui.End();
        theme.Pop();
    end

    -- ACTIVE MANEUVERS. Read from the player's real buff list (status ids
    -- 300-307), so it shows what the game says is up rather than what we
    -- think we pressed. Slot count is capped at 3 by the game.
    if (cdchimeIsPup()) and (#activeManeuvers > 0) and (theme.Enabled('cdchime_maneuvers')) then
        -- NO CHROME AT ALL (USER, 2026-08-16): fully transparent ground, no
        -- border, no padding. The icons ARE the widget - it should look like
        -- the game drew them, not like an addon panel. The digits carry their
        -- own 8-way dark outline, so they stay readable with nothing behind.
        -- theme.Push honours that via the popup's 'bare' flag.
        theme.Push('cdchime_maneuvers');
        if (imgui.Begin('cdchime_maneuvers', true, flags)) then
            -- Tile row: one icon per ACTIVE maneuver (a stacked element gets
            -- one tile each), seconds remaining burned into the lower-left.
            -- Tiles are drawn at absolute screen positions, then a Dummy of
            -- the same footprint reserves the space so AlwaysAutoResize can
            -- size the window - otherwise it collapses to nothing.
            -- One GROUP per tile: icon on top, countdown centred under it.
            -- Pure flow layout (BeginGroup + SameLine) so imgui measures and
            -- grows the window itself. The previous version hand-placed the
            -- tiles with SetCursorScreenPos and ended without submitting an
            -- item, which is precisely what the "extend window boundaries"
            -- assert was reporting.
            local sz = ICON_SIZE_ACTIVE;
            local first = true;
            for _, m in ipairs(activeManeuvers) do
                -- One row per buff instance now, so no inner count loop.
                local e = StatusIcon(MANEUVER_STATUS[m.name]);
                if (e ~= nil) then
                    do
                        if (not first) then imgui.SameLine(0, TILE_GAP); end
                        first = false;

                        -- A dim dash = up, but the press was never seen
                        -- (maneuver predates the addon load).
                        local lbl, col = '-', { 0.65, 0.65, 0.70, 0.90 };
                        -- m.left is the game's own expiry (exact). Fall back
                        -- to the chat-anchored model only when unavailable -
                        -- that one reads ~2s high because the chat line lags
                        -- the buff actually landing.
                        local left = (m.deadline ~= nil) and (m.deadline - now) or nil;
                        if (left == nil) and (m.at ~= nil) then
                            left = MANEUVER_DURATION - (now - m.at);
                        end
                        if (left ~= nil) then
                            if (left < 0) then left = 0; end
                            -- ceil, not floor: floor shows "59" the instant a
                            -- 60s maneuver lands and sits on "0" for the whole
                            -- final second. ceil counts 60..1 and only hits 0
                            -- at expiry, which is how a countdown should read.
                            lbl = ('%d'):fmt(math.ceil(left));
                            col = theme.Col('text');
                            if (left <= 10) then col = theme.Col('crit');
                            elseif (left <= 20) then col = theme.Col('warn'); end
                        end

                        imgui.BeginGroup();
                        local cx = imgui.GetCursorPosX();
                        imgui.Image(e.img, { sz, sz }, { 0, 0 }, { 1, 1 });
                        PushScale(TIMER_SCALE);
                        local tw = imgui.CalcTextSize(lbl);
                        imgui.SetCursorPosX(cx + (sz - tw) * 0.5);
                        local tx, ty = imgui.GetCursorScreenPos();
                        -- imgui has no bold face, so stamp a dark outline on
                        -- all 8 sides and lay the colour on top. Every one of
                        -- these IS an item submission, so boundaries grow.
                        for _, o in ipairs(OUTLINE) do
                            imgui.SetCursorScreenPos({ tx + o[1], ty + o[2] });
                            imgui.TextColored({ 0.0, 0.0, 0.0, 0.85 }, lbl);
                        end
                        imgui.SetCursorScreenPos({ tx, ty });
                        imgui.TextColored(col, lbl);
                        PopScale();
                        imgui.EndGroup();
                    end
                end
            end
        end
        imgui.End();
        theme.Pop();
    end

    -- Berserk nag: engaged on /WAR with Berserk off cooldown and the buff
    -- NOT up. Same cadence as the Jump nag, orange so it reads distinctly.
    if (zerkNagOn) and (zerkReadyAt > 0) and ((now - zerkReadyAt) >= JUMP_NAG_AFTER) then
        if ((((now - zerkReadyAt - JUMP_NAG_AFTER) % JUMP_PERIOD) <= JUMP_SHOW) and theme.Enabled('cdchime_zerk')) then
            if (not NagLine('cdchime_zerk', 'BERSERK Ready!')) then
            theme.Push('cdchime_zerk', pulse);
            if (imgui.Begin('cdchime_zerk', true, flags)) then
                PushScale(theme.Scale('cdchime_zerk'));
                imgui.TextColored(theme.TextCol('cdchime_zerk', 0.55 + 0.45 * pulse), 'BERSERK Ready!');
                PopScale();
            end
            imgui.End();
            theme.Pop();
            end
            -- Outside the merge guard: the voice fires whether the nag has
            -- its own window or is a line in the shared alerts window.
            Speak('Berserk Ready');
        end
    end

    -- Jump nag: engaged with /DRG and Jump sat ready for JUMP_NAG_AFTER
    -- (missed it) -> flash the reminder for JUMP_SHOW seconds at the start
    -- of every JUMP_PERIOD cycle until used. The instant-ready moment is
    -- already announced by the normal ready toast/voice.
    if (jumpNagOn) and (jumpReadyAt > 0) and ((now - jumpReadyAt) >= JUMP_NAG_AFTER) then
        if (jumpCycleAt == 0) then jumpCycleAt = now; end
        if ((((now - jumpCycleAt) % JUMP_PERIOD) <= JUMP_SHOW) and theme.Enabled('cdchime_jump')) then
            if (not NagLine('cdchime_jump', 'JUMP Ready!')) then
            theme.Push('cdchime_jump', pulse);
            if (imgui.Begin('cdchime_jump', true, flags)) then
                PushScale(theme.Scale('cdchime_jump'));
                imgui.TextColored(theme.TextCol('cdchime_jump', 0.55 + 0.45 * pulse), 'JUMP Ready!');
                PopScale();
            end
            imgui.End();
            theme.Pop();
            end
            -- Debounce (3s) < cycle (7s): speaks once per nag cycle. Outside
            -- the merge guard so the voice survives window merging.
            Speak('Jump Ready');
        end
    else
        jumpCycleAt = 0;
    end

    -- Maneuver-idle nag: the shared maneuver timer has sat READY unused for
    -- MAN_NAG_AFTER seconds while engaged -> flash + speak, repeating every
    -- MAN_NAG_PERIOD until a maneuver goes out.
    if (not cdchimeIsPup()) then maneuverIdleAt = 0; end
    if (cdchimeIsPup()) and (isEngaged) and (maneuverIdleAt > 0) then
        local idle = now - maneuverIdleAt - MAN_NAG_AFTER;
        if (idle >= 0) and ((idle % MAN_NAG_PERIOD) <= JUMP_SHOW) and (theme.Enabled('cdchime_mannag')) then
            if (not NagLine('cdchime_mannag', 'Maneuver waiting!')) then
            theme.Push('cdchime_mannag', pulse);
            if (imgui.Begin('cdchime_mannag', true, flags)) then
                PushScale(theme.Scale('cdchime_mannag'));
                imgui.TextColored(theme.TextCol('cdchime_mannag', 0.55 + 0.45 * pulse), 'Maneuver waiting!');
                PopScale();
            end
            imgui.End();
            theme.Pop();
            end
            Speak('Maneuver waiting');
        end
    end

    -- Pet-idle nag: you've been fighting PET_NAG_AFTER seconds and the
    -- puppet is standing there watching. Deploy is on Q.
    if (cdchimeIsPup()) and (petNagOn) and (combatStartAt > 0) then
        local idle = now - combatStartAt - PET_NAG_AFTER;
        if (idle >= 0) and ((idle % PET_NAG_PERIOD) <= JUMP_SHOW) and (theme.Enabled('cdchime_petnag')) then
            if (not NagLine('cdchime_petnag', 'Pet not engaged!')) then
            theme.Push('cdchime_petnag', pulse);
            if (imgui.Begin('cdchime_petnag', true, flags)) then
                PushScale(theme.Scale('cdchime_petnag'));
                imgui.TextColored(theme.TextCol('cdchime_petnag', 0.55 + 0.45 * pulse), 'Pet not engaged!');
                PopScale();
            end
            imgui.End();
            theme.Pop();
            end
            Speak('Pet not engaged');
        end
    end

    -- Maneuver-stack nag: fighting with fewer than 3 maneuver buffs up
    -- (after a grace period to stack them at fight start).
    if (manBuffCount >= 0) and (manBuffCount < 3) and (combatStartAt > 0) then
        local under = now - combatStartAt - BUFF_NAG_AFTER;
        if (under >= 0) and ((under % BUFF_NAG_PERIOD) <= JUMP_SHOW) and (theme.Enabled('cdchime_buffnag')) then
            if (not NagLine('cdchime_buffnag', ('Maneuvers %d/3!'):fmt(manBuffCount))) then
            theme.Push('cdchime_buffnag', pulse);
            if (imgui.Begin('cdchime_buffnag', true, flags)) then
                PushScale(theme.Scale('cdchime_buffnag'));
                imgui.TextColored(theme.TextCol('cdchime_buffnag', 0.55 + 0.45 * pulse),
                    ('Maneuvers %d/3!'):fmt(manBuffCount));
                PopScale();
            end
            imgui.End();
            theme.Pop();
            end
            local words = { [0] = 'No maneuvers active', 'One maneuver active', 'Two maneuvers active' };
            Speak(words[manBuffCount]);
        end
    end

    -- TP Ready: 1000+ TP while engaged -> green flash + voice the moment it
    -- crosses, repeating every TP_NAG_PERIOD until spent (E is right there).
    if (isEngaged) and (tpReadyAt > 0) then
        if ((((now - tpReadyAt) % TP_NAG_PERIOD) <= JUMP_SHOW) and theme.Enabled('cdchime_tpnag')) then
            if (not NagLine('cdchime_tpnag', 'TP Ready!')) then
            theme.Push('cdchime_tpnag', pulse);
            if (imgui.Begin('cdchime_tpnag', true, flags)) then
                PushScale(theme.Scale('cdchime_tpnag'));
                imgui.TextColored(theme.TextCol('cdchime_tpnag', 0.55 + 0.45 * pulse), 'TP Ready!');
                PopScale();
            end
            imgui.End();
            theme.Pop();
            end
            Speak('TP Ready');
        end
    end

    -- Group windows last: every nag above has now either drawn itself or
    -- dropped a line into one of these buckets this frame.
    DrawGroup('cdchime_groupa');
    DrawGroup('cdchime_groupb');
end);

-- Theme/config window rides its own present callback so it still draws (and
-- can be closed) while layout mode has the main one returning early.
theme.layout_get = function () return layout; end
theme.layout_set = function (v) layout = v; end
ashita.events.register('d3d_present', 'cdchime_theme_cb', function ()
    theme.DrawConfig();
end);

ashita.events.register('command', 'command_cb', function (e)
    local args = e.command:args();
    if (#args == 0 or (args[1] ~= '/heaphchimes' and args[1] ~= '/cdchime')) then return; end
    e.blocked = true;

    if (args[2] == 'config') or (args[2] == 'theme') then
        local on = theme.ToggleConfig();
        print(chat.header('cdchime'):append(chat.message(
            ('config window %s'):fmt(on and 'open' or 'closed'))));
        return;
    end

    if (args[2] == 'merge') then
        -- Kept as a shortcut; the real control is per-window in the config
        -- window ("Combine windows"), where each popup picks its own host.
        local NAGS = { 'cdchime_zerk', 'cdchime_jump', 'cdchime_mannag',
                       'cdchime_petnag', 'cdchime_buffnag', 'cdchime_tpnag' };
        local anyMerged = false;
        for _, id in ipairs(NAGS) do
            local p = theme.cfg.popups[id];
            if (p ~= nil) and ((p.merge_into or '') ~= '') then anyMerged = true; end
        end
        for _, id in ipairs(NAGS) do
            local p = theme.cfg.popups[id];
            if (p ~= nil) then p.merge_into = anyMerged and '' or 'cdchime_alerts'; end
        end
        theme.Save();
        print(chat.header('cdchime'):append(chat.message(('nags %s'):fmt(
            anyMerged and 'split back into their own windows'
                       or 'merged into the alerts window'))));
        return;
    end

    -- /cdchime trigger add <name> | <pattern> | <text> [| <secs>]
    -- /cdchime trigger list | del <name>
    if (args[2] == 'trigger') or (args[2] == 'trg') then
        local sub = args[3] and args[3]:lower() or 'list';
        if (sub == 'add') and (#args >= 4) then
            local rest = table.concat(args, ' ', 4);
            local parts = T{};
            for piece in rest:gmatch('[^|]+') do
                parts:append(piece:match('^%s*(.-)%s*$'));
            end
            if (#parts < 3) then
                print(chat.header('cdchime'):append(chat.error(
                    'Usage: /cdchime trigger add <name> | <pattern> | <text> [| <secs>]')));
                return;
            end
            local secs = tonumber(parts[4]);
            theme.cfg.triggers[parts[1]] = {
                pattern = parts[2],
                text    = parts[3],
                secs    = secs,
                sticky  = (secs ~= nil),
            };
            theme.Save();
            print(chat.header('cdchime'):append(chat.message('trigger '))
                :append(chat.success(parts[1]))
                :append(chat.message((' added: "%s" -> "%s"%s'):fmt(parts[2], parts[3],
                    (secs ~= nil) and (' (sticky %ds)'):fmt(secs) or ''))));
            return;
        end
        if (sub == 'del') or (sub == 'remove') then
            local name = table.concat(args, ' ', 4);
            if (theme.cfg.triggers[name] ~= nil) then
                theme.cfg.triggers[name] = nil;
                theme.Save();
                print(chat.header('cdchime'):append(chat.message('removed trigger ' .. name)));
            else
                print(chat.header('cdchime'):append(chat.error('no trigger named ' .. name)));
            end
            return;
        end
        if (sub == 'test') and (#args >= 4) then
            -- Fire a one-off popup so you can see where it lands.
            AL.toasts:append({ text = table.concat(args, ' ', 4), at = os.clock() });
            return;
        end
        print(chat.header('cdchime'):append(chat.message('Custom popups:')));
        local any = false;
        for name, t in pairs(theme.cfg.triggers) do
            any = true;
            print(('  %-12s "%s" -> "%s"%s'):fmt(name, t.pattern or '', t.text or '',
                t.sticky and (' [sticky %ds]'):fmt(t.secs or 10) or ''));
        end
        if (not any) then
            print('  none yet.');
            print('  /cdchime trigger add tod | (%a+) was defeated | $1 DOWN | 15');
        end
        return;
    end

    if (args[2] == 'range') and (#args >= 3) then
        if (args[3] == 'off') then
            AL.range.on = false; AL.alerts['range'] = nil;
        else
            local lo, hi = tonumber(args[3]), tonumber(args[4]);
            local secs = tonumber(args[5]) or 10;
            if (lo ~= nil and hi ~= nil) then
                AL.range.on = true; AL.range.lo = lo; AL.range.hi = hi;
                AL.range.untilAt = os.clock() + secs;
            end
        end
        return;
    end
    if (args[2] == 'alert') and (#args >= 4) then
        local key = args[3]:lower();
        local text = table.concat(args, ' ', 4);
        AL.alerts[key] = { text = text, at = os.clock() };
        return;
    end
    if (args[2] == 'clear') and (#args >= 3) then
        AL.alerts[args[3]:lower()] = nil;
        return;
    end
    if (args[2] == 'toast') and (#args >= 3) then
        AL.toasts:append({ text = table.concat(args, ' ', 3), at = os.clock() });
        return;
    end

    -- /cdchime timer 10m Dynamis entry   |  timer 1h30m Sky pop  |  timer 90s Ochiudo
    -- /cdchime timer list | cancel <name> | clear
    if (args[2] == 'timer') then
        local sub = args[3] and args[3]:lower() or 'list';
        if (sub == 'clear') then
            AL.timers = T{};
            print('[cdchime] Countdowns cleared.');
            return;
        end
        if (sub == 'cancel') and (args[4] ~= nil) then
            local name = table.concat(args, ' ', 4);
            local key = name:lower();
            if (AL.timers[key] ~= nil) then
                AL.timers[key] = nil;
                print(('[cdchime] Cancelled: %s'):fmt(name));
            else
                print(('[cdchime] No countdown called %s.'):fmt(name));
            end
            return;
        end
        if (sub == 'list') then
            local any = false;
            for _, t in pairs(AL.timers) do
                any = true;
                print(('[cdchime]   %s - %d s left'):fmt(t.name, math.max(0, math.floor(t.endsAt - os.clock()))));
            end
            if (not any) then print('[cdchime] No countdowns. /cdchime timer <duration> <name>  (10m, 1h30m, 90s, or plain minutes)'); end
            return;
        end
        -- duration: 90s | 10m | 1h | 1h30m | 1h30m15s | bare number = minutes
        local spec = sub;
        local secs = 0;
        if (spec:match('^%d+$')) then
            secs = tonumber(spec) * 60;
        else
            local ok = false;
            for num, unit in spec:gmatch('(%d+)([hms])') do
                ok = true;
                if (unit == 'h') then secs = secs + tonumber(num) * 3600;
                elseif (unit == 'm') then secs = secs + tonumber(num) * 60;
                else secs = secs + tonumber(num); end
            end
            if (not ok) then secs = 0; end
        end
        local name = (#args >= 4) and table.concat(args, ' ', 4) or nil;
        if (secs <= 0) or (name == nil) then
            print('[cdchime] Usage: /cdchime timer <duration> <name>   e.g. timer 10m Dynamis entry');
            return;
        end
        AL.timers[name:lower()] = { name = name, endsAt = os.clock() + secs };
        print(('[cdchime] Countdown: %s in %d min %d s. It pops in the Alerts window and is read aloud.'):fmt(
            name, math.floor(secs / 60), secs % 60));
        return;
    end

    if (#args == 1) or (args[2] == 'list') then
        print('[cdchime] /cdchime timer <10m|1h30m|90s> <name> - countdown, pops + spoken');
        print('[cdchime] /cdchime config    - colours, sizes, per-window on/off');
        print('[cdchime] /cdchime layout    - drag the windows into place');
        print('[cdchime] /cdtimers config   - buff tiles and recast bars');
        print('[cdchime] Tracked cooldowns (seen so far this session):');
        for id, t in pairs(tracked) do
            local name = abilityNames[id] or ('timer ' .. id);
            local state = (t.prev > 0) and 'on cooldown' or 'ready';
            local m = (muted[string.lower(name)]) and ' [muted]' or '';
            print(('  %s (%s)%s'):fmt(name, state, m));
        end
        for _, s in pairs(spellWatch) do
            print(('  %s [spell] (%s)'):fmt(s.name, (s.prev > 0) and 'on cooldown' or 'ready'));
        end
        return;
    end
    if (args[2] == 'mute') and (args[3] ~= nil) then
        local name = table.concat(args, ' ', 3);
        muted[string.lower(name)] = true;
        print(('[cdchime] Muted: %s'):fmt(name));
        return;
    end
    if (args[2] == 'unmute') and (args[3] ~= nil) then
        local name = table.concat(args, ' ', 3);
        muted[string.lower(name)] = nil;
        print(('[cdchime] Unmuted: %s'):fmt(name));
        return;
    end
    if (args[2] == 'plates') then
        cdchimeTogglePlates();
        return;
    end
    if (args[2] == 'man') then
        -- Why is the maneuver board empty? Every gate, in order.
        local pl = AshitaCore:GetMemoryManager():GetPlayer();
        local ent = GetPlayerEntity();
        local job = (pl ~= nil) and pl:GetMainJob() or -1;
        local pet = (ent ~= nil) and (ent.PetTargetIndex or 0) or 0;
        print(('[cdchime] mainjob=%d (PUP=18)  petIndex=%s  manBuffCount=%d')
            :fmt(job, tostring(pet), manBuffCount));
        local ids = T{};
        if (pl ~= nil) then
            for _, b in pairs(pl:GetBuffs()) do
                if (b ~= nil) and (b >= 300) and (b <= 307) then
                    ids:append(('%d=%s'):fmt(b, tostring(MANEUVER_BY_ID[b])));
                end
            end
        end
        print(('[cdchime] maneuver buffs on me: %s')
            :fmt(#ids > 0 and ids:concat(', ') or 'NONE'));
        print(('[cdchime] activeManeuvers rows: %d'):fmt(#activeManeuvers));
        for _, m in ipairs(activeManeuvers) do
            print(('[cdchime]   %-16s left=%s  pressAt=%s  icon=%s'):fmt(
                m.name,
                (m.deadline ~= nil) and ('%.1fs'):fmt(m.deadline - os.clock()) or 'model',
                tostring(m.at),
                tostring(StatusIcon(MANEUVER_STATUS[m.name]) ~= nil)));
        end
        local k = T{};
        for nm, t in pairs(maneuverAt) do k:append(('%s@%.0f'):fmt(nm, t)); end
        print(('[cdchime] presses recorded: %s  (now=%.0f)')
            :fmt(#k > 0 and k:concat(', ') or 'NONE', os.clock()));
        return;
    end
    if (args[2] == 'layout') then
        layout = not layout;
        print(('[cdchime] Layout mode %s - %s'):fmt(
            layout and 'ON' or 'OFF',
            layout and 'drag the windows where you want them, then run this again'
                    or 'positions saved.'));
        return;
    end
    if (args[2] == 'tp') then
        local tp = AshitaCore:GetMemoryManager():GetParty():GetMemberTP(0);
        print(('[cdchime] TP=%s engaged=%s tpReadyAt=%s (alert needs TP>=1000 AND engaged)'):fmt(
            tostring(tp), tostring(isEngaged), tostring(tpReadyAt)));
        return;
    end
    if (args[2] == 'say') and (args[3] ~= nil) then
        speakOn = (args[3] == 'on');
        print(('[cdchime] Speech %s.'):fmt(speakOn and 'ON' or 'OFF'));
        return;
    end
    if (args[2] == 'volume') and (tonumber(args[3]) ~= nil) then
        speakVol = math.max(0, math.min(100, tonumber(args[3])));
        print(('[cdchime] Speech volume %d.'):fmt(speakVol));
        lastSpoken['Voice ready'] = nil; Speak('Voice ready');
        return;
    end
    if (args[2] == 'addspell') and (args[3] ~= nil) then
        local name = AddSpell(table.concat(args, ' ', 3));
        if (name ~= nil) then
            print(('[cdchime] Watching spell: %s'):fmt(name));
        else
            print('[cdchime] Unknown spell.');
        end
        return;
    end
end);

-- UI BRIDGE (2026-08-21): everything that used to be command-only is reachable
-- from the config window through this handle. theme.lua owns the widgets; the
-- state stays here so there is still one source of truth.
_G.cdchimeShare = {
    -- cooldown list: [id] = { name, ready, muted }
    Tracked = function ()
        local out = T{};
        for id, t in pairs(tracked) do
            local nm = abilityNames[id] or ('timer ' .. id);
            out:append({ name = nm, ready = (t.prev <= 0),
                         muted = (muted[string.lower(nm)] == true) });
        end
        table.sort(out, function (a, b) return a.name < b.name; end);
        return out;
    end,
    SetMute = function (name, on)
        muted[string.lower(name)] = on and true or nil;
    end,
    Spells = function ()
        local out = T{};
        for id, s in pairs(spellWatch) do
            out:append({ id = id, name = s.name });
        end
        table.sort(out, function (a, b) return a.name < b.name; end);
        return out;
    end,
    AddSpell = function (n) return AddSpell(n); end,
    DelSpell = function (id) spellWatch[id] = nil; end,
    Say = function () return speakOn; end,
    SetSay = function (v) speakOn = v and true or false; end,
    Volume = function () return speakVol; end,
    SetVolume = function (v)
        speakVol = math.max(0, math.min(100, math.floor(v)));
        lastSpoken['Voice ready'] = nil; Speak('Voice ready');
    end,
    Toast = function (text)
        AL.toasts:append({ text = text, at = os.clock() });
    end,
};
