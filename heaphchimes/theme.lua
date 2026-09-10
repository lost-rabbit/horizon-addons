--[[
* theme.lua - ONE look for every cdchime window.
*
* Before this module each popup carried its own hard-coded background,
* border, rounding, padding and text scale - seven different backgrounds
* across the addon, plus phtimer's teal and the timer panels' indigo. The
* windows never looked like they belonged to the same addon.
*
* Everything is now driven from one saved palette:
*
*   ground / border / text / dim / good / warn / crit   - shared colours
*   rounding / border_size / pad_x / pad_y / pulse      - shared frame
*   tint                                                - 0.00 every popup
*                                                         uses the exact same
*                                                         ground (uniform),
*                                                         1.00 each popup's
*                                                         ground is pulled all
*                                                         the way to its own
*                                                         accent (the old look)
*
* Each popup keeps an accent colour (so JUMP still reads red, BERSERK amber)
* plus its own enable toggle and text scale, all editable in /cdchime config.
*
* Settings: config\addons\cdchime\<char>\cdtheme.lua
--]]

require('common');
local imgui    = require('imgui');
local chat     = require('chat');
local settings = require('settings');

local M = { };

----------------------------------------------------------------------------
-- Defaults - the indigo/navy palette the timer bars already use, so the
-- popups and the bars are one family out of the box.
----------------------------------------------------------------------------
local function P(id, label, r, g, b, scale, bare)
    return T{ id = id, label = label, accent = T{ r, g, b }, scale = scale,
              enabled = true, bare = bare or false,
              -- '' = its own window. Otherwise the id of a list window it
              -- renders into as a coloured line (see MERGE_TARGETS).
              merge_into = '' };
end

-- Windows that can host merged lines, in the order the combo shows them.
local MERGE_TARGETS = T{
    { id = '',                 label = 'Own window' },
    { id = 'cdchime_alerts',   label = 'Alerts window' },
    { id = 'cdchime_groupa',   label = 'Group A' },
    { id = 'cdchime_groupb',   label = 'Group B' },
};
M.MERGE_TARGETS = MERGE_TARGETS;

-- Only these can be merged; the icon strips and the timers draw their own
-- content and cannot become a text line.
local MERGEABLE = T{
    cdchime_zerk = true, cdchime_jump = true, cdchime_mannag = true,
    cdchime_petnag = true, cdchime_buffnag = true, cdchime_tpnag = true,
    cdchime_toast = true, cdchime_petcast = true,
};
M.MERGEABLE = MERGEABLE;

local defaults = T{
    show_config = false,
    theme = T{
        ground      = T{ 0.12, 0.11, 0.27, 0.95 },  -- flat dark navy, matches bar_bg
        border      = T{ 0.42, 0.38, 0.72, 0.90 },  -- matches bar_border
        text        = T{ 0.94, 0.94, 1.00, 1.00 },
        dim         = T{ 0.62, 0.63, 0.78, 1.00 },
        good        = T{ 0.55, 1.00, 0.60, 1.00 },
        warn        = T{ 1.00, 0.85, 0.40, 1.00 },
        crit        = T{ 1.00, 0.45, 0.40, 1.00 },
        rounding    = 10.0,
        border_size = 2.0,
        pad_x       = 20.0,
        pad_y       = 14.0,
        tint        = 0.25,   -- how far each ground is pulled toward its accent
        pulse       = true,   -- breathing border on the attention popups
        accent_border = true, -- border takes the popup's accent (else shared)
        accent_text   = true, -- headline text takes the accent (else shared)
    },
    -- Automaton nuke cadence. 35s is MEASURED from 475 cast gaps in the
    -- chatlogs (mode 35s, 33-40s covers 55%); see petcast.lua.
    petcast = T{
        enabled    = true,
        interval   = 35,
        warn_at    = 5,
        hide_after = 30,
        width      = 150,
        height     = 10,
        show_bar   = true,
        show_spell = true,
        label      = 'Nuke',
        ready_text = 'Nuke due',
    },
    -- User-defined chat triggers (/cdchime trigger ...). Each is
    -- { name=, pattern=, text=, secs=, sticky=, col= }
    triggers = T{ },
    -- Per-window. Keys are the imgui window ids already in use, so saved
    -- positions from /cdchime layout survive untouched.
    popups = T{
        cdchime_toast     = P('cdchime_toast',     'Ability ready',   1.00, 0.88, 0.40, 2.0),
        cdchime_alerts    = P('cdchime_alerts',    'Alerts / range',  1.00, 0.70, 0.25, 1.8),
        cdchime_risk      = P('cdchime_risk',      'Overload risk',   1.00, 0.88, 0.40, 1.5),
        cdchime_maneuvers = P('cdchime_maneuvers', 'Maneuver tiles',  0.65, 0.85, 1.00, 2.0, true),
        cdchime_zerk      = P('cdchime_zerk',      'Berserk nag',     1.00, 0.60, 0.20, 2.0),
        cdchime_jump      = P('cdchime_jump',      'Jump nag',        1.00, 0.35, 0.30, 2.0),
        cdchime_mannag    = P('cdchime_mannag',    'Maneuver nag',    1.00, 0.70, 0.25, 2.0),
        cdchime_petnag    = P('cdchime_petnag',    'Pet nag',         0.80, 0.45, 1.00, 2.0),
        cdchime_buffnag   = P('cdchime_buffnag',   'Buff nag',        0.35, 0.85, 1.00, 2.0),
        cdchime_tpnag     = P('cdchime_tpnag',     'TP nag',          0.40, 1.00, 0.50, 2.0),
        cdchime_petcast   = P('cdchime_petcast',   'Pet nuke timer',  0.55, 0.75, 1.00, 1.4),
        cdchime_phtimer   = P('cdchime_phtimer',   'Placeholders',    0.55, 0.85, 1.00, 1.6),
        cdchime_nmwindow  = P('cdchime_nmwindow',  'NM windows',      1.00, 0.55, 0.55, 1.6),
        cdchime_groupa    = P('cdchime_groupa',    'Group A',         0.80, 0.80, 0.95, 1.8),
        cdchime_groupb    = P('cdchime_groupb',    'Group B',         0.80, 0.80, 0.95, 1.8),
    },
};

