"""把竞赛标志和少量中文标题转成 AN970 像素扫描用的小型 ROM。"""

import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont, ImageOps


PROJECT = Path(__file__).resolve().parents[1]
BACKGROUND = PROJECT.parents[1] / "presentations" / "an970_gui" / "competition-background.png"
DATASET = BACKGROUND.with_name("dataset.js")
FONT = Path("C:/Windows/Fonts/msyhbd.ttc")
HEADER = (248, 252, 255)


def write_rom(name, values, fmt):
    (PROJECT / "data" / name).write_text("".join(f"{value:{fmt}}\n" for value in values), encoding="ascii")


def fit_logo(source, bounds, size, visible_width):
    padded = Image.new("RGB", size, HEADER)
    logo = ImageOps.contain(source.crop(bounds), (visible_width, size[1]))
    position = ((visible_width - logo.width) // 2, (size[1] - logo.height) // 2)
    padded.paste(logo, position)
    return padded


def main():
    with Image.open(BACKGROUND) as graphics:
        source = graphics.convert("RGB")
    left = fit_logo(source, (23, 15, 201, 84), (128, 48), 128)
    right = fit_logo(source, (648, 15, 946, 49), (256, 24), 224)
    atlas = Image.new("RGB", (256, 48))
    atlas.putdata([*left.getdata(), *right.getdata()])
    indexed = atlas.quantize(colors=16, dither=Image.Dither.NONE)
    colors = indexed.getpalette()[:48]
    palette = [r << 16 | g << 8 | b for r, g, b in zip(colors[::3], colors[1::3], colors[2::3])]
    write_rom("an970_logo.mem", indexed.getdata(), "x")
    write_rom("an970_palette.mem", palette, "06x")

    # 整核版压缩保留两个竞赛标志，屏幕波形随样本号下发。
    small_left = fit_logo(source, (23, 15, 201, 84), (96, 32), 96)
    small_right = fit_logo(source, (648, 15, 946, 49), (192, 16), 192)
    compact = Image.new("RGB", (192, 32))
    compact.putdata([*small_left.getdata(), *small_right.getdata()])
    compact_indexed = compact.quantize(colors=4, dither=Image.Dither.NONE)
    compact_palette = compact_indexed.getpalette()[:12]
    indexed_pixels = list(compact_indexed.getdata())
    write_rom("an970_live_logo.mem", (sum(pixel << (2 * lane) for lane, pixel in enumerate(indexed_pixels[i:i+4]))
                                     for i in range(0, len(indexed_pixels), 4)), "02x")
    write_rom("an970_live_palette.mem", (r << 16 | g << 8 | b for r, g, b in
              zip(compact_palette[::3], compact_palette[1::3], compact_palette[2::3])), "06x")

    mask = Image.new("1", (256, 152))
    painter = ImageDraw.Draw(mask)
    for y, size, label in ((0, 29, "语音关键词识别"), (32, 19, "样本编号"), (56, 19, "点积校验"),
                           (80, 17, "板上周期"), (104, 17, "联调接口"), (128, 17, "样本波形")):
        painter.text((0, y), label, font=ImageFont.truetype(str(FONT), size), anchor="lt", fill=1)
    bits = list(mask.getdata())
    # 按字节打包，兼容 Vivado 对 ROM 初始化的数据宽度要求。
    write_rom("an970_labels.mem", (sum(bit << (7 - offset) for offset, bit in enumerate(bits[i:i+8]))
                                   for i in range(0, len(bits), 8)), "02x")

    # 复用上位机从原始录音提取的能量包络，每条合并成 32 柱。
    source = DATASET.read_text(encoding="utf-8").strip()
    samples = json.loads(source.removeprefix("window.kwtDataset = ").removesuffix(";"))["samples"]
    if len(samples) != 600 or any(len(sample["peaks"]) != 64 for sample in samples):
        raise ValueError("样本波形尺寸不匹配")
    write_rom("an970_waves.mem", (round(max(row["peaks"][i:i+2]) * 31 / 100)
                                  for row in samples for i in range(0, 64, 2)), "02x")


if __name__ == "__main__":
    main()
