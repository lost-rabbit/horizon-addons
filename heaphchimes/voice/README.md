# HeaphChimes voice lines: the guide

Every line the addon can say is one small audio file in this folder. The
addon never generates speech and never runs anything outside the game. It
plays a file whose name matches the text it wants to say. That means adding
a new line is just putting a new file here with the right name, and this
guide is about the easiest ways to do that.

## 1. How a line finds its clip

Text becomes a file name by one rule: lower case, and every run of anything
that is not a letter or digit becomes a single underscore.

| Text the addon wants to say | File it looks for |
|---|---|
| Chakra ready | chakra_ready.mp3 |
| Dynamis entry | dynamis_entry.mp3 |
| Fire Maneuver used, 14 percent | fire_maneuver_used.mp3 then 14_percent.mp3 |
| Mee Deggi the Punisher window open | mee_deggi_the_punisher_window_open.mp3 |

A comma splits a line into parts and each part is its own clip. If no clip
matches, the addon plays reminder.mp3 (a spoken "Reminder"), so you always
hear something. Both .mp3 and .wav work; .mp3 is tried first.

## 2. Open PowerShell in this folder

1. In File Explorer, go to your game folder, then `addons`, then
   `heaphchimes`, then `voice`.
2. Click the address bar, type `powershell`, press Enter. A blue window opens
   already sitting in this folder.

If PowerShell refuses to run the script ("running scripts is disabled"), run
it this way instead, which only lifts the block for that one command:

    powershell -ExecutionPolicy Bypass -File .\make-voice-lines.ps1 "Dynamis entry"

## 3. The quick way: the Windows voice (nothing to install)

Windows has a built-in text-to-speech voice. This needs no download and no
internet.

    .\make-voice-lines.ps1 -Windows "Dynamis entry" "Sky pop" "Go to bed"

Each phrase becomes a .wav here and is added to phrases.txt. To see which
Windows voices you have and pick one:

    .\make-voice-lines.ps1 -ListVoices
    .\make-voice-lines.ps1 -Windows -WindowsVoice Zira "Dynamis entry"

More voices can be added in Windows Settings > Time & Language > Speech >
Manage voices (Windows 10 and 11).

## 4. The matching way: Yan, the voice of the shipped clips

The clips that come with the addon were recorded with Microsoft's online
neural voice "Yan" (en-HK-YanNeural) through the free edge-tts package. To
record new lines in the same voice, once:

1. Install Python from https://www.python.org/downloads/ (tick "Add python
   to PATH" on the first screen of the installer).
2. In any PowerShell window: `pip install edge-tts`

Then, in this folder:

    .\make-voice-lines.ps1 "Dynamis entry" "Sky pop"

The script finds Python on its own. It needs internet while recording; the
finished clips play offline like all the others. If it cannot find a Python
with edge-tts it says so and falls back to the Windows voice automatically.

Point it at a specific Python if you have several:

    .\make-voice-lines.ps1 -Python "C:\Python312\python.exe" "Dynamis entry"

## 5. Many lines at once

Put one phrase per line in a text file (lines starting with # are ignored):

    .\make-voice-lines.ps1 -FromFile mylines.txt
    .\make-voice-lines.ps1 -Windows -FromFile mylines.txt

## 6. A whole different voice

To re-record every shipped line with another edge-tts voice:

    .\make-voice-lines.ps1 -FromFile phrases.txt -Voice en-GB-SoniaNeural

List the available online voices with `python -m edge_tts --list-voices`.
Or re-record everything with the Windows voice using `-Windows -FromFile
phrases.txt`; the mp3 files stay in place but the addon prefers them, so
delete the .mp3 files you want replaced.

## 7. Hear it in game

    /addon reload heaphchimes
    /cdchime say on
    /cdchime timer 5s Dynamis entry

Five seconds later the Alerts window shows "Dynamis entry is up" and you hear
the clip. `/cdchime volume 70` sets the level, `/cdchime say off` mutes.

Anything that speaks can use your lines: `/cdchime timer`, `/cdchime trigger
add <name> | <chat pattern> | <spoken text> | <secs>`, NM windows and
placeholder timers (named after the mob), and the built-in reminders.

## 8. If something is off

- You hear "Reminder" instead of your words: the file name does not match
  the text. Check the rule in section 1 and the exact spelling you typed in
  game. phrases.txt lists every line that has a clip.
- Nothing at all: `/cdchime say on`, then `/cdchime volume 100`. Windows
  volume mixer also has a slider for the game.
- The Windows voice sounds robotic: that is the voice. Section 3 shows how to
  pick a different one; section 4 gets you the shipped voice.
- edge-tts fails: you are offline, or Python was installed without "Add to
  PATH". Use `-Python` with the full path, or `-Windows`.

You can also drop in any mp3 or wav you recorded yourself, as long as the
file name follows the rule.
