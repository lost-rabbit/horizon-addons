--[[
* timers.lua - cdtimers, now a MODULE of cdchime (merged 2026-08-19).
* The optional native status-row hide (NativeHide/NativeRestore) uses the
* same signature and reversible two-byte patch as statustimers by Heals
* (GPL), with credit; it is off by /cdtimers native and restored on unload.
* Loaded by cdchime.lua via require('timers'); registers its own event
* callbacks under distinct names. Commands stay /cdtimers ...
*
* (original header follows)
* cdtimers v1.0 - buff and recast timers in the cdchime style.
*
* Replaces the stock 'timers' addon. Two chrome-less panels:
*
*   BUFFS   - one tile per status effect on you: the game's own status icon
*             with the seconds remaining burned in underneath. The expiry is
*             read straight from the client (same memory read cdchime uses
*             for maneuvers), so it is EXACT - the stock addon estimated
*             durations from action packets and drifted or errored.
*   RECASTS - one tile per ability/spell currently on cooldown: name on top,
*             countdown underneath, optional depletion bar.
*
* Both panels are pure flow layout on a fully transparent window, digits with
* an 8-way dark outline so they read over anything. Drag them anywhere while
* unlocked; lock to freeze.
*
* Usage: /cdtimers            - open the config window
*        /cdtimers lock|unlock
*        /cdtimers buffs|recasts  - toggle a panel
*        /cdtimers native       - toggle hiding the game's own status row
*        /cdtimers reset        - restore default settings
* Read-only memory/resource reads; informational only.
--]]


require('common');
local imgui    = require('imgui');
local settings = require('settings');
local d3d8     = require('d3d8');
local ffi      = require('ffi');
local d3d8_device = d3d8.get_device();

