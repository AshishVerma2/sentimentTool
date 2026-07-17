#!/usr/bin/env python3

import json
import os
import sys
import asyncio
import logging
import logging.handlers
import concurrent.futures

try:
    import audioop
except ImportError:
    import audioop_lts as audioop

import websockets
from dotenv import load_dotenv
from audio_sentiment import analyze_audio

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
load_dotenv()

INTERFACE               = os.environ.get('SERVER_INTERFACE', '0.0.0.0')
PORT                    = int(os.environ.get('SERVER_PORT', 2700))
BAD_SENTIMENT_THRESHOLD = int(os.environ.get('BAD_SENTIMENT_THRESHOLD', 3))
LOG_DIR                 = os.environ.get('LOG_DIR', 'logs')

# SenseVoice sliding window: 1.5s @ 16kHz 16-bit
SER_WINDOW_BYTES = 48000 * 2
SER_SLIDE_BYTES  = 16000 * 2

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
os.makedirs(LOG_DIR, exist_ok=True)

_fmt = logging.Formatter(
    '%(asctime)s [%(threadName)-12.12s] [%(levelname)-5.5s] %(name)s - %(message)s'
)
_file_handler = logging.handlers.RotatingFileHandler(
    os.path.join(LOG_DIR, 'sentiment_server.log'),
    maxBytes=10 * 1024 * 1024,
    backupCount=5,
    encoding='utf-8',
)
_file_handler.setFormatter(_fmt)
_console_handler = logging.StreamHandler(sys.stdout)
_console_handler.setFormatter(_fmt)

logging.root.handlers = []
logging.basicConfig(level=logging.INFO, handlers=[_console_handler, _file_handler])
logger = logging.getLogger('sentiment-server')

pool = concurrent.futures.ThreadPoolExecutor(max_workers=(os.cpu_count() or 1))


# ---------------------------------------------------------------------------
# Media Server BWMA mode handler
# Receives G.711 mu-law 8kHz binary frames.
# SenseVoice provides emotion detection — no external services needed.
# Sends BADSENTIMENT to MS after BAD_SENTIMENT_THRESHOLD negative hits.
# ---------------------------------------------------------------------------
async def recognize_ms(websocket, init_message_raw):
    try:
        init = json.loads(init_message_raw)
    except ValueError:
        logger.error('Invalid BwmaInitializeMessage - closing connection')
        return

    contact_id   = init.get('executionInfo', {}).get('contactId', 'unknown')
    audio_format = init.get('format', 'MONO')
    logger.info(f'MS BWMA connected: contactId={contact_id} format={audio_format}')

    await websocket.send(json.dumps({
        "Message": "BEGIN AUDIO STREAM",
        "MessageType": "COMMAND",
        "ProtocolVersion": 1,
        "Format": audio_format,
        "AgreedCapabilities": ["UTTERANCE_DETECT"],
        "Parameters": {}
    }))
    logger.info(f'[{contact_id}] BWMA handshake complete')

    bad_count    = 0
    audio_buffer = b''

    try:
        async for message in websocket:
            if not isinstance(message, bytes):
                continue

            # Decode G.711 mu-law -> 16-bit PCM @ 8kHz, resample to 16kHz
            pcm_8k     = audioop.ulaw2lin(message, 2)
            pcm_16k, _ = audioop.ratecv(pcm_8k, 2, 1, 8000, 16000, None)

            audio_buffer += pcm_16k
            if len(audio_buffer) < SER_WINDOW_BYTES:
                continue

            window       = audio_buffer[:SER_WINDOW_BYTES]
            audio_buffer = audio_buffer[SER_SLIDE_BYTES:]

            # SenseVoice: emotion + transcription in one pass
            emotion, is_negative, text = await asyncio.get_event_loop().run_in_executor(
                pool, analyze_audio, window
            )

            if text:
                logger.info(f'[{contact_id}] Transcribed: "{text}"')
            logger.info(f'[{contact_id}] Emotion: {emotion} | negative={is_negative}')

            if is_negative:
                bad_count += 1
                logger.info(
                    f'[{contact_id}] Negative emotion: {emotion} '
                    f'count={bad_count}/{BAD_SENTIMENT_THRESHOLD}'
                )
                if bad_count >= BAD_SENTIMENT_THRESHOLD:
                    bad_count = 0
                    await websocket.send(json.dumps({
                        "MessageType": "BADSENTIMENT",
                        "Parameters": {
                            "contactId": contact_id,
                            "count": BAD_SENTIMENT_THRESHOLD
                        }
                    }))
                    logger.warning(
                        f'[{contact_id}] BADSENTIMENT sent to MS - '
                        f'threshold {BAD_SENTIMENT_THRESHOLD} reached'
                    )

    except websockets.exceptions.ConnectionClosed as e:
        logger.warning(f'[{contact_id}] MS connection closed: {e}')
    except Exception as e:
        logger.error(f'[{contact_id}] Unexpected error: {e}', exc_info=True)
    finally:
        logger.info(f'[{contact_id}] MS BWMA session ended')


# ---------------------------------------------------------------------------
# Connection dispatcher
# ---------------------------------------------------------------------------
async def recognize(websocket):
    logger.info(f'New connection from {websocket.remote_address}')
    try:
        first_message = await websocket.recv()
    except websockets.exceptions.ConnectionClosed:
        logger.warning('Connection closed before first message')
        return

    if isinstance(first_message, str):
        await recognize_ms(websocket, first_message)
    else:
        logger.warning('Binary first message received - not supported, closing')
        await websocket.close()


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
async def main():
    logger.info(f'Sentiment server starting on {INTERFACE}:{PORT}')
    logger.info(f'Bad sentiment threshold: {BAD_SENTIMENT_THRESHOLD}')
    logger.info(f'Log directory         : {os.path.abspath(LOG_DIR)}')
    logger.info('SenseVoice model will load on first audio window')
    async with websockets.serve(recognize, INTERFACE, PORT, ping_timeout=120):
        await asyncio.Future()

asyncio.run(main())
