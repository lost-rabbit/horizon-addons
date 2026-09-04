--[[
* nmwindow.lua - notorious monster repop WINDOW timer, a MODULE of cdchime.
*
* Distinct from phtimer.lua, which counts a PLACEHOLDER's respawn (seconds to
* your next lottery roll). This counts the NM's own post-kill cooldown: the
* dead time after it dies during which no amount of placeholder killing can
* pop it. Mee Deggi the Punisher is 50 minutes on Horizon; Quu Domi has no
* published figure and is assumed the same until measured; Leaping Lizzy
* has none at all (true lottery, repops ~5 min after death).
*
* Killing placeholders while the window is shut is wasted effort, so knowing
* the reopen time is the whole point.
*
* WHY os.time() AND NOT os.clock():
*   phtimer uses os.clock(), which counts seconds since the CLIENT started.
*   That is fine for a 16-second placeholder but wrong here - a 50 minute
*   window has to survive /addon reload, a zone, or a crash. os.time() is
*   wall-clock epoch seconds, so a saved timer stays correct across all three.
*
* DETECTION - three ways a kill is noticed, because one line is not enough:
*   1. "<killer> defeats <NM>."          you (or your pet) landed the kill
*   2. "You find <item> on <NM>."        party killed it, loot hit your pool,
*                                        and you were out of range to see the
*                                        defeat line at all - this happened
*                                        2026-08-25 12:52 and would otherwise
*                                        have been missed entirely
*   3. /nm at <HH:MM> <name>             somebody announced it in chat and you
*                                        never saw either line
*
* Rules note: chat-log reading and a countdown you configured, same footing as
* phtimer and the approved Timers addons. No entity-table scanning.
*
* Commands:
*   /nm                        list tracked NMs and live windows
*   /nm add <mins> <name>      register an NM with its cooldown
*   /nm kill <name>            stamp a kill right now
*   /nm at <HH:MM> <name>      stamp a kill at a past clock time today
*   /nm remove <name>
*   /nm clear
*
* Click any row in the window to acknowledge it - it hides until the next
* kill. That does not untrack the NM; use /nm remove for that.
*   /nm auto [on|off]      toggle auto-registering every NM kill
--]]

require('common');
local imgui    = require('imgui');
local chat     = require('chat');
local settings = require('settings');
local nmdata   = require('nmdata');   -- zone-aware researched cooldowns

local M = {};

-- cooldown is in SECONDS; killedAt is an os.time() epoch stamp, 0 if never
-- seen. Values below are from the Horizon wiki, not guesses - see each note.
-- Fallback cooldown for an NM we have not researched. 50 min is Mee Deggi's
-- confirmed Horizon figure and a fair lottery-NM default, but it IS a guess
-- per mob. Override with /nm add <minutes> <name>.
--[[
* Seconds from death to corpse despawn. phOnDespawn - the LSB hook that starts
* the NM cooldown - fires on DESPAWN, while the chat line we key off fires on
* DEATH. Without this the window is reported 16 seconds early.
--]]
local DEATH_DELAY = 16;

local AUTO_COOLDOWN = 3000;

local defaults = T{
    -- Master switch for NM hunting. Off = no NM window, no placeholder
    -- timers, no announcements, and nothing gets registered while you are
    -- doing something else. The saved list is kept, just dormant.
    hunt = true,
    -- Auto-register any NM you kill. Off = only the saved list is tracked.
    auto = true,
    nms = T{
        ['mee deggi the punisher'] = T{ name = 'Mee Deggi the Punisher', cooldown = 3000, killedAt = 0 },
        -- 3600 not 3000: LSB phOnDespawn(QUU_DOMI, 5, 3600) = a full hour.
        ['quu domi the gallant']   = T{ name = 'Quu Domi the Gallant',   cooldown = 3600, killedAt = 0 },
        -- South Gustaberg (F-8), Lv10-11. Wiki: "a true lottery spawn and has
        -- no cooldown after being killed" - it can repop five minutes after
        -- death. So 300s, NOT the Oztroja 50 min. Its two Rock Lizard
        -- placeholders respawn every 5m30s at a ~9.4% pop chance, which makes
        -- phtimer the more useful of the two windows for this one.
        ['leaping lizzy']          = T{ name = 'Leaping Lizzy',          cooldown = 300,  killedAt = 0 },
    },
};

local cfg = settings.load(defaults, 'nmwindow');

local function Save() settings.save('nmwindow'); end

--[[
* Published as a global so phtimer can read it without a require - the two are
* sibling modules with no import between them, and cdchime's d3d_present is at
* the 60-upvalue ceiling where new file-scope locals break the addon.
--]]
_G.cdchimeHunting = (cfg.hunt ~= false);

