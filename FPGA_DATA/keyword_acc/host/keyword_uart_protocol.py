"""AXU2CG-E 板端完整 W4 识别串口。"""

import argparse
from functools import lru_cache
import hashlib
import json
import secrets
import struct
from time import perf_counter

from demo_protocol import BAUD, BLOCK_BYTES, DATASET, OUTPUT_BYTES, WORKSPACE, encoder_model_payload, read_exact, serial_module
from mac_uart_protocol import CLOCK_HZ, checksum
from make_classifier_rom import LABELS


REPLY = struct.Struct("<cHHBBIIB")
PROBE_REPLY = b"K4F1"


@lru_cache(maxsize=1)
def dataset_metadata():
    source = (WORKSPACE / "presentations" / "an970_gui" / "dataset.js").read_text(encoding="utf-8").strip()
    display = json.loads(source.removeprefix("window.kwtDataset = ").removesuffix(";"))["samples"]
    manifest = json.loads((DATASET / "tasks600" / "labels.json").read_text(encoding="utf-8"))["files"]
    if len(display) != 600 or len(manifest) != 600:
        raise ValueError("评测数据应包含 600 条样本")
    return tuple(zip(manifest, display))


def load_sample(sample_id):
    if type(sample_id) is not int or not 0 <= sample_id < 600:
        raise ValueError("样本编号范围为 000–599")
    item, display = dataset_metadata()[sample_id]
    if item["index"] != sample_id or item["label"] != display["truth"] or len(display["peaks"]) != 64:
        raise ValueError(f"编号或波形清单不一致 #{sample_id:03d}")
    features = (DATASET / "tasks600" / f"task_{sample_id:03d}.bin").read_bytes()
    if len(features) != OUTPUT_BYTES or hashlib.sha256(features).hexdigest() != item["sha256"]:
        raise ValueError(f"输入特征未通过校验 #{sample_id:03d}")
    heights = [round(max(display["peaks"][i:i+2]) * 15 / 100) for i in range(0, 64, 2)]
    wave = bytes(heights[i] | (heights[i+1] << 4) for i in range(0, 32, 2))
    return features, wave


def open_board(port_name):
    return serial_module().Serial(port_name, BAUD, timeout=0.8, write_timeout=0.8)


def probe(port):
    previous_timeout = port.timeout
    try:
        port.timeout = 0.25
        port.reset_input_buffer()
        port.write(b"I")
        return port.read(len(PROBE_REPLY)) == PROBE_REPLY
    finally:
        port.timeout = previous_timeout


def run_sample(port, sample_id):
    features, wave = load_sample(sample_id)
    payload = features + encoder_model_payload()
    token = secrets.randbits(16)
    request = struct.pack("<cHH", b"K", token, sample_id) + wave
    port.reset_input_buffer()
    started = perf_counter()
    port.write(request + bytes([checksum(request)]))
    for offset in range(0, len(payload), BLOCK_BYTES):
        credit = read_exact(port, 1, f"W4 输入流许可 {offset}")
        if credit != b"G":
            raise RuntimeError(f"W4 输入流回执异常，偏移 {offset}：{credit!r}")
        port.write(payload[offset:offset + BLOCK_BYTES])
    reply = read_exact(port, REPLY.size, "W4 完整识别回执")
    marker, echo_token, echo_id, category, layers, cycles, wait, _ = REPLY.unpack(reply)
    if (marker, echo_token, echo_id) != (b"R", token, sample_id) or checksum(reply):
        raise ValueError("W4 回执的帧头、事务号、编号或校验不匹配")
    if category >= len(LABELS) or layers != 12 or not 0 <= wait < cycles:
        raise RuntimeError(f"板端识别未完成，层数 {layers}，类别码 {category}")
    return {"mode": "keyword", "sample_id": echo_id, "transaction": echo_token, "prediction": LABELS[category],
            "class_id": category, "layers": layers, "cycles": cycles, "wait_cycles": wait,
            "active_cycles": cycles - wait, "elapsed_seconds": round(perf_counter() - started, 3)}


def main():
    parser = argparse.ArgumentParser(description="验证板端 W4 完整识别")
    parser.add_argument("--port", default="COM7")
    parser.add_argument("--verify-replay", action="store_true", help="与 W4 离线记录逐样本比对")
    parser.add_argument("--all", action="store_true", help="遍历全部 600 条")
    parser.add_argument("samples", type=int, nargs="*")
    args = parser.parse_args()
    if not args.all and not args.samples:
        parser.error("需要样本编号或 --all")
    errors = 0
    with open_board(args.port) as port:
        if not probe(port):
            raise RuntimeError("板端尚未加载完整识别位流")
        for sample in range(600) if args.all else args.samples:
            result = run_sample(port, sample)
            if args.verify_replay:
                result["reference"] = dataset_metadata()[sample][1]["prediction"]
                result["matches_reference"] = result["prediction"] == result["reference"]
                errors += int(not result["matches_reference"])
            print(json.dumps(result), flush=True)
    if errors:
        raise SystemExit(f"{errors} 条板端分类与离线 W4 记录不同")


if __name__ == "__main__":
    main()
