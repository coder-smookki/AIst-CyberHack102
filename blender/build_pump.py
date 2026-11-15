"""Сцена Blender: насосный агрегат inline с шильдиком, манометром и переключаемыми внешними дефектами.

Строит модель из простых тел, снимает её со случайных точек обхода и сохраняет кадры с готовой разметкой.

Запуск:
    blender -b -P blender/build_pump.py -- <папка_текстур> <папка_набора> <выборка> <кадров> <зерно> [--save-blend]

Разметка вычисляется, а не рисуется вручную. Каждый размечаемый узел состоит из объектов с именем
«класс@экземпляр@деталь». Его рамка получается проекцией вершин на кадр и остаётся в разметке, только если
достаточная доля лучей от камеры действительно попадает в узел. Узлы, скрытые за двигателем или видимые
с обратной стороны, в разметку не попадают. Проверено в Blender 5.2, движок EEVEE, фоновый режим.
"""
import contextlib
import json
import math
import os
import random
import sys

import bpy
from bpy_extras.object_utils import world_to_camera_view
from mathutils import Euler, Vector

argv = sys.argv[sys.argv.index("--") + 1:]
TEX, OUT, SPLIT, N, SEED = argv[0], argv[1], argv[2], int(argv[3]), int(argv[4])
SAVE_BLEND = "--save-blend" in argv
W, H = 960, 720
CLASSES = ["motor", "pump_casing", "flange", "coupling_guard", "coupling_no_guard", "terminal_box",
           "terminal_box_burnt", "nameplate", "gauge", "leak", "corrosion"]
rnd = random.Random(SEED)

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
col = scene.collection


