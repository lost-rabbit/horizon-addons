# Submission notes for HorizonXI review

Public source: https://github.com/lost-rabbit/horizon-addons

Each section is written to be pasted into the Community Team ticket.

## HeaphChimes (folder `heaphchimes`)

HeaphChimes is a display and voice overlay. It registers d3d_present, text_in,
command, load and unload only; there is no packet_in or packet_out handler and
no AddOutgoingPacket anywhere. It contains exactly one QueueCommand reachable
from a player action, in the command handler: `/heaphchimes plates` (a keybind)
sends `/nameplate mode all` or `hidenpc`. No render-loop or chat-triggered path
issues a command, packet or key.

All timers are read from the player's own recast and status memory, or started
from chat lines the player saw (an NM defeat line, a dropped placeholder, a
typed `/nm at HH:MM`). Placeholder and NM intervals are a static table copied
from LandSandBoat source; the addon never scans the entity table or widescan,
never reads other players, and never reads enemy TP.

The only client memory write is the same two-byte status-icon-row hide that the
approved statustimers addon uses (same signature, credited, GPL). It is
optional (`/cdtimers native`) and restored on unload.

Spoken reminders are pre-recorded mp3 clips shipped in the addon's `voice`
folder, played through winmm's MCI call from inside the addon (the same
library other approved overlays use for sounds). The addon writes no files
other than its own settings and makes no network calls.

## HeaphTimers (folder `heaphtimers`)

HeaphTimers is a display-only replacement for the stock timers addon: two
transparent, draggable overlay panels. The Buffs panel shows one tile per
active status effect using the game's own status icon with the remaining
seconds beneath it, read from the client's status timer table so the countdown
is exact rather than estimated from packets. The Recasts panel lists every
ability and spell on cooldown as a bar or a compact tile. Sizes, thresholds,
colours and sort order are set in a fixed-size scrolling window opened with
`/heaphtimers`; positions are saved per character. An off-by-default option
hides the game's native status-icon row using the same reversible patch as
statustimers (Heals, GPL), restored on unload. It reads memory and resources
only, sends no packets and queues no commands. It is the timers module of
HeaphChimes packaged on its own; the two should not be loaded together.

## clamtrack

clamtrack is a Bibiki Bay clamming tracker. It reads chat (text_in) and one
incoming packet, the NPC event update (id 0x05C) that carries bucket weight and
capacity, which are the same numbers Toh Zonikki states in dialogue. The scan is
pinned to that packet id. It never sends packets or commands. Break odds are
computed from Horizon's published clamming abundance table and item weights. It
writes one file under `config\` (a per-dig CSV, `/clam log off` to stop); the
raw debug capture is off by default. Settings are per character through the
standard settings library.

## HeaphsGearScan (folder `heaphsgearscan`)

HeaphsGearScan is a one-shot manual inventory dump. `/heaphsgearscan` writes
every container's item names, level, job flags and the client's own stat
description to `config\gearscan_dump.txt` so gear sets can be planned outside
the game. It registers only a command handler, reads inventory memory and the
resource manager, and never issues a command, packet or network call. Nothing
in game consumes the file.
