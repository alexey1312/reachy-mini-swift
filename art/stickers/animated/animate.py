#!/usr/bin/env python3
"""
Аниматор стикеров Reachy Mini -> Telegram video stickers (.webm, VP9, alpha).

Модель движения
---------------
Каждая антенна режется в отдельный слой и крутится вокруг СВОЕГО основания.
Угол антенны складывается из двух частей:

1. АКТИВНАЯ поза. На живом Reachy антенны моторизованы — это его основная мимика,
   поэтому они не просто болтаются, а двигаются осмысленно: настораживаются,
   разъезжаются от удивления, качаются в такт.
2. ПАССИВНОЕ запаздывание. Затухающий осциллятор, который раскачивают ускорения
   головы (угловое и линейное). Даёт follow-through — вторичная масса догоняет
   основную.

Две степени свободы:
    swing — обе антенны в одну сторону (реакция на горизонтальные ускорения);
    splay — врозь / вместе (реакция на вертикальные: подпрыгнул — разъехались).

Углы антенн ОТНОСИТЕЛЬНЫЕ: слой антенн потом поворачивается вместе с головой
как единая группа. Складывать сюда угол головы нельзя — он применится дважды.

Использование:
    python3 animate.py <input.png> <preset> <output_basename> [кадров]
"""
import math
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image
from scipy import ndimage

FPS = 30
SIZE = 512
BASE_SCALE = 0.80      # запас у краёв, чтобы поворот и «дыхание» не срезали углы
STEM_EXT = 44          # длина огрызка стержня под головой (обрезается по её силуэту)
ANT_LEN = 130.0        # эффективная длина антенны, px — для пересчёта ускорений

# параметры пассивного осциллятора
SWING_HZ, SWING_ZETA = 1.7, 0.24
SPLAY_HZ, SPLAY_ZETA = 2.3, 0.30
PASSIVE_GAIN = 1.0
MAX_ANGLE = 26.0       # предохранитель от «вертолёта» на резких кадрах

# Режим --diecut: на вход подаются чистые «чернила» без белой обводки, а обводка
# и её серый кант рисуются заново на каждом кадре по силуэту. Нужен там, где
# обводка антенн слипается с обводкой головы: запечённая в PNG, она осталась бы
# стоять на месте, и антенны отъезжали бы от головы отдельным слоем.
DIECUT = False
R_WHITE, R_SHADOW = 16.0, 17.7      # радиусы обводки и канта, px при SIZE=512
C_WHITE, C_SHADOW = (236, 237, 237), (201, 201, 201)


# ---------------------------------------------------------------- сегментация
def _antenna_layer(px, mask, split_y, head_alpha):
    """Слой одной антенны. Ось вращения — её собственное основание.

    Вниз дорисовывается короткий огрызок стержня, чтобы при повороте в стыке не
    появлялся просвет. Огрызок обрезается по силуэту головы: иначе у тех
    персонажей, где антенна выходит за край шляпы, он торчал бы наружу и антенна
    выглядела бы неестественно длинной.
    """
    ys = np.where(mask.any(axis=1))[0]
    if len(ys) == 0:
        return None, None
    yb = int(ys.max())
    row_mask = mask[yb]
    xs = np.where(row_mask)[0]
    if len(xs) == 0:
        return None, None

    layer = np.zeros_like(px)
    layer[:split_y][mask] = px[:split_y][mask]

    stem = np.zeros_like(px[0])
    stem[row_mask] = px[yb][row_mask]
    end = min(SIZE, yb + 1 + STEM_EXT)
    block = np.repeat(stem[None, :, :], end - yb - 1, axis=0)
    block[~head_alpha[yb + 1:end]] = 0      # оставляем только то, что скроет голова
    layer[yb + 1:end] = block

    return Image.fromarray(layer), (float(xs.mean()), float(yb))


