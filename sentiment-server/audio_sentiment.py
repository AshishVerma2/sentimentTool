#!/usr/bin/env python3
"""
Acoustic emotion + transcription using SenseVoice (iic/SenseVoiceSmall).
https://github.com/FunAudioLLM/SenseVoice

Single inference pass returns both transcribed text and emotion label.
Model downloads automatically on first run (~300MB, cached locally).
Runs on CPU - no GPU required.
"""

import os
import logging
import numpy as np

logger = logging.getLogger('audio-sentiment')

DEVICE     = os.environ.get('SER_DEVICE', 'cpu')
# Local model path — set to folder containing model.pt + config.yaml.
# Falls back to ModelScope download if not set or not found.
MODEL_PATH = os.environ.get('SENSEVOICE_MODEL_PATH', '')

NEGATIVE_EMOTIONS = {'angry', 'sad', 'fearful', 'disgusted'}

_model = None

_EMOTION_TAGS = {
    '<|ANGRY|>':     'angry',
    '<|SAD|>':       'sad',
    '<|FEARFUL|>':   'fearful',
    '<|DISGUSTED|>': 'disgusted',
    '<|HAPPY|>':     'happy',
    '<|NEUTRAL|>':   'neutral',
    '<|SURPRISED|>': 'surprised',
}

# Strip all SenseVoice control tags from transcription output
_ALL_TAGS = list(_EMOTION_TAGS.keys()) + [
    '<|zh|>', '<|en|>', '<|yue|>', '<|ja|>', '<|ko|>', '<|nospeech|>',
    '<|EMO_UNKNOWN|>', '<|NEUTRAL|>', '<|withitn|>', '<|woitn|>',
    '<|BGM|>', '<|Speech|>', '<|Applause|>', '<|Laughter|>',
]


def _get_model():
    global _model
    if _model is None:
        try:
            from funasr import AutoModel

            # Resolve model source: local path > env var > ModelScope download
            script_dir   = os.path.dirname(os.path.abspath(__file__))
            local_default = os.path.join(script_dir, 'SenseVoiceSmall')

            if MODEL_PATH and os.path.isdir(MODEL_PATH):
                model_src = MODEL_PATH
            elif os.path.isdir(local_default):
                model_src = local_default
            else:
                model_src = 'iic/SenseVoiceSmall'

            logger.info(f'Loading SenseVoiceSmall from: {model_src}')
            _model = AutoModel(
                model=model_src,
                trust_remote_code=True,
                device=DEVICE,
                disable_update=True,
            )
            logger.info('SenseVoiceSmall loaded')
        except Exception as e:
            logger.error(f'Failed to load SenseVoiceSmall: {e}', exc_info=True)
            raise
    return _model


def analyze_audio(pcm_16k_bytes: bytes) -> tuple:
    """
    Run SenseVoice on raw 16-bit signed PCM at 16kHz (mono).
    Returns (label: str, is_negative: bool, text: str).
    label: 'angry','sad','fearful','disgusted','happy','neutral','surprised','neutral'
    text:  transcribed speech (tags stripped)
    """
    try:
        model = _get_model()

        samples = np.frombuffer(pcm_16k_bytes, dtype=np.int16).astype(np.float32) / 32768.0

        if len(samples) < 16000 * 0.3:
            return 'neutral', False, ''

        res = model.generate(
            input=samples,
            cache={},
            language='auto',
            use_itn=False,
            ban_emo_unk=True,
        )

        raw_text = res[0]['text'] if res else ''

        # Extract emotion
        label = 'neutral'
        for tag, name in _EMOTION_TAGS.items():
            if tag in raw_text:
                label = name
                break

        # Strip all control tags to get clean transcription
        clean_text = raw_text
        for tag in _ALL_TAGS:
            clean_text = clean_text.replace(tag, '')
        clean_text = clean_text.strip()

        is_negative = label in NEGATIVE_EMOTIONS

        logger.debug(
            f'SER: label={label} negative={is_negative} '
            f'text="{clean_text[:60]}" raw="{raw_text[:80]}"'
        )
        return label, is_negative, clean_text

    except Exception as e:
        logger.error(f'analyze_audio error: {e}', exc_info=True)
        return 'neutral', False, ''


def classify_emotion(pcm_16k_bytes: bytes) -> tuple:
    """Backward-compat wrapper. Returns (label, is_negative)."""
    label, is_negative, _ = analyze_audio(pcm_16k_bytes)
    return label, is_negative