----------------------------------------------------------------------------
-- Settings
----------------------------------------------------------------------------
local defaults = T{
    locked = false,
    show_config = false,
    buffs = T{
        enabled      = true,
        x = 400, y = 80,
        icon_size    = 40,          -- px
        gap          = 3,           -- px between tiles
        per_row      = 12,          -- wrap after this many tiles
        vertical     = true,        -- stack tiles downward (per_row = per column)
        font_scale   = 1.6,         -- countdown digits
        hide_maneuvers = true,      -- cdchime already draws 300..307
        hide_infinite  = true,      -- Signet-style no-expiry buffs
        hide_native    = true,      -- suppress the game's own status-icon row
        sort_soonest_first = true,
        warn_at      = 20,          -- seconds -> yellow
        crit_at      = 10,          -- seconds -> red
        max_tiles    = 32,
    },
    recasts = T{
        enabled      = true,
        x = 400, y = 160,
        tile_w       = 62,          -- px, name is squeezed to fit
        gap          = 4,
        per_row      = 10,
        vertical     = true,        -- stack tiles downward (per_row = per column)
        name_scale   = 0.85,
        font_scale   = 1.6,
        show_bar     = true,        -- (tiles style) depletion bar under the digits
        style        = 'bars',      -- 'bars': [Berserk        5:40] rows with a fill; 'tiles': name-over-digits
        bar_w        = 190,         -- px
        bar_h        = 22,          -- px
        bar_pad      = 6,           -- px text inset
        bar_round    = 3.0,
        bar_bg_alpha = 0.92,
        -- Palette (user swatch 2026-08-18): deep indigo ground with a lighter
        -- lavender lip along the top; the fill is the same hue, brighter.
        -- Each is TOP colour and BOTTOM colour of a vertical gradient.
        palette      = 3,
        -- v3 (user swatch #2): ground is a FLAT dark navy, no gradient lip.
        bar_bg_top   = T{ 0.12, 0.11, 0.27, 1.0 },
        bar_bg_bot   = T{ 0.12, 0.11, 0.27, 1.0 },
        bar_fill_top = T{ 0.55, 0.50, 0.85, 0.95 },
        bar_fill_bot = T{ 0.32, 0.28, 0.62, 0.95 },
        bar_border   = T{ 0.42, 0.38, 0.72, 0.90 },
        bar_fill     = T{ 0.30, 0.55, 0.90, 0.85 },   -- legacy single colour (unused when palette>=2)
        grow         = true,        -- long cooldowns start small and grow to full size
        grow_full_at = 60,          -- seconds left at which a row is full size
        grow_min_at  = 600,         -- seconds left at/above which a row is at grow_min
        grow_min     = 0.55,        -- smallest scale (of width, height and text)
        show_spells  = true,
        show_abilities = true,
        min_seconds  = 1.0,         -- ignore blips shorter than this
        sort_soonest_first = true,
        warn_at      = 10,
        crit_at      = 3,
        max_tiles    = 24,
    },
};
local cfg = settings.load(defaults, 'cdtimers');
-- A settings file saved before the indigo palette carries the old blue in
-- bar_fill and no gradient keys. Upgrade it once; the user can recolour after.
if (cfg.recasts ~= nil) and ((cfg.recasts.palette or 0) < 3) then
    local d = defaults.recasts;
    cfg.recasts.palette      = 3;
    cfg.recasts.bar_bg_alpha = d.bar_bg_alpha;
    cfg.recasts.bar_bg_top   = T{ d.bar_bg_top[1], d.bar_bg_top[2], d.bar_bg_top[3], d.bar_bg_top[4] };
    cfg.recasts.bar_bg_bot   = T{ d.bar_bg_bot[1], d.bar_bg_bot[2], d.bar_bg_bot[3], d.bar_bg_bot[4] };
    cfg.recasts.bar_fill_top = T{ d.bar_fill_top[1], d.bar_fill_top[2], d.bar_fill_top[3], d.bar_fill_top[4] };
    cfg.recasts.bar_fill_bot = T{ d.bar_fill_bot[1], d.bar_fill_bot[2], d.bar_fill_bot[3], d.bar_fill_bot[4] };
    cfg.recasts.bar_border   = T{ d.bar_border[1], d.bar_border[2], d.bar_border[3], d.bar_border[4] };
    settings.save('cdtimers');
end

----------------------------------------------------------------------------
-- Constants and helpers (defined ABOVE every call site)
----------------------------------------------------------------------------
local OUTLINE = {
    { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 },
    { -1, -1 }, { 1, -1 }, { -1, 1 }, { 1, 1 },
};
local COL_TEXT   = { 1.0, 1.0, 1.0, 1.0 };
local COL_WARN   = { 1.0, 0.90, 0.55, 1.0 };
local COL_CRIT   = { 1.0, 0.55, 0.50, 1.0 };
local COL_DIM    = { 0.75, 0.75, 0.80, 1.0 };
local COL_SHADOW = { 0.0, 0.0, 0.0, 0.85 };
local COL_BAR_BG = { 0.0, 0.0, 0.0, 0.55 };
local COL_BAR    = { 0.55, 0.80, 1.0, 0.95 };

-- Client clock and buff expiry: identical to cdchime's ManeuverTimers, but
-- returned for every slot rather than only maneuvers.
local VANA_BASE_STAMP  = 0x3C307D70;
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

-- Returns a list of { id=, left=seconds or nil(infinite) } for every active
-- status slot, or nil if the clock read failed.
local function ReadBuffs()
    local stamp = GameUtcStamp();
    if (stamp == nil) then return nil; end
    local pl = AshitaCore:GetMemoryManager():GetPlayer();
    if (pl == nil) then return nil; end
    local icons  = pl:GetStatusIcons();
    local timers = pl:GetStatusTimers();
    if (icons == nil) or (timers == nil) then return nil; end
    local comparand = (stamp - VANA_BASE_STAMP) * 60;
    local out = {};
    for j = 0, 31 do
        local id = icons[j + 1];
        if (id ~= nil) and (id > 0) and (id ~= 255) then
            local raw = timers[j + 1];
            local left = nil;
            if (raw ~= nil) and (raw ~= INFINITE_DURATION) then
                left = raw - comparand;
                while (left < -2147483648) do left = left + 0xFFFFFFFF; end
                left = left / 60;
                if (left < 0) then left = 0; end
            end
            table.insert(out, { id = id, left = left });
        end
    end
    return out;
end

-- Status icon textures from the client's own resource manager.
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
            local ptr = d3d8.gc_safe_release(ffi.cast('IDirect3DTexture8*', tex[0]));
            iconCache[id] = { ptr = ptr, img = tonumber(ffi.cast('uint32_t', ptr)) };
        end
    end
    return iconCache[id] or nil;
end

local function StatusName(id)
    local s = AshitaCore:GetResourceManager():GetString('buffs.names', id);
    if (s == nil) or (s == '') then return ('status %d'):fmt(id); end
    return s;
end

--[[
* NATIVE STATUS ROW. With this panel as the buff bar, the game's own row of
* tiny icons at the top of the screen is redundant. Same technique as the
* Horizon-approved 'statustimers' addon (Heals, GPL): NOP the two-byte
* conditional jump that leads into the native status-icon draw, and put the
* original bytes back on unload or when the option is turned off. Nothing
* else in the client is touched.
--]]
local native = { ptr = { 0, 0 }, orig = { 0, 0 }, patched = false };
local NATIVE_SIG = '75??55518B0D????????E8????????85C07F??8BDE';

local function NativeHide()
    if (native.patched) then return true; end
    native.ptr[1] = ashita.memory.find('FFXiMain.dll', 0, NATIVE_SIG, 0, 0);
    native.ptr[2] = ashita.memory.find('FFXiMain.dll', 0, NATIVE_SIG, 0, 1);
    if (native.ptr[1] == 0) or (native.ptr[2] == 0) or (native.ptr[1] == native.ptr[2]) then
        print('[cdtimers] native status row: signature not found, leaving it alone');
        return false;
    end
    native.orig[1] = ashita.memory.read_uint16(native.ptr[1]);
    native.orig[2] = ashita.memory.read_uint16(native.ptr[2]);
    if (native.orig[1] == 0x9090) or (native.orig[2] == 0x9090) then
        -- Something else (statustimers?) already patched it; don't fight.
        native.patched = false;
        return false;
    end
    ashita.memory.write_uint16(native.ptr[1], 0x9090);
    ashita.memory.write_uint16(native.ptr[2], 0x9090);
    native.patched = true;
    return true;
end

local function NativeRestore()
    if (not native.patched) then return; end
    if (native.ptr[1] ~= 0) and (native.orig[1] ~= 0) then
        ashita.memory.write_uint16(native.ptr[1], native.orig[1]);
    end
    if (native.ptr[2] ~= 0) and (native.orig[2] ~= 0) then
        ashita.memory.write_uint16(native.ptr[2], native.orig[2]);
    end
    native.patched = false;
end

-- Keep the patch state in step with the setting every frame (cheap: two
-- boolean compares once patched).
local function NativeSync()
    local want = cfg.buffs.enabled and cfg.buffs.hide_native;
    if (want and not native.patched) then NativeHide();
    elseif ((not want) and native.patched) then NativeRestore(); end
end

local function PushScale(s)
    if (imgui.SetWindowFontScale ~= nil) then imgui.SetWindowFontScale(s);
    else imgui.PushFont(imgui.GetFont(), imgui.GetFontSize() * s); end
end
local function PopScale()
    if (imgui.SetWindowFontScale ~= nil) then imgui.SetWindowFontScale(1.0);
    else imgui.PopFont(); end
end

-- "47" under a minute, "4:59" above; ceil so a fresh 60s buff reads 60 and
-- the display only hits 0 at expiry.
local function FmtLeft(left)
    local s = math.ceil(left);
    if (s >= 3600) then return ('%dh%02d'):fmt(math.floor(s / 3600), math.floor((s % 3600) / 60)); end
    if (s >= 60) then return ('%d:%02d'):fmt(math.floor(s / 60), s % 60); end
    return ('%d'):fmt(s);
end

local function LeftColour(left, warn, crit)
    if (left <= crit) then return COL_CRIT; end
    if (left <= warn) then return COL_WARN; end
    return COL_TEXT;
end

-- Outlined text at the current cursor, centred inside a box of width w.
-- Every stamp is an item submission, so the window's bounds grow correctly.
local function OutlinedTextCentered(lbl, col, w, scale)
    PushScale(scale);
    local tw = imgui.CalcTextSize(lbl);
    local cx = imgui.GetCursorPosX();
    imgui.SetCursorPosX(cx + math.max(0, (w - tw) * 0.5));
    local tx, ty = imgui.GetCursorScreenPos();
    for _, o in ipairs(OUTLINE) do
        imgui.SetCursorScreenPos({ tx + o[1], ty + o[2] });
        imgui.TextColored(COL_SHADOW, lbl);
    end
    imgui.SetCursorScreenPos({ tx, ty });
    imgui.TextColored(col, lbl);
    PopScale();
end

-- Outlined text at an absolute screen position (caller manages scale).
local function OutlinedTextAt(x, y, lbl, col)
    for _, o in ipairs(OUTLINE) do
        imgui.SetCursorScreenPos({ x + o[1], y + o[2] });
        imgui.TextColored(COL_SHADOW, lbl);
    end
    imgui.SetCursorScreenPos({ x, y });
    imgui.TextColored(col, lbl);
end

-- Squeeze a name into a tile: drop the space-separated tail, then truncate.
local function FitName(name, w, scale)
    PushScale(scale);
    local s = name;
    while (imgui.CalcTextSize(s) > w) and (#s > 3) do
        local cut = s:match('^(.*)%s+%S+$');
        if (cut ~= nil) and (#cut >= 3) then s = cut;
        else s = s:sub(1, #s - 1); end
    end
    PopScale();
    return s;
end

-- Chrome-less window wrapper: transparent, no border, no padding; movable
-- only while unlocked. Position is remembered in settings.
local BASE_FLAGS = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoScrollbar,
    ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing,
    ImGuiWindowFlags_NoSavedSettings);

local function BeginPanel(name, pcfg)
    local flags = BASE_FLAGS;
    if (cfg.locked) then
        flags = bit.bor(flags, ImGuiWindowFlags_NoMove, ImGuiWindowFlags_NoInputs);
    end
    imgui.SetNextWindowPos({ pcfg.x, pcfg.y }, cfg.locked and ImGuiCond_Always or ImGuiCond_FirstUseEver);
    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 0.0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0.0, 0.0 });
    imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.0, 0.0, 0.0, 0.0 });
    imgui.PushStyleColor(ImGuiCol_Border, { 0.0, 0.0, 0.0, 0.0 });
    local open = imgui.Begin(name, true, flags);
    return open;