def split_antennas(img: Image.Image):
    """-> ([(слой, опора) слева направо], слой головы). Антенны могут не найтись."""
    alpha = np.array(img.getchannel("A")) > 100
    # Линия реза — там, где начинается широкий силуэт головы или шляпы.
    # Количество кусков выше неё не ограничиваем: у мага между антеннами торчит
    # шпиль колпака, его отсеет фильтр по вытянутости.
    split_y = None
    for y in range(alpha.shape[0]):
        lab, n = ndimage.label(alpha[y])
        if n and max(int((lab == i).sum()) for i in range(1, n + 1)) >= 90:
            split_y = y
            break
    if split_y is None or split_y < 40:
        return [], img

    px = np.array(img)
    lab, n = ndimage.label(alpha[:split_y])
    comps = []
    for i in range(1, n + 1):
        m = lab == i
        ys, xs = np.where(m)
        if len(ys) < 30:
            continue
        h, w = ys.max() - ys.min() + 1, xs.max() - xs.min() + 1
        comps.append(dict(mask=m, ratio=h / max(w, 1), h=int(h), cx=float(xs.mean())))

    # Антенны — самый вытянутый элемент слева от центра и такой же справа.
    # Брать просто «два самых вытянутых» нельзя: у мага между антеннами торчит
    # шпиль колпака, и на наклонённой шляпе он бывает вытянутее самих антенн.
    def best(side):
        cand = [c for c in comps
                if side * (c["cx"] - SIZE / 2) > 0 and c["ratio"] >= 1.2 and c["h"] >= 40]
        return max(cand, key=lambda c: c["ratio"]) if cand else None

    left, right = best(-1), best(+1)
    if left is None or right is None:
        return [], img            # антенн не видно — шляпа закрывает их целиком
    ants = [left, right]
    rest = [c for c in comps if id(c) not in {id(a) for a in ants}]

    head_px = px.copy()
    head_px[:split_y, :, 3] = 0
    for c in rest:                       # всё лишнее сверху остаётся частью головы
        region = head_px[:split_y]
        region[c["mask"]] = px[:split_y][c["mask"]]

    head_img = Image.fromarray(head_px)
    head_alpha = head_px[:, :, 3] > 0

    layers = []
    for c in ants:
        layer, pivot = _antenna_layer(px, c["mask"], split_y, head_alpha)
        if layer is not None:
            layers.append((layer, pivot))
    if len(layers) != 2:
        return [], img
    return layers, head_img


def redraw_diecut(layer):
    """Белая обводка + серый кант по силуэту чернил. Порог по расстоянию берётся
    с полушагом — это даёт то же сглаживание края, что и настоящий растеризатор."""
    a = layer.getchannel("A")
    # поле расстояний считаем на удвоенном разрешении: по бинарной маске 512 край
    # обводки получается ступенчатым, а лишний уровень детализации потом всё равно
    # съедается общим уменьшением кадра
    big = np.array(a.resize((SIZE * 2, SIZE * 2), Image.LANCZOS)) > 128
    d = ndimage.distance_transform_edt(~big) / 2.0          # обратно в пиксели 512
    out = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    for radius, color in ((R_SHADOW, C_SHADOW), (R_WHITE, C_WHITE)):
        m = ndimage.binary_fill_holes(d <= radius)          # внутренние пустоты — тоже белые
        cover = (np.clip(radius + 0.25 - d, 0.0, 1.0) * m)
        cover = cover.reshape(SIZE, 2, SIZE, 2).mean(axis=(1, 3))
        rgba = np.zeros((SIZE, SIZE, 4), np.uint8)
        rgba[..., 0], rgba[..., 1], rgba[..., 2] = color
        rgba[..., 3] = np.rint(cover * 255).astype(np.uint8)
        out.alpha_composite(Image.fromarray(rgba))
    out.alpha_composite(layer)
    return out


def split_antennas_diecut(img: Image.Image):
    """Сегментация для чистых чернил (режим --diecut).

    Здесь горизонтальный рез не нужен и вреден: без запечённой обводки антенна —
    самостоятельная фигура, она физически не соприкасается с головой, их связывает
    только белая обводка, а её мы всё равно рисуем заново. Поэтому берём связные
    компоненты целиком: самая крупная — голова с коробкой, всё, что висит над её
    макушкой, — антенны. Каждая вращается вокруг своей нижней точки, поэтому
    основание остаётся на месте и обводка каждый кадр снова смыкает стык.
    """
    alpha = np.array(img.getchannel("A")) > 100
    px = np.array(img)
    lab, n = ndimage.label(alpha)
    if n < 3:
        return [], img
    areas = ndimage.sum(alpha, lab, range(1, n + 1))
    main = int(np.argmax(areas)) + 1
    main_top = int(np.where(lab == main)[0].min())

    groups = {-1: None, +1: None}
    used = np.zeros_like(alpha)
    for i in range(1, n + 1):
        if i == main:
            continue
        m = lab == i
        ys, xs = np.where(m)
        if ys.max() > main_top + 0.10 * SIZE:      # мелкие пометки на коробке — не антенны
            continue
        side = -1 if xs.mean() < SIZE / 2 else +1
        groups[side] = m if groups[side] is None else (groups[side] | m)
        used |= m
    if groups[-1] is None or groups[+1] is None:
        return [], img

    head_px = px.copy()
    # порог alpha>100 оставляет в голове полупрозрачную кромку антенны — она бы
    # стояла призраком на месте, поэтому вырезаем с запасом в пару пикселей
    head_px[ndimage.binary_dilation(used, iterations=2), 3] = 0
    head_img = Image.fromarray(head_px)

    layers = []
    for side in (-1, +1):
        m = groups[side]
        layer = np.zeros_like(px)
        layer[m] = px[m]
        ys, xs = np.where(m)
        yb = int(ys.max())
        row = np.where(m[yb])[0]
        layers.append((Image.fromarray(layer), (float(row.mean()), float(yb))))
    return layers, head_img


