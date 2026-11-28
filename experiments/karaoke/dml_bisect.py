"""Halves the graph until it finds the first tensor that DirectML computes
differently from the CPU (plan 11 A5, session 65): for a candidate tensor the
graph's only output becomes that tensor (ONNX Runtime drops the nodes after
it), it runs on both engines, and the search goes on in the half where the
difference first passes -60 dB. Prints each step, then the bad node and its
neighbours.

    python dml_bisect.py MODEL.onnx --audio A --chunk N
"""

import argparse
import collections
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from melband_onnx import diff_db, read_chunk, start_memory_watchdog, stft_numpy  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("model")
parser.add_argument("--audio", required=True)
parser.add_argument("--chunk", type=int, default=176400)
args = parser.parse_args()
start_memory_watchdog(14)

import onnx  # noqa: E402
import onnxruntime  # noqa: E402
from onnx import TensorProto, helper, shape_inference  # noqa: E402

model = onnx.load(args.model)
types = {v.name: v.type.tensor_type.elem_type
         for v in shape_inference.infer_shapes(model).graph.value_info}
floats = [(i, node, out) for i, node in enumerate(model.graph.node) for out in node.output
          if types.get(out) == TensorProto.FLOAT]
spec = stft_numpy(read_chunk(args.audio, args.chunk))
dml = {"performance_preference": "high_performance", "device_filter": "gpu"}


def gap(index):
    """DirectML vs CPU for the graph cut at floats[index], dB, and where the
    nodes ran on DirectML."""
    _, _, name = floats[index]
    del model.graph.output[:]
    model.graph.output.append(helper.make_tensor_value_info(name, TensorProto.FLOAT, None))
    data = model.SerializeToString()
    options = onnxruntime.SessionOptions()
    options.enable_mem_pattern = False
    options.execution_mode = onnxruntime.ExecutionMode.ORT_SEQUENTIAL
    options.enable_profiling = True
    session = onnxruntime.InferenceSession(
        data, options, providers=[("DmlExecutionProvider", dml), "CPUExecutionProvider"])
    on_dml = session.run(None, {"spec": spec})[0]
    events = json.loads(Path(session.end_profiling()).read_text())
    where = collections.Counter(e["args"].get("provider") for e in events
                                if e.get("cat") == "Node" and "provider" in e.get("args", {}))
    on_cpu = onnxruntime.InferenceSession(
        data, providers=["CPUExecutionProvider"]).run(None, {"spec": spec})[0]
    energy = float(np.sum(on_cpu.astype(np.float64) ** 2))
    value = diff_db(on_cpu, on_dml) if energy > 0 else (0.0 if np.any(on_dml) else -999.0)
    return value, dict(where)


low, high = 0, len(floats) - 1
value, where = gap(high)
print(f"whole graph: {value:.1f} dB, ran on {where}", flush=True)
while high - low > 1:
    middle = (low + high) // 2
    value, where = gap(middle)
    _, node, name = floats[middle]
    print(f"[{low}..{high}] cut at {middle} ({node.op_type} {node.name[:60]}): "
          f"{value:.1f} dB, ran on {where}", flush=True)
    if value > -60:
        high = middle
    else:
        low = middle
index, node, name = floats[high]
print("FIRST BAD:", node.op_type, node.name, "inputs", list(node.input))
for attribute in node.attribute:
    print("  attribute", attribute.name, helper.get_attribute_value(attribute))
for i in range(max(0, index - 4), index + 2):
    n = model.graph.node[i]
    print(f"  node {i}: {n.op_type} {n.name} {list(n.input)} -> {list(n.output)}")