M.cfg = settings.load(defaults, 'cdtheme');

-- A settings file written by an older build may be missing popups added
-- since. Fill the gaps without stomping anything the user has changed.
do
    local c = M.cfg;
    if (c.theme == nil) then c.theme = defaults.theme:copy(true); end
    for k, v in pairs(defaults.theme) do
        if (c.theme[k] == nil) then c.theme[k] = v; end
    end
    if (c.petcast == nil) then c.petcast = defaults.petcast:copy(true); end
    for k, v in pairs(defaults.petcast) do
        if (c.petcast[k] == nil) then c.petcast[k] = v; end
    end
    if (c.triggers == nil) then c.triggers = T{ }; end
    if (c.muted == nil) then c.muted = T{ ['boost'] = true }; end
    if (c.popups == nil) then c.popups = T{ }; end
    for id, d in pairs(defaults.popups) do
        local p = c.popups[id];
        if (p == nil) then
            c.popups[id] = d;
        else
            for k, v in pairs(d) do
                if (p[k] == nil) then p[k] = v; end
            end
        end
    end
end

function M.Save()
    settings.save('cdtheme');
    M.cfg._dirty = false;
end

function M.Dirty() M.cfg._dirty = true; end

----------------------------------------------------------------------------
-- Colour helpers
----------------------------------------------------------------------------
local function Mix(a, b, t)
    return { a[1] + (b[1] - a[1]) * t,
             a[2] + (b[2] - a[2]) * t,
             a[3] + (b[3] - a[3]) * t };
end

-- Shared palette colour as a plain 4-table, with an optional alpha override.
function M.Col(name, alpha)
    local c = M.cfg.theme[name] or T{ 1, 1, 1, 1 };
    return { c[1], c[2], c[3], alpha or c[4] or 1.0 };
end

function M.Get(id)
    return M.cfg.popups[id];
end

function M.Enabled(id)
    local p = M.cfg.popups[id];
    return (p == nil) or (p.enabled ~= false);
end

function M.Scale(id)
    local p = M.cfg.popups[id];
    return (p ~= nil) and (p.scale or 2.0) or 2.0;
end

-- Where should this popup draw? '' (or nil) = its own window; otherwise the
-- window id it should render into as a line. Non-mergeable windows always
-- answer ''.
function M.MergeTarget(id)
    if (MERGEABLE[id] ~= true) then return ''; end
    local p = M.cfg.popups[id];
    if (p == nil) then return ''; end
    local t = p.merge_into;
    if (t == nil) or (t == '') then return ''; end
    -- A target that is itself disabled would swallow the line silently.
    if (not M.Enabled(t)) then return ''; end
    return t;
end

-- Accent for this popup as a 4-table.
function M.Accent(id, alpha)
    local p = M.cfg.popups[id];
    local a = (p ~= nil) and p.accent or T{ 1, 1, 1 };
    return { a[1], a[2], a[3], alpha or 1.0 };
end

