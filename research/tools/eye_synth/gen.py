"""Synthetic eye crops with exact openness labels, from the ICT-FaceKit head (MIT).
    <research venv python> gen.py <out dir> [--n 20000] [--seed 0] [--runtime vulkan] [--preview]
Each sample: random pose, expression (eyes open, closed, half, winks, squints, wide), skin tone and texture,
brows, lashes, iris color, lights, background, sometimes glasses with screen reflections on the lenses, then
camera effects (size, blur, noise, color, JPEG). FaceMesh runs on the result exactly as on camera frames and
the eyes are cropped from its landmarks (crop.py), so the crops carry the same landmark errors as real ones.
Label per eye: openness from the lid gap of the deformed mesh, 0 at eyeBlink 1, 1 neutral, >1 wide.
Writes shard_XXXX.npz (crops N x 2 x H x W x 3 BGR, subject's Left then Right, Right mirrored) and meta.
"""
import argparse
import math
import sys
import time
from pathlib import Path

import cv2
import moderngl
import numpy as np
from matplotlib.path import Path as Poly

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "src"))
from yorishiro_research.adapters import mediapipe_points as mpp  # noqa: E402
from yorishiro_research.adapters.ict_fit import build_correspondence  # noqa: E402
from yorishiro_research.adapters.lens_glare import lens_glare  # noqa: E402
from yorishiro_research.avatar.ict import ICT_SHAPES, REGIONS, ensure_ict_facekit  # noqa: E402
from yorishiro_research.avatar.renderer import _gl, _perspective, _translate  # noqa: E402
from yorishiro_research.mediapipe_ncnn.facemesh import FaceMesh  # noqa: E402
from yorishiro_research.pose import ypr_to_rotation  # noqa: E402

from yorishiro_research.adapters.eye_openness import crop_eyes  # noqa: E402

SIZE = 512
NAMES = list(ICT_SHAPES)
IDX = {n: i for i, n in enumerate(NAMES)}
# the five upper lid vertices that move most under eyeBlink, and the lower lid vertices they land on
LID = {"_L": ([4163, 2924, 4164, 2850, 2849], [2824, 2819, 2824, 2821, 2821]),
       "_R": ([1964, 1963, 683, 608, 682], [583, 582, 579, 580, 578])}
EYE_SHAPES = {"eyeBlink", "eyeSquint", "eyeWide", "eyeLookDown", "eyeLookIn", "eyeLookOut", "eyeLookUp"}
OTHER = [n for n in NAMES if n.rstrip("_LR").rstrip("_") not in EYE_SHAPES and not n.startswith("eye")]

VS = """
#version 330
uniform mat4 mvp;
uniform mat4 model;
in vec3 in_pos;
in vec3 in_normal;
in vec3 in_color;
in float in_shine;
out vec3 v_pos;
out vec3 v_normal;
out vec3 v_color;
out float v_shine;
void main() {
    v_pos = (model * vec4(in_pos, 1.0)).xyz;
    v_normal = mat3(model) * in_normal;
    v_color = in_color;
    v_shine = in_shine;
    gl_Position = mvp * vec4(in_pos, 1.0);
}
"""

FS = """
#version 330
uniform vec3 eye;
uniform vec3 key_dir;
uniform vec3 key_color;
uniform vec3 fill_dir;
uniform vec3 fill_color;
uniform vec3 ambient;
uniform float spec;
uniform float wrap;
in vec3 v_pos;
in vec3 v_normal;
in vec3 v_color;
in float v_shine;
out vec4 f_color;
void main() {
    vec3 n = normalize(v_normal);
    vec3 v = normalize(eye - v_pos);
    if (dot(n, v) < 0.0) n = -n;
    vec3 k = normalize(key_dir);
    vec3 f = normalize(fill_dir);
    float dk = max((dot(n, k) + wrap) / (1.0 + wrap), 0.0);
    float df = max(dot(n, f), 0.0);
    // wet parts (eyes) get a sharp highlight, skin a broad one
    float power = mix(16.0, 400.0, v_shine);
    float sk = pow(max(dot(reflect(-k, n), v), 0.0), power) * mix(spec, 1.5, v_shine);
    float sf = pow(max(dot(reflect(-f, n), v), 0.0), power) * mix(spec, 1.2, v_shine) * 0.5;
    vec3 c = v_color * (ambient + key_color * dk + fill_color * df) + key_color * sk + fill_color * sf;
    f_color = vec4(c, 1.0);
}
"""

