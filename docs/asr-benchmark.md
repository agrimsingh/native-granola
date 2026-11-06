# ASR benchmark: Apple SpeechTranscriber vs Parakeet

November 2026, Apple M5 Pro, macOS 26.7, FluidAudio 0.18.2.

## Method

`NativeGranola --benchmark asr <manifest.json> <out.json>` transcribes every clip with each engine and scores
word error rate (WER) after normalization: lowercase, punctuation stripped, contractions expanded, numbers
and ordinals spelled out (`WordErrorRate` in GranolaSpeech). WER is pooled (total errors / total reference
words) per category. Speed is audio duration divided by inference time (RTFx), excluding model loading.

- **Apple**: `SpeechTranscriber` (`.transcription` preset) through `FileTranscriber`, batch over the file. The
  live app streams with `.fastResults`, which is likely somewhat less accurate than this.
- **Parakeet v3**: `parakeet-tdt-0.6b-v3` (25 European languages), int8 encoder, Core ML/ANE.
- **Parakeet v2**: `parakeet-tdt-0.6b-v2` (English only).

Data (1,180 s, 3,047 reference words), all 16 kHz mono:

| Category | Clips | Audio | Source |
|---|---|---|---|
| librispeech-clean | 15 | 143 s | LibriSpeech test-clean, one utterance per speaker, 15–40 words |
| librispeech-other | 15 | 132 s | LibriSpeech test-other, same selection |
| librispeech-long | 1 | 600 s | 67 test-clean utterances from 9 other speakers, concatenated with 0.5 s gaps |
| tts-meeting | 4 | 153 s | Synthetic meetings: 7–8 turns, 3–4 `say` voices (US, UK, AU, IE, IN, ZA) |
| tts-meeting-noisy | 4 | 153 s | Same, plus brown noise at 12 dB SNR and a 300–3400 Hz, 8 kHz phone channel |

The TTS clips are synthetic. They have conversational wording, names and numbers, but they are cleaner and
more regular than real people talking.

## Results

| Engine | clean | other | long | meeting | meeting, noisy | All | RTFx |
|---|---|---|---|---|---|---|---|
| Apple | **1.3%** | 5.9% | **3.0%** | 1.5% | 5.2% | 3.2% | 70x |
| Parakeet v3 | 1.9% | **2.8%** | 3.1% | **0.3%** | **1.0%** | **2.3%** | 137x |
| Parakeet v2 | **1.3%** | 3.1% | 3.5% | 0.8% | 1.5% | 2.6% | 218x |

On the 10-minute clip, Parakeet runs long-form chunking at 156x (v3) and 248x (v2), with no dropped text at
chunk seams (7 deletions in 1,537 words). Its remaining errors are mostly names and archaic spellings.

Loading: the first download and Core ML compile took 87 s (v3) and 81 s (v2), with 461 MB and 443 MB on disk.
The first load after an app build takes about 13 s; after that it's about 1 s. Apple's model is part of the
OS and loads in 0.1 s.

Speaker separation (`OfflineDiarizerManager`, 22 MB of models) on the four synthetic meetings, run as split
mic/system tracks with 6% remote-voice bleed into the mic: it found 3, 2, 2 and 2 remote speakers against
true counts of 3, 2, 2 and 3. Segment-level speaker accuracy was 100%, 100%, 75% and 71%. Errors came from
merging two similar synthetic male voices into one speaker. The text echo filter removed every mic segment
that was really remote audio (4–7 per meeting).

## Decision

After a meeting, re-transcribe with **Parakeet v3**. It makes 28% fewer errors overall and about 5x fewer
on noisy meeting audio. It ties Apple on long read speech, is twice as fast, and covers more languages than
v2. Apple keeps doing the live transcript. `SpeechPreferences` defaults: re-transcribe on (v3), separate
speakers on, name speakers on (needs an xAI key).

## Reproduce

LibriSpeech from openslr.org/12, synthetic clips from `say` plus ffmpeg (scripts kept outside the repo,
in `/tmp/ng-asr`). The manifest is a JSON array of `{id, category, audio, reference}`.

```sh
open -W -n NativeGranola.app --args --benchmark asr /tmp/ng-asr/all.json /tmp/ng-asr/bench.json
open -W -n NativeGranola.app --args --benchmark pipeline system.wav mic.wav out.json --timeline turns.json
```
