--[[
* phtimer.lua - placeholder respawn timers, a MODULE of cdchime.
*
* Camping a lottery NM means killing a specific placeholder over and over;
* each time one respawns it rolls for the NM. This watches YOUR combat log for
* "<killer> defeats the <placeholder>", starts a countdown, and shows a small
* window with the time until it is back - your next lottery chance. It turns
* red and speaks when it is up.
*
* NO LEARNING. Timers are fixed values, and that is deliberate.
*   An earlier version measured the gap between consecutive kills of the same
*   NAME and treated it as one respawn cycle. That only holds when a name has
*   ONE spawn point. Castle Oztroja has EIGHT placeholders per NM (LSB phList:
*   4 Yagudo Interrogator + 4 Yagudo Drummer for Mee Deggi, 4 Oracle + 4
*   Herald for Quu Domi), so most of those "gaps" were two different mobs of
*   the same name dying near each other. It collapsed to 30-second timers.
*   Two mitigations later it was still wrong, because the model did not
*   describe the camp. Values now come from, in order:
*     1. nmdata's researched figure for the zone you are standing in
*     2. whatever /ph add set
*     3. AUTO_RESPAWN
*
* ONE TIMER PER KILL, not per name - eight placeholders need eight independent
* countdowns, which a name-keyed table cannot express.
*
* Rules note: this only reads the chat log (your own kills) and counts down a
* timer you configured, same footing as the approved Timers/CTimers addons. It
* does NOT scan the entity table for spawns - that is ApRadar/Widescan
* territory and prohibited.
*
* Commands:
*   /ph                        list registered placeholders and live timers
*   /ph add <seconds> <name>   register a placeholder with a fixed respawn
*   /ph remove <name>          stop tracking one
*   /ph clear                  stop tracking all
*   /ph auto [on|off]          auto-register every mob you kill (default OFF)
*   /ph debug                  log match attempts to config\phtimer_debug.txt
--]]

require('common');
local imgui    = require('imgui');
local chat     = require('chat');
local settings = require('settings');
local nmdata   = require('nmdata');   -- zone-aware researched intervals

local M = {};

--[[
* Seconds between a mob DYING and its corpse DESPAWNING. The respawn clock
* starts at despawn, but the chat line we key off ("X defeats the Y.") fires
* at death - so every timer has to be pushed out by this much or it comes up
* early. Confirmed by the LSB hook name itself: entity.onMobDespawn, not
* onMobDeath. Measured at 16s on Horizon.
--]]
local DEATH_DELAY = 16;

-- Fallback for a mob with no researched figure and no /ph add.
local AUTO_RESPAWN = 960;

--[[
* Registrations persist; live countdowns do not. This module runs on
* os.clock(), which resets each launch, and a 16-minute timer is stale by the
* time you are back. Only name + interval is saved.
*
* Seeded with the four Castle Oztroja placeholders at 960s. DEATH_DELAY adds
* the 16s corpse-despawn gap at runtime, so the real interval from the moment
* you see the kill message is 16:16.
*
* That model beats the earlier 990s fudge. Measured kill-to-kill gaps peaked
* at 17:00-17:15 with a 16:49 median across 629 kills, and 976 + ~45s of
* notice-and-kill reaction lands exactly there. The wiki's flat "approximately
* 16 minutes" omits the despawn gap.
--]]
local defaults = T{
    -- Auto-register every mob you kill. OFF by default: at a camp you only
    -- care about the placeholders, and timing every crab buries them.
    auto = false,
    list = T{
        T{ name = 'Yagudo Interrogator', respawn = 960 },
        T{ name = 'Yagudo Drummer',      respawn = 960 },
        T{ name = 'Yagudo Herald',       respawn = 960 },
        T{ name = 'Yagudo Oracle',       respawn = 960 },
    },
};
local cfg = settings.load(defaults, 'phtimer');

-- [lowercase name] = { name = display, respawn = secs, auto = bool }
local phs = {};

