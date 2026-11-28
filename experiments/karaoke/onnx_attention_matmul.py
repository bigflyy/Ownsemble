"""Replaces the attention Einsums of the exported MelBand graph by MatMul
(plan 11 A5, session 65: DirectML ran the graph but its output was -2.5 dB
from PyTorch while the CPU matched; the separation library itself avoids
einsum on DirectML for the same attention):

    "bhid,bhjd->bhij"  ->  MatMul(q, Transpose(k, [0, 1, 3, 2]))
    "bhij,bhjd->bhid"  ->  MatMul(attn, v)

    python onnx_attention_matmul.py IN.onnx OUT.onnx
"""

import sys

import onnx
from onnx import helper

source, target = sys.argv[1], sys.argv[2]
model = onnx.load(source)
nodes = []
counts = {"scores": 0, "values": 0, "left": 0}
for node in model.graph.node:
    equation = next((a.s for a in node.attribute if a.name == "equation"), b"")
    equation = equation.replace(b" ", b"")
    if node.op_type == "Einsum" and equation == b"bhid,bhjd->bhij":
        q, k = node.input
        k_t = node.output[0] + "_kT"
        nodes += [helper.make_node("Transpose", [k], [k_t], perm=[0, 1, 3, 2]),
                  helper.make_node("MatMul", [q, k_t], [node.output[0]])]
        counts["scores"] += 1
    elif node.op_type == "Einsum" and equation == b"bhij,bhjd->bhid":
        nodes.append(helper.make_node("MatMul", list(node.input), [node.output[0]]))
        counts["values"] += 1
    else:
        if node.op_type == "Einsum":
            counts["left"] += 1
            print("left as is:", equation)
        nodes.append(node)
del model.graph.node[:]
model.graph.node.extend(nodes)
onnx.save(model, target)
print(counts)
