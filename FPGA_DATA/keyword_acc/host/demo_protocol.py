from dataclasses import dataclass
from functools import lru_cache
import hashlib
import json
from math import fsum
from pathlib import Path
import struct
import sys
from time import perf_counter


PROJECT = Path(__file__).resolve().parents[1]
WORKSPACE = PROJECT.parents[1]
VECTORS = (WORKSPACE / "research" / "kwt12042_handoff_20261119" / "server"
           / "w4_hundred_lean_mac" / "vectors")
DATASET = WORKSPACE / "research" / "20261110_official600_eval_01"
CASES = {"RIGHT": 250, "UP": 100, "LEFT": 200, "STOP": 400}
DIRECTIONS = {"RIGHT": b"R", "UP": b"U", "LEFT": b"L", "STOP": b"S"}
BLOCK_BYTES = 1024
OUTPUT_BYTES = 99 * 64 * 4
BAUD = 921600


@dataclass(frozen=True)
class Sample:
    label: str
    name: str
    audio: Path
    features: bytes
    expected: bytes


def get_samples():
    rows = json.loads((DATASET / "tasks600" / "labels.json").read_text(encoding="utf-8"))["files"]
    samples = {}
    for label, index in CASES.items():
        row = rows[index]
        features = (VECTORS / "loader" / row["sample"] / "input.bin").read_bytes()
        expected = (VECTORS / "golden" / row["sample"] / "layer_11.bin").read_bytes()
        audio = DATASET / "audio" / row["path"]
        if hashlib.sha256(features).hexdigest() != row["sha256"] or row["label"].upper() != label:
            raise ValueError(f"样本标签或输入不一致：{row['sample']}")
        if len(expected) != OUTPUT_BYTES or not audio.is_file():
            raise ValueError(f"样本音频或末层输出缺失：{row['sample']}")
        samples[label] = Sample(label, row["sample"], audio, features, expected)
    return samples


def encoder_payload(sample):
    if len(sample.features) != OUTPUT_BYTES:
        raise ValueError("输入特征字数不正确")
    return sample.features + encoder_model_payload()


@lru_cache(maxsize=1)
def encoder_model_payload():
    loader = VECTORS / "loader"
    tables = [(loader / f"{name}.bin").read_bytes() for name in ("gelu", "exp")]
    params = [(loader / "parameters" / f"layer_{layer:02}.bin").read_bytes() for layer in range(12)]
    if any(len(table) != 16388 for table in tables):
        raise ValueError("查表规格不正确")
    if any(len(layer) != 28548 for layer in params):
        raise ValueError("层参数字数不正确")
    return b"".join([*tables, *params])


def read_exact(port, count, step):
    result = port.read(count)
    if len(result) != count:
        raise TimeoutError(f"{step}超时，收到 {len(result)}/{count} 字节")
    return result


def run_mac(port, sample):
    port.reset_input_buffer()
    port.write(DIRECTIONS[sample.label])
    status = read_exact(port, 1, "MAC 回执")
    if status not in (b"P", b"F"):
        raise RuntimeError(f"未知回执 {status!r}，请核对 bitstream 模式")
    return {"mode": "mac", "ok": status == b"P", "display": sample.label, "sample": sample.name}


def run_encoder(port, sample, samples, predictor=None, readback_path=None):
    payload = encoder_payload(sample)
    port.reset_input_buffer()
    start = perf_counter()
    port.write(b"F")
    for offset in range(0, len(payload), BLOCK_BYTES):
        if read_exact(port, 1, "输入流许可") != b"G":
            raise RuntimeError(f"板端未许可输入块，偏移 {offset}")
        port.write(payload[offset:offset + BLOCK_BYTES])
    if read_exact(port, 1, "输出帧头") != b"D":
        raise RuntimeError("板端未返回输出帧头")
    output = read_exact(port, OUTPUT_BYTES, "末层输出")
    if readback_path is not None:
        readback_path.parent.mkdir(parents=True, exist_ok=True)
        readback_path.write_bytes(output)
    cycles, wait, layers = struct.unpack("<IIB", read_exact(port, 9, "运行统计"))
    words = sum(output[i:i+4] == sample.expected[i:i+4] for i in range(0, len(output), 4))
    ok = words == OUTPUT_BYTES // 4 and layers == 12 and wait <= cycles
    prediction = None
    try:
        if ok:
            prediction = predictor(output) if predictor else next(
                (c.label for c in samples.values() if c.expected == output), None)
    finally:
        port.write(DIRECTIONS.get(prediction, b"N"))
    return {"mode": "full", "ok": ok, "display": prediction, "sample": sample.name,
            "matched_words": words, "layers": layers, "cycles": cycles, "wait_cycles": wait,
            "active_cycles": cycles - wait, "elapsed_seconds": round(perf_counter() - start, 3),
            "head": "classification" if predictor else "known_vector", "sha256": hashlib.sha256(output).hexdigest()}


def serial_module():
    extras = PROJECT / "build" / "pydeps"
    if extras.is_dir():
        sys.path.insert(0, str(extras))
    import serial
    return serial


def prepare_predictor(head_dir):
    if head_dir is None:
        head_asset = PROJECT / "data" / "classification_head.json"
        if not head_asset.is_file():
            return None
        head = json.loads(head_asset.read_text(encoding="utf-8"))
        labels = head["labels"]
        weight, bias = head["head_w"], head["head_b"]
        if len(weight) != 64 or len(bias) != 12 or len(labels) != 12 or any(len(row) != 12 for row in weight):
            raise ValueError("分类头维度不正确")
        columns = tuple(zip(*weight))

        def predict_asset(output):
            cls = tuple(value / (1 << 20) for value in struct.unpack_from("<64i", output))
            logits = [fsum(a * b for a, b in zip(cls, column)) + offset
                      for column, offset in zip(columns, bias)]
            return labels[max(range(len(logits)), key=logits.__getitem__)].upper()

        return predict_asset
    sys.path.insert(0, str(head_dir.resolve(strict=True)))
    import numpy as np
    from classify import head_logits, load_head
    weight, bias, labels = load_head()

    def predict(output):
        values = np.frombuffer(output, dtype="<i4").reshape(99, 64)
        return labels[int(head_logits(values, weight, bias).argmax())].upper()

    return predict
