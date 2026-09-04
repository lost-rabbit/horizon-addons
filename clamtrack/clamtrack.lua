--[[
* clamtrack - Bibiki Bay clamming tracker with a real break probability.
*
* Overfill the bucket and you lose everything in it, so the number that
* matters is the chance the NEXT dig breaks the bucket. A fixed "warn at
* N ponzes free" threshold cannot express that, because the risk depends on
* which items are heavier than the headroom you have left.
*
* HOW THE ODDS ARE COMPUTED
*   P(break) = the summed drop weighting of every item heavier than your
*   remaining headroom, from Horizon's published clamming abundance list
*   (one list, it does not vary by bucket size). An exactly-full bucket is
*   safe; the break happens only when weight + item > capacity, which the
*   dig log confirmed (a 50/50 bucket survived a further dig).
*
* Also shown: expected weight per dig, roughly how many digs are left, the
* per-node dig cooldown, and the vendor / auction value sitting in the
* bucket versus banked versus lost.
*
* Everything comes from reading the chat log and the event packet Toh
* Zonikki sends when you talk to him. The addon never sends commands,
* packets or key presses; it is display and logging only.
*
* Files written (all under <Game>\config\):
*   clamtrack_digs.csv   one row per dig, when logging is on (default ON)
*
* Usage: /clam              status in chat
*        /clam help         command list
*        /clam reset        empty the bucket (after each turn-in)
*        /clam cap N        set capacity (50 / 100 / 150 / 200)
*        /clam set N        correct the current weight by hand
*        /clam hide         toggle the on-screen readout
*        /clam log [on|off] toggle the CSV dig log (default ON)
*        /clam bar N        cooldown bar height (default 24)
*        /clam cd N         dig cooldown seconds (measured: 10)
*        /clam font N       window font scale (default 1.6)
*
* Creation assisted by ADA.
--]]

addon.name    = 'clamtrack';
addon.author  = 'Heaph';
addon.version = '2.1';
addon.desc    = 'Bibiki Bay clamming tracker with real break probability.';

require('common');
local imgui    = require('imgui');
local chat     = require('chat');
local settings = require('settings');

--[[
* Vana'diel clock, for the dig log. Loaded defensively: no shipped addon
* currently requires ffxi.time, so the path is unproven here. If it fails the
* tracker still logs, just without game-time columns - it must never take the
* whole addon down.
--]]
local okTime, timelib = pcall(require, 'ffxi.time');
if (not okTime) then timelib = nil; end

-- Ponze weights, from the server data table. 30 items.
local WEIGHTS = {

    -- Not on Horizon's abundance list and never seen in 1900 logged digs,
    -- but it exists in the LandSandBoat data at 35pz. Kept so that if it
    -- ever does turn up it is not silently counted at the 6pz default.
    ['igneous rock'] = 35,
    ['tropical clam'] = 20,
    ['jacknife'] = 11,
    ['pebble'] = 7,
    ['white sand'] = 7,
    ['bibiki urchin'] = 6,
    ['goblin mask'] = 6,
    ['hobgoblin pie'] = 6,
    ['broken willow fishing rod'] = 6,
    ['clump of pamtam kelp'] = 6,
    ['coral fragment'] = 6,
    ['crab shell'] = 6,
    ['elm log'] = 6,
    ['handful of high-quality pugil scales'] = 6,
    ['high-quality crab shell'] = 6,
    ['lacquer tree log'] = 6,
    ['loaf of hobgoblin bread'] = 6,
    ['maple log'] = 6,
    ['nebimonite'] = 6,
    ['petrified log'] = 6,
    ['piece of oxblood'] = 6,
    ['seashell'] = 6,
    ['shall shell'] = 6,
    ['suit of goblin armor'] = 6,
    ['suit of goblin mail'] = 6,
    ['titanictus shell'] = 6,
    ['turtle shell'] = 6,
    ['uragnite shell'] = 6,
    ['vongola clam'] = 6,
    ['bibiki slug'] = 3,
    ['handful of fish scales'] = 3,
    ['handful of pugil scales'] = 3,
};
local DEFAULT_WEIGHT = 6;

--[[
* Horizon's loot table. ONE table, not four: unlike LandSandBoat, Horizon
* publishes a single abundance list that does not vary by bucket size.
* { name, ponzes, abundance-out-of-1000 }
--]]
local LOOT = {

    { 'pebble', 7, 223 },
    { 'jacknife', 11, 116 },
    { 'bibiki slug', 3, 111 },
    { 'clump of pamtam kelp', 6, 62 },
    { 'shall shell', 6, 56 },
    { 'vongola clam', 6, 49 },
    { 'handful of fish scales', 3, 37 },
    { 'handful of pugil scales', 3, 35 },
    { 'hobgoblin pie', 6, 27 },
    { 'crab shell', 6, 23 },
    { 'nebimonite', 6, 23 },
    { 'loaf of hobgoblin bread', 6, 23 },
    { 'goblin mask', 6, 22 },
    { 'suit of goblin mail', 6, 21 },
    { 'white sand', 7, 20 },
    { 'suit of goblin armor', 6, 19 },
    { 'tropical clam', 20, 19 },
    { 'seashell', 6, 18 },
    { 'broken willow fishing rod', 6, 18 },
    { 'titanictus shell', 6, 14 },
    { 'maple log', 6, 13 },
    { 'handful of high-quality pugil scales', 6, 11 },
    { 'bibiki urchin', 6, 10 },
    { 'turtle shell', 6, 9 },
    { 'coral fragment', 6, 7 },
    { 'uragnite shell', 6, 3 },
    { 'high-quality crab shell', 6, 3 },
    { 'piece of oxblood', 6, 3 },
    { 'lacquer tree log', 6, 2 },
    { 'elm log', 6, 2 },
    { 'petrified log', 6, 2 },
};