local function SetHunt(on)
    cfg.hunt = on;
    _G.cdchimeHunting = on;
    Save();
end

local function Speak(text)
    if (_G.cdchimeSpeak ~= nil) then _G.cdchimeSpeak(text); end
end

local function Hms(secs)
    secs = math.floor(secs);
    if (secs >= 3600) then
        return ('%d:%02d:%02d'):fmt(secs / 3600, (secs % 3600) / 60, secs % 60);
    end
    return ('%d:%02d'):fmt(secs / 60, secs % 60);
end

-- Mob names arrive with or without a leading article depending on which line
-- produced them ("on Mee Deggi" vs "on the Mee Deggi"), so flatten both.
local function Key(name)
    return (name:lower():gsub('^the ', ''));
end

local function Stamp(key, when, how)
    local nm = cfg.nms[key];
    if (nm == nil) then return; end
    -- Both the defeat line and the loot line fire for the same kill a second
    -- apart. Treat anything inside 30s as the same event, not a second kill.
    if (nm.killedAt ~= nil) and (math.abs(when - nm.killedAt) < 30) then return; end
    nm.killedAt = when;
    nm.announced = false;
    nm.acked = false;      -- a fresh kill un-acknowledges the row
    Save();
    local opens = when + nm.cooldown + DEATH_DELAY;
    print(chat.header('nmwindow'):append(chat.message('Killed ')):append(chat.success(nm.name))
        :append(chat.message((' (%s) - window opens %s, in %s'):fmt(
            how, os.date('%H:%M:%S', opens), Hms(opens - os.time())))));
end

----------------------------------------------------------------------------
-- Chat detection
----------------------------------------------------------------------------
-- "Heaph defeats Mee Deggi the Punisher."   (NMs carry no article)
-- "X-32 defeats Mee Deggi the Punisher."    (pet kills count too)
local RX_DEFEAT = '^%a[%w\'%- ]* defeats (.+)%.';
-- "You find a pair of impact knuckles on Mee Deggi the Punisher."
local RX_LOOT   = '^You find .- on (.+)%.';
--[[
* Raw chat is NOT the clean text you see in the log file. FFXI embeds colour
* and format control bytes, and lines can carry a trailing null. Any pattern
* anchored with ^ or $ silently never matches when those are present - no
* error, just a handler that quietly does nothing. Normalise first.
--]]
local function CleanMsg(msg)
    if (msg == nil) then return ''; end
    msg = msg:gsub('[%z\1-\31\127]', '');
    return (msg:gsub('^%s+', ''):gsub('%s+$', ''));
end


ashita.events.register('text_in', 'nmwindow_text_cb', function (e)
    if (_G.cdchimeHunting == false) then return; end
    local msg = CleanMsg(e.message);
    local victim = msg:match(RX_DEFEAT);
    local how = 'defeat line';
    if (victim == nil) then
        victim = msg:match(RX_LOOT);
        how = 'party loot';
    end
    if (victim == nil) then return; end
    local key = Key(victim);
    if (cfg.nms[key] == nil) then
        -- Unknown NM. The loot line ("You find X on Y.") fires for regular
        -- mobs too, so only the DEFEAT line may auto-register - otherwise
        -- every crab that drops a shell would create an NM window.
        if (cfg.auto == false) or (how ~= 'defeat line') then return; end
        -- The ARTICLE is what separates an NM from a regular mob: FFXI writes
        -- "defeats the Cutter." but "defeats Leaping Lizzy.". Key() strips a
        -- leading "the " so the loot line resolves to the same entry as the
        -- defeat line - but auto-register must look at the RAW victim, or
        -- every placeholder gets claimed here as a new NM. That is exactly
        -- what happened: "defeats the Yagudo Oracle." was registered with the
        -- 3000s fallback, putting a 50-minute NM window on a 16-minute
        -- placeholder. Anything with an article belongs to phtimer.
        if (victim:lower():match('^the ')) then return; end
        -- And it has to be a REAL NM. The article check alone still lets
        -- through pet names, mis-parsed lines, and any named non-NM; the
        -- wiki roster is the actual identity check.
        if (not nmdata.IsNM(victim)) then return; end
        -- Researched cooldown for this zone if we have one, else the guess.
        local known = nmdata.CD(victim);
        cfg.nms[key] = T{ name = victim, cooldown = known or AUTO_COOLDOWN,
                          killedAt = 0 };
    end
    Stamp(key, os.time(), how);
end);

