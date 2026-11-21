"""按触发后的时钟周期比较首层各算子的两路 MAC 输出。"""

import argparse
import csv
import json
from pathlib import Path

from first_k_trace import SAMPLES, read_probe_cycles


WIDTHS = (1, 4, 8, 1, 32, 32, 6)
FFN_WIDTHS = (1, 4, 8, 1, 8, 16, 1, 1, 17, 17, 4, 4)
STAGES = {0: "K", 1: "V", 2: "Q", 3: "QK", 5: "PV", 6: "O", 9: "FFN1", 11: "FFN2"}


def sim_results(log):
    for line in log.read_text(encoding="utf-8-sig").splitlines():
        if line.startswith("STAGEMAC "):
            *fields, value = line.split()[1:]
            cycle, dest, row, col, side = map(int, fields)
            yield cycle, dest, row, col, side, int(value, 16)


def compare(data, stage, sample, sim):
    start = next(cycle for cycle, dest, row, col, side, _ in sim
                 if (dest, row, col, side) == (stage, 0, 0, 0))
    board = read_probe_cycles(data / f"stage_{stage}", sample, WIDTHS, data / "probe_map.tsv")
    for cycle, dest, row, col, side, expected in sim:
        tick = cycle - start
        if dest != stage or row != 0 or tick < 0 or tick not in board:
            continue
        valid0, actual_dest, actual_col, valid1, data0, data1, actual_row_pair = board[tick]
        actual = (data0, data1)[side]
        tags_match = ((valid0, valid1)[side], actual_dest, actual_row_pair, actual_col) == (1, dest, row // 2, col)
        yield dict(sample=sample, stage=STAGES[stage], sim_cycle=cycle, capture_cycle=tick,
                   row=row + side, col=col, sim=f"{expected:08x}", board=f"{actual:08x}",
                   tags_match=tags_match, match=tags_match and expected == actual)


def compare_ffn(data, sample, log):
    heads = {dest: cycle for cycle, dest, row, col, side, _ in sim_results(log)
             if dest in (9, 11) and (row, col, side) == (0, 0, 0)}
    start, stop = heads[9], heads[11]
    board = read_probe_cycles(data / "stage_9", sample, FFN_WIDTHS, data / "probe_map.tsv")
    if board[0][:3] != (1, 9, 0):
        raise ValueError(f"样本 {sample} 的 FFN1 触发标签错误")
    for line in log.read_text(encoding="utf-8-sig").splitlines():
        if not line.startswith(("GELUTRACE ", "F2IN ")):
            continue
        section, cycle, *values = line.split()
        tick = int(cycle) - start
        if not 0 <= tick < stop - start:
            continue
        _, _, _, gelu_valid, gelu_tag, gelu_data, mac_valid, is_ffn2, *operands = board[tick]
        if section == "GELUTRACE":
            expected = (1, int(values[0]), int(values[1], 16))
            actual = (gelu_valid, gelu_tag, gelu_data)
        else:
            expected = (1, 1, *(int(value, 16) for value in values))
            actual = (mac_valid, is_ffn2, *operands)
        yield dict(sample=sample, section=section, capture_cycle=tick,
                   sim=expected, board=actual, match=expected == actual)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("data", type=Path)
    parser.add_argument("simulation", type=Path)
    parser.add_argument("--ffn", action="store_true", help="对比 GELU 输出与 FFN2 输入")
    args = parser.parse_args()
    stages = [stage for stage in STAGES if (args.data / f"stage_{stage}").is_dir()]
    comparison = []
    for sample in SAMPLES:
        log = args.simulation / f"sample_{sample}.log"
        if args.ffn:
            rows = list(compare_ffn(args.data, sample, log))
            comparison.extend(rows)
            for section in ("GELUTRACE", "F2IN"):
                values = [row for row in rows if row["section"] == section]
                if not values:
                    raise ValueError(f"样本 {sample} 缺少 {section} 仿真数据")
                print(json.dumps(dict(sample=sample, section=section,
                                      matched=sum(row["match"] for row in values), total=len(values),
                                      first_difference=next((row for row in values if not row["match"]), None))))
            continue
        sim = list(sim_results(log))
        all_rows = sorted((row for stage in stages for row in compare(args.data, stage, sample, sim)),
                          key=lambda row: (row["sim_cycle"], row["row"]))
        if not all_rows:
            raise ValueError(f"样本 {sample} 无可比对的首层结果")
        comparison.extend(all_rows)
        totals = {name: [sum(r["match"] for r in rows), len(rows)]
                  for name in (STAGES[stage] for stage in stages)
                  if (rows := [r for r in all_rows if r["stage"] == name])}
        print(json.dumps(dict(sample=sample, totals=totals,
                              first_difference=next((r for r in all_rows if not r["match"]), None))))
    with (args.data / "comparison.csv").open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=comparison[0])
        writer.writeheader()
        writer.writerows(comparison)


if __name__ == "__main__":
    main()
