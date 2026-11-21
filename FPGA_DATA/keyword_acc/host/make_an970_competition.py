"""生成 800×480 竞赛界面的板端底图、字模和真实标签表。"""

from itertools import groupby
import json
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

from an970_detail_assets import clean_backdrop, encode_details
from demo_protocol import DATASET
from make_an970_assets import BACKGROUND, write_rom
from make_classifier_rom import LABELS


COLORS = (
    "#f2f9fc", "#ddebf8", "#cfe3f6", "#bddbf5", "#aad0f0", "#9fc4e4",
    "#ffffff", "#163857", "#486580", "#d8e8f8", "#087e91", "#008cbe",
    "#00c878", "#2d5190", "#f8fcff", "#56738f",
)
RUN_LENGTHS = (*range(1, 29), 32, 48, 64, 128)
MEANINGS = ("静音", "范围外语音", "确认", "拒绝", "向上", "向下", "向左", "向右",
            "开启", "关闭", "停止", "前进")
STATUS = ("等待选样", "识别中", "识别完成", "识别失败", "标签一致", "标签不一致")
ASCII = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ #./-ms"
FONT_DIR = Path("C:/Windows/Fonts")


def background(source):
    canvas = source.copy()
    clean_backdrop(canvas)
    draw = ImageDraw.Draw(canvas)
    for box, color, border, radius in (
        ((24, 104, 439, 391), "#ffffff", "#cbddec", 10),
        ((456, 104, 775, 391), "#163857", "#163857", 10),
        ((24, 408, 775, 455), "#f8fcff", "#cbddec", 8),
    ):
        draw.rounded_rectangle(box, radius, fill=color, outline=border)
    draw.rounded_rectangle((48, 248, 415, 351), 4, fill="#eef6fc")
    for x in range(48, 416, 46):
        draw.line((x, 248, x, 351), fill="#d7e8f4")
    for y in (274, 300, 326):
        draw.line((48, y, 415, y), fill="#d7e8f4")
    draw.line((480, 330, 751, 330), fill="#56738f")
    for x in (275, 525):
        draw.line((x, 420, x, 444), fill="#cbddec")
    return canvas


def encode_background(source):
    palette = Image.new("P", (1, 1))
    palette.putpalette(bytes.fromhex("".join(color[1:] for color in COLORS)))
    indexed = background(source).resize((400, 240), Image.Resampling.BOX).quantize(
        palette=palette, dither=Image.Dither.NONE
    )
    offsets, commands, rows = [], [], {}
    for y in range(240):
        row = indexed.crop((0, y, 400, y + 1)).tobytes()
        if row in rows:
            offsets.append(rows[row])
            continue
        rows[row] = len(commands)
        offsets.append(rows[row])
        for color, pixels in groupby(row):
            remaining = sum(1 for _ in pixels)
            while remaining:
                code = max(i for i, length in enumerate(RUN_LENGTHS) if length <= remaining)
                commands.append((code << 4) | color)
                remaining -= RUN_LENGTHS[code]
    if len(commands) > 4096:
        raise ValueError(f"底图游程超出片上容量 {len(commands)}")
    write_rom("an970_competition_pixels.mem", commands + [0] * (4096 - len(commands)), "03x")
    write_rom("an970_competition_rows.mem", offsets, "03x")
    write_rom("an970_competition_palette.mem", (int(color[1:], 16) for color in COLORS), "06x")
    print(f"底图压缩为 {len(commands)} 个游程")


def glyph_rows(character, height, font):
    glyph = Image.new("1", (16, height))
    ImageDraw.Draw(glyph).text((0, 1 if height == 16 else 4), character, fill=1, anchor="lt", font=font)
    return [sum(glyph.getpixel((x, y)) << x for x in range(16)) for y in range(height)]


def encode_text():
    phrases = (*MEANINGS, *STATUS)
    chinese = list(dict.fromkeys("".join(phrases)))
    glyphs = []
    for characters, height, name, size in (
        (ASCII, 32, "consolab.ttf", 26), (chinese, 16, "msyh.ttc", 15),
    ):
        font = ImageFont.truetype(str(FONT_DIR / name), size)
        for character in characters:
            glyphs.extend(glyph_rows(character, height, font))
    if len(glyphs) > 2048:
        raise ValueError("字模超出片上容量")
    write_rom("an970_competition_glyphs.mem", glyphs + [0] * (2048 - len(glyphs)), "04x")
    codes = {character: 128 + index for index, character in enumerate(chinese)}
    labels = [bytes(codes[character] for character in phrase).ljust(8, b" ") for phrase in phrases]
    write_rom("an970_competition_phrases.mem", (int.from_bytes(label, "big") for label in labels), "016x")


def encode_truth():
    files = json.loads((DATASET / "tasks600" / "labels.json").read_text(encoding="utf-8"))["files"]
    groups = (2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 1, 0)
    if len(files) != 600 or any(row["index"] != i or row["label"] != LABELS[groups[i // 50]]
                                for i, row in enumerate(files)):
        raise ValueError("真实标签顺序与数据集不一致")
    write_rom("an970_competition_truth.mem", groups, "x")


if __name__ == "__main__":
    source = Image.open(BACKGROUND).convert("RGB").resize((800, 480), Image.Resampling.LANCZOS)
    encode_background(source)
    encode_details(source, FONT_DIR)
    encode_text()
    encode_truth()
