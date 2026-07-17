# Voice Sentiment Analysis - Full Specification

## Purpose

Real-time voice sentiment service. Listens to live call audio forked by NICE inContact Media Server over WebSocket. Detects negative customer emotion using AI. Signals Media Server to transfer call from BOT to human agent.

---

## System Overview

```
Media Server
  |-- connects ws://SERVER_IP:2700
  |-- sends BwmaInitializeMessage (JSON)
  |-- streams G.711 mu-law audio (binary, 160 bytes/frame, 8kHz, 20ms)
  |-- receives BADSENTIMENT (JSON) when negative emotion threshold hit

Sentiment Server (Python)
  |-- port 2700
  |-- decodes G.711 -> PCM 8kHz -> resample to 16kHz
  |-- accumulates 1.5s sliding window (slides every 0.5s)
  |-- runs SenseVoiceSmall: returns emotion label + transcribed text
  |-- counter++ on negative emotion (angry/sad/fearful/disgusted)
  |-- sends BADSENTIMENT to MS when counter reaches threshold
  |-- counter resets after each BADSENTIMENT (fires again after next N hits)
```

---

## Server

| | |
|---|---|
| IP | 172.28.129.220 |
| OS | Windows Server 2025 |
| AWS | t3.large (2 vCPU, 8GB RAM) |
| Disk | 2x 50GB |
| Python | 3.12 (C:\Python312\python.exe) |
| Install root | C:\voice-sentiment\ |
| Log root | C:\voice-sentiment\logs\ |
| Service manager | NSSM 2.24 (C:\tools\nssm\win64\nssm.exe) |
| Service name | VoiceSentiment |
| Port | 2700 (TCP inbound, firewall rule added) |

---

## File Structure (deployed)

```
C:\voice-sentiment\
  sentiment-server\
    sentiment_server.py
    audio_sentiment.py
    requirements.txt
    .env
    SenseVoiceSmall\          <- AI model files
      model.pt
      config.yaml
      tokens.json
      am.mvn
      chn_jpn_yue_eng_ko_spectok.bpe.model
      configuration.json
  logs\
    sentiment_server.log
    VoiceSentiment-stdout.log
    VoiceSentiment-stderr.log
```

---

## Source Files

### `sentiment_server.py`

Entry point. WebSocket server on port 2700.

**Dependencies:** `websockets`, `audioop` (stdlib Python 3.12), `dotenv`, `audio_sentiment.py`

**Startup sequence:**
1. Load `.env`
2. Start WebSocket server on `0.0.0.0:2700`
3. SenseVoice model loads on first audio window (lazy load)

**Per-connection flow:**
1. Receive first message - must be JSON (BWMA init)
2. Parse `contactId` from `executionInfo.contactId`
3. Send handshake response (BEGIN AUDIO STREAM)
4. Loop over binary frames:
   - `audioop.ulaw2lin(frame, 2)` -> PCM 16-bit @ 8kHz
   - `audioop.ratecv(pcm, 2, 1, 8000, 16000, None)` -> PCM 16-bit @ 16kHz
   - Accumulate into buffer
   - When buffer >= 1.5s (96000 bytes): run `analyze_audio(window)`
   - Slide buffer by 0.5s (32000 bytes)
   - Log transcribed text and emotion
   - If `is_negative`: `bad_count++`
   - If `bad_count >= BAD_SENTIMENT_THRESHOLD`: send BADSENTIMENT, reset counter

**Environment variables:**
```
SERVER_INTERFACE        = 0.0.0.0    # bind address
SERVER_PORT             = 2700       # listen port
BAD_SENTIMENT_THRESHOLD = 3          # hits before BADSENTIMENT fires
SER_DEVICE              = cpu        # cpu or cuda
LOG_DIR                 = logs       # log output directory
```

**BADSENTIMENT message sent to MS:**
```json
{
    "MessageType": "BADSENTIMENT",
    "Parameters": {
        "contactId": <contactId>,
        "count": <threshold>
    }
}
```

---

### `audio_sentiment.py`

Wraps SenseVoiceSmall inference.

**Function:** `analyze_audio(pcm_16k_bytes: bytes) -> (label: str, is_negative: bool, text: str)`

**Model loading priority:**
1. Path in env var `SENSEVOICE_MODEL_PATH` (if set and exists)
2. `./SenseVoiceSmall/` folder next to script (bundled)
3. Download from ModelScope `iic/SenseVoiceSmall` (fallback, requires internet)

**Negative emotions:** `angry`, `sad`, `fearful`, `disgusted`

**Neutral emotions (ignored):** `happy`, `neutral`, `surprised`

**Minimum audio length:** 0.3s (shorter windows skipped, returns `neutral`)

---

### `requirements.txt`

```
python-dotenv
websockets
funasr>=1.1.3
torch
torchaudio
numpy
audioop-lts; python_version >= "3.13"
```

> Install torch CPU-only first to avoid 2GB CUDA download:
> `pip install torch torchaudio --index-url https://download.pytorch.org/whl/cpu`

---

### `.env`

```
SERVER_INTERFACE=0.0.0.0
SERVER_PORT=2700
BAD_SENTIMENT_THRESHOLD=3
SER_DEVICE=cpu
```

---

## BWMA Protocol