end

local function EndPanel(pcfg)
    if (not cfg.locked) then
        local px, py = imgui.GetWindowPos();
        if (px ~= nil) then
            local nx, ny = math.floor(px), math.floor(py);
            if (nx ~= pcfg.x) or (ny ~= pcfg.y) then
                pcfg.x, pcfg.y = nx, ny;
                cfg._dirty = true;   -- flushed on lock / config close
            end
        end
    end
    imgui.End();
    imgui.PopStyleColor(2);
    imgui.PopStyleVar(3);
end

----------------------------------------------------------------------------
-- Recast bookkeeping. Ability recasts come as (timerId, ticks); spells as
-- (spellId, ticks). Ticks are 1/60 s. To draw a depletion bar we need the
-- full length: take it from the resource where present, otherwise remember
-- the largest value seen for that timer.
----------------------------------------------------------------------------
local abilityNames = {};   -- recast timer id -> name
local abilityTotal = {};   -- recast timer id -> full length in seconds (seeded by name below)
-- Full recast lengths so the BAR is right from the first frame even for a
-- cooldown that was already running when the addon loaded. Only the bar uses
-- these; the digits come from the client. Horizon values where they differ
-- (Mug 600). Anything unlisted is learned from the longest remaining time
-- observed for that timer.
local KNOWN_RECAST = {
    ['Berserk'] = 300, ['Warcry'] = 300, ['Defender'] = 180, ['Provoke'] = 30,
    ['Aggressor'] = 300, ['Mighty Strikes'] = 3600,
    ['Sneak Attack'] = 60, ['Trick Attack'] = 60, ['Flee'] = 300, ['Steal'] = 300,
    ['Mug'] = 600, ['Hide'] = 300, ['Bully'] = 300, ['Perfect Dodge'] = 3600,
    ['Accomplice'] = 300, ['Collaborator'] = 300,
    ['Maneuver'] = 15, ['Activate'] = 1200, ['Deactivate'] = 60, ['Repair'] = 180,
    ['Deus Ex Automata'] = 300, ['Overdrive'] = 3600, ['Role Reversal'] = 300,
    ['Ventriloquy'] = 300,
    ['Boost'] = 15, ['Focus'] = 300, ['Dodge'] = 300, ['Chi Blast'] = 180,
    ['Counterstance'] = 300, ['Chakra'] = 180, ['Hundred Fists'] = 3600,
    ['Yonin'] = 60, ['Innin'] = 60, ['Mijin Gakure'] = 3600,
    ['Third Eye'] = 60, ['Meditate'] = 180, ['Hasso'] = 60, ['Seigan'] = 60,
    ['Charm'] = 15, ['Reward'] = 90, ['Call Beast'] = 300, ['Sic'] = 60,
    ['Familiar'] = 3600, ['Tame'] = 600, ['Gauge'] = 30,
    ['Jump'] = 90, ['High Jump'] = 180, ['Super Jump'] = 180, ['Spirit Link'] = 180,
    ['Call Wyvern'] = 1200, ['Ancient Circle'] = 600,
    ['Convert'] = 600, ['Divine Seal'] = 600, ['Elemental Seal'] = 600, ['Manafont'] = 3600,
    ['Invincible'] = 3600, ['Sentinel'] = 300, ['Shield Bash'] = 300, ['Holy Circle'] = 600,
    ['Blood Weapon'] = 3600, ['Souleater'] = 360, ['Last Resort'] = 300,
    ['Weapon Bash'] = 300, ['Arcane Circle'] = 600,
    ['Sharpshot'] = 300, ['Barrage'] = 300, ['Scavenge'] = 300, ['Camouflage'] = 300,
    ['Shadowbind'] = 300, ['Eagle Eye Shot'] = 3600, ['Unlimited Shot'] = 180,
    ['Assault'] = 60, ['Fight'] = 60, ['Heel'] = 60, ['Stay'] = 60, ['Leave'] = 60,
    ['Snarl'] = 30, ['Spur'] = 180, ['Run Wild'] = 900,
};
local spellNames   = {};   -- spell id -> name
local spellTotal   = {};   -- spell id -> full recast in seconds (resource RecastDelay is 1/4 s)
local seenMax      = {};   -- key -> longest observed seconds

