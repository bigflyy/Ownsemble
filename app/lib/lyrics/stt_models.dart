/// The files "Hear the words" downloads on first use (plan 10 I2a; user
/// 2026-11-24, session 51: "upload everything in ownsemble except kim for
/// now"). Sizes and SHA-256 are written here, in the app, never taken
/// from the server.
///
/// Generated from the research copies (.local/v2-tools/stt-models,
/// sep-models) and GigaAmTranscriber's whisper.cpp build record; each
/// DLL's size and hash equal that record's.
library;

import 'fit_model.dart';
import 'model_bundle.dart';

/// Ownsemble's release that holds the files no one else publishes.
const sttReleaseBase =
    'https://github.com/bigflyy/Ownsemble/releases/download/stt-models-1/';

Uri _release(String asset) => Uri.parse('$sttReleaseBase$asset');

/// Room a job needs besides the models: the song decoded and its vocals
/// kept between stages (a 6 min song: about 130 MB as 44.1 kHz stereo
/// floats, 23 MB as 16 kHz vocals).
const sttWorkingBytes = 300 * 1000 * 1000;

/// The setting that keeps the CPU thread count of every model, chosen once
/// per PC (plan 10 I2c: the words depend on it).
const sttThreadsSetting = 'stt.threads';

/// What every heard song needs: MDX-Net Kim Vocal 2 (vocals), Silero VAD
/// (where the singing is) and GigaAM v3 RNNT int8 (Russian words, and the
/// confidence that says whether the song is Russian).
final hearWordsBundle = ModelBundle(
  name: 'hear-words',
  version: 1,
  files: [
    ModelFile(
      url: Uri.parse(
        'https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/Kim_Vocal_2.onnx',
      ),
      bytes: 66759214,
      sha256:
          'ce74ef3b6a6024ce44211a07be9cf8bc6d87728cc852a68ab34eb8e58cde9c8b',
      fileName: 'Kim_Vocal_2.onnx',
    ),
    ModelFile(
      url: _release('silero_vad_scan.onnx'),
      bytes: 1289833,
      sha256:
          '6cb8421514828dcaa42ceea48766d4fa0caef035f15c8672d4ce9c105a64fd5d',
      fileName: 'silero_vad_scan.onnx',
    ),
    ModelFile(
      url: _release('v3_e2e_rnnt_int8.model.json'),
      bytes: 644,
      sha256:
          'acd812f672acc6234c830d5795d44e87ac4f5ef8fe4c72e3be430e815778e539',
      fileName: 'gigaam/model.json',
    ),
    ModelFile(
      url: _release('v3_e2e_rnnt_int8.vocab.json'),
      bytes: 12406,
      sha256:
          '260c932355adc98a7440d49887f72a2fca42256971ad07a4e91265e93859ff69',
      fileName: 'gigaam/vocab.json',
    ),
    ModelFile(
      url: _release('v3_e2e_rnnt_int8.head.npz'),
      bytes: 7307660,
      sha256:
          '6c9c5c0631be839a71ef07926ca2b7a90f14254d5db58cf30319267e1ea637a8',
      fileName: 'gigaam/head.npz',
    ),
    ModelFile(
      url: _release('v3_e2e_rnnt_int8.encoder.onnx'),
      bytes: 319791534,
      sha256:
          'd9ee90d6b4f3461cf457b8e497b3fdeee01083c1f70fae06b4d7ae6037f0a32f',
      fileName: 'gigaam/encoder.onnx',
    ),
  ],
  notices: r'''
Ownsemble "Hear the words": model files and their licences

Kim_Vocal_2.onnx
  MDX-Net vocal separation model "Kim Vocal 2" by Kimberley Jensen
  (KimberleyJSN), as distributed with Ultimate Vocal Remover (UVR).
  Downloaded from UVR's own model repository:
  https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/Kim_Vocal_2.onnx
  No licence is stated for these weights. Ownsemble does not redistribute
  them: the app fetches this file from that address for your own use.

silero_vad_scan.onnx
  Silero VAD 6.2.1 (https://github.com/snakers4/silero-vad), MIT licence,
  Copyright (c) 2020-present Silero Team. The unchanged 16 kHz model wrapped
  in an ONNX Scan loop by GigaAM Transcriber's tools/make_silero_scan.py.
  From https://github.com/bigflyy/Ownsemble/releases/tag/stt-models-1

gigaam/encoder.onnx, gigaam/head.npz, gigaam/vocab.json, gigaam/model.json
  GigaAM v3 end-to-end RNNT (https://github.com/salute-developers/GigaAM),
  MIT licence, Copyright (c) 2024 GigaChat Team. Exported to ONNX by GigaAM
  Transcriber's tools/export_models.py; the encoder's MatMul weights
  quantized to int8 by Ownsemble's experiments/f2-timing/quantize_gigaam.py.
  From https://github.com/bigflyy/Ownsemble/releases/tag/stt-models-1

MIT licence text (Silero VAD, GigaAM):
  Permission is hereby granted, free of charge, to any person obtaining a
  copy of this software and associated documentation files (the
  "Software"), to deal in the Software without restriction, including
  without limitation the rights to use, copy, modify, merge, publish,
  distribute, sublicense, and/or sell copies of the Software, and to permit
  persons to whom the Software is furnished to do so, subject to the
  following conditions: The above copyright notice and this permission
  notice shall be included in all copies or substantial portions of the
  Software. THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
  EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
  MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN
  NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM,
  DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR
  OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE
  USE OR OTHER DEALINGS IN THE SOFTWARE.
''',
);