-- One entry PER KILL: { name, dueAt, announced }. Separate from phs, which is
-- one record per NAME. Two placeholders of the same name each need their own
-- countdown, which a name-keyed table cannot express.
local timers = {};
local MAX_TIMERS = 12;   -- backstop so a long grind cannot grow this forever

-- Which row the mouse was over LAST frame. ImGui cannot tell you a
-- widget is hovered until after it has been submitted, so the x is
-- shown based on the previous frame's answer.
local hoverRow = nil;

local function SaveList()
    cfg.list = T{};
    for _, ph in pairs(phs) do
        -- auto entries stay out of the file, or every crab you ever killed
        -- accumulates on disk.
        if (not ph.auto) then
            cfg.list:append(T{ name = ph.name, respawn = ph.respawn });
        end
    end
    settings.save('phtimer');
end

for _, e in ipairs(cfg.list) do
    phs[e.name:lower()] = { name = e.name, respawn = e.respawn };
end

local function Speak(text)
    if (_G.cdchimeSpeak ~= nil) then _G.cdchimeSpeak(text); end
end

local function Mmss(secs)
    secs = math.floor(secs);
    return ('%d:%02d'):fmt(secs / 60, secs % 60);
end

----------------------------------------------------------------------------
-- Chat detection
----------------------------------------------------------------------------
-- "Heaph defeats the Yagudo Drummer."  /  "X-32 defeats the Yagudo Herald."
-- Requires the article: that is what separates a regular mob from an NM, and
-- keeps this module out of nmwindow's way. No trailing $ - a stray byte at
-- end of line must not break the match.
local RX_DEFEAT = '^%a[%w'.."'"..'%- ]* defeats the (.+)%.';

--[[
* Raw chat is NOT the clean text the log file shows. FFXI embeds colour and
* format control bytes, and lines can carry a trailing null. A pattern
* anchored with ^ silently never matches when those are present - no error,
* just a handler that quietly does nothing.
--]]
local function CleanMsg(msg)
    if (msg == nil) then return ''; end
    msg = msg:gsub('[%z\1-\31\127]', '');
    return (msg:gsub('^%s+', ''):gsub('%s+$', ''));
end

