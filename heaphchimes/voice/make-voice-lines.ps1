# Make your own HeaphChimes voice lines.
#
#   .\make-voice-lines.ps1 "Dynamis entry" "Sky pop" "Go to bed"
#   .\make-voice-lines.ps1 -FromFile mylines.txt          (one phrase per line)
#   .\make-voice-lines.ps1 -Windows "Dynamis entry"       (skip Yan, use the Windows voice)
#   .\make-voice-lines.ps1 -Python C:\path\to\python.exe "Dynamis entry"
#
# Each phrase becomes one clip in this folder, named by the same rule the
# addon uses to look clips up: lower case, every run of anything that is not
# a letter or digit becomes one underscore. "Dynamis entry" -> dynamis_entry.
# Any timer, trigger, NM window or reminder whose text matches a clip name is
# read aloud with that clip; text with no clip plays the short Reminder chime.
#
# Two ways to record, tried in this order:
#   1. Yan (en-HK-YanNeural), the voice the shipped clips use. Needs Python
#      with the edge-tts package: pip install edge-tts. Needs internet while
#      recording. Writes <slug>.mp3.
#   2. The Windows built-in voice (no install, no internet). Writes <slug>.wav.
#      The addon plays either extension.
#
# This script runs outside the game, once, when you want new lines. The addon
# itself never runs anything; it only plays the files that are already here.
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(ValueFromRemainingArguments = $true)] [string[]] $Phrases,
    [string] $FromFile,
    [string] $Python,
    [switch] $Windows,
    [string] $Voice = 'en-HK-YanNeural'
)

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$list = @()
if ($FromFile) { $list += Get-Content $FromFile | Where-Object { $_.Trim() -ne '' -and -not $_.StartsWith('#') } }
if ($Phrases) { $list += $Phrases }
if (-not $list) {
    Get-Content $MyInvocation.MyCommand.Path | Select-Object -First 22 | ForEach-Object { $_ -replace '^# ?', '' }
    exit 2
}

function Slug([string] $text) {
    ($text.ToLower() -replace '[^a-z0-9]+', '_').Trim('_')
}

# Find a Python that has edge-tts, unless the Windows voice was asked for.
$py = $null
if (-not $Windows) {
    $candidates = @()
    if ($Python) { $candidates += $Python }
    if ($env:HEAPHCHIMES_PYTHON) { $candidates += $env:HEAPHCHIMES_PYTHON }
    $candidates += 'python', 'python3', 'py'
    foreach ($c in $candidates) {
        try {
            $cmd = Get-Command $c -ErrorAction Stop
            & $cmd.Source -c 'import edge_tts' 2>$null
            if ($LASTEXITCODE -eq 0) { $py = $cmd.Source; break }
        } catch { }
    }
    if (-not $py) {
        Write-Host "No Python with edge-tts found; using the Windows voice instead."
        Write-Host "For Yan's voice: pip install edge-tts, then run this again."
    }
}

$sapi = $null
if (-not $py) {
    Add-Type -AssemblyName System.Speech
    $sapi = New-Object System.Speech.Synthesis.SpeechSynthesizer
}

$made = 0
foreach ($phrase in $list) {
    $phrase = $phrase.Trim()
    if (-not $phrase) { continue }
    $slug = Slug $phrase
    if (-not $slug) { Write-Host "skip (no letters or digits): $phrase"; continue }
    if ($py) {
        $out = Join-Path $here "$slug.mp3"
        & $py -m edge_tts --voice $Voice --text $phrase --write-media $out 2>$null
        if ($LASTEXITCODE -ne 0 -or -not (Test-Path $out)) {
            Write-Host "edge-tts failed for '$phrase' (offline?). Try -Windows for the built-in voice."
            continue
        }
    } else {
        $out = Join-Path $here "$slug.wav"
        $sapi.SetOutputToWaveFile($out)
        $sapi.Speak($phrase)
        $sapi.SetOutputToNull()
    }
    $phrasesFile = Join-Path $here 'phrases.txt'
    $have = @()
    if (Test-Path $phrasesFile) { $have = Get-Content $phrasesFile }
    if ($have -notcontains $phrase) { Add-Content -Path $phrasesFile -Value $phrase -Encoding UTF8 }
    "{0,-40} -> {1}" -f $phrase, (Split-Path $out -Leaf)
    $made++
}
if ($sapi) { $sapi.Dispose() }
"$made clip(s) written to $here. Reload the addon (/addon reload heaphchimes) if it is running."
exit 0
