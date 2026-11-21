"""生成板端源码清单与仅改变器件映射的乘加核副本。"""

import argparse
import re
from pathlib import Path


FULL = Path(__file__).resolve().parents[1]
ARCHIVE = FULL.parents[2] / "research/kwt12042_handoff_20261119/server"
W4 = ARCHIVE / "w4_hundred_lean_mac"
BASE = ARCHIVE / "rtl"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mac-map", choices=("lut", "split", "split_bram", "split_bram_pv",
                                             "split_bram_pv_signed", "split_bram_pv_signed_b16",
                                             "split_bram_pv_signed_b4", "split_bram_pv_signed_b4_gelu"), default="lut")
    args = parser.parse_args()
    merge_pv = args.mac_map.startswith("split_bram_pv")
    fixed_mac = args.mac_map.startswith("split_bram_pv_signed")
    force_b16 = args.mac_map == "split_bram_pv_signed_b16"
    generated = FULL / "build" / ("generated" if args.mac_map == "lut" else f"generated_{args.mac_map}")
    generated.mkdir(parents=True, exist_ok=True)
    sources = [
        FULL / "rtl/ramsp_fpga.sv",
        BASE / "050_linear_requantize.sv",
        BASE / "attention_exp_interpolate.sv",
        BASE / "141_official_2048x32_1p.sv",
        BASE / "attention_table_ihp.sv",
        BASE / "122_ffn_gelu_ihp.sv",
        BASE / "147_ln_affine_stream_v1.sv",
        BASE / "149_ln_square_stream.sv",
        W4 / "114_ln_isqrt_free.sv",
        W4 / "115_ln_divider_fast.sv",
        W4 / "152_ln_round_divider_stream_v1.sv",
        BASE / "153_ln_output_pipeline_stream_v2.sv",
        BASE / "ac_mems.sv",
        ARCHIVE / "inputs/ac_row_store.sv",
        W4 / "arch_c_mac_array.sv",
        W4 / "ac_pair_x.sv",
        W4 / "attention_softmax.sv",
        W4 / "ac_ln_dual.sv",
        W4 / "ac_enc.sv",
        FULL / "rtl/w4_parameter_decode.sv",
        FULL / "rtl/w4_full_stream.sv",
    ]
    if fixed_mac:
        sources.insert(0, FULL / "rtl/w4_dsp_mul27x17.sv")
    compatible = []
    for source in sources:
        if not source.is_file():
            raise FileNotFoundError(source)
        code = source.read_text(encoding="utf-8")
        if source.name == "arch_c_mac_array.sv":
            declarations = [] if merge_pv else ["logic signed [19:0] odd_hi;"]
            if args.mac_map == "lut":
                declarations.append("logic signed [26:0] pv_hi;")
            for declaration in declarations:
                if code.count(declaration) != 1:
                    raise RuntimeError(f"归档乘加核版本不匹配: {declaration}")
                code = code.replace(declaration, f'(* use_dsp = "no" *) {declaration}')
            if args.mac_map != "lut":
                original = "    always_ff @(posedge clk) if (s1_v) s2_p[j] <= s1_a * bj;"
                if code.count(original) != 1:
                    raise RuntimeError("无法定位偶项乘法")
                fragment = (FULL / "rtl/mac_even_split.inc").read_text(encoding="utf-8")
                code = code.replace(original, fragment.rstrip())
            if merge_pv:
                first = code.index("    logic signed [33:0] odd_lo;")
                last = code.index("    wire signed [ACC_W-1:0] previous", first)
                fragment = (FULL / "rtl/mac_odd_pv_merge.inc").read_text(encoding="utf-8")
                code = code[:first] + fragment.rstrip() + "\n" + code[last:]
            if fixed_mac:
                first = code.index("  logic signed [35:0] prod_lo;")
                last = code.index("\n", code.index("  wire signed [63:0] full_product", first)) + 1
                fragment = (FULL / "rtl/mac_drain_fixed.inc").read_text(encoding="utf-8")
                code = code[:first] + fragment.rstrip() + "\n" + code[last:]
                odd_term = "s2_pair ? ACC_W'(s2_odd) : '0"
                if code.count(odd_term) != 1:
                    raise RuntimeError("无法定位原来的奇项累加扩展")
                code = code.replace(odd_term, "s2_pair ? odd_full : 44'd0")
                code, removed = re.subn(
                    r"(?m)^      if \(channel_scale != 13'sd1\) begin\n"
                    r"        prod_lo <= .*\n        prod_hi <= .*\n      end\n", "", code)
                if removed != 1:
                    raise RuntimeError("无法定位原来的通道重定标乘法")
                code = "`define W4_FIXED_MAC_DSP\n" + code + "\n`undef W4_FIXED_MAC_DSP\n"
                if force_b16:
                    code = "`define W4_FORCE_B16_SIGN\n" + code + "`undef W4_FORCE_B16_SIGN\n"
                if args.mac_map.startswith("split_bram_pv_signed_b4"):
                    code = "`define W4_FORCE_PROJECTION_SIGN\n" + code + "`undef W4_FORCE_PROJECTION_SIGN\n"
        if source.name == "122_ffn_gelu_ihp.sv" and args.mac_map.endswith("_gelu"):
            code, replaced = re.subn(r"(?m)^    assign interpolation = [^;]+;",
                                     (FULL / "rtl/gelu_interpolation.inc").read_text(encoding="utf-8").rstrip(), code)
            if replaced != 1:
                raise RuntimeError("无法定位 GELU 有符号插值表达式")
        if source.name == "ramsp_fpga.sv" and args.mac_map.startswith("split_bram"):
            # 将浅表的同步单端口实现切换到块存储，释放查找表。
            branch = "if (ADDR_BITS <= 7) begin : g_lutram"
            if code.count(branch) != 1:
                raise RuntimeError("无法定位浅表的存储分支")
            code = code.replace(branch, "if (1'b0) begin : g_lutram")
        # 旧版综合器在严格网络模式下误报隐式网络类型的输入声明。
        code = re.sub(r"(?m)^`default_nettype none\s*$", "", code)
        target = generated / source.name
        target.write_text(code, encoding="utf-8")
        compatible.append(target)
    (generated / "sources.f").write_text(
        "\n".join(source.as_posix() for source in compatible) + "\n", encoding="utf-8"
    )


if __name__ == "__main__":
    main()
