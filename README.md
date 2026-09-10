# Heaph's HorizonXI addons

Four display-only Ashita v4 addons written for HorizonXI. None of them sends a
command, packet or keypress on its own; everything they do is draw on screen,
keep timers, or write a file under `Game\config`.

| Addon | What it is | Commands |
|---|---|---|
| [HeaphChimes](heaphchimes/) | cooldown and reminder popups, maneuver tiles, buff tiles and recast bars, placeholder and NM window countdowns, plain countdowns (`/heaphchimes timer 10m Dynamis entry`), optional spoken reminders | `/heaphchimes` (alias `/cdchime`), `/cdtimers`, `/nm`, `/ph` |
| [HeaphTimers](heaphtimers/) | the buff tiles and recast bars from HeaphChimes as a standalone addon, for people who only want timers | `/heaphtimers` (alias `/cdtimers`) |
| [clamtrack](clamtrack/) | Bibiki Bay clamming tracker with the real chance the next dig breaks the bucket | `/clam` |
| [HeaphsGearScan](heaphsgearscan/) | one-shot inventory dump to a text file, for planning gear sets outside the game | `/heaphsgearscan` (alias `/gearscan`) |

HeaphChimes already contains the timers, so load either HeaphChimes or
HeaphTimers, not both.

## Install

Copy the addon folder into `Game\addons` so that, for example,
`Game\addons\heaphchimes\heaphchimes.lua` exists, then in game:

    /addon load heaphchimes

Add the same line to `Game\scripts\default.txt` to load it every time. Folder
names are lower case and must match the file inside them.

## HeaphChimes' voice

HeaphChimes can read its reminders aloud. Every phrase it can say is a small
recorded clip in `heaphchimes\voice\`, played through the Windows sound call
(winmm) from inside the addon. Nothing runs outside the game, nothing is
written to disk, nothing touches the network. `/heaphchimes say off` silences
it and `/heaphchimes volume N` sets the level. A reminder with no matching clip
plays a short spoken "Reminder" instead.

## Rules

Written to sit inside HorizonXI's addon rules: nothing acts without a player
input. The one command any of them issues is `/heaphchimes plates`, which
toggles enemy nameplates when the player presses the key it is bound to.
Details for reviewers are in [TICKETS.md](TICKETS.md).

Creation assisted by ADA. X-32 keeps the ledger.
