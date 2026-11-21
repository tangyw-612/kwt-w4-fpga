"""按流水拍序对照第 0 层第二行、第 0 个 K 通道。"""

import argparse
import csv
import hashlib
import json
from pathlib import Path
from typing import NamedTuple

from first_k_trace import SAMPLES, read_probe_cycles


OPERAND_WIDTHS = (1,) * 7 + (32, 32, 18, 18)
ACCUM_WIDTHS = (1,) * 6 + (44, 44, 12)


class Operands(NamedTuple):
    rd: int
    row_pair: int
    col_pair: int
    in_valid: int
    in_first: int
    in_last: int
    in_pair: int
    a_even: int
    a_odd: int
    b_even: int
    b_odd: int


class Accumulation(NamedTuple):
    rd: int
    row_pair: int
    col_pair: int
    accum_valid: int
    scale_valid: int
    drain_valid: int
    accumulator: int
    scale_acc: int
    scale: int


def sim_mac_cycles(path):
    operands, accumulation = {}, {}
    hex_fields = {8, 9, 10, 11, 15, 16, 17}
    for line in path.read_text(encoding="utf-8-sig").splitlines():
        if line.startswith("KMTRACE "):
            words = line.split()[1:]
            values = [int(word, 16 if i in hex_fields else 10) for i, word in enumerate(words)]
            operands[values[0]] = Operands(*values[1:12])
            accumulation[values[0]] = Accumulation(*values[1:4], *values[12:])
    if len(operands) != 128 or operands[0][:3] != (1, 1, 1):
        raise ValueError(f"缺少首层 K 仿真窗口：{path}")
    return operands, accumulation


def signed(value, width):
    return value - (1 << width) if value >> (width - 1) else value


def compare_mac(number, reference, board):
    sim_in, sim_acc = reference
    fpga_in, fpga_acc = board
    first = next(tick for tick, data in sim_in.items() if data.in_valid and data.in_first)
    last = next(tick for tick, data in sim_in.items() if tick >= first and data.in_valid and data.in_last)
    issue = [tick for tick in range(first, last + 1) if sim_in[tick].in_valid]
    drain = next(tick for tick, data in sim_acc.items() if tick > last and data.drain_valid)
    if len(issue) != 32 or any(not sim_acc[tick + 2].accum_valid for tick in issue) or not sim_acc[drain + 1].scale_valid:
        raise ValueError("首个 K 的 32 次双项归约或写出时序不符")

    rows = []

    def record(tick, term, signal, width, sim, fpga):
        expected, actual = getattr(sim[tick], signal), getattr(fpga[tick], signal)
        digits = (width + 3) // 4
        rows.append({"sample": number, "cycle": tick, "term": term, "signal": signal, "width": width,
                     "sim": f"{expected:0{digits}x}", "board": f"{actual:0{digits}x}", "match": actual == expected})

    reproduced = 0
    modeled_acc = 0
    for term, tick in enumerate(issue):
        for pin, width in (("in_valid", 1), ("in_first", 1), ("in_last", 1), ("in_pair", 1), ("a_even", 32), ("a_odd", 32)):
            record(tick, term, pin, width, sim_in, fpga_in)
        for pin in ("b_even", "b_odd"):
            record(tick + 1, term, pin, 18, sim_in, fpga_in)
        record(tick + 2, term, "accum_valid", 1, sim_acc, fpga_acc)
        record(tick + 3, term, "accumulator", 44, sim_acc, fpga_acc)

        # DSP 只做低位乘积，高位乘积仍用权重低四位的有符号值。
        for activation, weight, split in ((fpga_in[tick].a_even, fpga_in[tick + 1].b_even, 26),
                                           (fpga_in[tick].a_odd, fpga_in[tick + 1].b_odd, 16)):
            lo = (activation & ((1 << split) - 1)) * signed(weight, 18)
            hi = (signed(activation, 32) >> split) * signed(weight & 15, 4) << split
            modeled_acc = (modeled_acc + lo + hi) & ((1 << 44) - 1)
        reproduced += modeled_acc == fpga_acc[tick + 3].accumulator

    record(drain, -1, "drain_valid", 1, sim_acc, fpga_acc)
    for pin, width in (("scale_valid", 1), ("scale_acc", 44), ("scale", 12)):
        record(drain + 1, -1, pin, width, sim_acc, fpga_acc)

    rows.sort(key=lambda row: row["cycle"])
    details = {signal: [row for row in rows if row["signal"] == signal] for signal in dict.fromkeys(row["signal"] for row in rows)}
    return rows, {
        "first_difference": next((row for row in rows if not row["match"]), None),
        "signals": {signal: {"matched": sum(row["match"] for row in selected), "total": len(selected),
                             "first_difference": next((row for row in selected if not row["match"]), None)}
                    for signal, selected in details.items()},
        "accumulator_from_measured_operands": f"{reproduced}/32",
        "last_accumulator": details["accumulator"][-1],
        "scaler_input": details["scale_acc"][0],
        "scaler_coefficient": details["scale"][0],
    }


def main():
    parser = argparse.ArgumentParser(description="逐拍对比首层 K 乘加与缩放")
    parser.add_argument("operands", type=Path)
    parser.add_argument("accumulation", type=Path)
    parser.add_argument("simulation", type=Path)
    parser.add_argument("baseline", type=Path)
    args = parser.parse_args()
    result = {}
    trace = []
    for number in SAMPLES:
        sample = f"sample_{number}"
        hashes = {hashlib.sha256((path / f"{sample}_final.bin").read_bytes()).hexdigest()
                  for path in (args.operands, args.accumulation, args.baseline)}
        if len(hashes) != 1:
            raise ValueError(f"探针位流未复现同一末层回读：{sample}")
        sim = sim_mac_cycles(args.simulation / f"{sample}.log")
        fpga_in = {tick: Operands(*row) for tick, row in read_probe_cycles(args.operands, number, OPERAND_WIDTHS).items()}
        fpga_acc = {tick: Accumulation(*row) for tick, row in read_probe_cycles(args.accumulation, number, ACCUM_WIDTHS).items()}
        records, result[number] = compare_mac(number, sim, (fpga_in, fpga_acc))
        trace.extend(records)
    with (args.accumulation / "mac_comparison.csv").open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=trace[0].keys())
        writer.writeheader()
        writer.writerows(trace)
    summary = json.dumps(result, indent=2)
    (args.accumulation / "mac_comparison.json").write_text(summary + "\n", encoding="utf-8")
    print(summary)


if __name__ == "__main__":
    main()