--[[
* Gil per item: { NPC vendor, REALISABLE price }.
*
* The second number is not the best listing on the AH. A listing is an
* asking price, and for the common clamming drops it is fiction: Jacknife
* is listed at 500 with 17 in stock and sells about once every two days,
* while clamming produces roughly ten an hour. Valuing those at the asking
* price invented gil that never arrives.
*
* So this is what you will actually realise: the MEDIAN stack sale price
* divided by twelve for the handful of items whose stacks are both worth
* holding and demonstrably clearing, and the vendor price for everything
* else. Median, not the top listing - reading the listing is what made
* jacknife look like 500 a piece and turtle shell look like a 5,000 gil
* stack gain when the median sale makes it a wash.
*
* A vendor price of 0 means the NPC will not buy it at all.
--]]
local PRICES = {

    ['bibiki slug'] = { 10, 10 },   -- stack market dead
    ['bibiki urchin'] = { 750, 750 },
    ['broken willow fishing rod'] = { 0, 2 },   -- cannot vendor
    ['clump of pamtam kelp'] = { 8, 58 },   -- stack 700, 10 sold today
    ['coral fragment'] = { 1750, 2092 },   -- HOLD - stack 25.1k median, 10 sold today
    ['crab shell'] = { 383, 383 },
    ['elm log'] = { 384, 3092 },   -- HOLD - stack 37.1k median, 10 sold today
    ['goblin mask'] = { 0, 333 },   -- HOLD - stack 4k, 10 sold today
    ['handful of fish scales'] = { 24, 83 },   -- stack 1k
    ['handful of high-quality pugil scales'] = { 260, 260 },
    ['handful of pugil scales'] = { 24, 24 },   -- stack +112, below a slot
    ['high-quality crab shell'] = { 3312, 5000 },   -- HOLD - stack 60k
    ['hobgoblin pie'] = { 153, 153 },   -- no stack market
    ['jacknife'] = { 53, 53 },   -- stack is 42 ea - worse than vendor
    ['lacquer tree log'] = { 3578, 5417 },   -- HOLD - stack 65k median, 10 sold in 2 days
    ['loaf of hobgoblin bread'] = { 90, 90 },   -- singles dead a month
    ['maple log'] = { 15, 15 },
    ['nebimonite'] = { 52, 200 },   -- stack 2.4k median
    ['pebble'] = { 1, 1 },
    ['petrified log'] = { 2193, 3000 },   -- HOLD - stack 36k median, 10 sold today
    ['piece of oxblood'] = { 13250, 13250 },   -- stack +16k but 19h to fill, 10%% on held gil
    ['sack of white sand'] = { 258, 258 },
    ['seashell'] = { 30, 30 },   -- stack +440, below a slot
    ['shall shell'] = { 300, 483 },   -- stack 5.8k median, sells daily
    ['suit of goblin armor'] = { 0, 33 },   -- cannot vendor
    ['suit of goblin mail'] = { 0, 1154 },   -- HOLD - stack 13.85k median, 10 sold today
    ['titanictus shell'] = { 350, 350 },
    ['tropical clam'] = { 5100, 5100 },
    ['turtle shell'] = { 1224, 1224 },   -- stack MEDIAN 15k = 1250 ea, a wash
    ['uragnite shell'] = { 1500, 1500 },   -- stack +1k but 23 days to sell ten
    ['vongola clam'] = { 192, 396 },   -- stack 4.75k median; singles are dead
};

