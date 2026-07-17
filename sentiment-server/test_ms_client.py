#!/usr/bin/env python3
"""
Test client simulating Media Server BWMA WebSocket connection.
Usage:
    python test_ms_client.py                     # handshake only (silence frames)
    python test_ms_client.py --wav path/to.wav   # stream real audio from WAV file
    python test_ms_client.py --repeat 5          # repeat audio N times to hit threshold
"""

import asyncio
import json
import sys
import wave
import argparse
import struct

try:
    import audioop
except ImportError:
    # Python 3.13+ — audioop removed, use audioop-lts
    import audioop_lts as audioop  # pip install audioop-lts

import websockets

STT_SERVER_URL = "ws://172.28.129.220:2700"
CONTACT_ID = 99999
FRAME_SIZE = 160          # 160 bytes = 20ms of G.711 at 8kHz
FRAME_INTERVAL = 0.02     # 20ms between frames

BWMA_INIT = {
    "minimumVersion": 0,
    "maximumVersion": 1,
    "capabilities": ["UTTERANCE_DETECT"],
    "requiredCapabilities": ["UTTERANCE_DETECT"],
    "format": "MONO",
    "executionInfo": {
        "contactId": CONTACT_ID,
        "busNo": 1,
        "requestId": 1,
        "actionId": 0,
        "actionType": "WebSocketRelay",
        "scriptName": "test_script"
    },
    "systemTelemetryData": {
        "consumerProcessHost": "localhost",
        "consumerProcessName": "test_ms_client",
        "consumerProcessVersion": "1.0.0"
    },
    "appConfig": {},
    "appParams": {},
    "authenticationToken": "test-token",
    "streamsConfiguration": None,
    "streamPerspective": "TX_RELAY"
}


def read_wav_as_g711(wav_path: str) -> bytes:
    """Read WAV file and encode to G.711 mu-law at 8kHz."""
    with wave.open(wav_path, 'rb') as wf:
        src_rate = wf.getframerate()
        channels = wf.getnchannels()
        sampwidth = wf.getsampwidth()
        raw = wf.readframes(wf.getnframes())

    # Mix down to mono if stereo
    if channels == 2:
        raw = audioop.tomono(raw, sampwidth, 0.5, 0.5)

    # Resample to 8kHz if needed
    if src_rate != 8000:
        raw, _ = audioop.ratecv(raw, sampwidth, 1, src_rate, 8000, None)

    # Convert to 16-bit if needed
    if sampwidth != 2:
        raw = audioop.lin2lin(raw, sampwidth, 2)

    # Encode to G.711 mu-law
    return audioop.lin2ulaw(raw, 2)


def generate_silence_g711(seconds: float) -> bytes:
    """Generate G.711 mu-law encoded silence."""
    num_samples = int(8000 * seconds)
    pcm_silence = b'\x00' * (num_samples * 2)   # 16-bit silence
    return audioop.lin2ulaw(pcm_silence, 2)


async def run_test(wav_path=None, repeat=1, server_url=STT_SERVER_URL):
    print(f"Connecting to {server_url} ...")
    async with websockets.connect(server_url) as ws:

        # Step 1: Send BwmaInitializeMessage
        print("Sending BwmaInitializeMessage ...")
        await ws.send(json.dumps(BWMA_INIT))

        # Step 2: Expect BEGIN AUDIO STREAM
        response_raw = await asyncio.wait_for(ws.recv(), timeout=10)
        response = json.loads(response_raw)
        if response.get("Message") == "BEGIN AUDIO STREAM":
            print(f"Handshake OK: {response}")
        else:
            print(f"UNEXPECTED handshake response: {response}")
            return

        # Step 3: Prepare audio
        if wav_path:
            print(f"Loading WAV: {wav_path}")
            g711_audio = read_wav_as_g711(wav_path) * repeat
        else:
            print("No WAV provided — streaming 10 seconds of silence")
            g711_audio = generate_silence_g711(10.0)

        total_frames = len(g711_audio) // FRAME_SIZE
        print(f"Streaming {total_frames} frames ({total_frames * FRAME_INTERVAL:.1f}s) ...")

        # Step 4: Stream audio frames while listening for server messages
        async def stream_audio():
            for i in range(total_frames):
                frame = g711_audio[i * FRAME_SIZE:(i + 1) * FRAME_SIZE]
                await ws.send(frame)
                await asyncio.sleep(FRAME_INTERVAL)
            print("Audio stream complete.")

        async def listen_for_messages():
            try:
                async for msg in ws:
                    if isinstance(msg, str):
                        data = json.loads(msg)
                        msg_type = data.get("MessageType", "")
                        if msg_type == "BADSENTIMENT":
                            print(f"\n*** BADSENTIMENT received from server: {data} ***\n")
                        else:
                            print(f"Server text message: {data}")
            except websockets.exceptions.ConnectionClosed:
                pass

        await asyncio.gather(stream_audio(), listen_for_messages())

        # Send EOF
        await ws.send('{"eof" : 1}')
        print("EOF sent. Test complete.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Test MS BWMA WebSocket client")
    parser.add_argument("--wav", help="Path to WAV audio file to stream")
    parser.add_argument("--repeat", type=int, default=1,
                        help="Repeat audio N times (to trigger threshold)")
    parser.add_argument("--server", default=STT_SERVER_URL,
                        help=f"STT server URL (default: {STT_SERVER_URL})")
    args = parser.parse_args()

    asyncio.run(run_test(wav_path=args.wav, repeat=args.repeat, server_url=args.server))