def rotate_about(img, angle, pivot):
    if abs(angle) < 1e-3:
        return img
    px, py = pivot
    r = math.radians(-angle)
    c, s = math.cos(r), math.sin(r)
    m = (c, s, px - c * px - s * py, -s, c, py + s * px - c * py)
    return img.transform(img.size, Image.AFFINE, m, resample=Image.BICUBIC)


# --------------------------------------------------------- движение головы
# Пятнадцать пресетов, по одному на персонажа. Каждый отличается не амплитудой,
# а формой сигнала: числом гармоник, наличием удержаний, импульсов и фазового
# сдвига между вращением и сдвигом. Похожие по амплитуде, но одинаковые по форме
# движения глаз читает как одно и то же, поэтому важна именно форма.

def ease_io(t):
    return 0.5 - 0.5 * math.cos(math.pi * t)


def hold(t, rise=0.22, until=0.55):
    """0 -> 1 -> удержание -> 0. На стыке цикла производная нулевая."""
    if t < until:
        return ease_io(min(1.0, t / rise))
    return ease_io(max(0.0, 1.0 - (t - until) / rise))


# Подъём в позу не короче 0.16 цикла (~0.32 с, пять кадров при 15 fps). С 0.10–0.12
# поза менялась за три-четыре кадра стикера iMessage, и подъём читался рывком.
# Голова и антенны берут одни и те же числа, иначе они разойдутся по фазе.
_SCAN_HOLD = (0.16, 0.30)       # (rise, until) для hold()
_RAISE_HOLD = (0.16, 0.45)


def _pulse(t, at, width=0.07):
    """Гауссов импульс в момент at, замкнутый по кольцу цикла.

    Ширина 0.07 цикла — это ~0.14 с, около четырёх кадров при 15 fps. При 0.045
    поклёвка укладывалась в два-три кадра стикера iMessage и читалась рывком.
    """
    d = abs(t - at)
    return math.exp(-(min(d, 1.0 - d) / width) ** 2)


def _strikes(t, n=3):
    """n ударов вниз за цикл. Куб приподнятого косинуса сужает удар и растягивает
    паузу между ударами; спуск к удару и подъём после него симметричны."""
    return ((1 - math.cos(2 * math.pi * n * t)) / 2) ** 3


def _settle(t, start=0.78, span=0.22):
    """Гасит остаток движения к концу цикла: на шве и значение, и производная нулевые."""
    return 1.0 - ease_io(min(1.0, max(0.0, (t - start) / span)))


def _toss(u):
    """Замах перед ударом: мягко приподняли (0->1), потом падение с ускорением (1->0).

    В конце производная НЕ нулевая — коробка приходит в стол на скорости, иначе
    удар читается как мягкое касание.
    """
    return ease_io(u / 0.62) if u < 0.62 else 1.0 - ((u - 0.62) / 0.38) ** 2


_IMP_A, _IMP_D = 45.0, 11.0
_IMP_PEAK = math.log(1 + _IMP_A / _IMP_D) / _IMP_A
_IMP_NORM = (1 - math.exp(-_IMP_A * _IMP_PEAK)) * math.exp(-_IMP_D * _IMP_PEAK)


def _impact(s):
    """Удар: фронт за один кадр, затем упругий возврат. Нормирован на 1."""
    return (1 - math.exp(-_IMP_A * s)) * math.exp(-_IMP_D * s) / _IMP_NORM


def _M(rot=0.0, dx=0.0, dy=0.0, sx=1.0, sy=1.0):
    return dict(rot=rot, dx=dx, dy=dy, sx=sx, sy=sy)


