"""Картинка для превью ссылки (og:image) страницы скачивания: site/assets/og.jpg, 1200×630.
Лёд и шрифты — из приложения. Запуск: python3 tools/site/og.py"""
import os

from PIL import Image, ImageDraw, ImageFilter, ImageFont

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..")
APP = os.path.join(ROOT, "app", "assets")
W, H = 1200, 630
BG, INK, INK2, ACCENT = (241, 246, 251), (11, 26, 42), (74, 96, 119), (29, 99, 173)


def font(name, size):
    return ImageFont.truetype(os.path.join(APP, "fonts", name), size)


ice = Image.open(os.path.join(APP, "images", "ice-light.jpg")).convert("RGB")
ice = ice.resize((W, round(ice.height * W / ice.width)), Image.LANCZOS).crop((0, 0, W, H))
veil = Image.new("RGB", (W, H), BG)
mask = Image.linear_gradient("L").resize((W, H))  # сверху прозрачно, книзу — фон
img = Image.composite(veil, ice, mask.point(lambda v: 70 + v * 185 // 255))

icon = Image.open(os.path.join(APP, "icon", "icon.png")).convert("RGBA").resize((236, 236), Image.LANCZOS)
round_mask = Image.new("L", icon.size, 0)
ImageDraw.Draw(round_mask).rounded_rectangle((0, 0, 235, 235), radius=54, fill=255)
shadow = Image.new("RGBA", (W, H), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle((96, 214, 96 + 236, 214 + 236), radius=54, fill=(10, 35, 66, 90))
img = Image.alpha_composite(img.convert("RGBA"), shadow.filter(ImageFilter.GaussianBlur(22)))
img.paste(icon, (96, 197), round_mask)

d = ImageDraw.Draw(img)
x = 392
d.text((x + 2, 212), "КАЛЕНДАРЬ СТАРТОВ", font=font("GolosText-Bold.ttf", 25), fill=ACCENT, spacing=0)
d.text((x - 2, 250), "Фигурное", font=font("Piazzolla-Medium.ttf", 94), fill=INK)
d.text((x - 2, 342), "катание", font=font("Piazzolla-Medium.ttf", 94), fill=INK)
d.text((x + 2, 474), "Android, iPhone, Windows, Mac и браузер", font=font("GolosText-Medium.ttf", 28), fill=INK2)
img.convert("RGB").save(os.path.join(ROOT, "site", "assets", "og.jpg"), quality=86, optimize=True, progressive=True)
