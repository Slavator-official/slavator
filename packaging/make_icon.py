#!/usr/bin/env python3
"""Сборка иконки Славатора из портрета. Только стандартная библиотека.

    python3 make_icon.py <исходник.png> [результат.png]
    python3 make_icon.py --tint РРGGBB[:сила] <иконка.png> <результат.png>

Что делает: вырезает квадрат вокруг лица, масштабирует его методом ближайшего
соседа (пиксель-арт нельзя размывать интерполяцией), вписывает в squircle -
скруглённый квадрат по форме иконок macOS - и кладёт на подложку цвета
приложения, чтобы иконка читалась и на светлом, и на тёмном фоне.

Режим --tint красит готовую иконку в заданный цвет. Он нужен сборке: на
машине разработчика рабочих копий репозитория несколько, и приложения из
них раньше выглядели одинаково — в Spotlight и Launchpad висели три
«Славатора», и какой из них свежий, было видно только по дате файла.
Теперь копия из рабочего дерева красится, а сборка из основной — нет.
"""
import struct
import sys
import zlib
from pathlib import Path

OUT_SIZE = 2048
FIELD = 0.404          # доля холста под саму плитку: вокруг остаётся отступ
BACKDROP = (0x1B, 0x3E, 0x9E)   # подложка под краями портрета

# Куда смотреть при кадрировании: доли ширины/высоты исходника. Лицо на
# портрете смещено влево и вверх от геометрического центра.
FOCUS_X, FOCUS_Y = 0.47, 0.42
CROP = 0.86            # какую часть меньшей стороны берём в кадр


# --------------------------------------------------------------------------
# Чтение PNG
# --------------------------------------------------------------------------

def _paeth(a: int, b: int, c: int) -> int:
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def read_png(path: Path):
    """Вернуть (ширина, высота, пиксели RGBA как bytearray)."""
    data = path.read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise SystemExit(f"{path} — это не PNG")

    pos = 8
    width = height = depth = colour = 0
    idat = bytearray()
    palette = b""
    while pos < len(data):
        length = struct.unpack(">I", data[pos:pos + 4])[0]
        tag = data[pos + 4:pos + 8]
        body = data[pos + 8:pos + 8 + length]
        pos += 12 + length
        if tag == b"IHDR":
            width, height, depth, colour = struct.unpack(">IIBB", body[:10])
        elif tag == b"PLTE":
            palette = body
        elif tag == b"IDAT":
            idat += body
        elif tag == b"IEND":
            break

    if depth != 8:
        raise SystemExit(f"Поддерживается только глубина 8 бит, а здесь {depth}")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(colour)
    if channels is None:
        raise SystemExit(f"Неподдерживаемый тип цвета PNG: {colour}")

    raw = zlib.decompress(bytes(idat))
    stride = width * channels
    out = bytearray(width * height * 4)
    previous = bytearray(stride)
    offset = 0

    for row in range(height):
        filter_type = raw[offset]
        offset += 1
        line = bytearray(raw[offset:offset + stride])
        offset += stride

        if filter_type == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif filter_type == 2:
            for i in range(stride):
                line[i] = (line[i] + previous[i]) & 0xFF
        elif filter_type == 3:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((left + previous[i]) >> 1)) & 0xFF
        elif filter_type == 4:
            for i in range(stride):
                left = line[i - channels] if i >= channels else 0
                upleft = previous[i - channels] if i >= channels else 0
                line[i] = (line[i] + _paeth(left, previous[i], upleft)) & 0xFF

        base = row * width * 4
        for x in range(width):
            src = x * channels
            if colour == 6:
                r, g, b, a = line[src], line[src + 1], line[src + 2], line[src + 3]
            elif colour == 2:
                r, g, b, a = line[src], line[src + 1], line[src + 2], 255
            elif colour == 0:
                r = g = b = line[src]; a = 255
            elif colour == 4:
                r = g = b = line[src]; a = line[src + 1]
            else:  # палитра
                idx = line[src] * 3
                r, g, b = palette[idx], palette[idx + 1], palette[idx + 2]
                a = 255
            out[base + x * 4:base + x * 4 + 4] = bytes((r, g, b, a))
        previous = line

    return width, height, out


# --------------------------------------------------------------------------
# Форма иконки
# --------------------------------------------------------------------------

