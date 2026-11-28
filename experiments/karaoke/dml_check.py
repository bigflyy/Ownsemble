"""One process, one chunk: the plain MelBand graph on DirectML (twice) and on
the CPU, each against the PyTorch reference, with ONNX Runtime's profile of
which engine ran each node (plan 11 A5, session 65: the timing run gave
-2.5 dB on DirectML while a debug copy matched exactly).

    python dml_check.py MODEL.onnx --audio A --chunk N
"""

import argparse
import collections
import json
import sys
import time
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).parent))
from melband_onnx import diff_db, read_chunk, start_memory_watchdog, stft_numpy  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("model")
parser.add_argument("--audio", required=True)
parser.add_argument("--chunk", type=int, default=176400)
parser.add_argument("--mem-pattern", action="store_true")
parser.add_argument("--no-fusion", action="store_true")
args = parser.parse_args()
start_memory_watchdog(12)

import onnxruntime  # noqa: E402

spec = stft_numpy(read_chunk(args.audio, args.chunk))
reference = np.load(Path(args.model).with_suffix(".ref.npy"))
options = onnxruntime.SessionOptions()
options.enable_mem_pattern = args.mem_pattern
options.execution_mode = onnxruntime.ExecutionMode.ORT_SEQUENTIAL
options.enable_profiling = True
if args.no_fusion:
    # DirectML merges the graph into fused GPU graphs; this turns that off.
    options.add_session_config_entry("ep.dml.disable_graph_fusion", "1")
options.profile_file_prefix = str(Path(args.model).with_suffix("")) + "-prof"
dml = {"performance_preference": "high_performance", "device_filter": "gpu"}
session = onnxruntime.InferenceSession(
    args.model, options, providers=[("DmlExecutionProvider", dml), "CPUExecutionProvider"])
print("providers", session.get_providers())
outs = []
for run in range(2):
    clock = time.time()
    outs.append(session.run(None, {"spec": spec})[0])
    print(f"dml run {run}: {time.time() - clock:.2f}s, vs PyTorch "
          f"{diff_db(reference, outs[-1]):.1f} dB", flush=True)
print(f"dml run 0 vs run 1: {diff_db(outs[0], outs[1]):.1f} dB")
profile = session.end_profiling()
events = json.loads(Path(profile).read_text())
where = collections.Counter(e["args"].get("provider") for e in events
                            if e.get("cat") == "Node" and "provider" in e.get("args", {}))
print("nodes run by:", dict(where))
cpu_ops = collections.Counter(e["args"].get("op_name") for e in events
                              if e.get("cat") == "Node"
                              and e.get("args", {}).get("provider") == "CPUExecutionProvider")
print("ops on the CPU:", dict(cpu_ops.most_common(12)))
Path(profile).unlink()
cpu = onnxruntime.InferenceSession(args.model, providers=["CPUExecutionProvider"])
clock = time.time()
out_cpu = cpu.run(None, {"spec": spec})[0]
print(f"cpu: {time.time() - clock:.2f}s, vs PyTorch {diff_db(reference, out_cpu):.1f} dB; "
      f"dml vs cpu {diff_db(out_cpu, outs[0]):.1f} dB")
