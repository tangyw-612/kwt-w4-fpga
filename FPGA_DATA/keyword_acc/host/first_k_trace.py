"""首层激活读出和 K 投影的实板抓取与逐拍对照。"""

import argparse
import csv
import json
from pathlib import Path
import re
import struct
from typing import NamedTuple

from demo_protocol import BAUD, get_samples, run_encoder, serial_module


PROBE_WIDTHS = (1, 1, 1, 6, 32, 32, 1, 1, 32)
SAMPLES = (250, 100)


class Cycle(NamedTuple):
    read_enable: int
    row_pair: int
    column_pair: int
    input_col: int
    even: int
    odd: int
    mac_input_valid: int
    mac_output_valid: int
    projection: int
    destination: int = -1
    output_row: int = -1
    output_col: int = -1


def capture(port_name, number, output):
    samples = get_samples()
    sample = next(item for item in samples.values() if item.name == f"sample_{number}")
    with serial_module().Serial(port_name, BAUD, timeout=6, write_timeout=6) as port:
        result = run_encoder(port, sample, samples, readback_path=output / f"{sample.name}_final.bin")
    if result["layers"] != 12:
        raise RuntimeError(f"{sample.name} 未完成十二层计算")
    print(json.dumps(result))


def read_probe_cycles(output, number, widths, probe_map=None):
    probe_map = probe_map or output / "probe_map.tsv"
    layout = probe_map.with_name("probe_layout.json")
    physical_widths = tuple(json.loads(layout.read_text(encoding="utf-8"))) if layout.is_file() else widths
    if any(width <= 0 for width in physical_widths) or sum(widths) > sum(physical_widths):
        raise ValueError(f"复用 ILA 的探针布局不符：{physical_widths}")
    mappings = []
    masks = [0] * len(physical_widths)
    for line in probe_map.read_text(encoding="utf-8").splitlines():
        mapping, name = line.split("\t", 1)
        match = re.fullmatch(r"probe(\d+)\[(\d+)(?::(\d+))?\]", mapping)
        if not match:
            raise ValueError(f"探针映射未知：{mapping}")
        port, high, low = map(int, (match[1], match[2], match[3] or match[2]))
        width = high - low + 1
        mappings.append((port, low, high, name))
        span = ((1 << width) - 1) << low
        if masks[port] & span:
            raise ValueError(f"探针位重复：{mapping}")
        masks[port] |= span
    if masks != [(1 << width) - 1 for width in physical_widths]:
        raise ValueError(f"探针位宽错误：{masks}")

    with (output / f"sample_{number}.csv").open(newline="", encoding="utf-8-sig") as stream:
        csv_rows = csv.DictReader(stream)
        next(csv_rows)  # 跳过 Vivado 进制说明。
        columns = []
        for port, low, high, name in mappings:
            possible = (name, f"{name}[{high}:{low}]", f"{name}[{low}]")
            column = next((item for item in possible if item in csv_rows.fieldnames), None)
            if column is None:
                # CSV 有时用网名自身的原始位号，而非它在 ILA 端口中的位号。
                aliases = [item for item in csv_rows.fieldnames if item.startswith(name + "[")]
                if len(aliases) != 1:
                    raise ValueError(f"无法唯一确定探针的 CSV 列：{name}")
                column = aliases[0]
            columns.append((port, low, column))
        if len({column for _, _, column in columns}) != len(columns):
            raise ValueError("探针 CSV 列重复")
        rows = list(csv_rows)
    triggers = [int(row["Sample in Buffer"]) for row in rows if row["TRIGGER"] == "1"]
    if len(triggers) != 1:
        raise ValueError("每个样本应包含一个激活读触发点")
    result = {}
    for row in rows:
        probes = [0] * len(physical_widths)
        for port, low, column in columns:
            probes[port] |= int(row[column], 16) << low
        result[int(row["Sample in Buffer"]) - triggers[0]] = repack_probes(probes, physical_widths, widths)
    return result


def repack_probes(probes, physical_widths, logical_widths):
    if physical_widths == logical_widths:
        return tuple(probes)
    payload, offset = 0, 0
    for value, width in zip(probes, physical_widths):
        payload |= value << offset
        offset += width
    result = []
    for width in logical_widths:
        result.append(payload & ((1 << width) - 1))
        payload >>= width
    return tuple(result)