----------------------------------------------------------------------------
-- Commands
----------------------------------------------------------------------------
ashita.events.register('command', 'nmwindow_cmd_cb', function (e)
    local args = e.command:args();
    if (#args == 0) or (args[1] ~= '/nm') then return; end
    e.blocked = true;
    local sub = args[2] and args[2]:lower() or 'list';

    if (sub == 'add') and (#args >= 4) then
        local mins = tonumber(args[3]);
        local name = args:concat(' ', 4);
        if (mins == nil) or (mins <= 0) then
            print(chat.header('nmwindow'):append(chat.error('Usage: /nm add <minutes> <name>')));
            return;
        end
        cfg.nms[Key(name)] = T{ name = name, cooldown = math.floor(mins * 60), killedAt = 0 };
        Save();
        print(chat.header('nmwindow'):append(chat.message('Tracking ')):append(chat.success(name))
            :append(chat.message((' - %d min cooldown.'):fmt(mins))));
        return;
    end

    if (sub == 'kill') and (#args >= 3) then
        local name = args:concat(' ', 3);
        local key = Key(name);
        if (cfg.nms[key] == nil) then
            print(chat.header('nmwindow'):append(chat.error('Not tracked: ' .. name)));
            return;
        end
        Stamp(key, os.time(), 'manual');
        return;
    end

    -- /nm at 15:04 Mee Deggi the Punisher  - for kills you only heard about.
    if (sub == 'at') and (#args >= 4) then
        local hh, mm = args[3]:match('^(%d+):(%d+)$');
        local name = args:concat(' ', 4);
        local key = Key(name);
        if (hh == nil) then
            print(chat.header('nmwindow'):append(chat.error('Usage: /nm at <HH:MM> <name>')));
            return;
        end
        if (cfg.nms[key] == nil) then
            print(chat.header('nmwindow'):append(chat.error('Not tracked: ' .. name)));
            return;
        end
        local n = os.date('*t');
        n.hour, n.min, n.sec = tonumber(hh), tonumber(mm), 0;
        local when = os.time(n);
        -- A time later than now must mean yesterday, not the future.
        if (when > os.time()) then when = when - 86400; end
        cfg.nms[key].killedAt = 0;      -- bypass the 30s dedupe for a manual set
        Stamp(key, when, 'reported ' .. args[3]);
        return;
    end

    if (sub == 'remove') and (#args >= 3) then
        local name = args:concat(' ', 3);
        cfg.nms[Key(name)] = nil;
        Save();
        print(chat.header('nmwindow'):append(chat.message('Stopped tracking ')):append(chat.success(name)));
        return;
    end

    -- /nm hunt        toggle
    -- /nm off | /nm on  same switch, said the short way
    if (sub == 'hunt') or (sub == 'off') or (sub == 'on') then
        local on;
        if (sub == 'off') then on = false;
        elseif (sub == 'on') then on = true;
        elseif (args[3] ~= nil) then on = (args[3]:lower() == 'on');
        else on = (cfg.hunt == false); end
        SetHunt(on);
        print(chat.header('nmwindow'):append(chat.message('NM hunting '))
            :append(on and chat.success('ON') or chat.error('OFF'))
            :append(chat.message(on and ' - windows and timers live.'
                                     or ' - NM window and placeholder timers hidden.')));
        return;
    end

    if (sub == 'auto') then
        if (args[3] ~= nil) then
            cfg.auto = (args[3]:lower() == 'on');
        else
            cfg.auto = (cfg.auto == false);
        end
        Save();
        print(chat.header('nmwindow'):append(chat.message('Auto-register '))
            :append(chat.success(cfg.auto and 'ON' or 'OFF'))
            :append(chat.message(cfg.auto and ' - any NM you kill gets a window.'
                                          or ' - only the saved list.')));
        return;
    end
    if (sub == 'clear') then
        cfg.nms = T{};
        Save();
        print(chat.header('nmwindow'):append(chat.message('Cleared all NMs.')));
        return;
    end

    print(chat.header('nmwindow'):append(chat.message('NM windows:')));
    local any = false;
    for _, nm in pairs(cfg.nms) do
        any = true;
        local status;
        if ((nm.killedAt or 0) == 0) then
            status = 'no kill recorded';
        else
            local left = (nm.killedAt + nm.cooldown + DEATH_DELAY) - os.time();
            status = (left <= 0) and ('OPEN - %s ago'):fmt(Hms(-left))
                                 or ('opens %s, in %s'):fmt(
                                     os.date('%H:%M:%S', nm.killedAt + nm.cooldown + DEATH_DELAY), Hms(left));
        end
        print(chat.header('nmwindow'):append(chat.message(('  %s  (%d min)  -> %s'):fmt(
            nm.name, math.floor(nm.cooldown / 60), status))));
    end
    if (not any) then
        print(chat.header('nmwindow'):append(chat.message('  none. /nm add <minutes> <name>')));
    end
end);

----------------------------------------------------------------------------
-- UI bridge, same shape as cdchimePhShare so the config window can drive it
----------------------------------------------------------------------------
_G.cdchimeNmShare = {
    List = function ()
        local out = {};
        for key, nm in pairs(cfg.nms) do
            table.insert(out, { key = key, name = nm.name, cooldown = nm.cooldown,
                                killedAt = nm.killedAt or 0 });
        end
        table.sort(out, function (a, b) return a.name < b.name; end);
        return out;
    end,
    Add = function (name, mins)
        if (name == nil) or (name == '') then return false; end
        cfg.nms[Key(name)] = T{ name = name, cooldown = math.floor((mins or 50) * 60), killedAt = 0 };
        Save();
        return true;
    end,
    Kill = function (key) Stamp(key, os.time(), 'manual'); end,
    Remove = function (key) cfg.nms[key] = nil; Save(); end,
    Clear = function () cfg.nms = T{}; Save(); end,
};

----------------------------------------------------------------------------
-- Window
----------------------------------------------------------------------------
ashita.events.register('d3d_present', 'nmwindow_present_cb', function ()
    if (_G.cdchimeHunting == false) then return; end
    local live = {};
    for _, nm in pairs(cfg.nms) do
        if ((nm.killedAt or 0) > 0) and (not nm.acked) then
            table.insert(live, nm);
        end
    end
    if (#live == 0) then return; end
    table.sort(live, function (a, b)
        return (a.killedAt + a.cooldown) < (b.killedAt + b.cooldown);
    end);

    local th = _G.cdchimeTheme;
    if (th ~= nil) and (not th.Enabled('cdchime_nmwindow')) then return; end
    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing);
    if (th ~= nil) then
        th.Push('cdchime_nmwindow');
    else
        imgui.PushStyleVar(ImGuiStyleVar_WindowRounding, 8.0);
        imgui.PushStyleVar(ImGuiStyleVar_WindowBorderSize, 2.0);
        imgui.PushStyleVar(ImGuiStyleVar_WindowPadding, { 14.0, 10.0 });
        imgui.PushStyleColor(ImGuiCol_WindowBg, { 0.06, 0.10, 0.13, 0.90 });
        imgui.PushStyleColor(ImGuiCol_Border, { 0.55, 0.85, 1.0, 0.9 });
    end
    if (imgui.Begin('cdchime_nmwindow', true, flags)) then
        local scale = (th ~= nil) and th.Scale('cdchime_nmwindow') or 1.0;
        if (th ~= nil) and (scale ~= 1.0) then th.PushScale(scale); end
        local head = (th ~= nil) and th.TextCol('cdchime_nmwindow', 0.9) or { 0.55, 0.85, 1.0, 0.9 };
        imgui.TextColored(head, 'NM Windows');
        local now = os.time();
        for _, nm in ipairs(live) do
            local left = (nm.killedAt + nm.cooldown + DEATH_DELAY) - now;
            local label, col;
            if (left <= 0) then
                label = ('%s  OPEN'):fmt(nm.name);
                col = (th ~= nil) and th.Col('crit') or { 1.0, 0.45, 0.40, 1.0 };
                if (not nm.announced) then
                    Speak(nm.name .. ' window open');
                    nm.announced = true;
                end
            else
                label = ('%s  %s'):fmt(nm.name, Hms(left));
                if (left <= 120) then
                    col = (th ~= nil) and th.Col('warn') or { 1.0, 0.85, 0.40, 1.0 };
                else
                    col = (th ~= nil) and th.Col('text') or { 1.0, 1.0, 1.0, 0.95 };
                end
            end
            -- Only an OPEN row is clickable. While it is still counting
            -- down there is nothing to acknowledge, and a hit target there
            -- would just be something to dismiss the timer by accident.
            if (left <= 0) then
                imgui.PushStyleColor(ImGuiCol_Text, col);
                -- '##' keeps the widget id unique per NM while hiding it from
                -- the visible label, so two rows never collide.
                if (imgui.Selectable(label .. '  [x]##nmack_' .. nm.name, false)) then
                    nm.acked = true;
                    Save();
                end
                imgui.PopStyleColor();
                if (imgui.IsItemHovered()) then
                    imgui.SetTooltip('Click to close - returns on the next kill');
                end
            else
                imgui.TextColored(col, label);
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
