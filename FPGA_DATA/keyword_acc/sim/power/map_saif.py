"""按最终布线网表折叠 SAIF 中的生成块层级，只回标确切匹配的网络。"""

import argparse
from collections import Counter
from datetime import datetime
import json
from pathlib import Path
import re


TRACE_ROOT = ("TOP", "tb_kwt_power", "dut")
NET_LINE = re.compile(r"^\((\S+) (\(T0 .+\))\)$")
SAIF_PREFIX = re.compile(r"^\((TIMESCALE|DURATION)\s+(.+)\)$")
ESCAPED_CHAR = re.compile(r"\\(.)")


def unescape(name):
    return ESCAPED_CHAR.sub(r"\1", name.strip('"'))


def escape(name):
    return re.sub(r"([\[\]\\])", r"\\\1", name)


def activity_rows(path):
    scope, stack = [], []
    with path.open(encoding="ascii") as trace:
        for line in trace:
            line = line.strip()
            if line.startswith("(INSTANCE "):
                scope.append(unescape(line.split(maxsplit=1)[1]))
                stack.append("scope")
            elif line == "(NET":
                stack.append("net")
            elif line == ")":
                if stack and stack.pop() == "scope":
                    scope.pop()
            elif tuple(scope[:3]) == TRACE_ROOT and (match := NET_LINE.fullmatch(line)):
                yield tuple(scope[3:]), unescape(match[1]), match[2]


def placement_of(scopes, instances):
    prefix = ""
    while scopes:
        for i in range(1, len(scopes) + 1):
            candidate = prefix + ".".join(scopes[:i])
            if candidate in instances:
                prefix = candidate + "/"
                scopes = scopes[i:]
                break
        else:
            break
    return prefix, ".".join(scopes) + ("." if scopes else "")


def time_fields(path):
    fields = {}
    with path.open(encoding="ascii") as trace:
        for line in trace:
            if match := SAIF_PREFIX.fullmatch(line.strip()):
                fields[match[1]] = match[2]
            if len(fields) == 2:
                break
    if fields.get("TIMESCALE") not in ("1ps", "1 ps"):
        raise ValueError(f"不支持的 SAIF 时间单位 {fields}")
    return int(fields["DURATION"])


def write_instances(stream, node, indent):
    if node.get("nets"):
        stream.write(f"{indent}(NET\n")
        for net, counts in node["nets"]:
            stream.write(f"{indent} ({escape(net)} {counts})\n")
        stream.write(f"{indent})\n")
    for name, child in node.get("children", {}).items():
        stream.write(f"{indent}(INSTANCE {escape(name)}\n")
        write_instances(stream, child, indent + " ")
        stream.write(f"{indent})\n")


def map_activity(source, dest, nets, instances, no_display=False):
    tree, matched, scope_cache = {}, {}, {}
    totals = Counter()
    expected_scopes = ["g_full.u_demo/u_encoder", "g_full.u_demo/g_classifier.u_head"]
    if not no_display:
        expected_scopes.append("g_keyword_ui.u_scene")
    for scopes, signal, counts in activity_rows(source):
        totals["rtl_nets"] += 1
        if scopes not in scope_cache:
            scope_cache[scopes] = placement_of(scopes, instances)
        prefix, generation = scope_cache[scopes]
        mapped = prefix + generation + signal
        if mapped not in nets:
            continue
        if mapped in matched:
            if matched[mapped] != counts:
                raise ValueError(f"网名匹配出现冲突 {mapped}")
            continue
        matched[mapped] = counts
        for scope in expected_scopes:
            if mapped.startswith(scope + "/"):
                totals[scope] += 1
        components = mapped.split("/")
        node = tree
        for component in components[:-1]:
            node = node.setdefault("children", {}).setdefault(component, {})
        node.setdefault("nets", []).append((components[-1], counts))

    if any(not totals[scope] for scope in expected_scopes):
        raise ValueError(f"关键模块的活动缺失 {dict(totals)}")
    duration = time_fields(source)
    timestamp = datetime.now().strftime("%a %b %d %H:%M:%S %Y")
    with dest.open("w", encoding="ascii", newline="\n") as output:
        # Vivado 2020.2 需要完整的 SAIF 2.0 文件头及固定的字段顺序。
        output.write('(SAIFILE\n(SAIFVERSION "2.0")\n(DIRECTION "backward")\n(DESIGN )\n'
                     f'(DATE "{timestamp}")\n(VENDOR "Veripool")\n(PROGRAM_NAME "Verilator")\n'
                     '(VERSION "mapped SAIF")\n(DIVIDER /)\n'
                     f'(TIMESCALE 1 ps)\n(DURATION {duration})\n(INSTANCE dut\n')
        write_instances(output, tree, " ")
        output.write(")\n)\n")
    return dict(duration_ps=duration, matched_routed_names=len(matched), routed_names=len(nets), **totals)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("outputs", type=Path)
    parser.add_argument("--no-display", action="store_true")
    args = parser.parse_args()
    root = args.outputs
    nets = set((root / "net_names.txt").read_text(encoding="ascii").splitlines())
    instances = set((root / "cell_names.txt").read_text(encoding="ascii").splitlines())
    report = {}
    for mode in ("standby", "w4_active"):
        report[mode] = map_activity(root / f"{mode}.saif", root / f"{mode}_mapped.saif", nets, instances, args.no_display)
    (root / "saif_mapping.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report))


if __name__ == "__main__":
    main()
