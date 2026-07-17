# Voice Sentiment Analysis

Real-time voice sentiment service for NICE inContact Media Server. Monitors live call audio and automatically transfers calls from BOT agent to human agent when negative customer emotion is detected.

---

## How It Works

```
Media Server (BOT call in progress)
    |
    | 1. Connects WebSocket to ws://<server>:2700
    | 2. Sends BwmaInitializeMessage with contactId
    |
Sentiment Server
    |
    | 3. Handshake: responds BEGIN AUDIO STREAM
    | 4. Receives G.711 mu-law audio frames (160 bytes, 20ms each)
    | 5. Decodes audio: G.711 -> PCM 8kHz -> resampled to 16kHz
    | 6. Accumulates 1.5s sliding window
    | 7. Runs SenseVoice AI model -> emotion + transcribed text
    | 8. Negative emotion detected -> counter++
    | 9. Counter hits threshold (default: 3) -> sends BADSENTIMENT
    |
Media Server
    |
    | 10. Receives BADSENTIMENT
    | 11. Blind transfer: BOT agent -> Human agent queue
```

---

## AI Model

**SenseVoiceSmall** — unified speech emotion + transcription model  
Source: https://github.com/FunAudioLLM/SenseVoice

- Single inference pass returns both emotion and transcribed text
- No manual threshold calibration required
- Runs on CPU — no GPU needed
- Supports English, Chinese, Japanese, Korean, Cantonese (auto-detect)
- ~70x faster than real-time

**Negative emotions (trigger counter):** angry, sad, fearful, disgusted  
**Neutral emotions (ignored):** happy, neutral, surprised

---

## Repository Structure

```
voice-sentiment/
  sentiment-server/
    sentiment_server.py          # WebSocket server, BWMA protocol handler
    audio_sentiment.py     # SenseVoice wrapper
    requirements.txt       # Python dependencies
    .env                   # Configuration
    test_ms_client.py      # Local test client (simulates Media Server)
  SenseVoiceSmall.zip      # Bundled AI model
  package-deploy.ps1       # Packages repo into deploy zip
  server-setup.ps1         # Full server install script
  clean-server.ps1         # Removes all installed components from server
  ms-integration-prompt.md # Prompt for MS-side integration
  SPEC.md                  # Full technical specification
```

---

## Configuration

Edit `sentiment-server/.env`:

```env
SERVER_INTERFACE=0.0.0.0          # bind address
SERVER_PORT=2700                  # WebSocket port
BAD_SENTIMENT_THRESHOLD=3         # negative hits before transfer
SER_DEVICE=cpu                    # cpu or cuda
```

---

## Running Locally

**Prerequisites:** Python 3.12, pip

```powershell
cd sentiment-server

# Install dependencies
python -m pip install torch torchaudio --index-url https://download.pytorch.org/whl/cpu
python -m pip install -r requirements.txt

# Start server
python sentiment_server.py
```

**Test with WAV file** (in a second terminal):

```powershell
python test_ms_client.py --wav path\to\audio_8k.wav --server ws://localhost:2700 --repeat 5
```

Expected output when BADSENTIMENT triggers:
```
[99999] Transcribed: "I am really frustrated"
[99999] Emotion: angry | negative=True
[99999] Negative emotion: angry count=3/3
*** BADSENTIMENT received: {'MessageType': 'BADSENTIMENT', 'Parameters': {'contactId': 99999}} ***
```

> WAV file must be mono, 8kHz. The test client handles resampling from other rates.

---

## Server Deployment

**Target:** Windows Server 2025, Python 3.12

### Step 1 — Package (local machine)

```powershell
.\package-deploy.ps1
# Creates voice-sentiment-deploy.zip
```

### Step 2 — Copy zip to server

Copy `voice-sentiment-deploy.zip` to the server (RDP drag-drop or scp).

### Step 3 — Install (on server)

```powershell
Expand-Archive -Path "voice-sentiment-deploy.zip" -DestinationPath "D:\deploy" -Force
cd D:\deploy

# Install torch first (large download)
C:\Python312\python.exe -m pip install torch torchaudio --index-url https://download.pytorch.org/whl/cpu

# Full setup: Python, pip deps, NSSM service, firewall
powershell -ExecutionPolicy Bypass -File server-setup.ps1
```

### Step 4 — Verify

```powershell
Get-Service VoiceSentiment
# Should show: Running

Get-Content C:\voice-sentiment\logs\sentiment_server.log -Tail 30 -Wait
# Should show: Sentiment server starting on 0.0.0.0:2700
```

---

## Service Management

```powershell
# Status
Get-Service VoiceSentiment

# Start / Stop / Restart
C:\tools\nssm\win64\nssm.exe start   VoiceSentiment
C:\tools\nssm\win64\nssm.exe stop    VoiceSentiment
C:\tools\nssm\win64\nssm.exe restart VoiceSentiment

# Live logs
Get-Content C:\voice-sentiment\logs\sentiment_server.log -Tail 50 -Wait
Get-Content C:\voice-sentiment\logs\VoiceSentiment-stderr.log -Tail 50 -Wait
```

---

## Media Server Integration

See `ms-integration-prompt.md` for the full prompt to implement the MS-side WebSocket connection and BADSENTIMENT handler.

**MS connects to:** `ws://172.28.129.220:2700`

**BADSENTIMENT message received by MS:**
```json
{
    "MessageType": "BADSENTIMENT",
    "Parameters": {
        "contactId": 12345,
        "count": 3
    }
}
```

On receipt: call `MRC.IssueBlindTransferAction()` to transfer to human agent queue.

---

## Corporate Proxy

If pip downloads fail due to TLS inspection, add trusted hosts:

```powershell
pip install <package> --trusted-host pypi.org --trusted-host files.pythonhosted.org --trusted-host pypi.python.org
```

For torch:
```powershell
pip install torch torchaudio --index-url https://download.pytorch.org/whl/cpu --trusted-host download.pytorch.org
```