/// Whisper large-v3-turbo for songs GigaAM is not sure of, with the
/// whisper.cpp 1.9.5 CPU libraries it runs on (no Vulkan: CPU only).
final whisperBundle = ModelBundle(
  name: 'whisper-turbo',
  version: 1,
  files: [
    ModelFile(
      url: _release('ggml-large-v3-turbo-q5_0.bin'),
      bytes: 574041195,
      sha256:
          '394221709cd5ad1f40c46e6031ca61bce88931e6e088c188294c6d5a55ffa7e2',
      fileName: 'ggml-large-v3-turbo-q5_0.bin',
      mirrors: [
        Uri.parse(
          'https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-large-v3-turbo-q5_0.bin',
        ),
      ],
    ),
    ModelFile(
      url: _release('whisper.cpp-1.9.5.LICENSE.txt'),
      bytes: 1078,
      sha256:
          '94f29bbed6a22c35b992c5c6ebf0e7c92f13b836b90f36f461c9cf2f0f1d010d',
      fileName: 'whisper.cpp/LICENSE.txt',
    ),
    ModelFile(
      url: _release('whisper.cpp-1.9.5.ggml-base.dll'),
      bytes: 674304,
      sha256:
          'eb7b4b3dea5818b42df25848f380ab63cdc0ce650c6cf514bb7ee25ba4615c7b',
      fileName: 'whisper.cpp/ggml-base.dll',
    ),
    ModelFile(
      url: _release('whisper.cpp-1.9.5.ggml-cpu-alderlake.dll'),
      bytes: 1006080,
      sha256:
          '83bda326ca8a60dddb134af5c871202abbe50278796eaba02c32bcd3651ae9d8',
      fileName: 'whisper.cpp/ggml-cpu-alderlake.dll',
    ),
    ModelFile(
      url: _release('whisper.cpp-1.9.5.ggml-cpu-cannonlake.dll'),
      bytes: 1048576,
      sha256:
          '9cbdce34eb067c48acc3f7ad753ce4b1930dc2aca366f9812f5a741d43512b83',
      fileName: 'whisper.cpp/ggml-cpu-cannonlake.dll',
    ),
    ModelFile(
      url: _release('whisper.cpp-1.9.5.ggml-cpu-cascadelake.dll'),
      bytes: 1047040,
      sha256:
          'f8e14a8a953ce3d6b63fb168d2e4d7eaf2cd030ebd736bd8155626ac7417bddc',
      fileName: 'whisper.cpp/ggml-cpu-cascadelake.dll',
    ),
    ModelFile(
      url: _release('whisper.cpp-1.9.5.ggml-cpu-haswell.dll'),
      bytes: 1007104,
      sha256:
          '66c66abed7650c03d147db8565344caa4901a6e00129df13dd9d7aecfd609438',
      fileName: 'whisper.cpp/ggml-cpu-haswell.dll',
    ),
    ModelFile(
      url: _release('whisper.cpp-1.9.5.ggml-cpu-icelake.dll'),
      bytes: 1047040,
      sha256:
          'c2328cf573ecaae505ed430d58fdcfde5ea19b16192140197069e652b9003e3a',
      fileName: 'whisper.cpp/ggml-cpu-icelake.dll',
    ),
    ModelFile(
      url: _release('whisper.cpp-1.9.5.ggml-cpu-sandybridge.dll'),
      bytes: 1002496,
      sha256:
          '6d0b12c5ea09cbae727a8657bc34c1af49b2fdfb3fc100ba63c57dae6e657d8c',
      fileName: 'whisper.cpp/ggml-cpu-sandybridge.dll',
    ),
    ModelFile(
      url: _release('whisper.cpp-1.9.5.ggml-cpu-skylakex.dll'),
      bytes: 1048576,
      sha256:
          'ae4cbfc1716a230f039d51e11eb7ee987e9066975432b1b03f255f1ece761d35',
      fileName: 'whisper.cpp/ggml-cpu-skylakex.dll',
    ),
    ModelFile(
      url: _release('whisper.cpp-1.9.5.ggml-cpu-sse42.dll'),
      bytes: 839680,
      sha256:
          '1130ea7410bae80d55063cb8b3270beff5d1eafa17ba2e902e96b985a8c751b5',
      fileName: 'whisper.cpp/ggml-cpu-sse42.dll',
    ),
    ModelFile(
      url: _release('whisper.cpp-1.9.5.ggml-cpu-x64.dll'),
      bytes: 840704,
      sha256:
          '38a7153e60e12c6f61dd7e4eecf789536293f547d46110e89d4a0dbfb6554a56',
      fileName: 'whisper.cpp/ggml-cpu-x64.dll',
    ),
    ModelFile(
      url: _release('whisper.cpp-1.9.5.ggml.dll'),
      bytes: 61440,
      sha256:
          'bc1d2c5f5e0e3cfe275535249eca34b74ebea8e3d702a6761078e5dc634ee053',
      fileName: 'whisper.cpp/ggml.dll',
    ),
    ModelFile(
      url: _release('whisper.cpp-1.9.5.whisper.dll'),
      bytes: 1312768,
      sha256:
          'af0ba171c462b543ce9797a8571b5d6617fb2708d3fc00e3f2ed6014d363c792',
      fileName: 'whisper.cpp/whisper.dll',
    ),
    ModelFile(
      url: _release('whisper.cpp-1.9.5.build-info.json'),
      bytes: 2807,
      sha256:
          '82206a7f0f3a5e5c4158cf3e6762f26267e358a2df6946e450704152c9d0d6a4',
      fileName: 'whisper.cpp/build-info.json',
    ),
  ],
  notices: r'''
Ownsemble "Hear the words": Whisper files and their licences

ggml-large-v3-turbo-q5_0.bin
  OpenAI Whisper large-v3-turbo, MIT licence, Copyright (c) 2022 OpenAI;
  the q5_0 ggml conversion published by the whisper.cpp project
  (https://huggingface.co/ggerganov/whisper.cpp, commit
  5359861c739e955e79d9a303bcbc70fb988958b1). From
  https://github.com/bigflyy/Ownsemble/releases/tag/stt-models-1, with
  Hugging Face as the second address.

whisper.cpp/*.dll, whisper.cpp/LICENSE.txt, whisper.cpp/build-info.json
  whisper.cpp 1.9.5 and ggml (https://github.com/ggml-org/whisper.cpp), MIT
  licence (whisper.cpp/LICENSE.txt), Copyright (c) 2023-2026 The ggml
  authors. Built for Windows x64 (CPU backends only) by GigaAM
  Transcriber's tools/build_whisper_cpp.py from the v1.9.5 source with one
  patch, "one-encoder-pass-auto-language"; build-info.json records the
  source, options and every file's SHA-256.
  From https://github.com/bigflyy/Ownsemble/releases/tag/stt-models-1
''',
);