SKIN_TONES = np.array([  # linear-ish albedo, light to dark
    (0.86, 0.70, 0.62), (0.80, 0.62, 0.52), (0.72, 0.54, 0.43), (0.60, 0.43, 0.32),
    (0.46, 0.31, 0.22), (0.32, 0.21, 0.15)], np.float32)
IRIS = np.array([(0.25, 0.15, 0.08), (0.12, 0.07, 0.04), (0.06, 0.04, 0.03), (0.30, 0.42, 0.55),
                 (0.30, 0.38, 0.22), (0.40, 0.30, 0.15), (0.45, 0.25, 0.40)], np.float32)
# what a monitor or a window puts on a lens (BGR, 0..1)
GLARE = np.array([(1.0, 1.0, 1.0), (1.0, 0.85, 0.7), (0.6, 1.0, 0.55), (1.0, 0.75, 0.55), (0.9, 0.95, 1.0),
                  (0.95, 0.6, 0.9), (0.4, 0.8, 1.0)], np.float32)


class Renderer:
    def __init__(self, head, size: int = SIZE):
        self.head, self.size = head, size
        self.ctx = moderngl.create_standalone_context(backend="egl")
        self.ctx.enable(moderngl.DEPTH_TEST)
        n_verts = len(head.neutral)
        self.prog = self.ctx.program(vertex_shader=VS, fragment_shader=FS)
        self.deltas = head.deltas.reshape(len(head.deltas), -1)
        self.vbo_pos = self.ctx.buffer(reserve=n_verts * 12)
        self.vbo_nrm = self.ctx.buffer(reserve=n_verts * 12)
        self.vbo_col = self.ctx.buffer(reserve=n_verts * 12)
        shine = np.zeros(n_verts, np.float32)
        for r in ("sclera_l", "sclera_r"):
            lo, hi = REGIONS[r]
            shine[lo:hi] = 1.0
        self.vao = self.ctx.vertex_array(self.prog, [
            (self.vbo_pos, "3f", "in_pos"), (self.vbo_nrm, "3f", "in_normal"), (self.vbo_col, "3f", "in_color"),
            (self.ctx.buffer(shine.tobytes()), "1f", "in_shine")], self.ctx.buffer(head.faces.astype("i4").tobytes()))
        self.fbo_ms = self.ctx.framebuffer(
            color_attachments=[self.ctx.renderbuffer((size, size), 4, samples=4)],
            depth_attachment=self.ctx.depth_renderbuffer((size, size), samples=4))
        self.fbo = self.ctx.simple_framebuffer((size, size), components=4)

    def render(self, weights, rotation, cam_dist, fov, colors, light):
        eye = np.array([0.0, -1.0, cam_dist], np.float32)
        self.view_proj = _perspective(fov, 1.0, 1.0, 400.0) @ _translate(*(-eye))
        self.model = np.eye(4, dtype=np.float32)
        self.model[:3, :3] = rotation
        self.prog["eye"].value = tuple(eye)
        self.prog["model"].write(_gl(self.model))
        self.prog["mvp"].write(_gl(self.view_proj @ self.model))
        pos = self.head.neutral + (weights @ self.deltas).reshape(-1, 3)
        self.vbo_pos.write(pos.astype("f4").tobytes())
        self.vbo_nrm.write(vertex_normals(pos, self.head.faces).tobytes())
        for k, v in light.items():
            self.prog[k].value = v
        self.vbo_col.write(colors.astype("f4").tobytes())
        self.fbo_ms.use()
        self.ctx.clear(0, 0, 0, 0, depth=1.0)
        self.vao.render(moderngl.TRIANGLES)
        self.ctx.copy_framebuffer(self.fbo, self.fbo_ms)
        rgba = np.frombuffer(self.fbo.read(components=4), np.uint8).reshape(self.size, self.size, 4)[::-1]
        return np.ascontiguousarray(rgba[:, :, [2, 1, 0, 3]])  # BGRA, not mirrored: a camera frame

    def project(self, pts_cm: np.ndarray) -> np.ndarray:
        """ICT space points (cm) to pixel coordinates of the last render"""
        p = np.c_[pts_cm, np.ones(len(pts_cm))] @ (self.view_proj @ self.model).T
        ndc = p[:, :2] / p[:, 3:4]
        return np.c_[(ndc[:, 0] + 1) / 2 * self.size, (1 - ndc[:, 1]) / 2 * self.size]


