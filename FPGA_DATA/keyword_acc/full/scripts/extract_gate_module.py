"""从 Vivado 功能网表提取层次模块，供独立对照仿真。"""

import argparse
import re
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("netlist", type=Path)
    parser.add_argument("module")
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    netlist = args.netlist.read_text(encoding="utf-8")
    modules = dict(re.findall(r"(?ms)^module (\w+)\b(.*?)^endmodule\b", netlist))
    selected = {args.module, "glbl"}
    pending = [args.module]
    while pending:
        code = modules[pending.pop()]
        for name in re.findall(r"(?m)^  (\w+)[ \t]+(?=\S)", code):
            if name in modules and name not in selected:
                selected.add(name)
                pending.append(name)
    timescale = re.search(r"(?m)^`timescale .*", netlist).group()
    chunks = [timescale]
    renamed = {name: f"{name}_gate" for name in selected if name != "glbl"}
    for name, code in modules.items():
        if name in selected:
            code = re.sub(r"(?m)^  (\w+)(?=[ \t]+\S)",
                          lambda match: "  " + renamed.get(match[1], match[1]), code)
            chunks.append(f"module {renamed.get(name, name)}{code}endmodule")
    args.output.write_text("\n\n".join(chunks) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
