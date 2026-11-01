"""Convert MediaPipe's face_blendshapes.tflite (an MLP-Mixer of 1x1 convs) to ONNX, for tools/export_mediapipe.py.

tflite2onnx fails on it (scalar axis tensors, fp16 DEQUANTIZE weights). This handles exactly the ops in that
graph and raises on any other. Checked against LiteRT on 895 recorded faces: max difference 9e-6."""
import sys

import numpy as np
import onnx
import tflite
from onnx import TensorProto, helper, numpy_helper

OPS = {v: k for k, v in vars(tflite.BuiltinOperator).items() if not k.startswith("_")}
DTYPES = {tflite.TensorType.FLOAT32: np.float32, tflite.TensorType.FLOAT16: np.float16,
          tflite.TensorType.INT32: np.int32}
ACT = {tflite.ActivationFunctionType.NONE: None, tflite.ActivationFunctionType.RELU: "Relu"}


def convert(src, dst):
    buf = open(src, "rb").read()
    m = tflite.Model.GetRootAsModel(buf, 0)
    g = m.Subgraphs(0)
    name = lambda i: f"t{i}"
    consts, nodes, inits = {}, [], []

    def shape(i):
        t = g.Tensors(i)
        return [int(x) for x in t.ShapeAsNumpy()] if t.ShapeLength() else []

    for i in range(g.TensorsLength()):
        t = g.Tensors(i)
        b = m.Buffers(t.Buffer())
        if b.DataLength():
            consts[i] = np.frombuffer(b.DataAsNumpy().tobytes(), DTYPES[t.Type()]).reshape(shape(i))

    def const(i):
        return consts[i]

    def init(arr, nm):
        inits.append(numpy_helper.from_array(np.ascontiguousarray(arr), nm))
        return nm

    def inp(i):
        if i in consts and name(i) not in {x.name for x in inits}:
            a = consts[i]
            init(a.astype(np.float32) if a.dtype == np.float16 else a, name(i))
        return name(i)

    pending = []

    def act(out, a, k):
        """Fused activation: the op writes out_pre, the activation (added after the op) writes out."""
        if a is None:
            return out
        pending.append(helper.make_node(a, [out + "_pre"], [out], name=f"act{k}"))
        return out + "_pre"

    def options(op, cls):
        o = cls()
        t = op.BuiltinOptions()
        o.Init(t.Bytes, t.Pos)
        return o

    for k in range(g.OperatorsLength()):
        op = g.Operators(k)
        code = m.OperatorCodes(op.OpcodeIndex())
        kind = OPS[max(code.BuiltinCode(), code.DeprecatedBuiltinCode())]
        ins, outs = list(op.InputsAsNumpy()), list(op.OutputsAsNumpy())
        out = name(outs[0])
        if kind == "DEQUANTIZE":
            consts[outs[0]] = consts[ins[0]].astype(np.float32)
            continue
        if kind in ("ADD", "SUB", "MUL", "DIV"):
            cls = {"ADD": tflite.AddOptions, "SUB": tflite.SubOptions, "MUL": tflite.MulOptions,
                   "DIV": tflite.DivOptions}[kind]
            a = ACT[options(op, cls).FusedActivationFunction()]
            nodes.append(helper.make_node(kind.capitalize(), [inp(ins[0]), inp(ins[1])], [act(out, a, k)]))
        elif kind in ("NEG", "SQRT", "RSQRT", "LOGISTIC"):
            if kind == "RSQRT":
                nodes.append(helper.make_node("Sqrt", [inp(ins[0])], [out + "_s"]))
                nodes.append(helper.make_node("Reciprocal", [out + "_s"], [out]))
            else:
                onnx_op = {"NEG": "Neg", "SQRT": "Sqrt", "LOGISTIC": "Sigmoid"}[kind]
                nodes.append(helper.make_node(onnx_op, [inp(ins[0])], [out]))
        elif kind == "SQUARED_DIFFERENCE":
            nodes.append(helper.make_node("Sub", [inp(ins[0]), inp(ins[1])], [out + "_d"]))
            nodes.append(helper.make_node("Mul", [out + "_d", out + "_d"], [out]))
        elif kind in ("MEAN", "SUM"):
            keep = options(op, tflite.ReducerOptions).KeepDims()
            axes = init(np.atleast_1d(const(ins[1])).astype(np.int64), out + "_axes")
            onnx_op = "ReduceMean" if kind == "MEAN" else "ReduceSum"
            nodes.append(helper.make_node(onnx_op, [inp(ins[0]), axes], [out], keepdims=int(keep)))
        elif kind == "RESHAPE":
            shp = init(np.array(shape(outs[0]), np.int64), out + "_shape")
            nodes.append(helper.make_node("Reshape", [inp(ins[0]), shp], [out]))
        elif kind == "TRANSPOSE":
            nodes.append(helper.make_node("Transpose", [inp(ins[0])], [out], perm=[int(x) for x in const(ins[1])]))
        elif kind == "CONCATENATION":
            o = options(op, tflite.ConcatenationOptions)
            a = ACT[o.FusedActivationFunction()]
            nodes.append(helper.make_node("Concat", [inp(i) for i in ins], [act(out, a, k)], axis=o.Axis()))
        elif kind == "STRIDED_SLICE":
            o = options(op, tflite.StridedSliceOptions)
            if o.EllipsisMask() or o.NewAxisMask() or o.Offset():
                raise SystemExit(f"op {k}: unsupported strided slice masks")
            begin, end, strides = (const(i).astype(np.int64).copy() for i in ins[1:4])
            for ax in range(len(begin)):
                if o.BeginMask() >> ax & 1:
                    begin[ax] = 0
                if o.EndMask() >> ax & 1:
                    end[ax] = np.iinfo(np.int64).max
            shrink = [ax for ax in range(len(begin)) if o.ShrinkAxisMask() >> ax & 1]
            for ax in shrink:
                end[ax] = begin[ax] + 1
            names = [init(v, f"{out}_{n}") for v, n in ((begin, "b"), (end, "e"),
                                                        (np.arange(len(begin), dtype=np.int64), "a"),
                                                        (strides, "s"))]
            sliced = out + "_sl" if shrink else out
            nodes.append(helper.make_node("Slice", [inp(ins[0])] + names, [sliced]))
            if shrink:
                nodes.append(helper.make_node("Squeeze", [sliced, init(np.array(shrink, np.int64), out + "_sq")], [out]))
        elif kind == "CONV_2D":
            o = options(op, tflite.Conv2DOptions)
            w = const(ins[1])
            if w.shape[1:3] != (1, 1) or o.StrideH() != 1 or o.StrideW() != 1:
                raise SystemExit(f"op {k}: only 1x1 stride 1 convs are supported")
            a = ACT[o.FusedActivationFunction()]
            wn = init(w[:, 0, 0, :].T.astype(np.float32), out + "_w")  # OHWI -> I x O
            nodes.append(helper.make_node("MatMul", [inp(ins[0]), wn], [out + "_mm"]))
            nodes.append(helper.make_node("Add", [out + "_mm", inp(ins[2])], [act(out, a, k)]))
        else:
            raise SystemExit(f"op {k}: {kind} not handled")
        nodes.extend(pending)
        pending.clear()

    gi, go = g.InputsAsNumpy()[0], g.OutputsAsNumpy()[0]
    graph = helper.make_graph(nodes, "face_blendshapes", [helper.make_tensor_value_info(name(gi), TensorProto.FLOAT, shape(gi))],
                              [helper.make_tensor_value_info(name(go), TensorProto.FLOAT, shape(go))], inits)
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 18)], ir_version=9)
    onnx.checker.check_model(model)
    onnx.save(model, dst)


if __name__ == "__main__":
    convert(sys.argv[1], sys.argv[2])