ashita.events.register('text_in', 'phtimer_text_cb', function (e)
    -- Master switch, owned by nmwindow. Nothing is recorded while hunting is
    -- off, so you do not come back to a screen full of stale countdowns.
    if (_G.cdchimeHunting == false) then return; end
    local msg = CleanMsg(e.message);
    local victim = msg:match(RX_DEFEAT);

    --[[
    * Writes to a FILE, never chat. Printing from inside a text_in handler on
    * a pattern your own output can match is an unbounded feedback loop - the
    * first version of this printed a line containing 'defeats', re-entered
    * this handler, and crashed the client.
    --]]
    if (_G.phtimer_debug) and (msg:find('defeats')) then
        local ok, fh = pcall(io.open,
            AshitaCore:GetInstallPath() .. 'config\\phtimer_debug.txt', 'a');
        if (ok) and (fh ~= nil) then
            fh:write(('MATCH=%s  RAW=[%s]\n'):fmt(tostring(victim), msg));
            fh:close();
        end
    end

    if (victim == nil) then return; end
    local key = victim:lower();
    local ph = phs[key];
    if (ph == nil) then
        if (cfg.auto == false) then return; end
        ph = { name = victim, respawn = nmdata.PH(victim) or AUTO_RESPAWN,
               auto = true };
        phs[key] = ph;
    end
    if (ph.respawn == nil) or (ph.respawn <= 0) then return; end

    table.insert(timers, { name = ph.name,
                           dueAt = os.clock() + ph.respawn + DEATH_DELAY,
                           announced = false });
    while (#timers > MAX_TIMERS) do table.remove(timers, 1); end

    print(chat.header('phtimer'):append(chat.message('Killed ')):append(
        chat.success(ph.name)):append(chat.message(
        (' - next in %s  (%s + %ds despawn)'):fmt(
            Mmss(ph.respawn + DEATH_DELAY), Mmss(ph.respawn), DEATH_DELAY))));
end);

----------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------
ashita.events.register('command', 'phtimer_cmd_cb', function (e)
    local args = e.command:args();
    if (#args == 0) or (args[1] ~= '/ph') then return; end
    e.blocked = true;
    local sub = args[2] and args[2]:lower() or 'list';

    if (sub == 'add') and (#args >= 4) then
        local secs = tonumber(args[3]);
        local name = args:concat(' ', 4);
        if (secs == nil) or (secs <= 0) then
            print(chat.header('phtimer'):append(chat.error('Usage: /ph add <seconds> <name>')));
            return;
        end
        phs[name:lower()] = { name = name, respawn = secs };
        SaveList();
        print(chat.header('phtimer'):append(chat.message('Tracking ')):append(
            chat.success(name)):append(chat.message(
            (' - respawn %s.'):fmt(Mmss(secs)))));
        return;
    end

    if (sub == 'remove') and (#args >= 3) then
        local name = args:concat(' ', 3);
        phs[name:lower()] = nil;
        SaveList();
        print(chat.header('phtimer'):append(chat.message('Stopped tracking ')):append(chat.success(name)));
        return;
    end

    if (sub == 'clear') then
        phs = {};
        timers = {};
        SaveList();
        print(chat.header('phtimer'):append(chat.message('Cleared all placeholders.')));
        return;
    end

    if (sub == 'auto') then
        if (args[3] ~= nil) then
            cfg.auto = (args[3]:lower() == 'on');
        else
            cfg.auto = (cfg.auto == false);
        end
        settings.save('phtimer');
        if (cfg.auto == false) then
            for k, ph in pairs(phs) do
                if (ph.auto) then phs[k] = nil; end
            end
        end
        print(chat.header('phtimer'):append(chat.message('Auto-register '))
            :append(chat.success(cfg.auto and 'ON' or 'OFF')));
        return;
    end

    if (sub == 'debug') then
        _G.phtimer_debug = not _G.phtimer_debug;
        print(chat.header('phtimer'):append(chat.message('Debug log '))
            :append(chat.success(_G.phtimer_debug and 'ON' or 'OFF'))
            :append(chat.message(' -> config\\phtimer_debug.txt')));
        return;
    end

    print(chat.header('phtimer'):append(chat.message('Placeholders:')));
    local any = false;
    for _, ph in pairs(phs) do
        any = true;
        print(chat.header('phtimer'):append(chat.message(('  %s  respawn %s%s'):fmt(
            ph.name, Mmss(ph.respawn or 0), ph.auto and '  (auto)' or ''))));
    end
    if (not any) then
        print(chat.header('phtimer'):append(chat.message('  none. /ph add <seconds> <name>')));
    end
    print(chat.header('phtimer'):append(chat.message(('  %d live timer(s), auto-register %s'):fmt(
        #timers, cfg.auto and 'ON' or 'OFF'))));
end);

----------------------------------------------------------------------------
-- UI bridge for the cdchime config window
----------------------------------------------------------------------------
_G.cdchimePhShare = {
    List = function ()
        local out = {};
        for key, ph in pairs(phs) do
            table.insert(out, { key = key, name = ph.name,
                                respawn = ph.respawn, auto = ph.auto == true });
        end
        table.sort(out, function (a, b) return a.name < b.name; end);
        return out;
    end,
    Add = function (name, secs)
        if (name == nil) or (name == '') then return false; end
        phs[name:lower()] = { name = name, respawn = secs };
        SaveList();
        return true;
    end,
    Remove = function (key) phs[key] = nil; SaveList(); end,
    Clear = function () phs = {}; timers = {}; SaveList(); end,
};

----------------------------------------------------------------------------
-- Window
----------------------------------------------------------------------------
ashita.events.register('d3d_present', 'phtimer_present_cb', function ()
    if (_G.cdchimeHunting == false) then return; end
    local now = os.clock();
    -- Expire finished timers: announce once, then drop the row after a short
    -- linger so a pop that just came up is still readable.
    for i = #timers, 1, -1 do
        local t = timers[i];
        if ((t.dueAt - now) <= 0) then
            if (not t.announced) then
                Speak(t.name .. ' up');
                t.announced = true;
            end
            if ((now - t.dueAt) > 20) then table.remove(timers, i); end
        end
    end
    if (#timers == 0) then return; end
    table.sort(timers, function (a, b) return a.dueAt < b.dueAt; end);

    local th = _G.cdchimeTheme;
    if (th ~= nil) and (not th.Enabled('cdchime_phtimer')) then return; end
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing);
    if (th ~= nil) then
        th.Push('cdchime_phtimer');
    else
        imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 8.0);
        imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 2.0);
        imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 14.0, 10.0 });
        imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.06, 0.10, 0.13, 0.90 });
        imgui.PushStyleColor(ImGuiCol_Border, { 0.55, 0.85, 1.0, 0.9 });
    end
    if (imgui.Begin('cdchime_phtimer', true, flags)) then
        local scale = (th ~= nil) and th.Scale('cdchime_phtimer') or 1.0;
        if (th ~= nil) and (scale ~= 1.0) then th.PushScale(scale); end
        local head = (th ~= nil) and th.TextCol('cdchime_phtimer', 0.9) or { 0.55, 0.85, 1.0, 0.9 };
        imgui.TextColored(head, 'Placeholders');
        --[[
        * Forwards, so the soonest timer stays at the top - the list is sorted
        * by dueAt just above. Iterating backwards to make deletion safe would
        * have flipped the whole window upside down, and it is not needed:
        * `kill` is applied AFTER the loop, so no index shifts mid-iteration.
        --]]
        local kill = nil;
        local nextHover = nil;
        for i = 1, #timers do
            local t = timers[i];
            local left = t.dueAt - now;
            local label, col;
            if (left <= 0) then
                label = ('%s  UP'):fmt(t.name);
                col = (th ~= nil) and th.Col('crit') or { 1.0, 0.45, 0.40, 1.0 };
            else
                label = ('%s  %s'):fmt(t.name, Mmss(left));
                if (left <= 15) then
                    col = (th ~= nil) and th.Col('warn') or { 1.0, 0.85, 0.40, 1.0 };
                else
                    col = (th ~= nil) and th.Col('text') or { 1.0, 1.0, 1.0, 0.95 };
                end
            end

            -- Always drawn so the row never reflows; just invisible until the
            -- mouse is on it. '##ph<i>' is an ImGui id, hidden from the label -
            -- without it every button shares one id and one click fires all.
            local show = (i == hoverRow) and 1.0 or 0.0;
            imgui.PushStyleColor(ImGuiCol_Button,        { 0.0, 0.0, 0.0, 0.0 });
            imgui.PushStyleColor(ImGuiCol_ButtonHovered, { 0.85, 0.30, 0.30, 0.70 * show });
            imgui.PushStyleColor(ImGuiCol_ButtonActive,  { 1.00, 0.35, 0.35, 0.90 * show });
            imgui.PushStyleColor(ImGuiCol_Text,          { 0.90, 0.50, 0.50, show });
            if (imgui.SmallButton(('x##ph%d'):fmt(i))) then
                kill = i;
            end
            if (imgui.IsItemHovered()) then nextHover = i; end
            imgui.PopStyleColor(4);

            imgui.SameLine();
            imgui.TextColored(col, label);
            if (imgui.IsItemHovered()) then nextHover = i; end
        end
        hoverRow = nextHover;

        -- Removed after the loop: deleting mid-frame while ImGui still has
        -- widgets queued against that row is asking for trouble.
        if (kill ~= nil) then
            local gone = timers[kill];
            table.remove(timers, kill);
            hoverRow = nil;
            if (gone ~= nil) then
                print(chat.header('phtimer'):append(chat.message(
                    ('dismissed %s'):fmt(gone.name))));
            end
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

return M;
