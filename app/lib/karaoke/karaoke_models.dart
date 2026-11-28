/// The model the karaoke export uses to take the voice out on the CPU
/// (plan 11 D1d; user 2026-11-28: "for cpu we can use small models"):
/// UVR-MDX-NET Inst HQ 4, fetched from UVR's own model repository like Kim
/// Vocal 2, with its size and SHA-256 written here, never taken from the
/// server.
library;

import '../lyrics/fit_model.dart';
import '../lyrics/model_bundle.dart';

/// The model file's name inside the bundle folder.
const instHq4FileName = 'UVR-MDX-NET-Inst_HQ_4.onnx';

final karaokeInstBundle = ModelBundle(
  name: 'karaoke-inst',
  version: 1,
  files: [
    ModelFile(
      url: Uri.parse(
        'https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/UVR-MDX-NET-Inst_HQ_4.onnx',
      ),
      bytes: 59074342,
      sha256:
          '3c4b5b9b05090fdf238f38ba5046813982d50e2a652e9cb3324ea79720c3c9c8',
      fileName: instHq4FileName,
    ),
  ],
  notices: karaokeInstNotice,
);

/// What the app says about the model (also in its licence notices).
const karaokeInstNotice = r'''
Ownsemble karaoke video export: the voice remover

UVR-MDX-NET-Inst_HQ_4.onnx
  MDX-Net instrumental model "Inst HQ 4" from Ultimate Vocal Remover (UVR,
  https://github.com/Anjok07/ultimatevocalremovergui).
  Downloaded from UVR's own model repository:
  https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/UVR-MDX-NET-Inst_HQ_4.onnx
  No licence is stated for these weights. Ownsemble does not redistribute
  them: the app fetches this file from that address for your own use.
''';
