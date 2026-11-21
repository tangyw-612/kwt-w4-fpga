"""AXU2CG-E J8 的编号请求和双项点积回执。"""

import argparse
from functools import reduce
import json
from operator import xor
import secrets
import struct

from demo_protocol import BAUD, CASES, PROJECT, read_exact, serial_module


REPLY = struct.Struct("<BBHHBBIiiB")
PROBE_SAMPLE = 0xFFFF
PROBE_TOKEN = 0xD7C3
PROBE_STATUS = 0x10
CLOCK_HZ = 33_333_333


def checksum(payload):
    return reduce(xor, payload, 0)


def exchange(port, sample, token):
    # 请求字段依次为帧头、事务号、样本编号和异或校验。
    body = struct.pack("<BHH", 0xA5, token, sample)
    port.reset_input_buffer()
    port.write(body + bytes([checksum(body)]))
    reply = read_exact(port, REPLY.size, "J8 编号协议回执")
    magic, version, echo_token, echo_sample, status, matches, cycles, dot0, dot1, _ = REPLY.unpack(reply)
    if (magic, version, echo_token, echo_sample) != (0x5A, 1, token, sample) or checksum(reply):
        raise ValueError("J8 帧头、版本、事务号、编号或校验不匹配")
    return {"sample_id": echo_sample, "transaction": echo_token, "status": status,
            "matches": matches, "cycles": cycles, "dot0": dot0, "dot1": dot1}


def identify(port):
    # 探测帧各字节避开旧版的单字节启动命令。
    echo = exchange(port, PROBE_SAMPLE, PROBE_TOKEN)
    if echo["status"] != PROBE_STATUS or any(echo[k] for k in ("matches", "cycles", "dot0", "dot1")):
        raise ValueError("板端未返回编号协议探测回执")


def verify_result(result):
    sample = result["sample_id"]
    supported = sample in CASES.values()
    if not supported:
        if result["status"] != 2 or any(result[k] for k in ("matches", "cycles", "dot0", "dot1")):
            raise ValueError("未装载样本的回执字段不符合协议")
        return result

    expected = (PROJECT / "data" / "mac_expected.mem").read_text(encoding="ascii").split()
    reference = expected[list(CASES.values()).index(sample)]
    dots = struct.unpack("<ii", int(reference, 16).to_bytes(8, "little"))
    expected_matches = sum(result[key] == value for key, value in zip(("dot0", "dot1"), dots))
    if (result["status"] != int(expected_matches != 2) or result["matches"] != expected_matches
            or result["cycles"] <= 0):
        raise ValueError("板端校验字段与上位机独立参考不一致")
    return result


def open_board(port_name):
    return serial_module().Serial(port_name, BAUD, timeout=0.8, write_timeout=0.8)


def run_sample(port, sample):
    if type(sample) is not int or not 0 <= sample <= 599:
        raise ValueError("样本编号范围为 000–599")
    return verify_result(exchange(port, sample, secrets.randbits(16)))


def main():
    parser = argparse.ArgumentParser(description="验证 J8 编号协议和板上点积")
    parser.add_argument("--port", default="COM7")
    parser.add_argument("samples", type=int, nargs="*")
    args = parser.parse_args()
    with open_board(args.port) as port:
        identify(port)
        print(f"J8_PROBE_PASS {args.port} {BAUD} 8N1", flush=True)
        for sample in args.samples:
            print(json.dumps(run_sample(port, sample)), flush=True)


if __name__ == "__main__":
    main()
