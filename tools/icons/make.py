"""Иконки приложения из слоёв render.js (запуск: python3 make.py <папка слоёв 1024×1024>).

Основной значок — вариант «classic» («Классический · Лёд»): им становятся значки Android (ic_launcher),
iPhone (AppIcon), macOS, Windows (app_icon.ico), веба и assets/icon/*.png.
Пишет:
  • Android: слои в res/drawable-nodpi (icl_*), передний план каждой иконки — layer-list
    (icf_*), адаптивные иконки в mipmap-anydpi-v26 (ic_*), для Android 7 — классический;
    в манифест — по activity-alias на иконку (у значка с числом — на каждый день месяца:
    число в значке рисуется заранее, ставится включением нужного alias в полночь);
  • iPhone: альтернативные иконки без числа (число на iPhone не обновить без вопроса системы);
  • приложение: слои для предпросмотра и иконки окна на компьютере, список вариантов.
Повторный запуск перезаписывает всё сгенерированное.
"""
import io
import json
import os
import re
import shutil
import struct
import sys

from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
APP = os.path.join(HERE, "..", "..", "app")
RES = os.path.join(APP, "android", "app", "src", "main", "res")
MANIFEST = os.path.join(APP, "android", "app", "src", "main", "AndroidManifest.xml")
IOS_ASSETS = os.path.join(APP, "ios", "Runner", "Assets.xcassets")
FLUTTER_ASSETS = os.path.join(APP, "assets", "icon", "layers")
A = 'xmlns:android="http://schemas.android.com/apk/res/android"'

cfg = json.load(open(os.path.join(HERE, "variants.json"), encoding="utf-8"))