ashita.events.register('load', 'timers_load_cb', function ()
    local res = AshitaCore:GetResourceManager();
    for id = 0, 2048 do
        local a = res:GetAbilityById(id);
        if (a ~= nil) and (a.Name[1] ~= nil) and (a.RecastTimerId ~= nil) and (a.RecastTimerId ~= 0) then
            -- The maneuvers share one timer id; label it generically.
            if (a.Name[1]:find(' Maneuver') ~= nil) then
                abilityNames[a.RecastTimerId] = 'Maneuver';
                abilityTotal[a.RecastTimerId] = KNOWN_RECAST['Maneuver'];
            elseif (abilityNames[a.RecastTimerId] == nil) then
                abilityNames[a.RecastTimerId] = a.Name[1];
                abilityTotal[a.RecastTimerId] = KNOWN_RECAST[a.Name[1]];
            end
        end
    end
    for id = 0, 1024 do
        local s = res:GetSpellById(id);
        if (s ~= nil) and (s.Name[1] ~= nil) and (s.Name[1] ~= '') then
            spellNames[id] = s.Name[1];
            if (s.RecastDelay ~= nil) and (s.RecastDelay > 0) then
                spellTotal[id] = s.RecastDelay / 4.0;
            end
        end
    end
end);

-- Returns list of { key=, name=, left=, total= } for everything cooling down.
local function ReadRecasts()
    local mm = AshitaCore:GetMemoryManager():GetRecast();
    if (mm == nil) then return {}; end
    local out = {};
    if (cfg.recasts.show_abilities) then
        for x = 0, 31 do
            local id = mm:GetAbilityTimerId(x);
            if (id ~= nil) and (id ~= 0) then
                local ticks = mm:GetAbilityTimer(x);
                if (ticks ~= nil) and (ticks > 0) then
                    local left = ticks / 60.0;
                    local key = 'a' .. id;
                    if (seenMax[key] == nil) or (left > seenMax[key]) then seenMax[key] = left; end
                    if (left >= cfg.recasts.min_seconds) then
                        local total = math.max(seenMax[key], abilityTotal[id] or 0);
                        table.insert(out, { key = key, name = abilityNames[id] or ('Ability %d'):fmt(id),
                                            left = left, total = total });
                    end
                elseif (ticks == 0) then
                    seenMax['a' .. id] = nil;   -- forget so the next use re-measures
                end
            end
        end
    end
    if (cfg.recasts.show_spells) then
        for id = 0, 1024 do
            local ticks = mm:GetSpellTimer(id);
            if (ticks ~= nil) and (ticks > 0) then
                local left = ticks / 60.0;
                local key = 's' .. id;
                if (seenMax[key] == nil) or (left > seenMax[key]) then seenMax[key] = left; end
                if (left >= cfg.recasts.min_seconds) then
                    local total = math.max(seenMax[key], spellTotal[id] or 0);
                    table.insert(out, { key = key, name = spellNames[id] or ('Spell %d'):fmt(id),
                                        left = left, total = total });
                end
            end
        end
    end
    return out;