def squircle_alpha(x: float, y: float, radius: float, power: float = 5.0) -> float:
    value = (abs(x) / radius) ** power + (abs(y) / radius) ** power
    edge = value ** (1.0 / power)
    feather = 2.5 / radius
    if edge <= 1.0 - feather:
        return 1.0
    if edge >= 1.0:
        return 0.0
    return (1.0 - edge) / feather


def build(src: Path, dst: Path) -> None:
    width, height, pixels = read_png(src)
    print(f"исходник: {width}×{height}")

    side = int(min(width, height) * CROP)
    left = int(width * FOCUS_X - side / 2)
    top = int(height * FOCUS_Y - side / 2)
    left = max(0, min(left, width - side))
    top = max(0, min(top, height - side))
    print(f"кадр: {side}×{side} от ({left}, {top})")

    size = OUT_SIZE
    half = size / 2.0
    field = size * FIELD
    rows = []

    for py in range(size):
        row = bytearray()
        y = py - half + 0.5
        # Ближайший сосед: интерполяция превратила бы пиксель-арт в кашу.
        sy = top + int((py / size) * side)
        sy = max(0, min(sy, height - 1))
        for px in range(size):
            x = px - half + 0.5
            alpha = squircle_alpha(x, y, field)
            if alpha <= 0.0:
                row += b"\x00\x00\x00\x00"
                continue
            sx = left + int((px / size) * side)
            sx = max(0, min(sx, width - 1))
            base = (sy * width + sx) * 4
            r, g, b, a = pixels[base], pixels[base + 1], pixels[base + 2], pixels[base + 3]
            if a < 255:  # прозрачные места портрета кладём на подложку
                k = a / 255.0
                r = int(r * k + BACKDROP[0] * (1 - k))
                g = int(g * k + BACKDROP[1] * (1 - k))
                b = int(b * k + BACKDROP[2] * (1 - k))
            row += bytes((r, g, b, int(alpha * 255)))
        rows.append(row)

    write_png(dst, size, size, b"".join(bytes(r) for r in rows))
    print(f"готово: {dst} ({dst.stat().st_size // 1024} КБ, {size}×{size})")


def write_png(dst: Path, width: int, height: int, pixels: bytes) -> None:
    """Записать RGBA-пиксели в PNG без фильтров."""
    stride = width * 4
    raw = b"".join(b"\x00" + pixels[row * stride:(row + 1) * stride]
                   for row in range(height))

    def chunk(tag: bytes, body: bytes) -> bytes:
        payload = tag + body
        return struct.pack(">I", len(body)) + payload + struct.pack(">I", zlib.crc32(payload))

    dst.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def tint(src: Path, dst: Path, colour: tuple, strength: float) -> None:
    """Покрасить готовую иконку, сохранив рисунок.

    Пиксель тянется к заданному цвету тем сильнее, чем он светлее: тени
    остаются тёмными, и портрет читается — иначе получилась бы плоская
    цветная плитка. Прозрачные места (поле вокруг squircle) не трогаем,
    иначе вокруг иконки появится цветной квадрат.
    """
    width, height, pixels = read_png(src)
    for i in range(0, len(pixels), 4):
        if pixels[i + 3] == 0:
            continue
        r, g, b = pixels[i], pixels[i + 1], pixels[i + 2]
        light = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
        k = strength * (0.35 + 0.65 * light)
        pixels[i] = min(255, int(r * (1 - k) + colour[0] * k))
        pixels[i + 1] = min(255, int(g * (1 - k) + colour[1] * k))
        pixels[i + 2] = min(255, int(b * (1 - k) + colour[2] * k))
    write_png(dst, width, height, bytes(pixels))
    print(f"покрашено: {dst} ({dst.stat().st_size // 1024} КБ, {width}×{height})")


if __name__ == "__main__":
    args = sys.argv[1:]
    if args and args[0] == "--tint":
        if len(args) < 4:
            raise SystemExit("--tint RRGGBB[:сила] <иконка.png> <результат.png>")
        spec, rest = args[1], args[2:]
        value, _, force = spec.partition(":")
        colour = tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))
        tint(Path(rest[0]).expanduser(), Path(rest[1]).expanduser(),
             colour, float(force) if force else 0.45)
    else:
        if not args:
            raise SystemExit("Укажите исходное изображение")
        source = Path(args[0]).expanduser()
        target = Path(args[1]) if len(args) > 1 else Path("icon_master.png")
        build(source, target)
