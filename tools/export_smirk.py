"""Dev tool: export SMIRK's expression encoder to ONNX and ncnn.

Run: uv run python tools/export_smirk.py
Needs the dev dependency group (torch, timm, pnnx) and models/research/smirk/smirk_encoder.pt.
"""

import subprocess
import sys
from pathlib import Path

import timm
import torch
import torch.nn.functional as F
from torch import nn

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
from facecap.research.smirk import INPUT_SIZE, N_EXP, SMIRK_DIR  # noqa: E402


class ExpressionEncoder(nn.Module):
    # Same layout as smirk/src/smirk_encoder.py so the state dict loads as is.
    def __init__(self):
        super().__init__()
        self.encoder = timm.create_model(
            "tf_mobilenetv3_large_minimal_100", pretrained=False, features_only=True
        )
        feature_dim = self.encoder.feature_info[-1]["num_chs"]
        self.expression_layers = nn.Sequential(nn.Linear(feature_dim, N_EXP + 2 + 3))

    def forward(self, img):
        features = self.encoder(img)[-1]
        features = F.adaptive_avg_pool2d(features, (1, 1)).flatten(1)
        return self.expression_layers(features)


def main() -> None:
    state = torch.load(SMIRK_DIR / "smirk_encoder.pt", map_location="cpu", weights_only=True)
    prefix = "expression_encoder."
    model = ExpressionEncoder()
    model.load_state_dict({k[len(prefix):]: v for k, v in state.items() if k.startswith(prefix)})
    model.eval()

    onnx_path = SMIRK_DIR / "smirk_expression.onnx"
    dummy = torch.rand(1, 3, INPUT_SIZE, INPUT_SIZE)
    torch.onnx.export(model, dummy, onnx_path, input_names=["in0"], output_names=["out0"],
                      opset_version=17, dynamo=False)
    print(f"wrote {onnx_path}")

    subprocess.run(
        ["pnnx", onnx_path.name, f"inputshape=[1,3,{INPUT_SIZE},{INPUT_SIZE}]"],
        cwd=SMIRK_DIR, check=True, stdout=subprocess.DEVNULL,
    )
    for p in sorted(SMIRK_DIR.glob("smirk_expression.ncnn.*")):
        print(f"wrote {p}")


if __name__ == "__main__":
    main()
