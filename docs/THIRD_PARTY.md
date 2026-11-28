# Third-party models and tools, and their licences

Ownsemble is a personal app: one user, not sold, not offered as a product. Some of the models
it downloads have no licence or a non-commercial one, and a few are republished in this
repository's GitHub releases. That is accepted for personal use (owner's decision,
2026-11-28: "public github release, but note somewhere so we could know if we ever go public
what we would need to change / which models have license issues").

Keep this file current whenever a downloaded or bundled part is added or changed. The texts
the app shows for each download live in app/lib/lyrics/stt_models.dart (the bundle notices)
and app/lib/lyrics/fit_model.dart.

## Before going public (distributing the app to others, or selling it)

These would have to change, roughly worst first:

| Part | Problem | Where it comes from | What would need doing |
|---|---|---|---|
| MelBand RoFormer InstVoc Duality V2 by Unwa (planned: karaoke without the voice on the GPU, plan 11) | No licence stated on its page (huggingface.co/pcunwa/Mel-Band-Roformer-InstVoc-Duality), so all rights stay with the author; Ownsemble republishes a converted (ONNX) copy | Our public release (planned) | Ask the author for permission, or train or pick a model with a clear licence, or fall back to Inst HQ 4 |
| MMS_FA aligner (the Fit, plan 10) | CC BY-NC 4.0: non-commercial only; republished as int8 ONNX | Our release aligner-model-1 | Fine while free and non-commercial with credit; replace before any paid use |
| Kim Vocal 2 (Hear the words, and karaoke without the voice) | No licence stated | Downloaded by the app from UVR's own repository (TRvlvr/model_repo), not republished by us | Ask the author (Kimberley Jensen) or replace before distributing |
| UVR-MDX-NET Inst HQ 4 (planned: karaoke without the voice on the CPU, plan 11) | No licence stated (UVR model) | To be downloaded from UVR's own repository, like Kim Vocal 2 | As Kim Vocal 2 |
| Trimmed ffmpeg with libx264 (planned: karaoke video export, plan 11) | GPL: whoever distributes the exe must offer its complete source; H.264 has patents (free encoders are usually tolerated for personal use) | Our release (planned) | Keep the source bundle beside the exe in the release; for a product, check the H.264 patent terms or use the encoder built into the OS |

## Clear licences (nothing to change)

- Silero VAD 6.2.1: MIT.
- GigaAM v3: MIT.
- OpenAI Whisper large-v3-turbo: MIT; whisper.cpp and ggml (CPU and Vulkan): MIT.
- ONNX Runtime (CPU and DirectML builds): MIT.
- DirectML: Microsoft's DirectML licence, which allows redistribution with an app.
- libmpv (through media_kit): the playback library; its licence comes with media_kit's build.

## The app as a whole

The app's own code has no licence file yet. Choose one before going public.
