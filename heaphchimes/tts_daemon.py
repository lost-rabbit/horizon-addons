"""cdchime neural voice daemon.

Tails Game\\config\\cdchime_speech.txt (written by the cdchime addon) and
speaks each new line with a Microsoft Edge neural voice - far better than
the SAPI voices Windows exposes to VBScript. Phrases are synthesized once
and cached as mp3 next to this script, so repeats are instant and offline.

Control lines:  !vol N   (0-100)

Run with the DPS meter venv's pythonw (see CdchimeVoice.bat).
"""
import asyncio
import ctypes
import hashlib
import time
from pathlib import Path

import edge_tts

# Try alternatives with:  edge-tts --list-voices | findstr Female
# Cast 2026-08-08 after a 21-voice audition: Yan (Hong Kong English).
VOICE = "en-HK-YanNeural"
DEFAULT_VOL = 80

GAME = Path.home() / "AppData/Roaming/HorizonXI-Launcher/HorizonXI/Game"
QUEUE = GAME / "config" / "cdchime_speech.txt"
CACHE = Path(__file__).parent / "voice_cache"
CACHE.mkdir(exist_ok=True)

mci = ctypes.windll.winmm.mciSendStringW


def play(path: Path, vol: int) -> None:
    alias = f"cdv{int(time.time() * 1000) % 1000000}"
    mci(f'open "{path}" type mpegvideo alias {alias}', None, 0, None)
    mci(f"setaudio {alias} volume to {vol * 10}", None, 0, None)
    mci(f"play {alias} wait", None, 0, None)  # wait = phrases queue, never overlap
    mci(f"close {alias}", None, 0, None)


def mp3_for(text: str) -> Path:
    out = CACHE / (hashlib.md5(f"{VOICE}|{text}".encode()).hexdigest() + ".mp3")
    if not out.is_file():
        asyncio.run(edge_tts.Communicate(text, VOICE).save(str(out)))
    return out


VOLFILE = CACHE / "volume.txt"


def load_vol() -> int:
    try:
        return max(0, min(100, int(VOLFILE.read_text().strip())))
    except (OSError, ValueError):
        return DEFAULT_VOL


def main() -> None:
    vol = load_vol()
    QUEUE.touch(exist_ok=True)
    pos = QUEUE.stat().st_size  # start at EOF: never replay history
    play(mp3_for("voice ready"), vol)
    while True:
        try:
            try:
                size = QUEUE.stat().st_size
            except FileNotFoundError:
                QUEUE.touch(exist_ok=True); size = 0
            if size < pos:  # file truncated/recreated
                pos = 0
            if size > pos:
                with open(QUEUE, "r", encoding="utf-8", errors="replace") as f:
                    f.seek(pos)
                    chunk = f.read()
                    pos = f.tell()
                for line in chunk.splitlines():
                    line = line.strip()
                    if not line:
                        continue
                    if line.startswith("!vol "):
                        try:
                            vol = max(0, min(100, int(line[5:])))
                            VOLFILE.write_text(str(vol))  # persists across restarts
                            play(mp3_for(f"volume {vol}"), vol)
                        except ValueError:
                            pass
                        continue
                    try:
                        play(mp3_for(line), vol)
                    except Exception:
                        pass  # offline / synth hiccup: drop the phrase, keep running
        except OSError:
            pass
        time.sleep(0.2)


if __name__ == "__main__":
    main()