def vertex_normals(pos, tris):
    a, b, c = pos[tris[:, 0]], pos[tris[:, 1]], pos[tris[:, 2]]
    fn = np.cross(b - a, c - a)
    n = np.zeros_like(pos)
    for i in range(3):
        np.add.at(n, tris[:, i], fn)
    return (n / np.maximum(np.linalg.norm(n, axis=1, keepdims=True), 1e-9)).astype(np.float32)


def brow_masks(head) -> list[np.ndarray]:
    """face vertices under the brows, from MediaPipe's brow contours mapped onto the ICT head"""
    corr = build_correspondence(head, mpp.load_canonical(), mpp.MP_68)
    canon = corr.src_neutral_in_ict
    lo, hi = REGIONS["face"]
    v = head.neutral[lo:hi]
    out = []
    for side in (mpp.BROWS[:10], mpp.BROWS[10:]):
        upper, lower = canon[side[:5]], canon[side[5:]]
        poly = np.r_[upper[:, :2], lower[::-1, :2]]
        inside = Poly(poly).contains_points(v[:, :2]) & (v[:, 2] > 5)
        m = np.zeros(len(head.neutral), bool)
        m[lo:hi] = inside
        out.append(m)
    return out


def lid_gap(head, weights, side):
    up, low = LID[side]
    idx = up + low
    p = head.neutral[idx] + np.tensordot(weights, head.deltas[:, idx], axes=1)
    return float(np.linalg.norm(p[:5] - p[5:], axis=1).mean())


def sample_expression(rng):
    w = np.zeros(len(NAMES), np.float32)
    if rng.random() < 0.7:
        for n in rng.choice(OTHER, rng.integers(1, 6), replace=False):
            w[IDX[n]] = rng.uniform(0, 1) ** 1.5
    mode = rng.choice(["open", "both", "free", "wink"], p=[0.25, 0.3, 0.25, 0.2])
    if mode == "open":
        b = rng.uniform(0, 0.2, 2)
    elif mode == "both":
        b = np.clip(rng.uniform(0, 1) + rng.normal(0, 0.04, 2), 0, 1)
    elif mode == "free":
        b = rng.uniform(0, 1, 2)
    else:
        b = np.array([rng.uniform(0.75, 1), rng.uniform(0, 0.25)])
        rng.shuffle(b)
    for s, v in zip(("_L", "_R"), b):
        w[IDX["eyeBlink" + s]] = v
    sym = rng.random() < 0.7
    for shape, p, hi in (("eyeSquint", 0.3, 0.8), ("eyeWide", 0.2, 1.0), ("cheekSquint", 0.25, 1.0)):
        if rng.random() < p:
            v = rng.uniform(0, hi, 2)
            if sym:
                v[1] = v[0]
            w[IDX[shape + "_L"]], w[IDX[shape + "_R"]] = v
    # gaze: both eyes the same way
    gx, gy = rng.normal(0, 0.35), rng.normal(0, 0.3)
    for s, out in (("_L", gx > 0), ("_R", gx < 0)):
        w[IDX[("eyeLookOut" if out else "eyeLookIn") + s]] = min(abs(gx), 1)
        w[IDX[("eyeLookUp" if gy > 0 else "eyeLookDown") + s]] = min(abs(gy), 1)
    return w