def head_curve(name, t):
    """t в [0,1) по циклу -> поворот (град, + против часовой), сдвиг px, масштаб."""
    tau = 2 * math.pi * t

    if name == "float":          # астронавт: дрейф «восьмёркой» в невесомости
        return _M(rot=3.5 * math.sin(tau), dx=9.0 * math.sin(tau),
                  dy=-7.0 * math.sin(2 * tau + 0.7),
                  sx=1 + 0.012 * math.sin(tau), sy=1 + 0.012 * math.sin(tau))

    if name == "hammer":         # строитель: три удара молотком за цикл
        s = _strikes(t, 3)
        return _M(rot=-3.0 * s, dy=14.0 * s,
                  sx=1 + 0.06 * s, sy=1 - 0.07 * s)

    if name == "sail":           # капитан: качка — крен и вертикаль в противофазе
        return _M(rot=7.0 * math.sin(tau), dx=8.0 * math.sin(tau - 0.6),
                  dy=-6.0 * math.cos(tau))

    if name == "laugh":          # повар: хохот, два подскока за цикл
        p = abs(math.sin(2 * tau))
        sq = max(0.0, math.cos(2 * tau))
        return _M(rot=3.0 * math.sin(tau), dy=-12.0 * p,
                  sx=1 + 0.06 * sq - 0.02 * p, sy=1 - 0.07 * sq + 0.03 * p)

    if name == "swagger":        # ковбой: развалистая асимметричная раскачка
        a, b = math.sin(tau), math.sin(2 * tau)
        return _M(rot=6.0 * a + 2.5 * b, dx=-7.0 * a, dy=-3.0 * abs(a))

    if name == "think":          # доктор: склонил голову и держит
        k = hold(t)
        return _M(rot=10.0 * k, dx=-5.0 * k, dy=-2.0 * k)

    if name == "scan":           # исследователь: взгляд влево, пауза, вправо, пауза
        k1 = hold(t, *_SCAN_HOLD)
        k2 = hold((t - 0.5) % 1.0, *_SCAN_HOLD)
        return _M(rot=9.0 * (k1 - k2), dx=-6.0 * (k1 - k2), dy=-2.0 * (k1 + k2))

    if name == "breathe":        # фермер: почти чистое дыхание, без вращения
        s = math.sin(tau)
        return _M(rot=0.8 * s, dy=-2.0 * s,
                  sx=1 + 0.022 * s, sy=1 + 0.030 * s)

    if name == "bob":            # рыбак: поплавок на волне и одна поклёвка
        wave = math.sin(tau)
        bite = _pulse(t, 0.62)
        return _M(rot=2.5 * wave - 4.0 * bite, dy=-5.0 * wave + 22.0 * bite,
                  sx=1 + 0.04 * bite, sy=1 - 0.05 * bite)

    if name == "shake":          # хакер: «нет»
        return _M(rot=5.0 * math.sin(2 * tau), dx=14.0 * math.sin(2 * tau))

    if name == "groove":         # джазмен: качает головой в такт, со свингом
        beat = 2 * tau
        return _M(rot=5.0 * math.sin(beat) + 1.8 * math.sin(2 * beat),
                  dx=7.0 * math.sin(beat + 0.5), dy=-5.0 * abs(math.sin(beat)),
                  sy=1 - 0.03 * abs(math.sin(beat)))

    if name == "pop":            # маг: возникает из ничего с отскоком и уходит обратно
        # Уход в последнюю четверть цикла возвращает голову в позу t=0 — мелкую и
        # приподнятую. Без него на шве цикла масштаб прыгал с 1.0 на 0.55 за кадр.
        q = _settle(t, 0.75, 0.25)
        k = ease_io(min(1.0, t / 0.35)) * q
        b = math.exp(-5 * t) * math.sin(14 * t) * q
        return _M(rot=7.0 * b, dy=-26.0 * (1 - k) - 10.0 * b,
                  sx=0.55 + 0.45 * k + 0.06 * b, sy=0.55 + 0.45 * k - 0.06 * b)

    if name == "nod":            # сантехник: кивок «починил»
        p = math.sin(tau)
        return _M(rot=1.2 * p, dy=15.0 * p,
                  sx=1 + 0.045 * max(0.0, p), sy=1 - 0.055 * max(0.0, p))

    if name == "strut":          # богач: неспешно приосанивается
        s = math.sin(tau)
        u = 0.5 - 0.5 * math.cos(tau)
        return _M(rot=-4.5 * s, dx=5.0 * s, dy=-4.0 * u,
                  sx=1 + 0.020 * u, sy=1 + 0.028 * u)

    if name == "raise":          # студент: «я знаю!» — рывок вверх и зависание
        k = hold(t, *_RAISE_HOLD)
        return _M(rot=3.0 * math.sin(tau), dy=-30.0 * k,
                  sx=1 - 0.030 * k, sy=1 + 0.040 * k)

    if name == "unbox":          # посылка: замах, удар о стол и затухающий звон
        hit = 0.24
        if t < hit:
            k = _toss(t / hit)
            return _M(rot=-3.2 * k, dx=2.0 * k, dy=-15.0 * k,
                      sx=1 - 0.016 * k, sy=1 + 0.024 * k)
        s, q = t - hit, _settle(t, 0.84, 0.16)
        imp = _impact(s) * q
        ring = math.exp(-3.6 * s) * math.sin(2 * math.pi * 2.15 * s) * q
        hop = math.exp(-5.0 * s) * math.sin(2 * math.pi * 1.9 * s) * q
        return _M(rot=8.5 * ring, dx=4.5 * ring, dy=18.0 * imp - 5.0 * hop,
                  sx=1 + 0.070 * imp, sy=1 - 0.080 * imp)

    raise SystemExit(f"неизвестный пресет: {name}")


