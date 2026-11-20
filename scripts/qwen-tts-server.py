#!/usr/bin/env python3
"""Local Qwen TTS service for LLM Designer, built on mlx-audio.

Stands in for the Auda service: it speaks the interface `QwenTTSClient.swift` expects on 127.0.0.1:8790.

  GET  /health            200 while the service runs
  GET  /v1/audio/voices   {"voices": [{"id", "name", "gender", "native"}, ...]}
  POST /v1/audio/speech   {"model", "input", "voice", "language", "response_format": "wav",
                           "temperature"?, "instructions"?}  ->  WAV, 24 kHz mono

Setup (Miniforge in ~/miniforge3):
  ~/miniforge3/bin/conda create -y -n qwen-tts python=3.12
  ~/miniforge3/envs/qwen-tts/bin/pip install -U mlx-audio
Start:
  ~/miniforge3/envs/qwen-tts/bin/python scripts/qwen-tts-server.py
"""

import argparse
import hashlib
import io
import json
import sys
import threading
import time
from collections import OrderedDict
from concurrent.futures import ThreadPoolExecutor
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

# The app's model names map to the MLX conversions of the CustomVoice models (the ones with the nine voices).
# 8-bit instead of bf16: about a third less memory, which matters on a 16 GB Mac next to the chat model.
MODELS = {
    "qwen3-tts-small": "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-8bit",
    "qwen3-tts-large": "mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-8bit",
}

# Same list and order as `QwenTTSClient.fallbackVoices`, so the pickers don't change once the service answers.
VOICES = [
    {"id": "serena", "name": "Serena", "gender": "female", "native": "zh"},
    {"id": "vivian", "name": "Vivian", "gender": "female", "native": "zh"},
    {"id": "ono_anna", "name": "Ono Anna", "gender": "female", "native": "ja"},
    {"id": "sohee", "name": "Sohee", "gender": "female", "native": "ko"},
    {"id": "ryan", "name": "Ryan", "gender": "male", "native": "en"},
    {"id": "aiden", "name": "Aiden", "gender": "male", "native": "en"},
    {"id": "uncle_fu", "name": "Uncle Fu", "gender": "male", "native": "zh"},
    {"id": "eric", "name": "Eric", "gender": "male", "native": "zh"},
    {"id": "dylan", "name": "Dylan", "gender": "male", "native": "zh"},
]
VOICE_IDS = {voice["id"] for voice in VOICES}

# The app sends two-letter codes; mlx-audio wants language names and silently falls back to "auto" for
# anything it doesn't know, so an unmapped "de" would quietly lose the language hint.
LANGUAGES = {
    "auto": "auto", "de": "german", "en": "english", "fr": "french", "es": "spanish", "it": "italian",
    "pt": "portuguese", "ru": "russian", "ja": "japanese", "ko": "korean", "zh": "chinese",
}

CACHE_LIMIT_BYTES = 256 * 1024 * 1024


class ServiceError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


class Speaker:
    """Owns the models. MLX binds its GPU streams to the thread that created them, so every model call runs on
    one worker thread; the HTTP threads only wait for it. That also keeps generations one at a time, which is
    all the GPU can do well next to the chat model."""

    def __init__(self):
        self.worker = ThreadPoolExecutor(max_workers=1, thread_name_prefix="mlx")
        self.loaded_name = None
        self.model = None
        self.cache = OrderedDict()
        self.cache_bytes = 0
        self.cache_lock = threading.Lock()

    def preload(self, name):
        self.worker.submit(self._load, name).result()

    def speech(self, name, text, voice, language, temperature, instructions):
        key = hashlib.sha256(json.dumps([name, text, voice, language, temperature, instructions]).encode()).hexdigest()
        with self.cache_lock:
            if key in self.cache:
                self.cache.move_to_end(key)
                return self.cache[key]
        wav = self.worker.submit(self._generate, name, text, voice, language, temperature, instructions).result()
        with self.cache_lock:
            if key not in self.cache:
                self.cache[key] = wav
                self.cache_bytes += len(wav)
                while self.cache_bytes > CACHE_LIMIT_BYTES and len(self.cache) > 1:
                    _, old = self.cache.popitem(last=False)
                    self.cache_bytes -= len(old)
        return wav

    def _load(self, name):
        if self.loaded_name == name:
            return
        import mlx.core as mx
        from mlx_audio.tts.utils import load_model

        # Only one model at a time: small and large together would take about 5 GB of unified memory.
        self.model = None
        self.loaded_name = None
        mx.clear_cache()
        started = time.monotonic()
        log(f"Lade {MODELS[name]} …")
        self.model = load_model(MODELS[name])
        self.loaded_name = name
        log(f"{name} geladen in {time.monotonic() - started:.1f} s")

    def _generate(self, name, text, voice, language, temperature, instructions):
        import numpy as np
        from mlx_audio.audio_io import write as write_audio

        self._load(name)
        started = time.monotonic()
        pieces, sample_rate = [], 24_000
        # The 0.6B model ignores `instruct` by itself; the 1.7B model uses it for the speaking style.
        for result in self.model.generate_custom_voice(
            text=text, speaker=voice, language=language, instruct=instructions, temperature=temperature
        ):
            pieces.append(np.array(result.audio, dtype=np.float32).reshape(-1))
            sample_rate = result.sample_rate
        if not pieces:
            raise ServiceError(500, "Das Modell hat kein Audio erzeugt.")
        audio = np.concatenate(pieces)
        buffer = io.BytesIO()
        write_audio(buffer, audio, sample_rate, format="wav")
        seconds = len(audio) / sample_rate
        # Only lengths go to the log, never the text itself.
        log(f"{name}/{voice}/{language}: {len(text)} Zeichen → {seconds:.1f} s Audio in {time.monotonic() - started:.1f} s")
        return buffer.getvalue()


