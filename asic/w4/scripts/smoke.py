"""运行 W4 发布候选的静态检查和模块仿真。"""

import argparse
from pathlib import Path
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "build"
SIM_MODEL = ROOT / "sim" / "w4_sim_sram.sv"
TESTS = {
    "tb_mac_edges": "MAC_EDGES_PASS checks=448",
    "tb_nice_faults": "NICE_FAULTS_PASS cases=6",
}


def run(args, cwd, log):
    with log.open("wb") as output:
        try:
            subprocess.run(args, cwd=cwd, stdout=output, stderr=subprocess.STDOUT,
                           check=True, timeout=180)
        except subprocess.SubprocessError as error:
            raise RuntimeError(f"{args[0]} 执行失败，参见 {log}") from error


def lint():
    report = BUILD / "verilator-lint.log"
    run(["verilator", "--lint-only", "-Wno-fatal", "--top-module", "encoder_nice_core",
         "-f", "rtl/sources.f", "sim/w4_sim_sram.sv"], ROOT, report)
    print(f"Verilator 展开及静态检查完成，参见 {report.relative_to(ROOT)}")


def simulate():
    sources = [str(ROOT / path) for path in (ROOT / "rtl" / "sources.f").read_text().splitlines()
               if path.strip()]
    work = Path(tempfile.mkdtemp(prefix="questa_", dir=BUILD))
    ini = work / "modelsim.ini"
    ini.write_text("[Library]\nstd = $MODEL_TECH/../std\nieee = $MODEL_TECH/../ieee\nwork = work\n",
                   encoding="ascii")
    run(["vlib", "work"], work, work / "library.log")
    benches = [str(ROOT / "sim" / f"{name}.sv") for name in TESTS]
    run(["vlog", "-modelsimini", ini.name, "-sv", "-timescale", "1ns/1ps",
         *sources, str(SIM_MODEL), *benches],
        work, work / "compile.log")
    for name, expected in TESTS.items():
        report = work / f"{name}.log"
        run(["vsim", "-modelsimini", ini.name, "-c", "-onfinish", "stop", f"work.{name}", "-do",
             "onerror {quit -code 1}; run -all; quit -code 0"], work, report)
        text = report.read_text(encoding="utf-8", errors="replace")
        if expected not in text or "** Fatal" in text:
            raise RuntimeError(f"仿真结果未通过，参见 {report}")
        print(expected)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("lint", "sim"))
    mode = parser.parse_args().action
    BUILD.mkdir(exist_ok=True)
    try:
        (lint if mode == "lint" else simulate)()
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        parser.exit(1, f"{error}\n")