def antenna_pose(name, t):
    """Активная поза антенн: (swing — обе в одну сторону, splay — врозь)."""
    tau = 2 * math.pi * t

    if name == "float":
        return 3.0 * math.sin(tau + 1.4), 2.5 * math.sin(tau + 0.2)
    if name == "hammer":
        return 0.0, 4.0 * _strikes(t, 3)
    if name == "sail":
        return 2.5 * math.sin(tau + 1.0), 1.5 * math.sin(2 * tau)
    if name == "laugh":
        return 1.5 * math.sin(tau), 3.5 * math.sin(2 * tau + 0.6)
    if name == "swagger":
        return 2.5 * math.sin(tau + 0.8), 1.2 * math.sin(2 * tau)
    if name == "think":
        return 0.0, -4.0 * hold(t)
    if name == "scan":
        k1 = hold(t, *_SCAN_HOLD)
        k2 = hold((t - 0.5) % 1.0, *_SCAN_HOLD)
        return -2.5 * (k1 - k2), -2.0 * (k1 + k2)      # насторожились и повели
    if name == "breathe":
        return 0.0, 1.8 * math.sin(tau)
    if name == "bob":
        return 1.5 * math.sin(tau), 6.0 * _pulse(t, 0.62)   # вздрогнули на поклёвке
    if name == "shake":
        return -4.5 * math.sin(2 * tau), 0.0
    if name == "groove":
        return 3.5 * math.sin(2 * tau + 1.1), 2.0 * math.sin(4 * tau)
    if name == "pop":            # к шву антенны снова врозь, как в начале цикла
        q = _settle(t, 0.75, 0.25)
        return 0.0, 7.0 * (math.exp(-4 * t) * math.cos(10 * t) * q + (1 - q))
    if name == "nod":
        return 0.0, 4.5 * max(0.0, math.sin(tau))
    if name == "strut":
        return 1.5 * math.sin(tau), -2.5 * (0.5 - 0.5 * math.cos(tau))
    if name == "raise":
        return 0.0, 5.0 * hold(t, *_RAISE_HOLD)
    if name == "unbox":
        hit = 0.24
        if t < hit:
            return 0.0, -3.5 * _toss(t / hit)          # в полёте прижались к голове
        s, q = t - hit, _settle(t, 0.84, 0.16)
        return (2.5 * math.exp(-3.0 * s) * math.sin(2 * math.pi * 3.1 * s) * q,
                9.0 * math.exp(-3.4 * s) * math.sin(2 * math.pi * 2.7 * s) * q)
    return 0.0, 0.0


