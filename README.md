# Heaph's HorizonXI addons

Three display-only Ashita v4 addons written for HorizonXI. None of them sends a
command, packet or keypress on its own; everything they do is draw on screen,
keep timers, or write a file under `Game\config`.

| Addon | What it is | Commands |
|---|---|---|
| [cdchime](cdchime/) | cooldown and reminder popups, buff tiles and recast bars, placeholder and NM window countdowns, optional spoken reminders | `/cdchime`, `/cdtimers`, `/nm`, `/ph` |
| [clamtrack](clamtrack/) | Bibiki Bay clamming tracker with the real chance the next dig breaks the bucket | `/clam` |
| [gearscan](gearscan/) | one-shot inventory dump to a text file, for planning gear sets outside the game | `/gearscan` |

## Install

Copy the addon folder into `Game\addons` so that, for example,
`Game\addons\cdchime\cdchime.lua` exists, then in game:

    /addon load cdchime

Add the same line to `Game\scripts\default.txt` to load it every time.

## cdchime's voice (optional)

cdchime can read its reminders aloud. The addon itself only appends the phrase
to `Game\config\cdchime_speech.txt`. A separate helper outside the game,
`cdchime\tts_daemon.py`, reads that file and speaks each phrase through
Microsoft's Edge text-to-speech voice, caching the audio next to the script so
repeats play offline. To use it:

1. Install Python 3 from python.org.
2. `pip install edge-tts`
3. Run `cdchime\CdchimeVoice.bat` alongside the game.

Without the helper, cdchime works exactly the same and simply stays quiet.
Only the phrase text (ability names, reminder text, NM names) ever leaves the
machine, and only the first time each phrase is spoken.

## Rules

Written to sit inside HorizonXI's addon rules: nothing acts without a player
input. The one command any of them issues is `/cdchime plates`, which toggles
enemy nameplates when the player presses the key it is bound to. Details for
reviewers are in [TICKETS.md](TICKETS.md).

Creation assisted by ADA. X-32 keeps the ledger.