def mat(name, color, rough=0.5, metal=0.0, noise=None, bump=0.0):
    """Создаёт материал. Параметр noise задаёт масштаб шума и опорные цвета для пятнистой окраски."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    b = next(n for n in nt.nodes if n.bl_idname == "ShaderNodeBsdfPrincipled")
    b.inputs["Base Color"].default_value = (*color, 1)
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    if noise:
        scale, stops = noise
        tex = nt.nodes.new("ShaderNodeTexNoise")
        tex.inputs["Scale"].default_value = scale
        tex.inputs["Detail"].default_value = 8.0
        ramp = nt.nodes.new("ShaderNodeValToRGB")
        cr = ramp.color_ramp
        while len(cr.elements) < len(stops):
            cr.elements.new(0.5)
        for e, (pos, rgb) in zip(cr.elements, stops):
            e.position, e.color = pos, (*rgb, 1)
        nt.links.new(tex.outputs[0], ramp.inputs[0])
        nt.links.new(ramp.outputs["Color"], b.inputs["Base Color"])
        if bump:
            bp = nt.nodes.new("ShaderNodeBump")
            bp.inputs["Strength"].default_value = bump
            nt.links.new(tex.outputs[0], bp.inputs["Height"])
            nt.links.new(bp.outputs["Normal"], b.inputs["Normal"])
    return m


def img_mat(name, path, rough=0.45, metal=0.0):
    """Создаёт материал с изображением в качестве цвета."""
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    b = next(n for n in nt.nodes if n.bl_idname == "ShaderNodeBsdfPrincipled")
    t = nt.nodes.new("ShaderNodeTexImage")
    t.image = bpy.data.images.load(path)
    nt.links.new(t.outputs["Color"], b.inputs["Base Color"])
    b.inputs["Roughness"].default_value = rough
    b.inputs["Metallic"].default_value = metal
    return m


paint_hue = rnd.choice([(0.005, 0.16, 0.10), (0.008, 0.13, 0.13), (0.015, 0.07, 0.19), (0.03, 0.15, 0.07), (0.16, 0.17, 0.18)])
M = {
    "paint": mat("paint", paint_hue, 0.42, 0.1, (38, [(0.35, tuple(c * 0.82 for c in paint_hue)), (0.75, paint_hue)]), 0.04),
    "motor": mat("motor", (0.16, 0.17, 0.19), 0.5, 0.35),
    "dark": mat("dark", (0.05, 0.05, 0.055), 0.6, 0.2),
    "steel": mat("steel", (0.62, 0.63, 0.65), 0.32, 0.9),
    "pipe": mat("pipe", (0.2, 0.2, 0.21), 0.55, 0.5, (55, [(0.3, (0.15, 0.155, 0.16)), (0.8, (0.25, 0.255, 0.26))]), 0.03),
    "guard": mat("guard", (0.92, 0.62, 0.03), 0.45, 0.2),
    "coupling": mat("coupling", (0.78, 0.25, 0.04), 0.4, 0.3),
    "box": mat("box", (0.26, 0.28, 0.30), 0.5, 0.3),
    "burnt": mat("burnt", (0.03, 0.03, 0.03), 0.9, 0.0,
                 (9, [(0.25, (0.012, 0.010, 0.010)), (0.55, (0.10, 0.045, 0.02)), (0.8, (0.30, 0.27, 0.24))]), 0.5),
    "rust": mat("rust", (0.4, 0.15, 0.04), 0.95, 0.0,
                (22, [(0.25, (0.16, 0.055, 0.02)), (0.55, (0.47, 0.19, 0.05)), (0.85, (0.66, 0.34, 0.10))]), 0.9),
    "oil": mat("oil", (0.012, 0.010, 0.008), 0.06, 0.0),
    "floor": mat("floor", (0.2, 0.2, 0.2), 0.85, 0.0, (4.5, [(0.3, (0.13, 0.13, 0.125)), (0.75, (0.27, 0.27, 0.26))]), 0.15),
    "wall": mat("wall", (0.35, 0.36, 0.34), 0.9, 0.0, (2.2, [(0.3, (0.26, 0.27, 0.26)), (0.8, (0.42, 0.42, 0.40))]), 0.05),
    "plate": img_mat("plate", os.path.join(TEX, "nameplate.png"), 0.38, 0.55),
    "dial": img_mat("dial", os.path.join(TEX, "gauge_dial.png"), 0.5, 0.0),
    "needle": mat("needle", (0.02, 0.02, 0.02), 0.5, 0.0),
}


def finish(o, name, material, smooth=True):
    """Задаёт объекту имя и материал, сглаживает криволинейные поверхности."""
    o.name = name
    o.data.materials.append(M[material])
    if smooth and len(o.data.polygons) > 12:
        for p in o.data.polygons:
            p.use_smooth = True
    return o


def cyl(name, material, r, depth, loc, rot=(0, 0, 0), verts=48):
    """Добавляет цилиндр."""
    bpy.ops.mesh.primitive_cylinder_add(vertices=verts, radius=r, depth=depth, location=loc, rotation=rot)
    return finish(bpy.context.object, name, material)


def box(name, material, size, loc, rot=(0, 0, 0)):
    """Добавляет прямоугольный брусок заданных размеров."""
    bpy.ops.mesh.primitive_cube_add(size=1, location=loc, rotation=rot)
    o = bpy.context.object
    o.scale = size
    return finish(o, name, material, smooth=False)


def ell(name, material, scale, loc, rot=(0, 0, 0)):
    """Добавляет эллипсоид: им изображаются корпус, пятна ржавчины и подтёки."""
    bpy.ops.mesh.primitive_uv_sphere_add(segments=32, ring_count=16, radius=1, location=loc, rotation=rot)
    o = bpy.context.object
    o.scale = scale
    return finish(o, name, material)


def plane(name, material, sx, sy, loc, rot):
    """Добавляет прямоугольную плоскость."""
    bpy.ops.mesh.primitive_plane_add(size=1, location=loc, rotation=rot)
    o = bpy.context.object
    o.scale = (sx, sy, 1)
    return finish(o, name, material, smooth=False)


def disc(name, material, r, loc, rot):
    """Добавляет круглую пластину с развёрткой текстуры на весь круг."""
    bpy.ops.mesh.primitive_circle_add(vertices=64, radius=r, fill_type="NGON", calc_uvs=True, location=loc, rotation=rot)
    return finish(bpy.context.object, name, material, smooth=False)


RX = (0, math.pi / 2, 0)
RY = (math.pi / 2, 0, 0)
ZP = 0.55

plane("env@0@floor", "floor", 14, 14, (0, 0, 0), (0, 0, 0))
plane("env@0@wall", "wall", 14, 6, (0, 1.6, 3), (math.pi / 2, 0, 0))
box("env@0@plinth", "floor", (0.5, 0.5, 0.16), (0, 0, 0.08))
box("env@0@foot", "paint", (0.22, 0.22, 0.2), (0, 0, 0.26))

ell("pump_casing@0@volute", "paint", (0.27, 0.25, 0.21), (0, 0, ZP))
cyl("pump_casing@0@necks", "paint", 0.085, 0.72, (0, 0, ZP), RX)
cyl("pump_casing@0@top", "paint", 0.165, 0.10, (0, 0, ZP + 0.20))
for side, sx in (("L", -1), ("R", 1)):
    cyl(f"flange@{side}@a", "paint", 0.135, 0.03, (sx * 0.375, 0, ZP), RX)
    cyl(f"flange@{side}@b", "pipe", 0.135, 0.03, (sx * 0.408, 0, ZP), RX)
    for k in range(8):
        a = 2 * math.pi * k / 8 + 0.2
        cyl(f"flange@{side}@bolt{k}", "steel", 0.013, 0.095, (sx * 0.392, 0.108 * math.cos(a), ZP + 0.108 * math.sin(a)), RX, 12)
    cyl(f"env@{side}@pipe", "pipe", 0.07, 1.9, (sx * 1.37, 0, ZP), RX)

ZL0, ZL1 = ZP + 0.25, ZP + 0.47
cyl("env@0@lantern_bottom", "paint", 0.17, 0.035, (0, 0, ZL0 + 0.017))
cyl("env@0@lantern_top", "paint", 0.19, 0.035, (0, 0, ZL1 - 0.017))
for k in range(4):
    a = math.pi / 4 + k * math.pi / 2
    box(f"env@0@pillar{k}", "paint", (0.05, 0.035, ZL1 - ZL0), (0.155 * math.cos(a), 0.155 * math.sin(a), (ZL0 + ZL1) / 2), (0, 0, a))
cyl("coupling_no_guard@0@shaft", "steel", 0.024, ZL1 - ZL0, (0, 0, (ZL0 + ZL1) / 2))
cyl("coupling_no_guard@0@hub", "coupling", 0.058, 0.11, (0, 0, (ZL0 + ZL1) / 2 + 0.01))
guard_parts = []
for k, a in enumerate((-math.pi / 2, math.pi / 2, 0, math.pi)):
    guard_parts.append(box(f"coupling_guard@0@shield{k}", "guard", (0.20, 0.012, ZL1 - ZL0 - 0.075),
                           (0.168 * math.cos(a), 0.168 * math.sin(a), (ZL0 + ZL1) / 2), (0, 0, a + math.pi / 2)))

ZM0, ZM1 = ZL1, ZL1 + 0.50
cyl("motor@0@body", "motor", 0.185, ZM1 - ZM0, (0, 0, (ZM0 + ZM1) / 2))
for k in range(30):
    a = 2 * math.pi * k / 30
    box(f"motor@0@fin{k}", "motor", (0.03, 0.008, ZM1 - ZM0 - 0.06), (0.196 * math.cos(a), 0.196 * math.sin(a), (ZM0 + ZM1) / 2), (0, 0, a))
cyl("motor@0@fan_cover", "dark", 0.205, 0.13, (0, 0, ZM1 + 0.065))
cyl("motor@0@flange", "motor", 0.21, 0.03, (0, 0, ZM0 + 0.015))

A_BOX = math.radians(-58)
bx, by = 0.255 * math.cos(A_BOX), 0.255 * math.sin(A_BOX)
tb = box("terminal_box@0@body", "box", (0.17, 0.11, 0.15), (bx, by, ZM0 + 0.33), (0, 0, A_BOX))
tb_lid = box("terminal_box@0@lid", "box", (0.012, 0.125, 0.165), (0.345 * math.cos(A_BOX), 0.345 * math.sin(A_BOX), ZM0 + 0.33), (0, 0, A_BOX))
cyl("terminal_box@0@gland", "dark", 0.016, 0.05, (bx, by, ZM0 + 0.235), (0, 0, 0), 16)
soots = [
    ell("terminal_box_burnt@0@scorch", "burnt", (0.006, 0.05, 0.06),
        (0.352 * math.cos(A_BOX), 0.352 * math.sin(A_BOX), ZM0 + 0.34), (0, 0, A_BOX)),
    ell("terminal_box_burnt@0@soot", "burnt", (0.05, 0.02, 0.09),
        (0.205 * math.cos(A_BOX + 0.25), 0.205 * math.sin(A_BOX + 0.25), ZM0 + 0.445), (0, 0, A_BOX + 0.25)),
]

A_PL = math.radians(-118)
pl = plane("nameplate@0@plate", "plate", 0.17, 0.109, (0.213 * math.cos(A_PL), 0.213 * math.sin(A_PL), ZM0 + 0.27),
           (math.pi / 2, 0, A_PL + math.pi / 2))
box("env@0@plate_base", "motor", (0.02, 0.18, 0.118), (0.202 * math.cos(A_PL), 0.202 * math.sin(A_PL), ZM0 + 0.27), (0, 0, A_PL))

GX, GZ = 0.66, ZP + 0.27
cyl("env@0@gauge_stem", "steel", 0.012, 0.20, (GX, 0, ZP + 0.16), (0, 0, 0), 16)
cyl("gauge@0@body", "steel", 0.078, 0.04, (GX, 0, GZ), RY)
cyl("gauge@0@bezel", "dark", 0.079, 0.004, (GX, -0.0185, GZ), RY)
disc("gauge@0@dial", "dial", 0.071, (GX, -0.0215, GZ), (math.pi / 2, 0, 0))
needle = box("gauge@0@needle", "needle", (0.006, 0.002, 0.062), (GX, -0.024, GZ))
cyl("gauge@0@hubcap", "dark", 0.009, 0.006, (GX, -0.025, GZ), RY, 16)

leaks = [
    ell("leak@0@streak", "oil", (0.07, 0.012, 0.11), (-0.03, -0.238, ZP + 0.02), (0.25, 0, 0)),
    ell("leak@0@drip1", "oil", (0.02, 0.008, 0.035), (0.03, -0.236, ZP - 0.07)),
    ell("leak@0@seal", "oil", (0.10, 0.03, 0.022), (-0.01, -0.150, ZP + 0.245)),
    ell("leak@1@puddle", "oil", (0.30, 0.21, 0.004), (-0.05, -0.43, 0.004)),
]
rusts = [
    ell("corrosion@0@casing", "rust", (0.12, 0.014, 0.085), (0.13, -0.207, ZP + 0.04), (0, 0, 0.55)),
    ell("corrosion@1@flange", "rust", (0.02, 0.11, 0.11), (-0.426, 0, ZP)),
    ell("corrosion@2@pipe", "rust", (0.16, 0.022, 0.05), (-0.95, -0.056, ZP + 0.02)),
    ell("corrosion@3@foot", "rust", (0.10, 0.012, 0.07), (0.02, -0.112, 0.27)),
]

cam_data = bpy.data.cameras.new("cam")
cam = bpy.data.objects.new("cam", cam_data)
col.objects.link(cam)
scene.camera = cam
lights = []
for i, (kind, loc, energy) in enumerate((("AREA", (-1.5, -2.5, 3.2), 260), ("AREA", (2.5, -1.8, 2.4), 150), ("POINT", (0, -0.5, 3.4), 70))):
    ld = bpy.data.lights.new(f"l{i}", kind)
    ld.energy = energy
    if kind == "AREA":
        ld.size = 2.0
    lo = bpy.data.objects.new(f"l{i}", ld)
    lo.location = loc
    col.objects.link(lo)
    lights.append((lo, energy))
world = bpy.data.worlds.new("w")
world.use_nodes = True
scene.world = world
bg = next(n for n in world.node_tree.nodes if n.bl_idname == "ShaderNodeBackground")

scene.render.engine = "BLENDER_EEVEE"
scene.render.resolution_x, scene.render.resolution_y, scene.render.resolution_percentage = W, H, 100
with contextlib.suppress(Exception):
    scene.render.image_settings.media_type = "IMAGE"
scene.render.image_settings.file_format = "JPEG"
scene.render.image_settings.quality = 92
with contextlib.suppress(Exception):
    scene.eevee.taa_render_samples = 16

def set_hidden(o, flag):
    """Скрывает объект и для рендера, и для лучей проверки видимости."""
    o.hide_render = flag
    o.hide_viewport = flag


entities = {}
for o in scene.objects:
    if o.type == "MESH" and "@" in o.name:
        cls, inst, _ = o.name.split("@")
        if cls in CLASSES:
            entities.setdefault((cls, inst), []).append(o)


def visible_box(objs, dg):
    """Возвращает рамку узла на кадре, долю лучей, попавших в узел, и долю рамки внутри кадра."""
    cam_loc = cam.matrix_world.translation
    xs, ys, pts = [], [], []
    for o in objs:
        if o.hide_render:
            continue
        mw = o.matrix_world
        vs = o.data.vertices
        step = max(1, len(vs) // 60)
        for i in range(0, len(vs), step):
            p = mw @ vs[i].co
            c = world_to_camera_view(scene, cam, p)
            if c.z <= 0.05:
                continue
            xs.append(c.x)
            ys.append(1 - c.y)
            pts.append(p)
    if len(pts) < 4:
        return None
    names = {o.name for o in objs}
    hit = 0
    sample = pts[:: max(1, len(pts) // 40)]
    for p in sample:
        d = p - cam_loc
        dist = d.length
        ok, loc, _, _, ho, _ = scene.ray_cast(dg, cam_loc, d.normalized(), distance=dist + 0.02)
        if ok and ho is not None and (ho.name in names or (loc - p).length < 0.008):
            hit += 1
    frac = hit / max(1, len(sample))
    x1, x2, y1, y2 = max(0, min(xs)), min(1, max(xs)), max(0, min(ys)), min(1, max(ys))
    full = (max(xs) - min(xs)) * (max(ys) - min(ys))
    if x2 - x1 < 12 / W or y2 - y1 < 12 / H or full <= 0:
        return None
    inside = (x2 - x1) * (y2 - y1) / full
    return (x1, y1, x2, y2), frac, inside


MIN_VIS = {"nameplate": 0.6, "gauge": 0.5, "terminal_box": 0.35, "terminal_box_burnt": 0.5, "leak": 0.3, "corrosion": 0.3}

img_dir, lab_dir = os.path.join(OUT, "images", SPLIT), os.path.join(OUT, "labels", SPLIT)
os.makedirs(img_dir, exist_ok=True)
os.makedirs(lab_dir, exist_ok=True)
meta_all = []
truth = json.load(open(os.path.join(TEX, "truth.json")))
gmin, gmax, sweep = truth["gauge"]["min"], truth["gauge"]["max"], math.radians(truth["gauge"]["sweep_deg"])

for i in range(N):
    guard_on = rnd.random() < 0.6
    for o in guard_parts:
        set_hidden(o, not guard_on)
    leak_on = rnd.random() < 0.4
    for o in leaks:
        set_hidden(o, not leak_on)
    for o in rusts:
        set_hidden(o, rnd.random() > 0.4)
    burnt = rnd.random() < 0.35
    for o in soots:
        set_hidden(o, not burnt)
    for o in (tb, tb_lid):
        o.data.materials[0] = M["burnt"] if burnt else M["box"]
    bar = round(rnd.uniform(0.5, 9.5), 2)
    ang = (bar - gmin) / (gmax - gmin) * sweep - sweep / 2
    needle.rotation_euler = Euler((0, ang, 0))
    needle.location = Vector((GX, -0.024, GZ)) + Vector((math.sin(ang), 0, math.cos(ang))) * 0.022

    az = math.radians(rnd.uniform(-180, 180) if rnd.random() < 0.2 else rnd.uniform(-80, 80))
    el = math.radians(rnd.uniform(-2, 28))
    r = rnd.uniform(1.5, 3.3)
    tgt = Vector((rnd.uniform(-0.25, 0.3), 0, rnd.uniform(0.6, 1.05)))
    if rnd.random() < 0.22:
        tgt = Vector(rnd.choice([(0.21 * math.cos(A_PL), 0.21 * math.sin(A_PL), ZM0 + 0.27), (GX, 0, GZ),
                                 (bx, by, ZM0 + 0.33), (0, -0.2, ZP + 0.1)]))
        r = rnd.uniform(0.7, 1.3)
        az = math.radians(rnd.uniform(-70, 40)) + (A_PL + math.pi / 2 if tgt.z > ZM0 and tgt.x < 0 else 0) * 0.5
    pos = tgt + Vector((math.sin(az) * math.cos(el), -math.cos(az) * math.cos(el), math.sin(el))) * r
    pos.z = max(0.25, pos.z)
    if pos.y > 1.35:
        pos.y = 1.35
    cam.location = pos
    q = (tgt - pos).to_track_quat("-Z", "Y")
    cam.rotation_euler = (q.to_matrix().to_4x4() @ Euler((0, 0, math.radians(rnd.uniform(-5, 5)))).to_matrix().to_4x4()).to_euler()
    cam_data.lens = rnd.uniform(24, 45)

    for lo, e in lights:
        lo.data.energy = e * rnd.uniform(0.35, 1.6)
        lo.data.color = (1.0, rnd.uniform(0.86, 1.0), rnd.uniform(0.72, 1.0))
    g = rnd.uniform(0.02, 0.35)
    bg.inputs[0].default_value = (g, g, g * rnd.uniform(0.9, 1.1), 1)
    bg.inputs[1].default_value = rnd.uniform(0.25, 0.9)

    bpy.context.view_layer.update()
    dg = bpy.context.evaluated_depsgraph_get()
    rows, found = [], []
    for (cls, inst), objs in entities.items():
        if all(o.hide_render for o in objs) and cls != "terminal_box_burnt":
            continue
        if (cls == "terminal_box" and burnt) or (cls == "terminal_box_burnt" and not burnt):
            continue
        if cls == "coupling_no_guard" and guard_on:
            continue
        group = objs + ([tb, tb_lid] if cls == "terminal_box_burnt" else [])
        res = visible_box(group, dg)
        if not res:
            continue
        (x1, y1, x2, y2), frac, inside = res
        if frac < MIN_VIS.get(cls, 0.25) or inside < 0.55:
            continue
        rows.append(f"{CLASSES.index(cls)} {(x1 + x2) / 2:.5f} {(y1 + y2) / 2:.5f} {x2 - x1:.5f} {y2 - y1:.5f}\n")
        found.append({"cls": cls, "inst": inst, "box": [round(v, 4) for v in (x1, y1, x2, y2)], "vis": round(frac, 2)})

    name = f"{SPLIT}_{SEED}_{i:04d}"
    scene.render.filepath = os.path.join(img_dir, name + ".jpg")
    bpy.ops.render.render(write_still=True)
    open(os.path.join(lab_dir, name + ".txt"), "w").writelines(rows)
    meta_all.append({"file": name + ".jpg", "gauge_bar": bar, "guard": guard_on, "leak": leak_on, "burnt": burnt,
                     "az_deg": round(math.degrees(az), 1), "el_deg": round(math.degrees(el), 1), "dist_m": round(r, 2),
                     "lens_mm": round(cam_data.lens, 1), "objects": found})

json.dump({"classes": CLASSES, "frames": meta_all}, open(os.path.join(OUT, f"meta_{SPLIT}_{SEED}.json"), "w"), indent=0)
if SAVE_BLEND:
    for o in guard_parts + leaks + rusts + soots:
        set_hidden(o, False)
    bpy.ops.wm.save_as_mainfile(filepath=os.path.join(OUT, "pump_unit.blend"))
print("RENDERED", N, "frames ->", img_dir)