def simulate(name, n):
    """Пассивный отклик антенн: затухающий осциллятор, раскачиваемый головой."""
    dt = 1.0 / FPS
    rot = [head_curve(name, i / n)["rot"] for i in range(n)]
    dx = [head_curve(name, i / n)["dx"] for i in range(n)]
    dy = [head_curve(name, i / n)["dy"] for i in range(n)]

    def accel(seq):  # вторая производная по кольцу — цикл замкнут
        return [(seq[(i + 1) % n] - 2 * seq[i] + seq[(i - 1) % n]) / dt ** 2 for i in range(n)]

    a_rot, a_x, a_y = accel(rot), accel(dx), accel(dy)
    deg = 180.0 / math.pi
    ws, wp = 2 * math.pi * SWING_HZ, 2 * math.pi * SPLAY_HZ

    swing = [0.0] * n
    splay = [0.0] * n
    th_s = v_s = th_p = v_p = 0.0
    for cycle in range(8):                    # прогреваем до установившегося режима
        for i in range(n):
            # база уехала вправо -> верхушка отстаёт влево (против часовой, +)
            drv_s = (a_x[i] / ANT_LEN) * deg - a_rot[i]
            # голова рванула вверх -> стержни продавливает вниз, они расходятся
            drv_p = -(a_y[i] / ANT_LEN) * deg * 0.7
            v_s += (-2 * SWING_ZETA * ws * v_s - ws * ws * th_s + drv_s) * dt
            th_s += v_s * dt
            v_p += (-2 * SPLAY_ZETA * wp * v_p - wp * wp * th_p + drv_p) * dt
            th_p += v_p * dt
            if cycle == 7:
                swing[i], splay[i] = th_s, th_p
    return swing, splay


# ------------------------------------------------------------------- рендер
def render_frames(src, preset, n, outdir):
    img = Image.open(src).convert("RGBA")
    ants, head = (split_antennas_diecut if DIECUT else split_antennas)(img)
    swing, splay = simulate(preset, n)

    for i in range(n):
        t = i / n
        c = head_curve(preset, t)
        a_sw, a_sp = antenna_pose(preset, t)
        sw = a_sw + PASSIVE_GAIN * swing[i]
        sp = a_sp + PASSIVE_GAIN * splay[i]

        if ants:
            layer = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
            # + = против часовой: левая антенна «врозь» уходит влево, правая вправо
            for (ant_img, pivot), sign in zip(ants, (+1.0, -1.0)):
                ang = max(-MAX_ANGLE, min(MAX_ANGLE, sw + sign * sp))
                layer.alpha_composite(rotate_about(ant_img, ang, pivot))
            layer.alpha_composite(head)      # голова закрывает стыки стержней
        else:
            layer = img

        if DIECUT:
            layer = redraw_diecut(layer)

        sx, sy = c["sx"] * BASE_SCALE, c["sy"] * BASE_SCALE
        w, h = max(1, int(SIZE * sx)), max(1, int(SIZE * sy))
        scaled = layer.resize((w, h), Image.LANCZOS)
        big = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
        big.alpha_composite(scaled, ((SIZE - w) // 2, (SIZE - h) // 2))
        big = rotate_about(big, c["rot"], (SIZE / 2, SIZE * 0.92))   # ось — «шея»

        canvas = Image.new("RGBA", (SIZE, SIZE), (0, 0, 0, 0))
        canvas.alpha_composite(big, (int(round(c["dx"])), int(round(c["dy"]))))
        canvas.save(os.path.join(outdir, f"f{i:03d}.png"))


def encode(outdir, out_webm, out_webp):
    common = ["-y", "-framerate", str(FPS), "-i", os.path.join(outdir, "f%03d.png")]
    for crf in (28, 34, 40, 46, 52):
        subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", *common,
                        "-c:v", "libvpx-vp9", "-pix_fmt", "yuva420p", "-b:v", "0",
                        "-crf", str(crf), "-auto-alt-ref", "0", "-an", "-f", "webm",
                        out_webm], check=True)
        if os.path.getsize(out_webm) <= 256_000:
            break
    subprocess.run(["ffmpeg", "-hide_banner", "-loglevel", "error", *common,
                    "-c:v", "libwebp_anim", "-lossless", "0", "-q:v", "72",
                    "-loop", "0", "-pix_fmt", "yuva420p", out_webp], check=True)
    return crf


if __name__ == "__main__":
    argv = [a for a in sys.argv[1:] if a != "--diecut"]
    DIECUT = "--diecut" in sys.argv
    src, preset, base = argv[0], argv[1], argv[2]
    frames = int(argv[3]) if len(argv) > 3 else 60
    with tempfile.TemporaryDirectory() as td:
        render_frames(src, preset, frames, td)
        crf = encode(td, base + ".webm", base + ".webp")
    print(f"{os.path.basename(base):24s} {preset:6s} "
          f"webm {os.path.getsize(base + '.webm') / 1024:6.1f} КБ (crf {crf})  "
          f"{frames / FPS:.1f} с")