-- Headline text colour: the accent when accent_text is on, else shared text.
function M.TextCol(id, alpha)
    if (M.cfg.theme.accent_text == false) then return M.Col('text', alpha); end
    return M.Accent(id, alpha);
end

----------------------------------------------------------------------------
-- Window styling. Push/Pop are symmetric: always 3 style vars + 2 colours.
--
--   local acc = theme.Push(id, pulse)
--   if (imgui.Begin(id, true, flags)) then ... end
--   imgui.End();
--   theme.Pop();
----------------------------------------------------------------------------
function M.Push(id, pulse)
    local t = M.cfg.theme;
    local p = M.cfg.popups[id];
    local accent = (p ~= nil) and p.accent or T{ 1, 1, 1 };

    if ((p ~= nil) and p.bare) then
        -- Icon strips: no chrome at all, whatever the palette says.
        imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 0.0);
        imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0.0);
        imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 0.0, 0.0 });
        imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.0, 0.0, 0.0, 0.0 });
        imgui.PushStyleColor(ImGuiCol_Border, { 0.0, 0.0, 0.0, 0.0 });
        return { accent[1], accent[2], accent[3], 1.0 };
    end

    local g = t.ground;
    local bg = Mix({ g[1], g[2], g[3] }, accent, (t.tint or 0) * 0.35);
    local bd;
    if (t.accent_border == false) then
        bd = { t.border[1], t.border[2], t.border[3], t.border[4] or 0.9 };
    else
        bd = { accent[1], accent[2], accent[3], 1.0 };
    end
    if (pulse ~= nil) and (t.pulse ~= false) then bd[4] = pulse; end

    imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, t.rounding or 10.0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, t.border_size or 2.0);
    imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { t.pad_x or 20.0, t.pad_y or 14.0 });
    imgui.PushStyleColor(ImGuiCol_WindowBg, { bg[1], bg[2], bg[3], g[4] or 0.95 });
    imgui.PushStyleColor(ImGuiCol_Border, bd);
    return { accent[1], accent[2], accent[3], 1.0 };
end

function M.Pop()
    imgui.PopStyleColor(2);
    imgui.PopStyleVar(3);
end

-- Font scaling, guarded the same way cdchime.lua does it: older imgui
-- bindings have no SetWindowFontScale and need the PushFont/PopFont pair.
function M.PushScale(s)
    if (imgui.SetWindowFontScale ~= nil) then
        imgui.SetWindowFontScale(s);
    else
        imgui.PushFont(imgui.GetFont(), imgui.GetFontSize() * s);
    end
end

function M.PopScale()
    if (imgui.SetWindowFontScale ~= nil) then
        imgui.SetWindowFontScale(1.0);
    else
        imgui.PopFont();
    end
end

----------------------------------------------------------------------------
-- Presets. Each sets the shared palette; accents are left alone so the
-- popups keep their meaning (red = Jump, amber = Berserk...).
----------------------------------------------------------------------------
local PRESETS = T{
    -- Sampled from the XIUI pet bar: indigo-violet ground, salmon HP, lime
    -- MP, sky-blue TP. Sets the good/warn/crit trio too, so countdowns and
    -- risk numbers pick up the same three accents.
    T{ name = 'XIUI (pet bar)',
       ground = T{ 0.17, 0.14, 0.34, 0.95 }, border = T{ 0.46, 0.40, 0.78, 0.90 },
       text = T{ 0.95, 0.95, 0.99, 1.00 },   dim  = T{ 0.66, 0.64, 0.84, 1.00 },
       good = T{ 0.56, 0.83, 0.29, 1.00 },   warn = T{ 0.91, 0.51, 0.29, 1.00 },
       crit = T{ 0.94, 0.48, 0.42, 1.00 } },
    T{ name = 'Indigo (matches timer bars)',
       ground = T{ 0.12, 0.11, 0.27, 0.95 }, border = T{ 0.42, 0.38, 0.72, 0.90 },
       text = T{ 0.94, 0.94, 1.00, 1.00 },   dim = T{ 0.62, 0.63, 0.78, 1.00 } },
    T{ name = 'Carbon (neutral dark)',
       ground = T{ 0.10, 0.10, 0.12, 0.95 }, border = T{ 0.45, 0.45, 0.52, 0.90 },
       text = T{ 0.95, 0.95, 0.96, 1.00 },   dim = T{ 0.62, 0.62, 0.68, 1.00 } },
    T{ name = 'Abyss (deep teal)',
       ground = T{ 0.05, 0.13, 0.16, 0.95 }, border = T{ 0.28, 0.62, 0.68, 0.90 },
       text = T{ 0.92, 0.98, 1.00, 1.00 },   dim = T{ 0.58, 0.74, 0.78, 1.00 } },
    T{ name = 'Ember (warm brown)',
       ground = T{ 0.14, 0.09, 0.05, 0.95 }, border = T{ 0.70, 0.48, 0.25, 0.90 },
       text = T{ 1.00, 0.97, 0.92, 1.00 },   dim = T{ 0.78, 0.70, 0.60, 1.00 } },
    T{ name = 'Parchment (light)',
       ground = T{ 0.88, 0.85, 0.78, 0.96 }, border = T{ 0.45, 0.38, 0.28, 0.90 },
       text = T{ 0.12, 0.10, 0.08, 1.00 },   dim = T{ 0.38, 0.34, 0.28, 1.00 } },
};

