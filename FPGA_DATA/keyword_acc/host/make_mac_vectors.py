from pathlib import Path
import struct


PROJECT = Path(__file__).resolve().parents[1]
VECTORS = (PROJECT.parents[1] / "research" / "kwt12042_handoff_20261119"
           / "server" / "w4_hundred_lean_mac" / "vectors" / "loader")
SAMPLES = ("sample_250", "sample_100", "sample_200", "sample_400")


def signed_nibble(code):
    return (code ^ 8) - 8


def main():
    params = (VECTORS / "parameters" / "layer_00.bin").read_bytes()
    if len(params) != 28548:
        raise ValueError("W4 首层参数格式不正确")
    # Q 投影头两个输出通道的权重。前 288 个字存储逐通道尺度。
    packed_weights = params[288 * 4:288 * 4 + 64]
    weights = [(signed_nibble(pair & 15), signed_nibble(pair >> 4))
               for pair in packed_weights]
    words, expected_words = [], []
    for sample in SAMPLES:
        input_file = VECTORS / sample / "input.bin"
        # 取首个声学位置的 64 维输入，计算缩放与偏置前的两个原始点积。
        activation = input_file.read_bytes()
        if len(activation) != 99 * 64 * 4:
            raise ValueError(f"输入特征长度不正确：{sample}")
        values = struct.unpack_from("<64i", activation, 64 * 4)
        expected = tuple(sum(a * b[lane] for a, b in zip(values, weights)) for lane in range(2))
        assert all(-(1 << 31) <= number < (1 << 31) for number in expected)
        expected_words.append(f"{expected[1] & 0xffffffff:08x}{expected[0] & 0xffffffff:08x}")
        for index in range(0, 64, 2):
            codes = packed_weights[index] | (packed_weights[index + 1] << 8)
            words.append(f"{codes:04x}{values[index + 1] & 0xffffffff:08x}{values[index] & 0xffffffff:08x}")
        print(sample, *expected)
    destination = PROJECT / "data"
    destination.mkdir(exist_ok=True)
    (destination / "mac_vectors.mem").write_text("\n".join(words) + "\n", encoding="ascii")
    (destination / "mac_expected.mem").write_text("\n".join(expected_words) + "\n", encoding="ascii")


if __name__ == "__main__":
    main()
