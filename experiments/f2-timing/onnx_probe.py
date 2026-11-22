"""Plan 10 F2: what would the aligner cost inside the app?

Exports torchaudio's MMS_FA model to ONNX (the form onnxruntime runs from
Dart), makes an int8 copy, and times all three on the same audio with the
given number of threads. Then checks that the int8 model still places lines
the same: it aligns the given songs with each model and prints the offsets.

    python -I onnx_probe.py DATA_DIR WORK_DIR [--only 0,1] [--threads 4]

WORK_DIR receives the two .onnx files (about 1.2 GB and 0.3 GB). Prints only
indexes and numbers.
"""

import argparse
import json
import sys
import time
from pathlib import Path

import numpy as np
import torch
import torchaudio

sys.path.insert(0, str(Path(__file__).parent))
import timing_probe as tp  # noqa: E402


def export(work):
    """The fp32 and int8 ONNX files, made once."""
    fp32, int8 = work / "mms_fa.onnx", work / "mms_fa.int8.onnx"
    if not fp32.exists():
        wrapped = torchaudio.pipelines.MMS_FA.get_model(with_star=False).eval()

        class EmissionOnly(torch.nn.Module):
            """The bundle's model without its shape-dependent layer_norm call
            (the exporter cannot take a normalized_shape read from the input):
            the same normalization written out, then log-softmax."""

            def __init__(self, inner):
                super().__init__()
                self.inner = inner

            def forward(self, wave):
                mean = wave.mean()
                var = ((wave - mean) ** 2).mean()
                wave = (wave - mean) / torch.sqrt(var + 1e-5)
                out, _ = self.inner(wave)
                return torch.nn.functional.log_softmax(out, dim=-1)

        model = EmissionOnly(wrapped.model).eval()
        dummy = torch.randn(1, 16000 * 20)
        torch.onnx.export(
            model, (dummy,), str(fp32), input_names=["wave"],
            output_names=["emission"],
            dynamic_axes={"wave": {1: "samples"}, "emission": {1: "frames"}},
            opset_version=17, dynamo=False)
    if not int8.exists():
        from onnxruntime.quantization import QuantType, quantize_dynamic
        # Only the MatMuls (the transformer, most of the weights): the CPU
        # build has no ConvInteger for quantized convolutions.
        quantize_dynamic(str(fp32), str(int8), weight_type=QuantType.QInt8,
                         op_types_to_quantize=["MatMul"])
    return fp32, int8


class OrtEmission:
    """Emission from an ONNX file, in the same 20 s chunks as the probe."""

    def __init__(self, path, threads):
        import onnxruntime as ort
        options = ort.SessionOptions()
        options.intra_op_num_threads = threads
        self.session = ort.InferenceSession(str(path), options,
                                            providers=["CPUExecutionProvider"])

    def model(self, wave):
        out = self.session.run(["emission"], {"wave": wave.numpy()})[0]
        return torch.from_numpy(out), None


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("data")
    parser.add_argument("work")
    parser.add_argument("--only", default="0,1")
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    data, work = Path(args.data), Path(args.work)
    work.mkdir(parents=True, exist_ok=True)
    fp32, int8 = export(work)
    print(f"onnx sizes: fp32 {fp32.stat().st_size / 1e6:.0f} MB,"
          f" int8 {int8.stat().st_size / 1e6:.0f} MB")

    aligner = tp.Aligner(args.threads)
    runners = {"torch": aligner.model}
    for name, path in (("ort-fp32", fp32), ("ort-int8", int8)):
        runners[name] = OrtEmission(path, args.threads).model
    torch_model = aligner.model
    for index in [int(i) for i in args.only.split(",")]:
        song = json.loads((data / "songs" / f"{index}.json").read_text(encoding="utf-8"))
        samples = tp.decode(data / "audio" / f"{index}.mp3")
        seconds = len(samples) / tp.SAMPLE_RATE
        line = [f"#{index} {seconds:.0f}s"]
        for name, run in runners.items():
            aligner.model = run
            started = time.time()
            emission, spf = aligner.emission(samples)
            took = time.time() - started
            offsets = []
            for source, lines in song["sources"].items():
                sung = tp.sung_lines(lines)
                spans, owner = aligner.align(emission, sung)
                starts = {}
                for word_spans, line_index in zip(spans, owner):
                    starts.setdefault(line_index, word_spans[0].start * spf)
                deltas = [starts[i] - sung[i][0] for i in sorted(starts)]
                offsets.append(f"{source} {np.median(deltas):+.2f}"
                               f" within {np.mean([abs(d - np.median(deltas)) < 1 for d in deltas]):.2f}")
            line.append(f"{name} {took / seconds:.3f} s/s [{'; '.join(offsets)}]")
        aligner.model = torch_model
        print(" | ".join(line), flush=True)


if __name__ == "__main__":
    sys.exit(main())