function M.ApplyPreset(i)
    local p = PRESETS[i];
    if (p == nil) then return; end
    local t = M.cfg.theme;
    t.ground = p.ground:copy(true);
    t.border = p.border:copy(true);
    t.text   = p.text:copy(true);
    t.dim    = p.dim:copy(true);
    -- good/warn/crit are optional: a preset that only restyles the chrome
    -- leaves the semantic trio (and therefore every countdown colour) alone.
    if (p.good ~= nil) then t.good = p.good:copy(true); end
    if (p.warn ~= nil) then t.warn = p.warn:copy(true); end
    if (p.crit ~= nil) then t.crit = p.crit:copy(true); end
    M.Dirty();
end

-- Push the palette into the timer bars so panels and popups agree.
--
-- Goes through timers.lua's shared handle rather than settings.load(...,
-- 'cdtimers'): that call re-caches the alias's DEFAULTS as whatever table you
-- hand it, so passing an empty one would leave "Reset defaults" in the timers
-- config resetting to nothing. It also returns a different table than the one
-- timers.lua renders, so the change would not show until a reload.
function M.ApplyToTimerBars()
    local share = _G.cdtimersShare;
    if (share == nil) then return false; end
    local tset = share.cfg();
    if (tset == nil) or (tset.recasts == nil) then return false; end
    local t = M.cfg.theme;
    local g, b = t.ground, t.border;
    tset.recasts.bar_bg_top = T{ g[1], g[2], g[3], 1.0 };
    tset.recasts.bar_bg_bot = T{ g[1], g[2], g[3], 1.0 };
    tset.recasts.bar_border = T{ b[1], b[2], b[3], b[4] or 0.9 };
    -- Fill: the border hue, brighter on top and darker at the bottom.
    tset.recasts.bar_fill_top = T{ math.min(b[1] * 1.35, 1.0), math.min(b[2] * 1.35, 1.0), math.min(b[3] * 1.20, 1.0), 0.95 };
    tset.recasts.bar_fill_bot = T{ b[1] * 0.78, b[2] * 0.75, b[3] * 0.86, 0.95 };
    share.save();
    return true;
end

----------------------------------------------------------------------------
-- Config window
----------------------------------------------------------------------------
local function SliderF(label, tbl, key, lo, hi, fmt)
    local v = { tbl[key] };
    if (imgui.SliderFloat(label, v, lo, hi, fmt or '%.2f')) then tbl[key] = v[1]; M.Dirty(); end
end
local function Check(label, tbl, key)
    local v = { tbl[key] ~= false };
    if (imgui.Checkbox(label, v)) then tbl[key] = v[1]; M.Dirty(); end
end
local function ColorRow(label, tbl, key)
    local f = tbl[key] or T{ 0.5, 0.5, 0.5, 1.0 };
    local c = { f[1], f[2], f[3], f[4] or 1.0 };
    if (imgui.ColorEdit4(label, c)) then
        tbl[key] = T{ c[1], c[2], c[3], c[4] }; M.Dirty();
    end
end
local function ColorRow3(label, tbl, key)
    local f = tbl[key] or T{ 0.5, 0.5, 0.5 };
    local c = { f[1], f[2], f[3] };
    if (imgui.ColorEdit3(label, c)) then
        tbl[key] = T{ c[1], c[2], c[3] }; M.Dirty();
    end
end

local ORDER = T{
    'cdchime_toast', 'cdchime_alerts', 'cdchime_risk', 'cdchime_maneuvers',
    'cdchime_zerk', 'cdchime_jump', 'cdchime_mannag', 'cdchime_petnag',
    'cdchime_buffnag', 'cdchime_tpnag', 'cdchime_petcast', 'cdchime_phtimer',
    'cdchime_nmwindow',
    'cdchime_groupa', 'cdchime_groupb',
};

-- Set by cdchime.lua so the config window can drive layout mode.
M.layout_get = nil;
M.layout_set = nil;