def write(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def names(v):
    """[(суффикс ресурса, день или None)] для варианта."""
    if v["group"] == "date":
        return [(f"{v['id']}_{d}", d) for d in range(1, 32)]
    return [(v["id"], None)]


def tint(im, hexc):
    r, g, b = (int(hexc[i:i + 2], 16) for i in (1, 3, 5))
    c = Image.new("RGBA", im.size, (r, g, b, 255))
    c.putalpha(im.getchannel("A"))
    return c


def compose(src, v, day):
    im = Image.open(os.path.join(src, "bg.png")).convert("RGBA")
    im.alpha_composite(Image.open(os.path.join(src, "skater.png")).convert("RGBA"))
    if v["group"] == "date":
        im.alpha_composite(Image.open(os.path.join(src, f"num_{day}_fill.png")).convert("RGBA"))
        im.alpha_composite(tint(Image.open(os.path.join(src, f"num_{day}_line.png")).convert("RGBA"), cfg["lines"][v["line"]]))
    im.alpha_composite(Image.open(os.path.join(src, f"band_{v['band']}.png")).convert("RGBA"))
    return im


def android(src):
    nodpi = os.path.join(RES, "drawable-nodpi")
    for d in (nodpi, os.path.join(RES, "drawable")):
        if os.path.isdir(d):
            for f in os.listdir(d):
                if f.startswith(("icl_", "icf_", "icb_")):
                    os.unlink(os.path.join(d, f))
    for d in ("mipmap-anydpi-v26", "mipmap"):
        p = os.path.join(RES, d)
        if os.path.isdir(p):
            for f in os.listdir(p):
                if f.startswith("ic_v_"):
                    os.unlink(os.path.join(p, f))
    os.makedirs(nodpi, exist_ok=True)
    # в лаунчере значок не больше 288 px видимой части — слоёв по 512 хватает
    for f in os.listdir(src):
        Image.open(os.path.join(src, f)).resize((512, 512), Image.LANCZOS).save(os.path.join(nodpi, "icl_" + f), optimize=True)
    # прежние слои основного значка больше не нужны
    for d in os.listdir(RES):
        if d.startswith("drawable-") and d != "drawable-nodpi":
            for f in ("ic_launcher_background.png", "ic_launcher_foreground.png", "ic_launcher_monochrome.png"):
                if os.path.exists(os.path.join(RES, d, f)):
                    os.unlink(os.path.join(RES, d, f))
    # фон — общий: однотонная подложка и лёд в видимой части
    write(os.path.join(RES, "drawable", "icb_bg.xml"), f"""<?xml version="1.0" encoding="utf-8"?>
<layer-list {A}>
  <item><color android:color="#123F72"/></item>
  <item><inset android:drawable="@drawable/icl_bg" android:inset="16%"/></item>
</layer-list>
""")
    aliases = []
    for v in cfg["variants"]:
        for suffix, day in names(v):
            items = ['    <item><bitmap android:src="@drawable/icl_skater"/></item>']
            if day:
                items.append(f'    <item><bitmap android:src="@drawable/icl_num_{day}_fill"/></item>')
                items.append(f'    <item><bitmap android:src="@drawable/icl_num_{day}_line" android:tint="{cfg["lines"][v["line"]]}"/></item>')
            items.append(f'    <item><bitmap android:src="@drawable/icl_band_{v["band"]}"/></item>')
            write(os.path.join(RES, "drawable", f"icf_{suffix}.xml"), f"""<?xml version="1.0" encoding="utf-8"?>
<inset {A} android:inset="16%">
  <layer-list>
{chr(10).join(items)}
  </layer-list>
</inset>
""")
            adaptive = f"""<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon {A}>
  <background android:drawable="@drawable/icb_bg"/>
  <foreground android:drawable="@drawable/icf_{suffix}"/>
</adaptive-icon>
"""
            if v["id"] == "classic":
                # основной значок: ic_launcher и псевдоним .MainActivity в манифесте
                write(os.path.join(RES, "mipmap-anydpi-v26", "ic_launcher.xml"), adaptive)
                for d, px in (("mdpi", 48), ("hdpi", 72), ("xhdpi", 96), ("xxhdpi", 144), ("xxxhdpi", 192)):
                    compose(src, v, None).resize((px, px), Image.LANCZOS).convert("RGB").save(
                        os.path.join(RES, f"mipmap-{d}", "ic_launcher.png"), optimize=True)
                continue
            write(os.path.join(RES, "mipmap-anydpi-v26", f"ic_v_{suffix}.xml"), adaptive)
            # до Android 8 адаптивных иконок нет — там всегда классический
            write(os.path.join(RES, "mipmap", f"ic_v_{suffix}.xml"), f"""<?xml version="1.0" encoding="utf-8"?>
<bitmap {A} android:src="@mipmap/ic_launcher"/>
""")
            aliases.append(f"""        <activity-alias
            android:name=".icon.{suffix}"
            android:targetActivity=".AppActivity"
            android:enabled="false"
            android:exported="true"
            android:icon="@mipmap/ic_v_{suffix}">
            <intent-filter>
                <action android:name="android.intent.action.MAIN"/>
                <category android:name="android.intent.category.LAUNCHER"/>
            </intent-filter>
        </activity-alias>""")
    m = open(MANIFEST, encoding="utf-8").read()
    block = "        <!-- иконки: создано tools/icons/make.py -->\n" + "\n".join(aliases) + "\n        <!-- /иконки -->"
    if "<!-- иконки: создано" in m:
        m = re.sub(r"        <!-- иконки: создано.*?<!-- /иконки -->", lambda _: block, m, flags=re.S)
    else:
        m = m.replace("        <!-- Don't delete the meta-data below.", block + "\n        <!-- Don't delete the meta-data below.", 1)
    open(MANIFEST, "w", encoding="utf-8").write(m)
    return len(aliases)


def rounded(img, inset=0.0, radius=0.2237):
    """Квадрат со скруглёнными углами и прозрачными полями. inset — поля с каждой стороны (доля стороны),
    radius — доля стороны самой плашки. Маска рисуется вчетверо крупнее, чтобы край был гладким."""
    n = img.width
    k = 4
    box = round(n * (1 - 2 * inset))
    off = (n - box) // 2
    mask = Image.new("L", (n * k, n * k), 0)
    ImageDraw.Draw(mask).rounded_rectangle(
        (off * k, off * k, (off + box) * k - 1, (off + box) * k - 1), radius=box * radius * k, fill=255)
    # усреднение, а не LANCZOS: тот «звенит» и оставляет в углах альфу 1–2 вместо нуля
    mask = mask.reduce(k)
    out = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    plate = img.convert("RGBA").resize((box, box), Image.LANCZOS)
    out.paste(plate, (off, off))
    out.putalpha(Image.composite(out.getchannel("A"), Image.new("L", (n, n), 0), mask))
    return out


MAC_INSET = 100 / 1024  # поля по шаблону macOS: плашка 824 из 1024
WIN_RADIUS = 0.2
# панель задач, ярлыки и Проводник при 100–200 % масштаба берут 16…64, крупные виды — 96…256
WIN_SIZES = (16, 20, 24, 30, 32, 36, 40, 48, 60, 64, 72, 80, 96, 128, 256)


def bmp_frame(im):
    """Кадр ICO в классическом виде: 32-битный BMP с альфой и маской AND (прозрачное — 1).
    Мелкие кадры — только так: PNG внутри ICO читают не все места оболочки Windows."""
    n = im.width
    px = im.transpose(Image.FLIP_TOP_BOTTOM).tobytes("raw", "BGRA")
    row = ((n + 31) // 32) * 4
    alpha = im.getchannel("A").transpose(Image.FLIP_TOP_BOTTOM).tobytes()
    mask = bytearray(row * n)
    for y in range(n):
        for x in range(n):
            if alpha[y * n + x] == 0:
                mask[y * row + x // 8] |= 0x80 >> (x % 8)
    head = struct.pack("<IiiHHIIiiII", 40, n, n * 2, 1, 32, 0, len(px) + len(mask), 0, 0, 0, 0)
    return head + px + bytes(mask)


def write_ico(path, frames):
    """ICO из готовых кадров: каждый размер нарисован отдельно (Pillow сам ужимает из одного крупного
    и пишет все кадры PNG). 256 — PNG, как принято, меньше — BMP."""
    blobs = []
    for im in frames:
        if im.width >= 256:
            b = io.BytesIO()
            im.save(b, "PNG", optimize=True)
            blobs.append(b.getvalue())
        else:
            blobs.append(bmp_frame(im))
    out = struct.pack("<HHH", 0, 1, len(frames))
    off = 6 + 16 * len(frames)
    for im, blob in zip(frames, blobs):
        s = im.width % 256  # 256 записывается нулём
        out += struct.pack("<BBBBHHII", s, s, 0, 0, 1, 32, len(blob), off)
        off += len(blob)
    with open(path, "wb") as f:
        f.write(out + b"".join(blobs))


def desktop_icons(big):
    """macOS и Windows сами углы не скругляют (iPhone и Android — да): рисуем в самой картинке."""
    mac = rounded(big.convert("RGB").resize((1024, 1024), Image.LANCZOS), inset=MAC_INSET)
    base = os.path.join(APP, "macos", "Runner", "Assets.xcassets", "AppIcon.appiconset")
    for im in json.load(open(os.path.join(base, "Contents.json")))["images"]:
        px = round(float(im["size"].split("x")[0]) * int(im["scale"][0]))
        mac.resize((px, px), Image.LANCZOS).save(os.path.join(base, im["filename"]), optimize=True)
    # каждый размер — своя плашка со своей маской: углы прозрачны в каждом кадре, а не только в крупном
    rgb = big.convert("RGB")
    write_ico(os.path.join(APP, "windows", "runner", "resources", "app_icon.ico"),
              [rounded(rgb.resize((s, s), Image.LANCZOS), radius=WIN_RADIUS) for s in WIN_SIZES])


def main_icon(src):
    """Основной значок на всех платформах — «classic»."""
    v = next(x for x in cfg["variants"] if x["id"] == "classic")
    big = compose(src, v, None).convert("RGB")
    icon_dir = os.path.join(APP, "assets", "icon")
    big.save(os.path.join(icon_dir, "icon.png"), optimize=True)
    Image.open(os.path.join(src, "bg.png")).convert("RGB").save(os.path.join(icon_dir, "background.png"), optimize=True)
    fg = Image.open(os.path.join(src, "skater.png")).convert("RGBA")
    fg.alpha_composite(Image.open(os.path.join(src, f"band_{v['band']}.png")).convert("RGBA"))
    fg.save(os.path.join(icon_dir, "foreground.png"), optimize=True)
    base = os.path.join(IOS_ASSETS, "AppIcon.appiconset")
    for im in json.load(open(os.path.join(base, "Contents.json")))["images"]:
        px = round(float(im["size"].split("x")[0]) * int(im["scale"][0]))
        big.resize((px, px), Image.LANCZOS).save(os.path.join(base, im["filename"]), optimize=True)
    desktop_icons(big)
    web = os.path.join(APP, "web")
    big.resize((16, 16), Image.LANCZOS).save(os.path.join(web, "favicon.png"))
    for name, px in (("Icon-192.png", 192), ("Icon-512.png", 512), ("Icon-maskable-192.png", 192), ("Icon-maskable-512.png", 512)):
        big.resize((px, px), Image.LANCZOS).save(os.path.join(web, "icons", name), optimize=True)


def ios(src):
    out = []
    for f in os.listdir(IOS_ASSETS):
        if f.startswith(("skate_", "date_")) and f.endswith(".appiconset"):
            shutil.rmtree(os.path.join(IOS_ASSETS, f))
    for v in cfg["variants"]:
        # на iPhone — без числа: сменить его каждый день без вопроса системы нельзя
        if v["group"] != "classic" or v["id"] == "classic":
            continue
        d = os.path.join(IOS_ASSETS, f"{v['id']}.appiconset")
        os.makedirs(d, exist_ok=True)
        compose(src, v, None).convert("RGB").save(os.path.join(d, "icon.png"), optimize=True)
        write(os.path.join(d, "Contents.json"), json.dumps({
            "images": [{"filename": "icon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
            "info": {"author": "xcode", "version": 1},
        }, indent=2) + "\n")
        out.append(v["id"])
    pbx = os.path.join(APP, "ios", "Runner.xcodeproj", "project.pbxproj")
    t = open(pbx, encoding="utf-8").read()
    t = re.sub(r'ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "[^"]*";',
               f'ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES = "{" ".join(out)}";', t)
    open(pbx, "w", encoding="utf-8").write(t)
    return out


def flutter(src):
    if os.path.isdir(FLUTTER_ASSETS):
        shutil.rmtree(FLUTTER_ASSETS)
    os.makedirs(FLUTTER_ASSETS)
    keep = ["bg.png", "skater.png"] + [f"band_{b}.png" for b in cfg["bands"]]
    for f in keep:
        Image.open(os.path.join(src, f)).resize((256, 256), Image.LANCZOS).save(os.path.join(FLUTTER_ASSETS, f), optimize=True)
    shutil.copy(os.path.join(HERE, "variants.json"), os.path.join(APP, "assets", "icon", "variants.json"))


if __name__ == "__main__":
    if sys.argv[1] == "--desktop":
        # только значки компьютера из готового assets/icon/icon.png (без слоёв)
        desktop_icons(Image.open(os.path.join(APP, "assets", "icon", "icon.png")).convert("RGB"))
        sys.exit(0)
    src = sys.argv[1]
    n = android(src)
    main_icon(src)
    ids = ios(src)
    flutter(src)
    print(f"Android: {n} иконок; iPhone: {', '.join(ids)}")