def colors_for(head, rng, brows):
    n = len(head.neutral)
    c = np.zeros((n, 3), np.float32)
    t = rng.uniform(0, len(SKIN_TONES) - 1)
    i = int(t)
    skin = SKIN_TONES[i] * (1 - (t - i)) + SKIN_TONES[min(i + 1, len(SKIN_TONES) - 1)] * (t - i)
    skin = skin * rng.uniform(0.9, 1.1, 3)
    # blotchy low-frequency variation (redness, shading of the texture)
    p = head.neutral
    freq = rng.uniform(0.2, 0.8, (3, 3))
    phase = rng.uniform(0, 6.3, 3)
    noise = sum(np.sin(p @ freq[k] + phase[k]) for k in range(3)) / 3
    c[:] = skin * (1 + rng.uniform(0.02, 0.1) * noise[:, None] * np.array([1.0, 0.7, 0.6]))
    for r, col in (("mouth_socket", (0.35, 0.10, 0.10)), ("gums_tongue", (0.8, 0.42, 0.45)),
                   ("teeth", (0.93, 0.92, 0.86))):
        lo, hi = REGIONS[r]
        c[lo:hi] = col
    lo, hi = REGIONS["eye_socket"]
    c[lo:hi] = skin * rng.uniform(0.55, 0.85) * np.array([1.0, 0.9, 0.9])
    # ICT's eyelash mesh is a band over the lid margin: skin with a little lash or liner darkness
    lo, hi = REGIONS["eyelashes"]
    a = rng.uniform(0.0, 0.5)
    c[lo:hi] = c[lo:hi] * (1 - a) + a * rng.uniform(0.02, 0.2) * np.array([1.0, 0.9, 0.85])
    # brows: darker than skin, from barely there to strong
    brow = rng.uniform(0.04, 0.35) * np.array([1.0, 0.85, 0.75]) * rng.uniform(0.8, 1.2, 3)
    a = rng.uniform(0.3, 1.0)
    for m in brows:
        c[m] = c[m] * (1 - a) + brow * a
    iris = IRIS[rng.integers(len(IRIS))] * rng.uniform(0.7, 1.3)
    sclera = np.array([0.92, 0.9, 0.88]) * rng.uniform(0.75, 1.0)
    for r in ("sclera_l", "sclera_r"):
        lo, hi = REGIONS[r]
        d = head.neutral[lo:hi] - head.neutral[lo:hi].mean(0)
        ang = np.degrees(np.arccos(np.clip(d[:, 2] / np.linalg.norm(d, axis=1), -1, 1)))
        cc = np.tile(sclera, (hi - lo, 1))
        cc[ang < rng.uniform(28, 34)] = iris
        cc[ang < rng.uniform(9, 15)] = (0.02, 0.02, 0.02)
        c[lo:hi] = cc
    return np.clip(c, 0, 1)


def sample_light(rng):
    def direction(spread):
        return tuple(np.array([rng.normal(0, spread), rng.normal(0.3, spread), 1.0]))
    tint = rng.uniform(0.85, 1.0, 3)
    key = rng.uniform(0.5, 1.2)
    return dict(key_dir=direction(0.8), key_color=tuple(key * tint), fill_dir=direction(1.0),
                fill_color=tuple(rng.uniform(0.0, 0.5) * rng.uniform(0.8, 1.0, 3)),
                ambient=tuple(rng.uniform(0.1, 0.45) * rng.uniform(0.8, 1.0, 3)),
                spec=float(rng.uniform(0.02, 0.25)), wrap=float(rng.uniform(0, 0.5)))