-- Live buffers for the "add" forms. imgui writes into these tables in place,
-- so they must outlive the frame.
local newTrg = {
    name = T{ '' }, pattern = T{ '' }, text = T{ '' },
    sticky = { false }, secs = { 10 }, speak = { false },
};
local trgError = nil;
local newPh   = { name = T{ '' }, secs = { 300 } };
local newSpell = T{ '' };
local muteFilter = T{ '' };

----------------------------------------------------------------------------
-- Config window.
--
-- One fixed-size, resizable window (ImGuiCond_FirstUseEver, so a size the
-- user drags to is kept) with the sections split across tabs. Every tab body
-- sits inside a child region that fills the tab and scrolls, so no amount of
-- content can grow the window taller than the screen. The previous layout
-- was a single AlwaysAutoResize column of collapsing headers; once enough
-- sections were added it auto-sized past the display height, and an
-- auto-resized window taller than the screen crashes the client outright.
----------------------------------------------------------------------------
local CONFIG_W, CONFIG_H = 560, 620;

local function Heading(text)
    imgui.TextColored(M.Col('warn'), text);
end

local function TabTheme()
    Heading('Palette');
    imgui.TextColored(M.Col('dim'), 'Presets');
    for i, p in ipairs(PRESETS) do
        if (imgui.Button(p.name)) then M.ApplyPreset(i); end
        if (i % 2 == 1) and (i < #PRESETS) then imgui.SameLine(); end
    end
    imgui.Separator();
    ColorRow('Window ground', M.cfg.theme, 'ground');
    ColorRow('Border (shared)', M.cfg.theme, 'border');
    ColorRow('Text', M.cfg.theme, 'text');
    ColorRow('Dim text', M.cfg.theme, 'dim');
    ColorRow('Good', M.cfg.theme, 'good');
    ColorRow('Warning', M.cfg.theme, 'warn');
    ColorRow('Critical', M.cfg.theme, 'crit');
    imgui.Separator();
    SliderF('Accent tint in ground', M.cfg.theme, 'tint', 0.0, 1.0);
    imgui.TextColored(M.Col('dim'), '0 = every popup identical, 1 = each takes its own colour');
    Check('Border uses the popup colour', M.cfg.theme, 'accent_border');
    Check('Headline text uses the popup colour', M.cfg.theme, 'accent_text');
    Check('Pulse the border on attention popups', M.cfg.theme, 'pulse');

    imgui.Separator();
    Heading('Frame');
    SliderF('Corner rounding', M.cfg.theme, 'rounding', 0.0, 20.0, '%.0f');
    SliderF('Border thickness', M.cfg.theme, 'border_size', 0.0, 5.0, '%.1f');
    SliderF('Padding X', M.cfg.theme, 'pad_x', 0.0, 40.0, '%.0f');
    SliderF('Padding Y', M.cfg.theme, 'pad_y', 0.0, 40.0, '%.0f');
end

local function TabWindows()
    Heading('Windows');
    imgui.TextColored(M.Col('dim'), 'On/off, accent colour and text scale for each popup.');
    imgui.Separator();
    for _, id in ipairs(ORDER) do
        local p = M.cfg.popups[id];
        if (p ~= nil) then
            imgui.PushID(id);
            local ev = { p.enabled ~= false };
            if (imgui.Checkbox('##on', ev)) then p.enabled = ev[1]; M.Dirty(); end
            imgui.SameLine();
            ColorRow3('##acc', p, 'accent');
            imgui.SameLine();
            imgui.TextColored(M.Accent(id), p.label or id);
            if (not p.bare) or (id == 'cdchime_maneuvers') then
                local sv = { p.scale or 2.0 };
                imgui.PushItemWidth(180);
                if (imgui.SliderFloat('scale', sv, 0.6, 3.5, '%.2f')) then
                    p.scale = sv[1]; M.Dirty();
                end
                imgui.PopItemWidth();
            end
            imgui.PopID();
            imgui.Separator();
        end
    end

    Heading('Timer panels');
    imgui.TextColored(M.Col('dim'), 'Buff tiles and recast bars have their own window.');
    if (imgui.Button('Open timer panel settings')) then
        local share = _G.cdtimersShare;
        if (share ~= nil) and (share.showConfig ~= nil) then share.showConfig(); end
    end
    imgui.Separator();
    if (imgui.Button('Match timer bars to this palette')) then
        if (M.ApplyToTimerBars()) then
            print(chat.header('cdchime'):append(chat.message('Timer bars recoloured - /cdtimers config to fine-tune.')));
        else
            print(chat.header('cdchime'):append(chat.error('Could not load cdtimers settings.')));
        end
    end
    imgui.TextColored(M.Col('dim'), 'Copies ground/border into the recast bars.');
end

local function TabCombine()
    Heading('Combine windows');
    imgui.TextColored(M.Col('dim'), 'Send a popup into a shared window instead of its own.');
    imgui.TextColored(M.Col('dim'), 'Each keeps its colour as a line in the host.');
    imgui.Separator();
    for _, id in ipairs(ORDER) do
        if (MERGEABLE[id] == true) then
            local p = M.cfg.popups[id];
            if (p ~= nil) then
                imgui.PushID('mg' .. id);
                -- current index in MERGE_TARGETS
                local cur, names = 0, T{};
                for i, tgt in ipairs(MERGE_TARGETS) do
                    names:append(tgt.label);
                    if ((p.merge_into or '') == tgt.id) then cur = i - 1; end
                end
                imgui.TextColored(M.Accent(id), p.label or id);
                imgui.SameLine(150);
                imgui.PushItemWidth(160);
                local sel = { cur };
                if (imgui.Combo('##tgt', sel, names, #names)) then
                    p.merge_into = MERGE_TARGETS[sel[1] + 1].id;
                    M.Dirty();
                end
                imgui.PopItemWidth();
                imgui.PopID();
            end
        end
    end
    imgui.Separator();
    if (imgui.Button('All nags -> Alerts')) then
        for _, id in ipairs({ 'cdchime_zerk', 'cdchime_jump', 'cdchime_mannag',
                              'cdchime_petnag', 'cdchime_buffnag', 'cdchime_tpnag' }) do
            if (M.cfg.popups[id] ~= nil) then M.cfg.popups[id].merge_into = 'cdchime_alerts'; end
        end
        M.Dirty();
    end
    imgui.SameLine();
    if (imgui.Button('Split all back out')) then
        for id in pairs(MERGEABLE) do
            if (M.cfg.popups[id] ~= nil) then M.cfg.popups[id].merge_into = ''; end
        end
        M.Dirty();
    end
end

local function TabCooldowns()
    Heading('Cooldown popups');
    local sh = _G.cdchimeShare;
    if (sh == nil) then
        imgui.TextColored(M.Col('dim'), 'cdchime not loaded yet.');
        return;
    end
    imgui.TextColored(M.Col('dim'), 'Untick anything too chatty to pop.');
    imgui.PushItemWidth(200);
    imgui.InputText('filter', muteFilter, 64);
    imgui.PopItemWidth();
    local f = (muteFilter[1] or ''):lower();
    -- Bordered child; EndChild is unconditional in this binding.
    imgui.BeginChild('mutelist', { 0, 150 }, ImGuiChildFlags_Borders, 0);
    for _, a in ipairs(sh.Tracked()) do
        if (f == '') or (a.name:lower():find(f, 1, true)) then
            local on = { not a.muted };
            if (imgui.Checkbox(a.name, on)) then
                sh.SetMute(a.name, not on[1]);
            end
        end
    end
    imgui.EndChild();
    imgui.Separator();
    imgui.TextColored(M.Col('dim'), 'Watched spells (recasts are usually too short to bother):');
    for _, s in ipairs(sh.Spells()) do
        imgui.PushID('sp' .. tostring(s.id));
        if (imgui.Button('X')) then sh.DelSpell(s.id); end
        imgui.SameLine();
        imgui.TextColored(M.Col('text'), s.name);
        imgui.PopID();
    end
    imgui.PushItemWidth(200);
    imgui.InputText('spell name', newSpell, 64);
    imgui.PopItemWidth();
    imgui.SameLine();
    if (imgui.Button('Watch')) then
        local nm = (newSpell[1] or ''):match('^%s*(.-)%s*$');
        if (nm ~= '') and (sh.AddSpell(nm) ~= nil) then newSpell[1] = ''; end
    end
end

local function TabCustom()
    Heading('Custom popups');
    -- Existing triggers, each editable in place.
    local names = T{};
    for name in pairs(M.cfg.triggers) do names:append(name); end
    table.sort(names);
    for _, name in ipairs(names) do
        local t = M.cfg.triggers[name];
        imgui.PushID('trg' .. name);
        if (imgui.Button('Delete')) then
            M.cfg.triggers[name] = nil; M.Dirty();
            imgui.PopID();
        else
            imgui.SameLine();
            imgui.TextColored(M.Col('text'), name);
            imgui.PushItemWidth(230);
            local pat = T{ t.pattern or '' };
            if (imgui.InputText('when chat matches', pat, 256)) then
                t.pattern = pat[1]; M.Dirty();
            end
            local txt = T{ t.text or '' };
            if (imgui.InputText('show this', txt, 256)) then
                t.text = txt[1]; M.Dirty();
            end
            imgui.PopItemWidth();
            local st = { t.sticky == true };
            if (imgui.Checkbox('stay on screen', st)) then t.sticky = st[1]; M.Dirty(); end
            if (t.sticky) then
                imgui.SameLine();
                imgui.PushItemWidth(110);
                local sc = { t.secs or 10 };
                if (imgui.SliderInt('secs', sc, 1, 60)) then t.secs = sc[1]; M.Dirty(); end
                imgui.PopItemWidth();
            end
            local sp = { t.speak == true };
            if (imgui.Checkbox('speak it', sp)) then t.speak = sp[1]; M.Dirty(); end
            if (imgui.Button('Test')) then
                if (_G.cdchimeShare ~= nil) then
                    _G.cdchimeShare.Toast((t.text or name):gsub('%$%d', 'sample'));
                end
            end
            imgui.PopID();
            imgui.Separator();
        end
    end

    -- Add form
    imgui.TextColored(M.Col('warn'), 'New popup');
    imgui.PushItemWidth(230);
    imgui.InputText('name', newTrg.name, 64);
    imgui.InputText('when chat matches##new', newTrg.pattern, 256);
    imgui.InputText('show this##new', newTrg.text, 256);
    imgui.PopItemWidth();
    imgui.Checkbox('stay on screen##new', newTrg.sticky);
    if (newTrg.sticky[1]) then
        imgui.SameLine();
        imgui.PushItemWidth(110);
        imgui.SliderInt('secs##new', newTrg.secs, 1, 60);
        imgui.PopItemWidth();
    end
    imgui.Checkbox('speak it##new', newTrg.speak);
    if (imgui.Button('Add popup')) then
        local nm = (newTrg.name[1] or ''):match('^%s*(.-)%s*$');
        local pt = (newTrg.pattern[1] or ''):match('^%s*(.-)%s*$');
        local tx = (newTrg.text[1] or ''):match('^%s*(.-)%s*$');
        if (nm == '') or (pt == '') then
            trgError = 'Give it a name and something to match.';
        else
            -- A bad Lua pattern would throw on every chat line, so
            -- prove it compiles before storing it.
            local ok = pcall(string.match, 'test string', pt);
            if (not ok) then
                trgError = 'That match text is not a valid pattern.';
            else
                M.cfg.triggers[nm] = {
                    pattern = pt,
                    text    = (tx ~= '') and tx or nm,
                    sticky  = newTrg.sticky[1],
                    secs    = newTrg.secs[1],
                    speak   = newTrg.speak[1],
                };
                M.Dirty(); M.Save();
                newTrg.name[1] = ''; newTrg.pattern[1] = ''; newTrg.text[1] = '';
                trgError = nil;
            end
        end
    end
    imgui.SameLine();
    if (imgui.Button('Preview##new')) then
        if (_G.cdchimeShare ~= nil) then
            local tx = (newTrg.text[1] or ''):gsub('%$%d', 'sample');
            _G.cdchimeShare.Toast((tx ~= '') and tx or 'preview');
        end
    end
    if (trgError ~= nil) then
        imgui.TextColored(M.Col('crit'), trgError);
    end
    imgui.TextColored(M.Col('dim'), 'Match is a Lua pattern. Captures come back as $1 $2 $3.');
    imgui.TextColored(M.Col('dim'), 'e.g.  (%a+) was defeated   ->   $1 DOWN');
end

local function TabPets()
    Heading('Pet nuke timer');
    local p = M.cfg.petcast;
    Check('Enabled##pc', p, 'enabled');
    local iv = { p.interval or 35 };
    if (imgui.SliderInt('Interval (s)', iv, 5, 90)) then p.interval = iv[1]; M.Dirty(); end
    imgui.TextColored(M.Col('dim'), 'Measured 35s: mode of 475 cast gaps in your logs.');
    local wa = { p.warn_at or 5 };
    if (imgui.SliderInt('Turn amber at (s)', wa, 0, 20)) then p.warn_at = wa[1]; M.Dirty(); end
    local ha = { p.hide_after or 30 };
    if (imgui.SliderInt('Hide after due (s)', ha, 5, 120)) then p.hide_after = ha[1]; M.Dirty(); end
    Check('Show bar##pc', p, 'show_bar');
    Check('Show last spell##pc', p, 'show_spell');
end

local function TabPlaceholders()
    Heading('Placeholder timers');
    local ph = _G.cdchimePhShare;
    if (ph == nil) then
        imgui.TextColored(M.Col('dim'), 'phtimer not loaded yet.');
        return;
    end
    -- phtimer's share is { key, name, respawn, auto }: fixed intervals only,
    -- the old "learning" fields no longer exist.
    for _, e in ipairs(ph.List()) do
        imgui.PushID('ph' .. e.key);
        if (imgui.Button('X')) then ph.Remove(e.key); end
        imgui.SameLine();
        local secs = e.respawn or 0;
        local desc = ('%s  every %d:%02d%s'):fmt(e.name,
            math.floor(secs / 60), math.floor(secs % 60),
            e.auto and ' (auto)' or '');
        imgui.TextColored(M.Col('text'), desc);
        imgui.PopID();
    end
    imgui.Separator();
    imgui.PushItemWidth(200);
    imgui.InputText('mob name', newPh.name, 64);
    imgui.SliderInt('respawn (s)', newPh.secs, 30, 1800);
    imgui.PopItemWidth();
    if (imgui.Button('Track it')) then
        local nm = (newPh.name[1] or ''):match('^%s*(.-)%s*$');
        if (nm ~= '') then
            ph.Add(nm, newPh.secs[1]);
            newPh.name[1] = '';
        end
    end
    imgui.TextColored(M.Col('dim'), 'Respawn is the mob\'s own interval; the 16s despawn delay is added for you.');
end

local function TabVoice()
    Heading('Voice');
    local sh = _G.cdchimeShare;
    if (sh == nil) then
        imgui.TextColored(M.Col('dim'), 'cdchime not loaded yet.');
        return;
    end
    local on = { sh.Say() };
    if (imgui.Checkbox('Speak the popups', on)) then sh.SetSay(on[1]); end
    imgui.PushItemWidth(200);
    local v = { sh.Volume() };
    if (imgui.SliderInt('Volume', v, 0, 100)) then sh.SetVolume(v[1]); end
    imgui.PopItemWidth();
    imgui.TextColored(M.Col('dim'), 'Needs the TTS daemon running (CdchimeVoice.bat).');
end

-- Tab bodies run under pcall so a fault in one section cannot skip the
-- EndChild / EndTabItem below it and leave ImGui's window stack broken for
-- every other addon that draws this frame. The error is printed once per
-- distinct message rather than every frame.
local lastTabError = nil;
local function Tab(label, body)
    if (imgui.BeginTabItem(label)) then
        imgui.BeginChild('##tab_' .. label, { 0, 0 }, 0, 0);
        local ok, err = pcall(body);
        imgui.EndChild();
        imgui.EndTabItem();
        if (not ok) then
            local msg = tostring(err);
            if (msg ~= lastTabError) then
                lastTabError = msg;
                print(chat.header('cdchime'):append(chat.error(('config tab "%s": %s'):fmt(label, msg))));
            end
        end
    end
end

function M.DrawConfig()
    if (not M.cfg.show_config) then return; end
    local open = { true };
    imgui.SetNextWindowSize({ CONFIG_W, CONFIG_H }, ImGuiCond_FirstUseEver);
    if (imgui.Begin('cdchime config', open, ImGuiWindowFlags_None)) then
        if (imgui.Button('Save')) then M.Save(); end
        imgui.SameLine();
        if (imgui.Button('Reset theme')) then
            settings.reset('cdtheme');
            M.cfg = settings.load(defaults, 'cdtheme');
            M.cfg.show_config = true;
        end
        imgui.SameLine();
        if (M.layout_get ~= nil) and (M.layout_set ~= nil) then
            local lv = { M.layout_get() };
            if (imgui.Checkbox('Move windows', lv)) then M.layout_set(lv[1]); end
            imgui.SameLine();
        end
        imgui.TextColored(M.Col('dim'), 'Tick "Move windows" to drag popups into place, then Save.');
        imgui.Separator();

        if (imgui.BeginTabBar('##cdchime_tabs', ImGuiTabBarFlags_None)) then
            Tab('Theme',        TabTheme);
            Tab('Windows',      TabWindows);
            Tab('Combine',      TabCombine);
            Tab('Cooldowns',    TabCooldowns);
            Tab('Custom',       TabCustom);
            Tab('Pets',         TabPets);
            Tab('Placeholders', TabPlaceholders);
            Tab('Voice',        TabVoice);
            imgui.EndTabBar();
        end
    end
    imgui.End();
    if (not open[1]) then
        M.cfg.show_config = false;
        M.Save();
    end
end

function M.ToggleConfig()
    M.cfg.show_config = not M.cfg.show_config;
    return M.cfg.show_config;
end

settings.register('cdtheme', 'cdtheme_settings_update', function (s)
    if (s ~= nil) then M.cfg = s; end
end);

_G.cdchimeTheme = M;
return M;
