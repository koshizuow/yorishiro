import math

import moderngl
import numpy as np

from .ict import IctHead

TEX_W = 4096

VERTEX_SHADER = """
#version 330
uniform mat4 mvp;
uniform mat4 model;
uniform sampler2D deltas;
uniform int n_verts;
uniform int n_shapes;
uniform float weights[64];
in vec3 in_pos;
in vec3 in_color;
out vec3 v_pos;
out vec3 v_color;
void main() {
    vec3 p = in_pos;
    for (int s = 0; s < n_shapes; ++s) {
        float w = weights[s];
        if (w < 0.001) continue;
        int idx = s * n_verts + gl_VertexID;
        p += w * texelFetch(deltas, ivec2(idx % 4096, idx / 4096), 0).xyz;
    }
    v_pos = (model * vec4(p, 1.0)).xyz;
    v_color = in_color;
    gl_Position = mvp * vec4(p, 1.0);
}
"""

FRAGMENT_SHADER = """
#version 330
uniform vec3 eye;
in vec3 v_pos;
in vec3 v_color;
out vec4 f_color;
void main() {
    vec3 n = normalize(cross(dFdx(v_pos), dFdy(v_pos)));
    vec3 v = normalize(eye - v_pos);
    if (dot(n, v) < 0.0) n = -n;
    vec3 l = normalize(vec3(0.3, 0.5, 1.0));
    float diff = max(dot(n, l), 0.0);
    float spec = pow(max(dot(reflect(-l, n), v), 0.0), 24.0) * 0.15;
    f_color = vec4(v_color * (0.28 + 0.72 * diff) + spec, 1.0);
}
"""


def _perspective(fov_y_deg: float, aspect: float, near: float, far: float) -> np.ndarray:
    f = 1.0 / math.tan(math.radians(fov_y_deg) / 2)
    return np.array([
        [f / aspect, 0, 0, 0],
        [0, f, 0, 0],
        [0, 0, (far + near) / (near - far), 2 * far * near / (near - far)],
        [0, 0, -1, 0],
    ], dtype=np.float32)


def _translate(x: float, y: float, z: float) -> np.ndarray:
    m = np.eye(4, dtype=np.float32)
    m[:3, 3] = (x, y, z)
    return m


def _gl(m: np.ndarray) -> bytes:
    return m.T.astype("f4").tobytes()  # GL expects column-major


class HeadRenderer:
    """Offscreen renderer for the ICT bald head. Blendshapes are applied on the GPU."""

    def __init__(self, head: IctHead, size: int = 540, samples: int = 4):
        self.head = head
        self.size = size
        self.ctx = moderngl.create_standalone_context(backend="egl")
        self.ctx.enable(moderngl.DEPTH_TEST)

        n_shapes, n_verts = head.deltas.shape[:2]
        flat = head.deltas.reshape(-1, 3)
        rows = math.ceil(len(flat) / TEX_W)
        packed = np.zeros((rows * TEX_W, 3), dtype=np.float32)
        packed[: len(flat)] = flat
        self.delta_tex = self.ctx.texture((TEX_W, rows), 3, packed.tobytes(), dtype="f4")
        self.delta_tex.filter = (moderngl.NEAREST, moderngl.NEAREST)

        self.prog = self.ctx.program(vertex_shader=VERTEX_SHADER, fragment_shader=FRAGMENT_SHADER)
        self.prog["n_verts"].value = n_verts
        self.prog["n_shapes"].value = n_shapes
        self.prog["deltas"].value = 0

        vbo_pos = self.ctx.buffer(head.neutral.astype("f4").tobytes())
        vbo_col = self.ctx.buffer(head.vertex_colors().tobytes())
        ibo = self.ctx.buffer(head.faces.astype("i4").tobytes())
        self.vao = self.ctx.vertex_array(
            self.prog, [(vbo_pos, "3f", "in_pos"), (vbo_col, "3f", "in_color")], ibo
        )

        self.fbo_ms = self.ctx.framebuffer(
            color_attachments=[self.ctx.renderbuffer((size, size), samples=samples)],
            depth_attachment=self.ctx.depth_renderbuffer((size, size), samples=samples),
        )
        self.fbo = self.ctx.simple_framebuffer((size, size))

        self.eye = np.array([0.0, -1.0, 62.0], dtype=np.float32)
        self.view_proj = _perspective(32.0, 1.0, 1.0, 200.0) @ _translate(*(-self.eye))
        self.prog["eye"].value = tuple(self.eye)

    def render(self, ict_weights: np.ndarray, rotation: np.ndarray, mirror: bool = True) -> np.ndarray:
        """Return a BGR uint8 image. `rotation` is a 3x3 matrix in face-model space."""
        model = np.eye(4, dtype=np.float32)
        model[:3, :3] = rotation
        self.prog["model"].write(_gl(model))
        self.prog["mvp"].write(_gl(self.view_proj @ model))
        w = np.zeros(64, dtype=np.float32)
        w[: len(ict_weights)] = ict_weights
        self.prog["weights"].write(w.tobytes())

        self.fbo_ms.use()
        self.ctx.clear(0.13, 0.14, 0.16, depth=1.0)
        self.delta_tex.use(0)
        self.vao.render(moderngl.TRIANGLES)
        self.ctx.copy_framebuffer(self.fbo, self.fbo_ms)

        rgb = np.frombuffer(self.fbo.read(components=3), dtype=np.uint8)
        img = rgb.reshape(self.size, self.size, 3)[::-1, :, ::-1]  # GL origin is bottom-left, RGB to BGR
        if mirror:
            img = img[:, ::-1]
        return np.ascontiguousarray(img)

    def close(self) -> None:
        self.ctx.release()
