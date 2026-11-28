"""Finds where ONNX Runtime's DirectML run of a graph first departs from its
CPU run (plan 11 A5, session 65: the MelBand graph came out at -2.5 dB from
PyTorch on DirectML).

Step "mark": writes a copy of the graph whose outputs also include every
Nth float tensor along the way (in graph order).
Step "run": runs that copy on PROVIDER (cpu or dml) and saves all outputs.
Step "compare": prints, in graph order, how far the DirectML tensors are from
the CPU ones (dB of the difference against the CPU tensor) and the node that
made each, so the first bad one shows.

    python onnx_diverge.py mark IN.onnx OUT.onnx --every 40
    python onnx_diverge.py run OUT.onnx --provider cpu|dml --audio A --chunk N
    python onnx_diverge.py compare OUT.onnx
"""

import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from melband_onnx import diff_db, read_chunk, start_memory_watchdog, stft_numpy  # noqa: E402


def mark(args):
    import onnx
    from onnx import TensorProto, helper, shape_inference

    model = onnx.load(args.source)
    inferred = shape_inference.infer_shapes(model)
    types = {v.name: v.type.tensor_type.elem_type for v in inferred.graph.value_info}
    picked = []
    floats = [(node.name, node.op_type, out) for node in model.graph.node
              for out in node.output if types.get(out) == TensorProto.FLOAT]
    for i, item in enumerate(floats):
        if i % args.every == 0:
            picked.append(item)
    for _, _, out in picked:
        model.graph.output.append(helper.make_tensor_value_info(out, TensorProto.FLOAT, None))
    onnx.save(model, args.target)
    Path(args.target + ".points.json").write_text(json.dumps(picked))
    print(f"marked {len(picked)} of {len(floats)} float tensors")


def run(args):
    import onnxruntime

    points = json.loads(Path(args.source + ".points.json").read_text())
    spec = stft_numpy(read_chunk(args.audio, args.chunk))
    options = onnxruntime.SessionOptions()
    if args.provider == "dml":
        options.enable_mem_pattern = False
        options.execution_mode = onnxruntime.ExecutionMode.ORT_SEQUENTIAL
        providers = [("DmlExecutionProvider", {"performance_preference": "high_performance",
                                               "device_filter": "gpu"}), "CPUExecutionProvider"]
    else:
        providers = ["CPUExecutionProvider"]
    session = onnxruntime.InferenceSession(args.source, options, providers=providers)
    names = ["inst"] + [out for _, _, out in points]
    results = session.run(names, {"spec": spec})
    np.savez(args.source + f".{args.provider}.npz",
             **{f"t{i}": r for i, r in enumerate(results)})
    print(f"{args.provider}: saved {len(results)} tensors")


def compare(args):
    points = json.loads(Path(args.source + ".points.json").read_text())
    cpu = np.load(args.source + ".cpu.npz")
    dml = np.load(args.source + ".dml.npz")
    labels = [("output", "inst", "inst")] + points
    for i, (node, op, out) in enumerate(labels):
        a, b = cpu[f"t{i}"], dml[f"t{i}"]
        print(f"{i:3d} {diff_db(a, b):7.1f} dB  {op:10s} {node[:70]}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("step", choices=["mark", "run", "compare"])
    parser.add_argument("source")
    parser.add_argument("target", nargs="?")
    parser.add_argument("--every", type=int, default=40)
    parser.add_argument("--provider", default="cpu")
    parser.add_argument("--audio")
    parser.add_argument("--chunk", type=int, default=176400)
    parser.add_argument("--limit-gb", type=float, default=12)
    args = parser.parse_args()
    start_memory_watchdog(args.limit_gb)
    {"mark": mark, "run": run, "compare": compare}[args.step](args)


if __name__ == "__main__":
    main()
