"""Moves every Constant node's value into the graph's initializers.

ONNX Runtime 1.23 keeps large Constant values as in-memory external data;
its shape inference for Split then fails ("Cannot parse data from external
tensors", plan 11 A5, session 65). As initializers they load normally.

    python onnx_constants.py IN.onnx OUT.onnx
"""

import sys

import onnx
from onnx import numpy_helper

source, target = sys.argv[1], sys.argv[2]
model = onnx.load(source)
graph = model.graph
kept = []
moved = 0
for node in graph.node:
    if node.op_type == "Constant" and len(node.attribute) == 1 \
            and node.attribute[0].name == "value":
        tensor = numpy_helper.from_array(
            numpy_helper.to_array(node.attribute[0].t), node.output[0])
        graph.initializer.append(tensor)
        moved += 1
    else:
        kept.append(node)
del graph.node[:]
graph.node.extend(kept)
# Einsum equations written with spaces (einops style, "b h i d, b h j d ->
# b h i j"): DirectML rejects them ("The parameter is incorrect").
spaced = 0
for node in graph.node:
    if node.op_type == "Einsum":
        for attribute in node.attribute:
            if attribute.name == "equation" and b" " in attribute.s:
                attribute.s = attribute.s.replace(b" ", b"")
                spaced += 1
print(f"einsum equations without spaces: {spaced}")
onnx.save(model, target)
print(f"moved {moved} constants; {len(kept)} nodes left")
