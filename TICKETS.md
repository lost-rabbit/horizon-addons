# Submission notes for HorizonXI review

Public source: https://github.com/lost-rabbit/horizon-addons

Each section is written to be pasted into the Community Team ticket.

## cdchime

cdchime is a display and voice overlay. It registers d3d_present, text_in,
command, load and unload only; there is no packet_in or packet_out handler and
no AddOutgoingPacket anywhere. It contains exactly one QueueCommand reachable
from a player action, in the command handler: `/cdchime plates` (a keybind)
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

The addon writes one text file, `config\cdchime_speech.txt`. An optional
program that runs outside Ashita (`tts_daemon.py`, started by
`CdchimeVoice.bat`) reads that file and synthesises the phrase text with
Microsoft's Edge text-to-speech service, caching mp3s locally. Only the phrase
text (ability and NM names, reminder text) is sent; no character, chat or log
data. The addon itself makes no network calls.

## clamtrack

clamtrack is a Bibiki Bay clamming tracker. It reads chat (text_in) and one
incoming packet, the NPC event update (id 0x05C) that carries bucket weight and
capacity, which are the same numbers Toh Zonikki states in dialogue. The scan is
pinned to that packet id. It never sends packets or commands. Break odds are
computed from Horizon's published clamming abundance table and item weights. It
writes one file under `config\` (a per-dig CSV, `/clam log off` to stop); the
raw debug capture is off by default. Settings are per character through the
standard settings library.

## gearscan

gearscan is a one-shot manual inventory dump. `/gearscan` writes every
container's item names, level, job flags and the client's own stat description
to `config\gearscan_dump.txt` so gear sets can be planned outside the game. It
registers only a command handler, reads inventory memory and the resource
manager, and never issues a command, packet or network call. Nothing in game
consumes the file.
