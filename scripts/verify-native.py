#!/usr/bin/env python3
"""Offline integration check using upstream's public JFK sample, never microphone audio."""
import array
import ctypes
import hashlib
from pathlib import Path
import wave

root = Path(__file__).resolve().parents[1]
model = root / '.build/qa-models/ggml-base.bin'
if not model.exists():
    raise SystemExit('Place the verified ggml-base.bin test model in .build/qa-models first.')
assert hashlib.file_digest(model.open('rb'), 'sha256').hexdigest() == '60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe'
lib = ctypes.CDLL(str(root / '.build/native/lib/libSMMWhisper.dylib'))
lib.smm_whisper_open.argtypes = [ctypes.c_char_p, ctypes.c_int]
lib.smm_whisper_open.restype = ctypes.c_void_p
lib.smm_whisper_close.argtypes = [ctypes.c_void_p]
lib.smm_whisper_run.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float), ctypes.c_int, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_void_p]
lib.smm_whisper_count.argtypes = [ctypes.c_void_p]
lib.smm_whisper_text.argtypes = [ctypes.c_void_p, ctypes.c_int]
lib.smm_whisper_text.restype = ctypes.c_char_p
sample = root / '.build/native/whisper-source/samples/jfk.wav'
with wave.open(str(sample)) as audio:
    assert audio.getframerate() == 16000 and audio.getnchannels() == 1 and audio.getsampwidth() == 2
    integers = array.array('h', audio.readframes(audio.getnframes()))
samples = (ctypes.c_float * len(integers))(*(x / 32768 for x in integers))
context = lib.smm_whisper_open(str(model).encode(), 1)
assert context, 'Could not load speech model'
try:
    assert lib.smm_whisper_run(context, samples, len(samples), b'en', None, None) == 0
    text = ' '.join(lib.smm_whisper_text(context, i).decode() for i in range(lib.smm_whisper_count(context)))
    assert 'country' in text.lower() and 'ask' in text.lower(), text
    print('Offline Whisper integration passed:', text.strip())
finally:
    lib.smm_whisper_close(context)
webp = ctypes.CDLL(str(root / '.build/native/lib/libwebp.dylib'))
webp.WebPEncodeRGBA.argtypes = [ctypes.POINTER(ctypes.c_ubyte), ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_float, ctypes.POINTER(ctypes.c_void_p)]
webp.WebPEncodeRGBA.restype = ctypes.c_size_t
webp.WebPFree.argtypes = [ctypes.c_void_p]
pixels = (ctypes.c_ubyte * 16)(*[255, 0, 0, 255] * 4)
output = ctypes.c_void_p()
size = webp.WebPEncodeRGBA(pixels, 2, 2, 8, 80, ctypes.byref(output))
try:
    data = ctypes.string_at(output, size)
    assert data[:4] == b'RIFF' and data[8:12] == b'WEBP'
    print('WebP integration passed:', size, 'bytes')
finally:
    webp.WebPFree(output)