end

----------------------------------------------------------------------------
-- Panels
----------------------------------------------------------------------------
-- Tile placement. Horizontal: tiles run left->right and wrap to a new line
-- after per_row. Vertical: tiles stack top->bottom; after per_row they start
-- a new column to the right. imgui only flows downward natively, so a column
-- is a BeginGroup of stacked tiles and columns are joined with SameLine.
local function IsVertical(p)
    return (p.vertical ~= false);   -- nil (older settings file) = vertical
end
local function PlaceTile(n, p)
    if (n == 0) then
        if (IsVertical(p)) then imgui.BeginGroup(); end
        return;
    end
    if (IsVertical(p)) then
        if (n % p.per_row == 0) then
            imgui.EndGroup();
            imgui.SameLine(0, p.gap);
            imgui.BeginGroup();
        end
        -- consecutive tiles in a column simply flow downward with a gap
        imgui.Dummy({ 0, p.gap });
    else
        if (n % p.per_row == 0) then imgui.NewLine();
        else imgui.SameLine(0, p.gap); end
    end
end
local function FinishTiles(n, p)
    if (IsVertical(p)) and (n > 0) then imgui.EndGroup(); end
end

local function DrawBuffs()
    local p = cfg.buffs;
    local list = ReadBuffs();
    if (list == nil) then return; end
    local rows = {};
    for _, b in ipairs(list) do
        local keep = true;
        if (p.hide_maneuvers) and (b.id >= 300) and (b.id <= 307) then keep = false; end
        if (p.hide_infinite) and (b.left == nil) then keep = false; end
        if (keep) then table.insert(rows, b); end
    end
    if (#rows == 0) then return; end
    -- Total order: by remaining (infinite last), then id, so tiles never
    -- shuffle between two frames with equal keys.
    table.sort(rows, function (a, b)
        local la = a.left or 1e12; local lb = b.left or 1e12;
        if (la ~= lb) then
            if (p.sort_soonest_first) then return la < lb; else return la > lb; end
        end
        return a.id < b.id;
    end);

    if (BeginPanel('cdtimers_buffs', p)) then
        local sz = p.icon_size;
        local n = 0;
        for _, b in ipairs(rows) do
            if (n >= p.max_tiles) then break; end
            local e = StatusIcon(b.id);
            if (e ~= nil) then
                PlaceTile(n, p);
                n = n + 1;
                imgui.BeginGroup();
                imgui.Image(e.img, { sz, sz }, { 0, 0 }, { 1, 1 });
                if (imgui.IsItemHovered()) then imgui.SetTooltip(StatusName(b.id)); end
                local lbl, col = '-', COL_DIM;
                if (b.left ~= nil) then
                    lbl = FmtLeft(b.left);
                    col = LeftColour(b.left, p.warn_at, p.crit_at);
                end
                OutlinedTextCentered(lbl, col, sz, p.font_scale);
                imgui.EndGroup();
            end
        end
        FinishTiles(n, p);
    end
    EndPanel(p);
end

-- One [Name          5:40] row: dark ground, a fill that grows left->right as
-- the cooldown ELAPSES (full = ready), name inset left, time inset right.
-- Rects go through the draw list; text goes through the cursor so it can use
-- the window font scale; a Dummy reserves the footprint so autoresize works.
-- Size factor for a row: 1.0 at/below grow_full_at seconds left, easing
-- down to grow_min at/above grow_min_at. Smoothstep so the growth reads as
-- a swell rather than a linear creep.
local function RowScale(p, left)
    if (p.grow == false) then return 1.0; end
    local full, small = p.grow_full_at or 60, p.grow_min_at or 600;
    local kmin = p.grow_min or 0.55;
    if (left <= full) then return 1.0; end
    if (left >= small) then return kmin; end
    local t = (left - full) / (small - full);      -- 0 at full size .. 1 at smallest
    t = t * t * (3 - 2 * t);
    return 1.0 - (1.0 - kmin) * t;
end

local function DrawBarRow(p, name, left, total)
    local k = RowScale(p, left);
    local w, h = math.floor(p.bar_w * k), math.floor(p.bar_h * k);
    local x, y = imgui.GetCursorScreenPos();
    local dl = imgui.GetWindowDrawList();
    local frac = 0;
    if (total ~= nil) and (total > 0) then
        frac = 1.0 - math.max(0, math.min(1, left / total));
    end
    local a = p.bar_bg_alpha or 0.9;
    local function U(c, am)   -- colour table -> u32, alpha multiplied
        return imgui.GetColorU32({ c[1], c[2], c[3], (c[4] or 1.0) * (am or 1.0) });
    end
    local bgt, bgb = p.bar_bg_top or { 0.24, 0.21, 0.44, 1 }, p.bar_bg_bot or { 0.11, 0.10, 0.24, 1 };
    local ft,  fb  = p.bar_fill_top or { 0.55, 0.50, 0.85, 1 }, p.bar_fill_bot or { 0.32, 0.28, 0.62, 1 };
    local bd = p.bar_border or { 0.42, 0.38, 0.72, 0.9 };
    -- ground: top-lit vertical gradient
    dl:AddRectFilledMultiColor({ x, y }, { x + w, y + h },
        U(bgt, a), U(bgt, a), U(bgb, a), U(bgb, a));
    -- fill: same hue, brighter, grows left->right as the cooldown elapses
    if (frac > 0) then
        local fx = x + math.max(2, w * frac);
        dl:AddRectFilledMultiColor({ x, y }, { fx, y + h },
            U(ft), U(ft), U(fb), U(fb));
        -- crisp lip on the fill's top edge, like the swatch
        dl:AddLine({ x, y + 0.5 }, { fx, y + 0.5 }, U({ ft[1] + 0.15, ft[2] + 0.15, ft[3] + 0.10, 1.0 }), 1.0);
    end
    dl:AddRect({ x, y }, { x + w, y + h }, U(bd), 0.0, 0, 1.0);
    PushScale(p.font_scale * k);
    local pad = math.max(2, math.floor(p.bar_pad * k));
    local th = imgui.GetTextLineHeight();
    local ty = y + (h - th) * 0.5;
    local tlbl = FmtLeft(left);
    local tw = imgui.CalcTextSize(tlbl);
    -- the name gets whatever width the time leaves it
    local nm = FitName(name, w - pad * 3 - tw, 1.0);
    OutlinedTextAt(x + pad, ty, nm, COL_TEXT);
    OutlinedTextAt(x + w - pad - tw, ty, tlbl, LeftColour(left, p.warn_at, p.crit_at));
    PopScale();
    imgui.SetCursorScreenPos({ x, y });
    imgui.Dummy({ w, h });
end

local function DrawRecasts()
    local p = cfg.recasts;
    local rows = ReadRecasts();
    if (#rows == 0) then return; end
    table.sort(rows, function (a, b)
        if (a.left ~= b.left) then
            if (p.sort_soonest_first) then return a.left < b.left; else return a.left > b.left; end
        end
        return a.key < b.key;
    end);

    if (BeginPanel('cdtimers_recasts', p)) then
        local w = p.tile_w;
        local n = 0;
        for _, r in ipairs(rows) do
            if (n >= p.max_tiles) then break; end
            PlaceTile(n, p);
            n = n + 1;
            if (p.style ~= 'tiles') then
                DrawBarRow(p, r.name, r.left, r.total);
            else
            imgui.BeginGroup();
            OutlinedTextCentered(FitName(r.name, w, p.name_scale), COL_DIM, w, p.name_scale);
            OutlinedTextCentered(FmtLeft(r.left), LeftColour(r.left, p.warn_at, p.crit_at), w, p.font_scale);
            if (p.show_bar) and (r.total ~= nil) and (r.total > 0) then
                local frac = math.max(0, math.min(1, r.left / r.total));
                local x, y = imgui.GetCursorScreenPos();
                local dl = imgui.GetWindowDrawList();
                local h = 3;
                dl:AddRectFilled({ x, y }, { x + w, y + h }, imgui.GetColorU32(COL_BAR_BG));
                dl:AddRectFilled({ x, y }, { x + w * frac, y + h }, imgui.GetColorU32(COL_BAR));
                imgui.Dummy({ w, h + 1 });   -- reserve the bar's footprint
            end
            imgui.EndGroup();
            end
        end
        FinishTiles(n, p);
    end
    EndPanel(p);
end

----------------------------------------------------------------------------
-- Config window
----------------------------------------------------------------------------
local function SliderI(label, tbl, key, lo, hi)
    local v = { tbl[key] };
    if (imgui.SliderInt(label, v, lo, hi)) then tbl[key] = v[1]; cfg._dirty = true; end
end
local function SliderF(label, tbl, key, lo, hi, fmt)
    local v = { tbl[key] };
    if (imgui.SliderFloat(label, v, lo, hi, fmt or '%.2f')) then tbl[key] = v[1]; cfg._dirty = true; end
end
local function Check(label, tbl, key)
    local v = { tbl[key] };
    if (imgui.Checkbox(label, v)) then tbl[key] = v[1]; cfg._dirty = true; end
end

local function DrawConfig()
    if (not cfg.show_config) then return; end
    local open = { true };
    -- Fixed, resizable, scrolling: with both headers open this column is
    -- taller than a 1080p display, and an AlwaysAutoResize window taller
    -- than the screen crashes the client.
    imgui.SetNextWindowSize({ 400, 600 }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('cdtimers config', open, ImGuiWindowFlags_None)) then
        Check('Lock panels (freeze position, click-through)', cfg, 'locked');
        imgui.SameLine();
        if (imgui.Button('Save')) then settings.save('cdtimers'); cfg._dirty = false; end
        imgui.SameLine();
        if (imgui.Button('Reset defaults')) then
            settings.reset('cdtimers'); cfg = settings.load(defaults, 'cdtimers'); cfg.show_config = true;
        end
        imgui.Separator();

        if (imgui.CollapsingHeader('Buffs panel', ImGuiTreeNodeFlags_DefaultOpen)) then
            local b = cfg.buffs;
            Check('Enabled##b', b, 'enabled');
            SliderI('Icon size##b', b, 'icon_size', 20, 96);
            SliderI('Gap##b', b, 'gap', 0, 16);
            Check('Stack downward##b', b, 'vertical');
            SliderI('Tiles per column/row##b', b, 'per_row', 1, 32);
            SliderF('Digit scale##b', b, 'font_scale', 0.8, 3.0);
            SliderI('Yellow at (s)##b', b, 'warn_at', 1, 120);
            SliderI('Red at (s)##b', b, 'crit_at', 1, 60);
            SliderI('Max tiles##b', b, 'max_tiles', 1, 32);
            Check("Hide the game's own status-icon row", b, 'hide_native');
            Check('Hide maneuvers (cdchime draws them)', b, 'hide_maneuvers');
            Check('Hide no-expiry buffs (Signet etc.)', b, 'hide_infinite');
            Check('Soonest first##b', b, 'sort_soonest_first');
        end
        if (imgui.CollapsingHeader('Recasts panel', ImGuiTreeNodeFlags_DefaultOpen)) then
            local r = cfg.recasts;
            Check('Enabled##r', r, 'enabled');
            Check('Abilities', r, 'show_abilities'); imgui.SameLine();
            Check('Spells', r, 'show_spells');
            local bars = { r.style ~= 'tiles' };
            if (imgui.Checkbox('Bar rows  [Name        5:40]', bars)) then
                r.style = bars[1] and 'bars' or 'tiles'; cfg._dirty = true;
            end
            if (r.style ~= 'tiles') then
                SliderI('Bar width##r', r, 'bar_w', 100, 400);
                SliderI('Bar height##r', r, 'bar_h', 14, 48);
                SliderF('Ground alpha##r', r, 'bar_bg_alpha', 0.0, 1.0);
                Check('Long cooldowns start small and grow', r, 'grow');
                if (r.grow ~= false) then
                    SliderI('Full size at (s left)##r', r, 'grow_full_at', 5, 300);
                    SliderI('Smallest at (s left)##r', r, 'grow_min_at', 60, 3600);
                    SliderF('Smallest scale##r', r, 'grow_min', 0.3, 1.0);
                end
                local function ColorRow(label, key)
                    local f = r[key] or T{ 0.5, 0.5, 0.5, 1.0 };
                    local c = { f[1], f[2], f[3], f[4] };
                    if (imgui.ColorEdit4(label, c)) then
                        r[key] = T{ c[1], c[2], c[3], c[4] }; cfg._dirty = true;
                    end
                end
                ColorRow('Ground top##r',  'bar_bg_top');
                ColorRow('Ground bottom##r', 'bar_bg_bot');
                ColorRow('Fill top##r',    'bar_fill_top');
                ColorRow('Fill bottom##r', 'bar_fill_bot');
                ColorRow('Border##r',      'bar_border');
            else
                Check('Depletion bar under digits', r, 'show_bar');
                SliderI('Tile width##r', r, 'tile_w', 40, 140);
                SliderF('Name scale##r', r, 'name_scale', 0.6, 1.5);
            end
            SliderI('Gap##r', r, 'gap', 0, 16);
            Check('Stack downward##r', r, 'vertical');
            SliderI('Rows per column##r', r, 'per_row', 1, 24);
            SliderF('Text scale##r', r, 'font_scale', 0.8, 3.0);
            SliderF('Ignore under (s)##r', r, 'min_seconds', 0.0, 10.0, '%.1f');
            SliderI('Yellow at (s)##r', r, 'warn_at', 1, 60);
            SliderI('Red at (s)##r', r, 'crit_at', 1, 30);
            SliderI('Max tiles##r', r, 'max_tiles', 1, 32);
            Check('Soonest first##r', r, 'sort_soonest_first');
        end
        imgui.Separator();
        if (imgui.Button('Popup colours & theme...')) then
            -- Direct call into the sibling module; no command is queued.
            local th = _G.cdchimeTheme;
            if (th ~= nil) and (th.cfg ~= nil) then th.cfg.show_config = true; end
        end
        imgui.SameLine();
        imgui.TextColored(COL_DIM, 'toasts, nags, range, placeholders');
        imgui.TextColored(COL_DIM, 'Unlock, drag the panels where you want them, lock, Save.');
    end
    imgui.End();
    if (not open[1]) then
        cfg.show_config = false;
        settings.save('cdtimers'); cfg._dirty = false;
    end
end

----------------------------------------------------------------------------
-- Events
----------------------------------------------------------------------------
ashita.events.register('d3d_present', 'timers_present_cb', function ()
    NativeSync();
    if (cfg.buffs.enabled)   then DrawBuffs();   end
    if (cfg.recasts.enabled) then DrawRecasts(); end
    DrawConfig();
end);

ashita.events.register('command', 'timers_command_cb', function (e)
    local args = e.command:args();
    if (#args == 0) or (args[1] ~= '/heaphtimers' and args[1] ~= '/cdtimers') then return; end
    e.blocked = true;
    local sub = args[2] and args[2]:lower() or nil;
    if (sub == nil) or (sub == 'config') then
        cfg.show_config = not cfg.show_config;
    elseif (sub == 'lock') then
        cfg.locked = true; settings.save('cdtimers'); print('[cdtimers] locked');
    elseif (sub == 'unlock') then
        cfg.locked = false; print('[cdtimers] unlocked - drag the panels, then /cdtimers lock');
    elseif (sub == 'buffs') then
        cfg.buffs.enabled = not cfg.buffs.enabled; settings.save('cdtimers');
        print(('[cdtimers] buffs panel %s'):fmt(cfg.buffs.enabled and 'on' or 'off'));
    elseif (sub == 'recasts') then
        cfg.recasts.enabled = not cfg.recasts.enabled; settings.save('cdtimers');
        print(('[cdtimers] recasts panel %s'):fmt(cfg.recasts.enabled and 'on' or 'off'));
    elseif (sub == 'native') then
        cfg.buffs.hide_native = not cfg.buffs.hide_native; settings.save('cdtimers');
        print(('[cdtimers] native status row %s'):fmt(cfg.buffs.hide_native and 'hidden' or 'shown'));
    elseif (sub == 'reset') then
        settings.reset('cdtimers'); cfg = settings.load(defaults, 'cdtimers'); print('[cdtimers] settings reset');
    else
        print('[cdtimers] /cdtimers [config|lock|unlock|buffs|recasts|native|reset]');
    end
end);

-- Persist on unload so dragged positions survive even without an explicit save.
ashita.events.register('unload', 'timers_unload_cb', function ()
    NativeRestore();
    if (cfg._dirty) then settings.save('cdtimers'); end
end);

-- Settings lib may hand us a fresh table (e.g. character change).
settings.register('cdtimers', 'timers_settings_update', function (s)
    if (s ~= nil) then cfg = s; end
end);

-- Shared handle for theme.lua's "Match timer bars to this palette" button.
-- It must mutate THIS live table and save through here: calling
-- settings.load(..., 'cdtimers') from another module would overwrite the
-- cached defaults for the alias (breaking Reset defaults) and hand us a
-- different table than the one being rendered.
_G.cdtimersShare = {
    cfg  = function () return cfg; end,
    save = function ()
        settings.save('cdtimers');
        cfg._dirty = false;
    end,
    -- Opened from the cdchime config window's "Timer panels" button.
    showConfig = function () cfg.show_config = true; end,
};

return { name = 'timers', version = '1.0' };
