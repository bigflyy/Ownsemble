"""Plan 10 I1b: an int8 copy of a GigaAM model folder (CTC or RNNT) for the CPU.

The encoder's MatMul weights become int8 (onnxruntime dynamic quantisation, the
way sherpa-onnx's GigaAM int8 builds are made); Conv and the rest stay float.
The other files (vocab.json, head.npz for RNNT) are copied as they are, and
model.json gets the new name, size and SHA-256, so gigaam_app loads the folder
like a bundled model.

    python -I quantize_gigaam.py SRC_FOLDER DST_FOLDER [--per-channel]

Env: newrag (onnx 1.19.1, onnxruntime 1.23.2).
"""

import argparse
import hashlib
import json
import shutil
from pathlib import Path

from onnxruntime.quantization import QuantType, quantize_dynamic


def sha256_of(path):
    """SHA-256 hex digest of a file, read in 1 MB blocks."""
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1 << 20), b""):
            digest.update(block)
    return digest.hexdigest()


def unfold_fp16_weights(source, target):
    """Write an fp32 copy of an encoder whose weights are stored as fp16.

    GigaAmTranscriber's encoders keep each weight as an fp16 initializer followed
    by Cast(to=float), so the quantiser finds no float MatMul weights. Each such
    Cast is replaced by an fp32 initializer under the Cast's output name.
    """
    import numpy as np
    import onnx
    from onnx import numpy_helper

    model = onnx.load(str(source))
    graph = model.graph
    inits = {init.name: init for init in graph.initializer}
    kept, unfolded = [], 0
    for node in graph.node:
        to = next((attr.i for attr in node.attribute if attr.name == "to"), None)
        source_init = inits.get(node.input[0]) if node.op_type == "Cast" and node.input else None
        if (source_init is not None and source_init.data_type == onnx.TensorProto.FLOAT16
                and to == onnx.TensorProto.FLOAT):
            values = numpy_helper.to_array(source_init).astype(np.float32)
            graph.initializer.append(numpy_helper.from_array(values, node.output[0]))
            unfolded += 1
        else:
            kept.append(node)
    del graph.node[:]
    graph.node.extend(kept)
    used = {name for node in graph.node for name in node.input}
    unused = [init for init in graph.initializer if init.name not in used]
    for init in unused:
        graph.initializer.remove(init)
    onnx.save(model, str(target))
    print(f"unfolded {unfolded} fp16 weights, dropped {len(unused)} unused")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("src", type=Path)
    parser.add_argument("dst", type=Path)
    parser.add_argument("--per-channel", action="store_true")
    args = parser.parse_args()

    meta = json.loads((args.src / "model.json").read_text(encoding="utf-8"))
    args.dst.mkdir(parents=True, exist_ok=True)
    for key, entry in meta["files"].items():
        source = args.src / entry["name"]
        target = args.dst / entry["name"]
        if key == "encoder":
            fp32 = args.dst / "encoder-fp32.tmp.onnx"
            unfold_fp16_weights(source, fp32)
            # MatMul only: ConvInteger is slow or missing on several providers.
            quantize_dynamic(str(fp32), str(target), weight_type=QuantType.QInt8,
                             op_types_to_quantize=["MatMul"], per_channel=args.per_channel)
            fp32.unlink()
        else:
            shutil.copyfile(source, target)
        entry["size"] = target.stat().st_size
        entry["sha256"] = sha256_of(target)
        print(f"{key}: {entry['name']} {entry['size'] / 1e6:.1f} MB")
    meta["name"] = args.dst.name
    (args.dst / "model.json").write_text(json.dumps(meta, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