def background(rng, size):
    bg = np.zeros((size, size, 3), np.float32)
    small = rng.uniform(0, 1, (rng.integers(2, 8), rng.integers(2, 8), 3)).astype(np.float32)
    bg += cv2.resize(small, (size, size), interpolation=cv2.INTER_CUBIC)
    for _ in range(rng.integers(0, 6)):  # shelves, doors, posters
        x, y = rng.integers(0, size, 2)
        w, h = rng.integers(20, size // 2, 2)
        cv2.rectangle(bg, (int(x), int(y)), (int(x + w), int(y + h)), tuple(rng.uniform(0, 1, 3).tolist()), -1)
    bg = cv2.GaussianBlur(bg, (0, 0), rng.uniform(1, 8))
    gray = bg.mean(2, keepdims=True)
    bg = gray + (bg - gray) * rng.uniform(0.1, 0.7)  # rooms are not rainbows
    return np.clip(bg * rng.uniform(0.2, 1.0), 0, 1)


# anti-reflection coatings tint what lenses reflect: green most often, then purple or blue
COATING = np.array([(0.55, 1.0, 0.6), (0.6, 1.0, 0.8), (1.0, 0.6, 0.95), (1.0, 0.8, 0.6), (1.0, 1.0, 1.0)],
                   np.float32)


def screen_image(rng, size=96):
    """what a monitor shows, as a lens sees it: a background, windows, lines of text, tinted by the coating"""
    bright = rng.random() < 0.5
    img = np.full((size, size, 3), rng.uniform(0.75, 1.0) if bright else rng.uniform(0.05, 0.3), np.float32)
    img *= rng.uniform(0.8, 1.0, 3)
    for _ in range(rng.integers(1, 7)):  # windows, panels, video
        x, y = rng.integers(0, size, 2)
        ww, hh = rng.integers(8, size, 2)
        cv2.rectangle(img, (int(x), int(y)), (int(x + ww), int(y + hh)), tuple(rng.uniform(0, 1, 3).tolist()), -1)
    if rng.random() < 0.7:  # text: short dark or light dashes in rows
        ink = 0.1 if bright else 0.9
        y = rng.integers(2, 10)
        while y < size:
            x = rng.integers(0, 10)
            while x < size:
                ln = int(rng.integers(3, 15))
                cv2.line(img, (int(x), int(y)), (int(x + ln), int(y)), (ink, ink, ink), 1)
                x += ln + int(rng.integers(2, 5))
            y += int(rng.integers(3, 8))
    return np.clip(img * COATING[rng.integers(len(COATING))], 0, 1)


def add_glasses(img, r: Renderer, rng, rotation):
    """frames and lenses projected from 3D rims in front of the eyes, reflections on the lenses.
    Returns per image eye (subject's Left, Right) lens masks."""
    h, w = img.shape[:2]
    radius = rng.uniform(1.5, 2.8)
    squash = rng.uniform(0.65, 1.0)
    rect = rng.uniform(2, 6)  # superellipse exponent: 2 round, larger squarer
    cx, cy, cz = rng.uniform(3.0, 3.5), rng.uniform(3.0, 4.2), rng.uniform(10.6, 11.6)
    t = np.linspace(0, 2 * np.pi, 48, endpoint=False)
    ring = np.c_[np.sign(np.cos(t)) * np.abs(np.cos(t)) ** (2 / rect),
                 np.sign(np.sin(t)) * np.abs(np.sin(t)) ** (2 / rect) * squash] * radius
    thick = max(1, int(rng.uniform(0.004, 0.02) * w))
    frame = rng.choice([0, 1, 2], p=[0.5, 0.3, 0.2])  # dark, metal, rimless
    color = {0: rng.uniform(0.02, 0.25, 3), 1: rng.uniform(0.4, 0.8) * rng.uniform(0.8, 1, 3),
             2: None}[frame]
    tint = rng.uniform(0.85, 1.0, 3)
    masks = {}
    for side in (1, -1):  # ICT +x is the subject's left
        pts = np.c_[ring[:, 0] + side * cx, ring[:, 1] + cy, np.full(len(t), cz) - 0.15 * np.abs(ring[:, 0])]
        poly = r.project(pts)
        m = np.zeros((h, w), np.uint8)
        cv2.fillPoly(m, [np.round(poly * 16).astype(np.int32)], 255, cv2.LINE_AA, 4)
        mf = m.astype(np.float32)[..., None] / 255
        img[:] = img * (1 - mf) + img * tint * mf
        if color is not None:
            cv2.polylines(img, [np.round(poly * 16).astype(np.int32)], True, tuple(color.tolist()), thick,
                          cv2.LINE_AA, 4)
        masks["Left" if side == 1 else "Right"] = (m, poly)
    if color is not None:  # bridge and temples
        def seg(a, b):
            pa, pb = r.project(np.array([a, b], float))
            cv2.line(img, tuple(np.round(pa * 16).astype(int)), tuple(np.round(pb * 16).astype(int)),
                     tuple(color.tolist()), thick, cv2.LINE_AA, 4)
        seg((cx - radius, cy + 0.3, cz), (-(cx - radius), cy + 0.3, cz))
        for s in (1, -1):
            seg((s * (cx + radius), cy + 0.1, cz - 0.3), (s * 8.3, cy - 0.1, -0.5))
    for side, (m, poly) in masks.items():
        # minus lenses (short sight) show the eye smaller, around the lens center
        k = rng.uniform(0.82, 1.0)
        c = poly.mean(0)
        yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
        warped = cv2.remap(img, (c[0] + (xx - c[0]) / k).astype(np.float32), (c[1] + (yy - c[1]) / k).astype(np.float32), cv2.INTER_LINEAR,
                           borderMode=cv2.BORDER_REFLECT)
        mf = m.astype(np.float32)[..., None] / 255
        img[:] = img * (1 - mf) + warped * mf
    glare = {}
    if rng.random() < 0.85:
        screen = screen_image(rng)
        strength = rng.uniform(0.25, 1.0)
        # one screen seen in both lenses at slightly different places, often covering most of the lens
        fx, fy = rng.uniform(-0.5, 0.5, 2)
        fw, fh = rng.uniform(0.6, 2.4), rng.uniform(0.5, 2.0)
        for side, (m, poly) in masks.items():
            c = poly.mean(0)
            span = poly.max(0) - poly.min(0)
            q = np.array([[-1, -1], [1, -1], [1, 1], [-1, 1]], float) * [fw, fh] / 2
            q = q + rng.normal(0, 0.08, (4, 2)) * [fw, fh]  # perspective of a screen seen at an angle
            q = q @ cv2.Rodrigues(np.array([0, 0, rng.normal(0, 0.15)]))[0][:2, :2].T
            q = c + (q + [fx, fy] + rng.normal(0, 0.06, 2)) * span / 2
            sh, sw = screen.shape[:2]
            mat = cv2.getPerspectiveTransform(np.float32([[0, 0], [sw, 0], [sw, sh], [0, sh]]), q.astype(np.float32))
            s_img = cv2.warpPerspective(screen, mat, (w, h))
            cover = cv2.warpPerspective(np.ones((sh, sw), np.float32), mat, (w, h))
            g = cv2.GaussianBlur(cover, (0, 0), rng.uniform(0.5, 2.5)) * (m.astype(np.float32) / 255)
            g *= strength * rng.uniform(0.85, 1.0)
            s_img = cv2.GaussianBlur(s_img, (0, 0), rng.uniform(0.3, 1.5))  # out of focus, the lens is close
            # a reflection adds light, and washes out what is behind it
            img[:] = img * (1 - 0.6 * g[..., None]) + s_img * g[..., None]
            glare[side] = g
            if rng.random() < 0.5:  # bright line along part of the lens edge
                n = len(poly)
                i0 = rng.integers(n)
                arc = poly[[(i0 + j) % n for j in range(rng.integers(4, n // 2))]]
                over = img.copy()
                cv2.polylines(over, [np.round(arc * 16).astype(np.int32)], False, (1.0, 1.0, 1.0),
                              max(1, thick // 2), cv2.LINE_AA, 4)
                a = rng.uniform(0.3, 0.9)
                img[:] = img * (1 - a) + over * a
    return glare


def camera(img, rng):
    """the webcam: exposure, white balance, blur, sensor noise, resize, JPEG"""
    img = img * rng.uniform(0.6, 1.4) * rng.uniform(0.85, 1.15, 3)
    img = np.clip(img, 0, 1) ** rng.uniform(0.8, 1.25)
    if rng.random() < 0.6:
        img = cv2.GaussianBlur(img, (0, 0), rng.uniform(0.3, 1.5))
    if rng.random() < 0.15:  # motion
        k = np.zeros((9, 9), np.float32)
        k[4] = 1
        k = cv2.warpAffine(k, cv2.getRotationMatrix2D((4, 4), rng.uniform(0, 180), 1), (9, 9))
        img = cv2.filter2D(img, -1, k / k.sum())
    img = img + rng.normal(0, rng.uniform(0.0, 0.04), img.shape)
    out = np.clip(img * 255, 0, 255).astype(np.uint8)
    q = int(rng.uniform(40, 95))
    return cv2.imdecode(cv2.imencode(".jpg", out, [cv2.IMWRITE_JPEG_QUALITY, q])[1], cv2.IMREAD_COLOR)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("--n", type=int, default=20000)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--runtime", default="vulkan")
    ap.add_argument("--shard", type=int, default=5000)
    ap.add_argument("--preview", action="store_true", help="also write full frames of the first 24 samples")
    a = ap.parse_args()
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    rng = np.random.default_rng(a.seed)
    head = ensure_ict_facekit()
    r = Renderer(head)
    mesh = FaceMesh(runtime=a.runtime, flip_average=False)
    brows = brow_masks(head)
    neutral_gap = {s: lid_gap(head, np.zeros(len(NAMES), np.float32), s) for s in LID}
    closed_gap = {}
    for s in LID:
        wc = np.zeros(len(NAMES), np.float32)
        wc[IDX["eyeBlink" + s]] = 1
        closed_gap[s] = lid_gap(head, wc, s)

    buf = {k: [] for k in ("crops", "open", "blink", "squint", "wide", "ypr", "glasses", "glare", "lens_glare",
                           "lid", "seed")}
    shard, kept, t0 = 0, 0, time.time()
    previews = []
    for i in range(a.n):
        s_rng = np.random.default_rng([a.seed, i])
        w = sample_expression(s_rng)
        ypr = np.array([s_rng.normal(0, 15), s_rng.normal(0, 10), s_rng.normal(0, 8)], np.float32)
        ypr = np.clip(ypr, [-40, -30, -25], [40, 30, 25])
        rot = ypr_to_rotation(np.radians(ypr).astype(np.float32))
        # face size in the frame: camera at 40 to 90 cm with a 50 to 70 degree lens, cropped to the head
        dist = s_rng.uniform(40, 90)
        fov = math.degrees(2 * math.atan(s_rng.uniform(14, 22) / dist))
        rgba = r.render(w, rot, dist, fov, colors_for(head, s_rng, brows), sample_light(s_rng))
        alpha = rgba[..., 3:].astype(np.float32) / 255
        img = rgba[..., :3].astype(np.float32) / 255 * alpha + background(s_rng, SIZE) * (1 - alpha)
        wears = s_rng.random() < 0.55
        glare = add_glasses(img, r, s_rng, rot) if wears else {}
        frame_size = int(s_rng.uniform(220, 512))
        img = cv2.resize(img.astype(np.float32), (frame_size, frame_size), interpolation=cv2.INTER_AREA)
        bgr = camera(img, s_rng)
        mesh.roi = None
        lm = mesh.process(bgr)
        if lm is None:
            continue
        crops = crop_eyes(bgr, lm)
        pts = mpp.landmarks_to_points(lm, frame_size, frame_size)
        # which image eye is ICT's _L: the projected lid vertex lands near it
        lid_px = r.project(head.neutral[[LID["_L"][0][0]]])[0] * frame_size / SIZE
        mp_left = lm[[362, 263], :2].mean(0) * frame_size
        mp_right = lm[[133, 33], :2].mean(0) * frame_size
        l_is_left = np.linalg.norm(lid_px - mp_left) < np.linalg.norm(lid_px - mp_right)
        order = ("_L", "_R") if l_is_left else ("_R", "_L")
        opens = [max(0.0, (lid_gap(head, w, s) - closed_gap[s]) / (neutral_gap[s] - closed_gap[s])) for s in order]
        buf["crops"].append(crops)
        buf["open"].append(opens)
        buf["blink"].append([w[IDX["eyeBlink" + s]] for s in order])
        buf["squint"].append([w[IDX["eyeSquint" + s]] for s in order])
        buf["wide"].append([w[IDX["eyeWide" + s]] for s in order])
        buf["ypr"].append(ypr)
        buf["glasses"].append(wears)
        gl = [float(glare[sd].max()) if sd in glare else 0.0 for sd in ("Left", "Right")]
        buf["glare"].append(gl)
        buf["lens_glare"].append(lens_glare(bgr, lm))
        buf["lid"].append([mpp._lid_gap(pts, sd) for sd in ("Left", "Right")])
        buf["seed"].append(i)
        kept += 1
        if a.preview and len(previews) < 24:
            previews.append(cv2.resize(bgr, (256, 256)))
        if len(buf["crops"]) >= a.shard or i == a.n - 1:
            np.savez_compressed(out / f"shard_{a.seed:03d}_{shard:04d}.npz",
                                **{k: np.array(v) for k, v in buf.items()})
            shard += 1
            buf = {k: [] for k in buf}
        if i % 500 == 499:
            print(f"{i + 1}/{a.n} kept {kept} {(time.time() - t0) / (i + 1) * 1000:.0f} ms/sample", flush=True)
    if buf["crops"]:
        np.savez_compressed(out / f"shard_{a.seed:03d}_{shard:04d}.npz", **{k: np.array(v) for k, v in buf.items()})
    if previews:
        rows = [np.hstack(previews[j:j + 6]) for j in range(0, len(previews) - 5, 6)]
        cv2.imwrite(str(out / "preview_frames.jpg"), np.vstack(rows))
    print(f"done: {kept}/{a.n} with a face, {time.time() - t0:.0f} s")


if __name__ == "__main__":
    main()
