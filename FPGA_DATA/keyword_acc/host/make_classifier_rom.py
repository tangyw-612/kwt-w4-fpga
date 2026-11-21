"""从提交版分类头生成板端定点系数。"""

import json
from pathlib import Path


DATA = Path(__file__).resolve().parents[1] / "data"
LABELS = ("_silence_", "_unknown_", "yes", "no", "up", "down", "left", "right", "on", "off", "stop", "go")
WEIGHT_FRAC = 24
INPUT_FRAC = 20


def coefficients():
    head = json.loads((DATA / "classification_head.json").read_text(encoding="utf-8"))
    if tuple(head["labels"]) != LABELS or len(head["head_w"]) != 64 or len(head["head_b"]) != 12:
        raise ValueError("分类头结构或类别顺序不一致")
    weights = tuple(tuple(round(value * (1 << WEIGHT_FRAC)) for value in row)
                    for row in zip(*head["head_w"], strict=True))
    bias = tuple(round(value * (1 << (INPUT_FRAC + WEIGHT_FRAC))) for value in head["head_b"])
    if len(weights) != 12 or any(not -(1 << 23) <= value < (1 << 23) for row in weights for value in row):
        raise ValueError("分类头权重超出 24 位表示范围")
    return weights, bias


def main():
    weights, bias = coefficients()
    (DATA / "w4_cls_weights.mem").write_text(
        "".join(f"{value & 0xffffff:06x}\n" for row in weights for value in row), encoding="ascii")
    (DATA / "w4_cls_bias.mem").write_text(
        "".join(f"{value & 0xffffffffffffffff:016x}\n" for value in bias), encoding="ascii")


if __name__ == "__main__":
    main()
