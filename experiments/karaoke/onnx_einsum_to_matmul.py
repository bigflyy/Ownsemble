"""Replaces the band-averaging Einsum "rj,bjtc->brtc" of the exported MelBand
graph by Reshape -> MatMul -> Reshape (the same arithmetic), since DirectML
refused the graph (plan 11 A5, session 65) and a re-export needs over 10 GB.

    python onnx_einsum_to_matmul.py IN.onnx OUT.onnx
"""

import sys

import numpy as np
import onnx
from onnx import helper, numpy_helper

source, target = sys.argv[1], sys.argv[2]
model = onnx.load(source)
graph = model.graph
dims = {t.name: list(t.dims) for t in graph.initializer}
new_nodes = []
replaced = 0
for node in graph.node:
    equation = next((a.s for a in node.attribute if a.name == "equation"), b"")
    if node.op_type == "Einsum" and equation.replace(b" ", b"") == b"rj,bjtc->brtc":
        average, mask = node.input
        rows, bands = dims[average]
        frames = 1101
        name = node.output[0]
        flat_shape = numpy_helper.from_array(np.array([bands, frames * 2], np.int64),
                                             name + "_flat_shape")
        out_shape = numpy_helper.from_array(np.array([1, rows, frames, 2], np.int64),
                                            name + "_out_shape")
        graph.initializer.extend([flat_shape, out_shape])
        new_nodes += [
            helper.make_node("Reshape", [mask, flat_shape.name], [name + "_flat"]),
            helper.make_node("MatMul", [average, name + "_flat"], [name + "_mm"]),
            helper.make_node("Reshape", [name + "_mm", out_shape.name], [name]),
        ]
        replaced += 1
    else:
        new_nodes.append(node)
del graph.node[:]
graph.node.extend(new_nodes)
onnx.checker.check_model(model, full_check=False)
onnx.save(model, target)
print(f"replaced {replaced} einsum")