### MS sends on connect (JSON text):
```json
{
    "minimumVersion": 0,
    "maximumVersion": 1,
    "capabilities": ["UTTERANCE_DETECT"],
    "requiredCapabilities": ["UTTERANCE_DETECT"],
    "format": "MONO",
    "executionInfo": {
        "contactId": 12345,
        "busNo": 1,
        "requestId": 1,
        "actionId": 0,
        "actionType": "WebSocketRelay",
        "scriptName": "SentimentAnalysis"
    },
    "systemTelemetryData": {
        "consumerProcessHost": "mediaserver-hostname",
        "consumerProcessName": "EsnMediaServer",
        "consumerProcessVersion": "1.0.0"
    },
    "appConfig": {},
    "appParams": {},
    "authenticationToken": "",
    "streamsConfiguration": null,
    "streamPerspective": "TX_RELAY"
}
```

### Server responds (JSON text):
```json
{
    "Message": "BEGIN AUDIO STREAM",
    "MessageType": "COMMAND",
    "ProtocolVersion": 1,
    "Format": "MONO",
    "AgreedCapabilities": ["UTTERANCE_DETECT"],
    "Parameters": {}
}
```

### MS then streams binary G.711 frames:
- Encoding: mu-law (ulaw)
- Sample rate: 8kHz
- Frame size: 160 bytes = 20ms per frame
- Channel: mono

---

## Deployment Scripts

### 1. `package-deploy.ps1` - run on local machine

Creates `voice-sentiment-deploy.zip` with all files needed on server.

**What it packages:**
- `sentiment-server/` source files
- `SenseVoiceSmall/` model (extracted from `SenseVoiceSmall.zip`)
- `server-setup.ps1`

```powershell
.\package-deploy.ps1
# Output: voice-sentiment-deploy.zip
```

---

### 2. `server-setup.ps1` - run on server

Full automated install from scratch.

**Steps it performs:**
1. Check/install Python 3.12 (MSI download or winget fallback)
2. Create directory structure under `C:\voice-sentiment\`
3. Copy source files from deploy package
4. Install torch CPU-only (separate step, avoids CUDA bloat)
5. Install remaining pip dependencies from `requirements.txt`
6. Check/install NSSM (download or use existing)
7. Register `VoiceSentiment` as Windows Service with NSSM
   - Auto-start on boot
   - Rotating logs (10MB, 5 backups)
   - Env vars: `LOG_DIR`, `SER_DEVICE`
8. Open TCP port 2700 inbound in Windows Firewall
9. Start service
10. Print status and log paths

```powershell
powershell -ExecutionPolicy Bypass -File server-setup.ps1
```

**Corporate proxy notes:**
- All pip installs use `--trusted-host pypi.org --trusted-host files.pythonhosted.org`
- torch uses `--trusted-host download.pytorch.org`
- NSSM and Python downloads may fail behind strict proxy - copy binaries manually if needed
  - Python: `python-3.12.10-amd64.exe` -> run manually, install to `C:\Python312`
  - NSSM: `nssm.exe` -> copy to `C:\tools\nssm\win64\nssm.exe`

---

## Full Deploy Steps

### Local machine:
```powershell
cd C:\code\voice-sentiment
.\package-deploy.ps1
# Copy voice-sentiment-deploy.zip to server via RDP or scp
```

### On server:
```powershell
# Extract
Expand-Archive -Path "voice-sentiment-deploy.zip" -DestinationPath "D:\proj\voice-sentiment-deploy" -Force
cd D:\proj\voice-sentiment-deploy

# Install torch (do separately - large download)
C:\Python312\python.exe -m pip install torch torchaudio --index-url https://download.pytorch.org/whl/cpu --trusted-host download.pytorch.org --trusted-host pypi.org --trusted-host files.pythonhosted.org

# Full setup
powershell -ExecutionPolicy Bypass -File server-setup.ps1

# Watch startup
Get-Content "C:\voice-sentiment\logs\VoiceSentiment-stderr.log" -Tail 30 -Wait
# Look for: SenseVoiceSmall loaded
```

---

## Service Management

```powershell
# Status
Get-Service VoiceSentiment

# Control
C:\tools\nssm\win64\nssm.exe start   VoiceSentiment
C:\tools\nssm\win64\nssm.exe stop    VoiceSentiment
C:\tools\nssm\win64\nssm.exe restart VoiceSentiment

# Logs
Get-Content C:\voice-sentiment\logs\sentiment_server.log -Tail 50 -Wait
Get-Content C:\voice-sentiment\logs\VoiceSentiment-stderr.log -Tail 50 -Wait
```

---

## Local Testing

```powershell
# Terminal 1 - start server locally
cd sentiment-server
python sentiment_server.py

# Terminal 2 - run test client
python test_ms_client.py --wav C:\path\to\audio.wav --server ws://localhost:2700 --repeat 5
```

Expected log output:
```
[99999] Transcribed: "I am very frustrated with this"
[99999] Emotion: angry | negative=True
[99999] Negative emotion: angry count=1/3
...
[99999] BADSENTIMENT sent to MS - threshold 3 reached
```

---

## Tuning

| Parameter | Env Var | Default | Effect |
|-----------|---------|---------|--------|
| Trigger threshold | `BAD_SENTIMENT_THRESHOLD` | 3 | Lower = triggers sooner |
| Audio window | hardcoded | 1.5s | Shorter = more responsive, less accurate |
| Slide interval | hardcoded | 0.5s | How often model runs |
| Device | `SER_DEVICE` | cpu | Set `cuda` if GPU available |
| Model path | `SENSEVOICE_MODEL_PATH` | ./SenseVoiceSmall | Override model location |
