"""用原尺寸像素生成 AN970 的标志和静态文字。"""

from PIL import Image, ImageDraw, ImageFilter, ImageFont

from make_an970_assets import write_rom


LOGOS = (
    ((22, 14, 166, 74), ((3, 195, 126), (0, 140, 196), (0, 60, 120))),
    ((538, 13, 788, 46), ((20, 26, 39), (10, 109, 124), (44, 147, 166))),
)
LABELS = (
    (211, 29, 26, "语音关键词识别", 0, True),
    (211, 65, 17, "KWT-STAR · 30054", 1, True),
    (387, 60, 22, "芯希望", 3, True),
    (48, 124, 20, "样本编号", 0, True),
    (48, 222, 18, "语音波形", 1, False),
    (480, 124, 20, "识别关键词", 2, True),
    (480, 342, 16, "真实标签", 2, False),
    (41, 424, 18, "模式", 1, False),
    (293, 424, 18, "编码层数", 1, False),
    (543, 424, 18, "板上耗时", 1, False),
)


def clean_backdrop(canvas):
    for box, _ in LOGOS:
        crop = canvas.crop(box)
        mask = crop.convert("L").point(lambda value: 255 if value < 196 else 0).filter(ImageFilter.MaxFilter(3))
        # 以相邻浅色像素填回标志原来的位置，保留竞赛底纹和边框。
        filled = crop.filter(ImageFilter.MaxFilter(9)).filter(ImageFilter.GaussianBlur(1))
        canvas.paste(filled, box[:2], mask)


def logo_index(rgb, colors):
    r, g, b = rgb
    if r >= 121 or (r >= 75 and g >= 185 and b >= 201):
        return 0
    return 1 + min(range(3), key=lambda i: sum((a - b) ** 2 for a, b in zip(rgb, colors[i])))


def pack(fields):
    value = 0
    for field, width in fields:
        if not 0 <= field < 1 << width:
            raise ValueError(f"显示区域字段超出 {width} 位")
        value = (value << width) | field
    return value


def append_tiles(layer, row_height, bits, codes, indices):
    for y in range(0, layer.height, row_height):
        for x in range(0, layer.width, 4):
            tile = layer.crop((x, y, x + 4, y + row_height)).tobytes()
            word = sum(code << (bits * i) for i, code in enumerate(tile))
            indices.append(codes.setdefault(word, len(codes)))


def encode_logos(canvas, codes, indices):
    regions, palettes = [], []
    for box, colors in LOGOS:
        crop = canvas.crop(box)
        layer = Image.new("L", crop.size)
        pixels = crop.tobytes()
        layer.putdata([logo_index(pixels[i:i + 3], colors) for i in range(0, len(pixels), 3)])
        cols = (layer.width + 3) // 4
        regions.append(pack(((box[0], 11), (box[1], 10), (layer.width, 8), (layer.height, 6),
                             (len(indices), 12), (cols, 6))))
        palettes.extend([0, *(int.from_bytes(bytes(rgb), "big") for rgb in colors)])
        append_tiles(layer, 2, 2, codes, indices)
    write_rom("an970_detail_logo_regions.mem", regions, "014x")
    write_rom("an970_detail_logo_palette.mem", palettes, "06x")


def encode_labels(font_dir, codes, indices):
    regions = []
    for x, y, size, label, color, bold in LABELS:
        mask = Image.new("L", (256, 48))
        font = ImageFont.truetype(str(font_dir / ("msyhbd.ttc" if bold else "msyh.ttc")), size)
        ImageDraw.Draw(mask).text((0, 0), label, fill=255, font=font, anchor="lt")
        mask = mask.point(lambda coverage: int(coverage >= 96))
        bounds = mask.getbbox()
        sprite = mask.crop(bounds)
        cols = (sprite.width + 3) // 4
        regions.append(pack(((x + bounds[0], 11), (y + bounds[1], 10), (sprite.width, 8), (sprite.height, 6),
                             (len(indices), 12), (cols, 6), (color, 2))))
        append_tiles(sprite, 4, 1, codes, indices)
    write_rom("an970_detail_text_regions.mem", regions, "014x")


def encode_details(canvas, font_dir):
    codes, indices = {}, []
    encode_logos(canvas, codes, indices)
    encode_labels(font_dir, codes, indices)
    if len(indices) > 3584 or len(codes) > 1024:
        raise ValueError("标志和静态文字图块超出片上容量")
    # 标志和小字的显示区域互不重叠，共用一份 16 位图块 ROM。
    write_rom("an970_detail_map.mem", indices + [0] * (3584 - len(indices)), "03x")
    write_rom("an970_detail_tiles.mem", [*codes, *([0] * (1024 - len(codes)))], "04x")
    print(f"清晰图层复用 {len(codes)} 个图块，覆盖 {len(indices)} 处位置")
