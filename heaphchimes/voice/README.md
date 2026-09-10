# HeaphChimes voice clips

Every line the addon can say is one small audio file in this folder. The
addon never generates speech; it plays a file whose name matches the text.

## How a line finds its clip

Text is turned into a file name by this rule: lower case, and every run of
anything that is not a letter or digit becomes one underscore.

| Text the addon wants to say | File it looks for |
|---|---|
| Chakra ready | chakra_ready.mp3 |
| Fire Maneuver used, 14 percent | fire_maneuver_used.mp3 then 14_percent.mp3 |
| Dynamis entry | dynamis_entry.mp3 |

A comma splits a line into parts and each part is one clip. Text with no
matching clip plays reminder.mp3, a short spoken "Reminder". Both .mp3 and
.wav are accepted; .mp3 is tried first.

## Make your own lines

    .\make-voice-lines.ps1 "Dynamis entry" "Sky pop"
    .\make-voice-lines.ps1 -FromFile mylines.txt

The script records in Yan's voice (the one the shipped clips use) when a
Python with the edge-tts package is on the machine, and falls back to the
Windows built-in voice otherwise. See the top of the script for options.

Then name the thing you want spoken after the clip:

    /cdchime timer 10m Dynamis entry
    /cdchime trigger add sky | Sky pop | Sky pop | 10

You can also drop in any mp3 or wav you recorded yourself, as long as the
file name follows the rule above.

## Replace a voice

Regenerate every line in phrases.txt with a different voice:

    .\make-voice-lines.ps1 -FromFile phrases.txt -Voice en-GB-SoniaNeural

The edge-tts package lists its voices with `python -m edge_tts --list-voices`.