def log(message):
    print(time.strftime("%H:%M:%S"), message, file=sys.stderr, flush=True)


def parse_speech_request(body):
    try:
        request = json.loads(body or b"{}")
    except json.JSONDecodeError:
        raise ServiceError(400, "Die Anfrage ist kein gültiges JSON.")
    if not isinstance(request, dict):
        raise ServiceError(400, "Die Anfrage muss ein JSON-Objekt sein.")

    name = request.get("model", "qwen3-tts-small")
    if name not in MODELS:
        raise ServiceError(400, f"Unbekanntes Modell „{name}“. Möglich: {', '.join(MODELS)}.")
    text = request.get("input")
    if not isinstance(text, str) or not text.strip():
        raise ServiceError(400, "Kein Text zum Sprechen.")
    voice = str(request.get("voice", "serena")).lower()
    if voice not in VOICE_IDS:
        raise ServiceError(400, f"Unbekannte Stimme „{voice}“.")
    code = str(request.get("language", "auto")).lower()
    language = LANGUAGES.get(code) or (code if code in LANGUAGES.values() else None)
    if language is None:
        raise ServiceError(400, f"Sprache „{code}“ wird nicht unterstützt.")
    if request.get("response_format", "wav") != "wav":
        raise ServiceError(400, "Nur WAV wird unterstützt.")
    temperature = request.get("temperature")
    if temperature is not None:
        if not isinstance(temperature, (int, float)):
            raise ServiceError(400, "„temperature“ muss eine Zahl sein.")
        temperature = min(max(float(temperature), 0.05), 2.0)
    instructions = request.get("instructions")
    if instructions is not None and not isinstance(instructions, str):
        raise ServiceError(400, "„instructions“ muss ein Text sein.")
    return name, text, voice, language, temperature, (instructions or None)


def make_handler(speaker):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def do_GET(self):
            if self.path == "/health":
                self._json(200, {"status": "ok", "model": speaker.loaded_name})
            elif self.path.split("?")[0] == "/v1/audio/voices":
                self._json(200, {"voices": VOICES})
            elif self.path == "/v1/models":
                self._json(200, {"object": "list", "data": [{"id": name, "object": "model"} for name in MODELS]})
            else:
                self._error(404, "Unbekannter Pfad.")

        def do_POST(self):
            if self.path != "/v1/audio/speech":
                self._error(404, "Unbekannter Pfad.")
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
                request = parse_speech_request(self.rfile.read(length))
                wav = speaker.speech(*request)
            except ServiceError as error:
                self._error(error.status, error.message)
                return
            except Exception as error:  # Model errors must reach the app as a message, not a dropped connection.
                log(f"Fehler: {type(error).__name__}: {error}")
                self._error(500, f"{type(error).__name__}: {error}")
                return
            self.send_response(200)
            self.send_header("Content-Type", "audio/wav")
            self.send_header("Content-Length", str(len(wav)))
            self.end_headers()
            try:
                self.wfile.write(wav)
            except (BrokenPipeError, ConnectionResetError):
                pass  # The app cancelled; the result stays in the cache for the next try.

        def _json(self, status, payload):
            data = json.dumps(payload, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _error(self, status, message):
            self._json(status, {"error": {"message": message}})

        def log_message(self, format, *args):
            pass  # Request lines are noise; generations are logged with their timing instead.

    return Handler


def main():
    parser = argparse.ArgumentParser(description="Qwen-TTS-Dienst für LLM Designer (mlx-audio)")
    parser.add_argument("--port", type=int, default=8790)
    parser.add_argument("--preload", choices=["small", "large", "none"], default="small",
                        help="Modell beim Start laden (lädt es beim ersten Mal von Hugging Face)")
    args = parser.parse_args()

    speaker = Speaker()
    if args.preload != "none":
        speaker.preload(f"qwen3-tts-{args.preload}")
    # Loopback only: the service is for this Mac, nothing else on the network should reach it.
    server = ThreadingHTTPServer(("127.0.0.1", args.port), make_handler(speaker))
    log(f"Qwen TTS bereit auf http://127.0.0.1:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