local function PriceOf(name)
    local key = name:lower();
    local p = PRICES[key];
    if (p ~= nil) then return p[1], p[2]; end
    -- The chat name can carry a prefix the table does not ("sack of white
    -- sand" vs "white sand"). Fall back the same way WeightOf does rather
    -- than silently valuing the item at nothing.
    for k, v in pairs(PRICES) do
        if (key:find(k, 1, true) ~= nil) then return v[1], v[2]; end
    end
    return 0, 0;
end

--[[
* Persisted preferences. Bucket capacity is the important one: it is a
* server-side character variable with no item to inspect, so once you have
* told the addon (or it has inferred) which tier you are on, that has to
* survive a reload - otherwise every /addon reload silently drops you back to
* the 50pz loot table and every break percentage after it is wrong.
*
* Weight itself is deliberately NOT persisted. A reload mid-bucket is rare,
* and a stale weight is worse than an obviously-zero one: it would read as
* authoritative while being wrong, which is exactly the failure this addon
* exists to prevent. /clam set N corrects it by hand.
--]]
local cfg = settings.load(T{
    capacity  = 50,
    fontScale = 1.6,
    barHeight = 24,
    visible   = true,
    logging   = true,
});

local weight   = 0;
local capacity = cfg.capacity or 50;
local found    = T{};
local visible  = (cfg.visible ~= false);
local fontScale = cfg.fontScale or 1.6;   -- /clam font N
-- The cooldown bar sizes itself, NOT off fontScale, so changing the text size
-- does not drag the bar around with it.
local barHeight = cfg.barHeight or 24;    -- /clam bar N
local logging  = (cfg.logging ~= false);

local function SaveCfg()
    cfg.capacity  = capacity;
    cfg.fontScale = fontScale;
    cfg.barHeight = barHeight;
    cfg.visible   = visible;
    cfg.logging   = logging;
    settings.save();
end

-- The settings library swaps in a per-character table on login and logout.
-- Without this callback `cfg` would keep pointing at the pre-login table and
-- settings.save() would write a different one, so nothing would persist.
settings.register('settings', 'clamtrack_settings', function (s)
    if (s ~= nil) then
        cfg       = s;
        capacity  = cfg.capacity or 50;
        fontScale = cfg.fontScale or 1.6;
        barHeight = cfg.barHeight or 24;
        visible   = (cfg.visible ~= false);
        logging   = (cfg.logging ~= false);
    end
end);
local lastMsg, lastMsgAt = '', 0;
-- session totals, survive a bucket break
local sDigs, sBreaks, sWeight = 0, 0, 0;

-- Gil, split by whether you actually have it yet. bVen/bAH is sitting in the
-- bucket and evaporates on a break; kVen/kAH is banked; lVen/lAH is what
-- breaks have already cost.
local bVen, bAH = 0, 0;
local kVen, kAH = 0, 0;
local lVen, lAH = 0, 0;

-- Active dig time. A gap longer than DIG_GAP_CAP is treated as time away and
-- not counted, so an hour spent AFK in the bay does not flatten the rate.
local DIG_GAP_CAP = 300;
local lastDigAt, activeSec = 0, 0;

--[[
* Dig cooldown, MEASURED rather than taken from the server source.
*
* LandSandBoat says 16 seconds, or 10 with the clamming legs mod. Neither is
* what this server does. Measured across 429 dig -> refusal -> success runs in
* the chat log:
*
*   refused as late as 10s    -> the cooldown was still running at 10
*   succeeded as early as 10s -> it had expired by 10
*
* Both land on the same second at the log's one-second resolution, so it is
* 10. Midday and evening samples are identical, so the trunks are not what is
* switching it - Horizon's base is simply 10.
*
* Only plain gaps between successes were ever ambiguous, and only because
* walking to a fresh point lets you dig at once; a refusal can only come from
* a node you dug yourself, which is what makes those runs same-node.
*
* Overridable with /clam cd N if gear or a patch ever moves it.
--]]
local digAt, digCd = 0, 10.0;

local function Gil(n)
    if (n >= 1000000) then return ('%.2fm'):fmt(n / 1000000); end
    if (n >= 1000) then return ('%.1fk'):fmt(n / 1000); end
    return ('%d'):fmt(n);
end

local function PerHour(total)
    if (activeSec < 60) then return 0; end
    return total * 3600.0 / activeSec;
end

-- Value handed to Zonikki but not yet confirmed as delivered.
local pVen, pAH = 0, 0;
local pending = false;

-- Every kit costs 500 gil, and a broken bucket forces you to buy another.
local KIT_COST = 500;
local kits, kitSpend = 0, 0;
-- Zonikki's line arrives three times per purchase; collapse the repeats.
local lastKitAt = 0;

-- Net is what you are actually up: delivered, less what the kits cost.
local function NetVen() return kVen + bVen - kitSpend; end
local function NetAH()  return kAH  + bAH  - kitSpend; end

--[[
* "You obtain 4 handfuls of fish scales!" has to become the singular table
* key. Plurals here are irregular enough (handfuls, loaves, jacknives) that a
* trailing-s rule does not cover them.
--]]
local function Singular(s)
    s = s:gsub('handfuls', 'handful'):gsub('clumps', 'clump');
    s = s:gsub('loaves', 'loaf'):gsub('suits', 'suit');
    s = s:gsub('jacknives', 'jacknife'):gsub('pieces', 'piece');
    s = s:gsub('pebbles', 'pebble'):gsub('slugs', 'slug');
    s = s:gsub('clams', 'clam'):gsub('shells', 'shell');
    s = s:gsub('logs', 'log'):gsub('fragments', 'fragment');
    s = s:gsub('urchins', 'urchin'):gsub('masks', 'mask');
    s = s:gsub('pies', 'pie'):gsub('rods', 'rod');
    s = s:gsub('nebimonites', 'nebimonite');
    return s;
end

local function WeightOf(name)
    local key = name:lower():gsub('^%s+', ''):gsub('%s+$', '');
    if (WEIGHTS[key] ~= nil) then return WEIGHTS[key]; end
    for k, w in pairs(WEIGHTS) do
        if (key:find(k, 1, true) ~= nil) then return w; end
    end
    return DEFAULT_WEIGHT;
end

--[[
* Chance the next dig overfills the bucket, as a percentage.
* Every item heavier than the headroom is a break; sum their weightings.
--]]
local function BreakChance()
    local tbl = LOOT;
    local room = capacity - weight;
    local bad, all = 0, 0;
    for _, row in ipairs(tbl) do
        all = all + row[3];
        if (row[2] > room) then bad = bad + row[3]; end
    end
    if (all == 0) then return 0; end
    return 100.0 * bad / all;
end

-- Mean ponzes per dig for this bucket size.
local function MeanPull()
    local tbl = LOOT;
    local sum, all = 0, 0;
    for _, row in ipairs(tbl) do
        sum = sum + row[2] * row[3];
        all = all + row[3];
    end
    if (all == 0) then return DEFAULT_WEIGHT; end
    return sum / all;
end

--[[
* FFXI wraps the item name in colour codes: 0x1E 0x02 before, 0x1E 0x01
* after, and a trailing 0x7F. A capture class of printable characters can
* never start, so every match returned nil while the chatlog looked clean -
* the log file is written by the timestamp addon AFTER stripping them.
* Strip first, match second.
--]]
local function CleanMsg(msg)
    if (msg == nil) then return ''; end
    msg = msg:gsub('[%z\1-\31\127]', '');
    return (msg:gsub('^%s+', ''):gsub('%s+$', ''));
end

local function Note(msg)
    lastMsg = msg; lastMsgAt = os.clock();
end

--[[
* Anything still pending when the next clamming event arrives was never
* delivered. That is the loss, and it needs no break message to detect.
--]]
local function FlushPending()
    if (not pending) then return; end
    pending = false;
    if (pAH > 0.5) or (pVen > 0.5) then
        lVen = lVen + pVen; lAH = lAH + pAH;
        -- A break costs the contents AND the 500g to get back in the water.
        Note(('bucket lost - %s gone, +%dg for a new kit'):fmt(
            Gil(pAH), KIT_COST));
        sBreaks = sBreaks + 1;
    end
    pVen, pAH = 0, 0;
end

--[[
* Reconcile against a weight the SERVER stated. Anything it is not holding
* that we thought it was has been lost - to a break, an Alraune, or a zone -
* and must come off the gil rate rather than sit there inflating it.
--]]
local function SyncWeight(sw)
    if (sw == weight) then return; end
    if (sw < weight) then
        local frac = 1.0;
        if (weight > 0) then frac = (weight - sw) / weight; end
        local dv, da = bVen * frac, bAH * frac;
        lVen = lVen + dv; lAH = lAH + da;
        bVen = bVen - dv; bAH = bAH - da;
        if (sw == 0) then found = T{}; sBreaks = sBreaks + 1; end
        Note(('lost %dpz - wrote off %s'):fmt(weight - sw, Gil(da)));
    else
        Note(('resynced %d -> %dpz'):fmt(weight, sw));
    end
    weight = sw;
end

--[[
* CAPACITY AUTO-DETECTION
*
* There is no clamming kit ITEM to inspect - the bucket is a server-side
* character variable, so nothing in the inventory says how big it is. The
* only direct signal is the "capacity has increased" message, which you see
* once and never again on that tier.
*
* So it is inferred from behaviour instead, two ways:
*
*   RAISE  the bucket is holding more than we thought it could. It obviously
*          never broke, so our capacity was too low - jump to the smallest
*          tier that fits. This corrects a wrong /clam cap within a few digs.
*
*   BREAK  the bucket held `before` and `before + w` destroyed it, so
*            before <= capacity < before + w
*          Since capacities are only 50/100/150/200 that bracket usually
*          lands on exactly one tier.
--]]
local TIERS = { 50, 100, 150, 200 };
local lastBefore, lastWeight = 0, 0;

local function RaiseCapacity()
    if (weight <= capacity) then return; end
    for _, t in ipairs(TIERS) do
        if (t >= weight) then
            capacity = t;
            SaveCfg();
            Note(('capacity must be %dpz - corrected'):fmt(t));
            return;
        end
    end
end

local function InferFromBreak()
    -- Prefer the tight bracket if we saw the fatal find; otherwise all we
    -- know is that the bucket held `lastBefore` and something broke it.
    local lo = lastBefore;
    local hi = (lastWeight > 0) and (lastBefore + lastWeight) or (lastBefore + 35);
    local hit = nil;
    for _, t in ipairs(TIERS) do
        if (t >= lo) and (t < hi) then
            if (hit ~= nil) then return; end   -- ambiguous, leave it alone
            hit = t;
        end
    end
    if (hit ~= nil) and (hit ~= capacity) then
        capacity = hit;
        SaveCfg();
        Note(('capacity inferred %dpz from the break'):fmt(hit));
    end
end

--[[
* DIG LOG - one CSV row per dig, so the weight and abundance tables above
* can be checked against what Horizon actually does rather than assumed.
* Game hour and moon phase are logged with each find so any tide or moon
* dependence in the drop rates can be tested once there is enough data.
*
* Columns: real_time, game_hour, game_min, moon_phase, moon_pct, weekday,
*          capacity, bucket_before, item, weight
*
* A dig that breaks the bucket is logged too (bucket_before + weight will
* exceed capacity on that row).
--]]
-- `logging` is declared with the other persisted state, above.
local LOGPATH = AshitaCore:GetInstallPath() .. 'config\\clamtrack_digs.csv';

-- Verbatim capture of every clamming-related chat line and of the matched
-- event packet, for pattern debugging. Off for release; flip to true to
-- write config\clamtrack_raw.txt.
local RAW_DEBUG = false;

-- Active dig time bookkeeping, shared by ordinary and fatal digs.
local function TouchActive()
    local now = os.time();
    if (lastDigAt > 0) then
        local gap = now - lastDigAt;
        if (gap > 0) and (gap <= DIG_GAP_CAP) then
            activeSec = activeSec + gap;
        end
    end
    lastDigAt = now;
end

local function LogDig(item, w, before)
    if (not logging) then return; end
    local gh, gm, mp, mpct, wd = -1, -1, -1, -1, -1;
    if (timelib ~= nil) then
        local ok = pcall(function ()
            gh   = timelib.get_game_hours();
            gm   = timelib.get_game_minutes();
            mp   = timelib.get_game_moon_phase();
            mpct = timelib.get_game_moon_percent();
            wd   = timelib.get_game_weekday();
        end);
        if (not ok) then gh, gm, mp, mpct, wd = -1, -1, -1, -1, -1; end
    end
    local ok, fh = pcall(io.open, LOGPATH, 'a');
    if (not ok) or (fh == nil) then return; end
    -- header on first write
    if (fh:seek('end') == 0) then
        fh:write('real_time,game_hour,game_min,moon_phase,moon_pct,weekday,' ..
                 'capacity,bucket_before,item,weight\n');
    end
    fh:write(('%s,%d,%d,%d,%d,%d,%d,%d,"%s",%d\n'):fmt(
        os.date('%Y-%m-%d %H:%M:%S'), gh, gm, mp, mpct, wd,
        capacity, before, item, w));
    fh:close();
end

ashita.events.register('text_in', 'clamtrack_text_in', function (e)
    local msg = CleanMsg(e.message);

    --[[
    * RAW CAPTURE - every line mentioning a find goes to disk verbatim, with
    * whether the pattern matched. This exists because the addon was silently
    * matching nothing and reasoning about the pattern was not settling it.
    * Written to a FILE, never chat: printing from inside text_in on a pattern
    * your own output can match is an unbounded loop.
    --]]
    if (RAW_DEBUG) and ((msg:find('You find') ~= nil)
        or (msg:find('clamming') ~= nil) or (msg:find('ponze') ~= nil)
        or (msg:find('capacity') ~= nil) or (msg:find('bucket') ~= nil)) then
        local ok, fh = pcall(io.open,
            AshitaCore:GetInstallPath() .. 'config\\clamtrack_raw.txt', 'a');
        if (ok) and (fh ~= nil) then
            local hit = msg:match('You find an? ([%w%s%-\'%.]+)%.');
            fh:write(('[%s] match=%s  raw=<<%s>>\n'):fmt(
                os.date('%H:%M:%S'), tostring(hit), msg));
            fh:close();
        end
    end

    --[[
    * THE FATAL DIG. On Horizon it is a single line that starts exactly like
    * an ordinary find (observed, verbatim):
    *
    *   "You find a pebble and toss it into your bucket...But the weight is
    *    too much for the bucket and its bottom breaks!All your shellfish are
    *    washed back into the sea..."
    *
    * So it has to be tested BEFORE the find branch. Otherwise the find
    * branch swallows it, adds the item, and RaiseCapacity then "corrects"
    * the capacity tier upward and persists it, because the bucket appears to
    * be holding more than it can. The phrases are specific on purpose: a
    * player saying "tropical always breaks my bucket" in chat must not empty
    * the tracker (that exact line has been seen).
    --]]
    local broke = (msg:find('too much for the bucket', 1, true) ~= nil)
        or (msg:find('bottom breaks', 1, true) ~= nil)
        or (msg:find('washed back into the sea', 1, true) ~= nil)
        or (msg:find('^You cannot collect any clams with a broken bucket') ~= nil);
    if (broke) then
        -- "cannot collect" repeats on every click of a broken node; only
        -- act if there is still something to write off.
        if (weight > 0) or (bVen > 0) or (bAH > 0) then
            local item = msg:match('^You find an? (.-) and toss');
            if (item ~= nil) then
                local w = WeightOf(item);
                LogDig(item, w, weight);   -- bucket weight BEFORE this find
                lastBefore, lastWeight = weight, w;
                sDigs = sDigs + 1;
                digAt = os.clock();
                TouchActive();
            else
                lastBefore, lastWeight = weight, 0;
            end
            InferFromBreak();   -- must run BEFORE the reset clears the numbers
            lVen = lVen + bVen; lAH = lAH + bAH;
            Note(('BUCKET BROKE - lost %s'):fmt(Gil(bAH)));
            weight = 0; found = T{}; sBreaks = sBreaks + 1;
            lastBefore, lastWeight = 0, 0;
            bVen, bAH = 0, 0;
        end
        return;
    end

    -- Exact name, not a greedy run of printable characters: the message
    -- reads "You find a <item> and toss it into your bucket.", so stopping
    -- at " and toss" yields the item alone. Anchored, so a player quoting
    -- the line in chat (which is prefixed by their name) cannot match.
    local item = msg:match('^You find an? (.-) and toss');
    if (item == nil) then
        item = msg:match('^You find an? (.-)!');
    end
    if (item ~= nil) and (msg:find(' on the ') == nil) and (msg:find(' in the ') == nil) then
        local w = WeightOf(item);
        LogDig(item, w, weight);   -- bucket weight BEFORE this find
        lastBefore, lastWeight = weight, w;
        weight = weight + w;
        sDigs = sDigs + 1; sWeight = sWeight + w;
        FlushPending();   -- digging again means the turn-in is finished
        digAt = os.clock();
        local pv, pa = PriceOf(item);
        bVen = bVen + pv; bAH = bAH + pa;
        TouchActive();
        RaiseCapacity();   -- holding more than we thought? capacity was wrong
        found[item] = (found[item] or 0) + 1;
        Note(('+%dpz %s'):fmt(w, item));
        return;
    end

    -- "Toh Zonikki : I'd say this bucket here weighs about 41 ponzes."
    -- A second, independent statement of the truth, in case the packet scan
    -- ever stops matching.
    local sw = msg:match('weighs about (%d+) ponze');
    if (sw ~= nil) then
        SyncWeight(tonumber(sw));
        return;
    end

    -- The exact wording of the upgrade line is not worth betting on, and
    -- betting on it is what left the addon stuck at 50pz. Any line that
    -- mentions clamming capacity and carries a number is enough.
    local cap = msg:match('[Cc]lamming capacity.-(%d+)')
               or msg:match('capacity .-(%d+) ponze');
    if (cap ~= nil) then
        capacity = tonumber(cap);
        SaveCfg();
        Note(('capacity now %dpz'):fmt(capacity));
        return;
    end

    -- Leaving the zone drops the kit and everything in it (LSB removeKit).
    -- That is a loss. Only a turn-in at Zonikki is money in your pocket.
    if (msg:find('dropped the clamming kit') ~= nil) then
        weight = 0; found = T{};
        lVen = lVen + bVen; lAH = lAH + bAH;
        Note(('zoned out - lost %s'):fmt(Gil(bAH)));
        bVen, bAH = 0, 0;
        return;
    end

    -- Handing the kit over does NOT prove the items arrived - you hand it
    -- over after a break too. Hold the value until the obtain lines confirm.
    if (msg:find('return the clamming kit') ~= nil) then
        FlushPending();
        weight = 0; found = T{};
        pVen, pAH = bVen, bAH;
        pending = true;
        bVen, bAH = 0, 0;
        return;
    end

    --[[
    * "You obtain N <item>!" - LSB giveClammedItems. Proof of delivery, so
    * this and only this moves gil into banked. Gated on `pending` so an
    * ordinary mob drop cannot be mistaken for a turn-in.
    --]]
    if (pending) then
        local n, nm = msg:match('You obtain (%d+) (.+)!');
        if (n ~= nil) then
            local key = Singular(nm):lower();
            local v, a = PriceOf(key);
            if (PRICES[key] ~= nil) then
                local cnt = tonumber(n);
                kVen = kVen + v * cnt; kAH = kAH + a * cnt;
                pVen = math.max(0, pVen - v * cnt);
                pAH  = math.max(0, pAH  - a * cnt);
                return;
            end
        end
    end

    -- Every kit is sold at 50pz; upgrades happen later, in-session. So the
    -- moment one is handed over we know both numbers for certain.
    -- Lowercased: the message is "Obtained key item: Clamming kit." with a
    -- capital C, and Lua's find is case sensitive, so the old lowercase
    -- pattern never matched and new kits went unnoticed entirely.
    local low = msg:lower();
    local gotKit = ((low:find('obtained key item') ~= nil)
                    and (low:find('clamming kit') ~= nil))
                or (low:find('yer clamming kit') ~= nil);
    if (gotKit) then
        local now = os.time();
        if ((now - lastKitAt) > 5) then
            lastKitAt = now;
            FlushPending();
            -- Anything still credited to the bucket at this point was lost
            -- without a message (zoning drops the kit). It must not carry
            -- over into the new bucket and inflate the gil rate.
            if (bVen > 0) or (bAH > 0) then
                lVen = lVen + bVen; lAH = lAH + bAH;
                Note(('previous bucket lost - %s written off'):fmt(Gil(bAH)));
            end
            bVen, bAH = 0, 0;
            capacity = 50; weight = 0; found = T{};
            kits = kits + 1; kitSpend = kitSpend + KIT_COST;
            SaveCfg();
            Note(('new kit #%d - 50pz, -%dg'):fmt(kits, KIT_COST));
        end
    end
end);

--[[
* SERVER-AUTHORITATIVE BUCKET READ
*
* Talking to Toh Zonikki sends an event update carrying
* (weight, size, size, size+50, 0, 0, 0, 0). Every observed instance was
* packet 0x005C at offset 4, so only that packet is inspected, but the
* signature is still scanned for rather than a fixed offset trusted.
* Reading dwords with string.byte avoids depending on struct being present.
--]]
local TIERSET = { [50] = true, [100] = true, [150] = true, [200] = true };

local function DW(s, i)   -- little-endian dword at 0-based offset i
    local a, b, c, d = s:byte(i + 1, i + 4);
    if (d == nil) then return nil; end
    return a + b * 256 + c * 65536 + d * 16777216;
end

ashita.events.register('packet_in', 'clamtrack_packet_in', function (e)
    if (e.id ~= 0x005C) then return; end
    local d = e.data;
    if (d == nil) then return; end
    local n = #d;
    if (n < 36) or (n > 512) then return; end
    for i = 0, n - 32 do
        -- Cheapest, most selective test first: capacity is one of four values.
        local sz = DW(d, i + 4);
        if (sz ~= nil) and (TIERSET[sz] == true)
            and (DW(d, i + 8) == sz) and (DW(d, i + 12) == sz + 50)
            and (DW(d, i + 16) == 0) and (DW(d, i + 20) == 0)
            and (DW(d, i + 24) == 0) and (DW(d, i + 28) == 0) then
            local w = DW(d, i + 0);
            if (w ~= nil) and (w <= 400) then
                local changed = (sz ~= capacity) or (w ~= weight);
                capacity = sz;
                SyncWeight(w);
                if (changed) then
                    SaveCfg();
                    Note(('server says %d/%dpz'):fmt(w, sz));
                end
                if (RAW_DEBUG) then
                    local ok, fh = pcall(io.open,
                        AshitaCore:GetInstallPath() .. 'config\\clamtrack_raw.txt', 'a');
                    if (ok) and (fh ~= nil) then
                        fh:write(('[%s] PKT id=0x%03X off=%d weight=%d cap=%d\n'):fmt(
                            os.date('%H:%M:%S'), e.id, i, w, sz));
                        fh:close();
                    end
                end
                return;
            end
        end
    end
end);

ashita.events.register('d3d_present', 'clamtrack_present', function ()
    if (not visible) then return; end
    local room = capacity - weight;
    local risk = BreakChance();
    local mean = MeanPull();
    local digs = (mean > 0) and math.floor(room / mean) or 0;

    local flags = bit.bor(ImGuiWindowFlags_NoTitleBar, ImGuiWindowFlags_NoScrollbar,
        ImGuiWindowFlags_AlwaysAutoResize, ImGuiWindowFlags_NoFocusOnAppearing);
    if (imgui.Begin('clamtrack', true, flags)) then
        -- Weight and break risk are read mid-dig at a glance, so the window
        -- runs larger than default. /clam font N to change it.
        --
        -- PushFont(font, size), NOT SetWindowFontScale: that call does not
        -- exist in this Ashita build and calling it nil-errors the whole
        -- render loop.
        imgui.PushFont(imgui.GetFont(), 12 * fontScale);
        -- Risk drives the colour, not a fixed headroom number.
        local col;
        if (risk >= 25) then      col = { 1.00, 0.35, 0.30, 1.0 };
        elseif (risk >= 8) then   col = { 1.00, 0.75, 0.30, 1.0 };
        else                      col = { 0.55, 0.90, 0.65, 1.0 }; end

        imgui.TextColored({ 0.60, 0.75, 0.95, 0.9 }, 'CLAMMING');
        imgui.Text(('%d / %d pz'):fmt(weight, capacity));
        imgui.SameLine();
        imgui.TextColored({ 0.55, 0.60, 0.70, 1.0 }, ('(%d room)'):fmt(room));
        imgui.TextColored(col, ('break risk  %.1f%%'):fmt(risk));
        imgui.TextColored({ 0.55, 0.60, 0.70, 1.0 },
            ('~%d digs left  |  %.1fpz avg'):fmt(digs, mean));
        -- Dig cooldown. Per NODE on the server, so this is "when can I click
        -- THIS point again" - stepping to another one lets you dig now.
        if (digAt > 0) then
            local left = digCd - (os.clock() - digAt);
            -- Label on its own line, bar overlay left empty. ImGui anchors
            -- an overlay to the filled edge rather than centring it, so a
            -- label passed to ProgressBar slides across as it charges.
            if (left > 0) then
                imgui.TextColored({ 1.00, 0.65, 0.30, 1.0 },
                    ('DIG IN %.1fs'):fmt(left));
                imgui.PushStyleColor(ImGuiCol_PlotHistogram, { 0.90, 0.45, 0.15, 1.0 });
                imgui.ProgressBar(1.0 - (left / digCd), { -1, barHeight }, '');
                imgui.PopStyleColor();
            else
                imgui.TextColored({ 0.45, 0.95, 0.50, 1.0 }, 'READY');
                imgui.PushStyleColor(ImGuiCol_PlotHistogram, { 0.20, 0.70, 0.30, 1.0 });
                imgui.ProgressBar(1.0, { -1, barHeight }, '');
                imgui.PopStyleColor();
            end
        end
        imgui.TextColored({ 0.85, 0.80, 0.55, 1.0 },
            ('bucket  %s v / %s ah'):fmt(Gil(bVen), Gil(bAH)));
        imgui.TextColored({ 0.55, 0.85, 0.60, 1.0 },
            ('%s/hr v  |  %s/hr ah'):fmt(
                Gil(PerHour(NetVen())), Gil(PerHour(NetAH()))));
        if (lastMsg ~= '') and ((os.clock() - lastMsgAt) < 6) then
            imgui.TextColored({ 0.70, 0.75, 0.85, 1.0 }, lastMsg);
        end
        imgui.PopFont();   -- must pair with the PushFont above
    end
    imgui.End();
end);

--[[
* Prints the addon help information.
*
* @param {boolean} isError - Flag if this function was invoked due to an error.
--]]
local function print_help(isError)
    if (isError) then
        print(chat.header(addon.name):append(chat.error('Invalid command syntax for command: ')):append(chat.success('/clam')));
    else
        print(chat.header(addon.name):append(chat.message('Available commands:')));
    end

    local cmds = T{
        { '/clam', 'Prints the bucket, session and gil status to chat.' },
        { '/clam help', 'Displays the addons help information.' },
        { '/clam reset', 'Empties the tracked bucket (after a turn-in).' },
        { '/clam cap <n>', 'Sets the bucket capacity (50, 100, 150 or 200).' },
        { '/clam set <n>', 'Corrects the current bucket weight by hand.' },
        { '/clam hide', 'Toggles the on-screen readout.' },
        { '/clam log [on|off]', 'Toggles the CSV dig log (config\\clamtrack_digs.csv).' },
        { '/clam bar <n>', 'Sets the cooldown bar height (8 to 80).' },
        { '/clam cd <n>', 'Sets the dig cooldown in seconds (default 10).' },
        { '/clam font <n>', 'Sets the readout font scale (0.5 to 4.0).' },
    };

    cmds:ieach(function (v)
        print(chat.header(addon.name):append(chat.error('Usage: ')):append(chat.message(v[1]):append(' - ')):append(chat.color1(6, v[2])));
    end);
end

ashita.events.register('command', 'clamtrack_command', function (e)
    local args = e.command:args();
    if (#args == 0) or (args[1] ~= '/clam') then return; end
    e.blocked = true;
    local sub = args[2] and args[2]:lower() or '';

    if (sub == 'help') then
        print_help(false);
        return;
    end
    if (sub == 'reset') then
        weight = 0; found = T{}; bVen, bAH = 0, 0;
        print(chat.header('clamtrack'):append(chat.message('Bucket emptied.')));
        return;
    end
    if (sub == 'cap') and (tonumber(args[3]) ~= nil) then
        capacity = tonumber(args[3]);
        SaveCfg();
        print(chat.header('clamtrack'):append(chat.message(
            ('Capacity set to %dpz.'):fmt(capacity))));
        return;
    end
    if (sub == 'set') and (tonumber(args[3]) ~= nil) then
        weight = tonumber(args[3]);
        print(chat.header('clamtrack'):append(chat.message(
            ('Weight set to %dpz.'):fmt(weight))));
        return;
    end
    if (sub == 'log') then
        if (args[3] ~= nil) then logging = (args[3]:lower() == 'on');
        else logging = not logging; end
        SaveCfg();
        print(chat.header('clamtrack'):append(chat.message('Dig logging '))
            :append(chat.success(logging and 'ON' or 'OFF'))
            :append(chat.message(' -> config\\clamtrack_digs.csv')));
        return;
    end
    if (sub == 'bar') and (tonumber(args[3]) ~= nil) then
        barHeight = math.max(8, math.min(80, tonumber(args[3])));
        SaveCfg();
        print(chat.header('clamtrack'):append(chat.message(
            ('Bar height %d'):fmt(barHeight))));
        return;
    end
    if (sub == 'cd') and (tonumber(args[3]) ~= nil) then
        digCd = math.max(1.0, tonumber(args[3]));
        print(chat.header('clamtrack'):append(chat.message(
            ('Dig cooldown %.0fs'):fmt(digCd))));
        return;
    end
    if (sub == 'font') and (tonumber(args[3]) ~= nil) then
        fontScale = math.max(0.5, math.min(4.0, tonumber(args[3])));
        SaveCfg();
        print(chat.header('clamtrack'):append(chat.message(
            ('Font scale %.2f'):fmt(fontScale))));
        return;
    end
    if (sub == 'hide') then
        visible = not visible;
        SaveCfg();
        print(chat.header('clamtrack'):append(chat.message(
            'Readout ' .. (visible and 'shown.' or 'hidden.'))));
        return;
    end
    if (sub ~= '') then
        print_help(true);
        return;
    end

    -- computed up front: nesting math.floor inside the format call made the
    -- paren count easy to get wrong, and it did.
    local left = math.floor((capacity - weight) / MeanPull());
    print(chat.header('clamtrack'):append(chat.message(
        ('%d/%dpz  |  %.1f%% break risk  |  ~%d digs left'):fmt(
            weight, capacity, BreakChance(), left))));
    print(chat.header('clamtrack'):append(chat.message(
        ('session: %d digs, %d breaks, %dpz dug, %d min active'):fmt(
            sDigs, sBreaks, sWeight, math.floor(activeSec / 60)))));
    print(chat.header('clamtrack'):append(chat.message(
        ('gil: bucket %s/%s  |  banked %s/%s  |  lost %s/%s   (vendor/AH)'):fmt(
            Gil(bVen), Gil(bAH), Gil(kVen), Gil(kAH), Gil(lVen), Gil(lAH)))));
    if (pending) then
        print(chat.header('clamtrack'):append(chat.message(
            ('   %s awaiting confirmation from the turn-in'):fmt(Gil(pAH)))));
    end
    print(chat.header('clamtrack'):append(chat.message(
        ('rate: %s gil/hr vendor  |  %s gil/hr AH   (net of kit costs)'):fmt(
            Gil(PerHour(NetVen())), Gil(PerHour(NetAH()))))));
    print(chat.header('clamtrack'):append(chat.message(
        ('kits: %d bought, -%s spent   |   net %s vendor / %s AH'):fmt(
            kits, Gil(kitSpend), Gil(NetVen()), Gil(NetAH())))));
    local any = false;
    for k, v in pairs(found) do
        any = true;
        print(chat.header('clamtrack'):append(chat.message(
            ('   %2dx %s  (%dpz ea)'):fmt(v, k, WeightOf(k)))));
    end
    if (not any) then
        print(chat.header('clamtrack'):append(chat.message('   bucket empty')));
    end
end);