def board_cycles(output, number):
    return {tick: Cycle(*values) for tick, values in read_probe_cycles(output, number, PROBE_WIDTHS).items()}


def sim_cycles(simulation, number):
    rows = {}
    for line in (simulation / f"sample_{number}.log").read_text(encoding="utf-8-sig").splitlines():
        if line.startswith("KTRACE "):
            fields = line.split()[1:]
            values = [int(value, 16 if i in (5, 6, 9) else 10) for i, value in enumerate(fields)]
            rows[values[0]] = Cycle(*values[1:])
    if len(rows) != 1024 or tuple(rows[0][:4]) != (1, 1, 1, 0):
        raise ValueError(f"样本 {number} 仿真窗口不完整")
    return rows


def compare_sample(number, sample, reference, board):
    readings = [tick for tick, row in reference.items() if row[:3] == (1, 1, 1)][:32]
    outputs = [(tick, row.output_col) for tick, row in reference.items()
               if row.mac_output_valid and row.destination == 0 and row.output_row == 0]
    if ([reference[tick].input_col for tick in readings] != list(range(0, 64, 2))
            or [col for _, col in outputs] != list(range(64))):
        raise ValueError("缺少首个行对的完整激活和 K 投影仿真参考")
    trace = []
    raw = struct.unpack_from("<64I", sample.features, 64 * 4)
    for issue in readings:
        col = reference[issue].input_col
        tick = issue + 1
        expected = (reference[tick].even, reference[tick].odd)
        actual = (board[tick].even, board[tick].odd)
        if expected != raw[col:col + 2]:
            raise ValueError(f"RTL 的激活与输入文件不一致，列 {col}")
        valid = board[issue][:4] == reference[issue][:4] and bool(board[tick].mac_input_valid)
        for term, values in enumerate(zip(expected, actual)):
            trace.append((tick, "X", col + term, *values, valid))
    for tick, col in outputs:
        trace.append((tick, "K", col, reference[tick].projection, board[tick].projection,
                      bool(board[tick].mac_output_valid)))

    summaries = {}
    result = []
    for tick, stage, col, expected, actual, valid in sorted(trace):
        result.append({"sample": number, "cycle": tick, "stage": stage, "row": 1, "col": col,
                       "sim": f"{expected:08x}", "board": f"{actual:08x}",
                       "valid": valid, "match": valid and actual == expected})
    for stage in ("X", "K"):
        rows = [row for row in result if row["stage"] == stage]
        summaries[stage] = {"matched": sum(row["match"] for row in rows), "total": len(rows),
                            "first": rows[0], "first_difference": next((row for row in rows if not row["match"]), None)}
    summaries["first_difference"] = next((row for row in result if not row["match"]), None)
    return summaries, result


def compare(output, simulation):
    samples = {sample.name: sample for sample in get_samples().values()}
    comparison = []
    results = {}
    for number in SAMPLES:
        data = sim_cycles(simulation, number)
        actual = board_cycles(output, number)
        results[number], trace = compare_sample(number, samples[f"sample_{number}"], data, actual)
        comparison.extend(trace)
    with (output / "comparison.csv").open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=comparison[0].keys())
        writer.writeheader()
        writer.writerows(comparison)
    result = json.dumps(results, indent=2)
    (output / "comparison.json").write_text(result + "\n", encoding="utf-8")
    print(result)


def main():
    parser = argparse.ArgumentParser(description="首层激活与 K 投影诊断")
    commands = parser.add_subparsers(dest="action", required=True)
    board = commands.add_parser("capture")
    board.add_argument("port")
    board.add_argument("sample", type=int, choices=SAMPLES)
    board.add_argument("output", type=Path)
    reference = commands.add_parser("compare")
    reference.add_argument("output", type=Path)
    reference.add_argument("simulation", type=Path)
    args = parser.parse_args()
    if args.action == "capture":
        capture(args.port, args.sample, args.output)
    else:
        compare(args.output, args.simulation)


if __name__ == "__main__":
    main()
