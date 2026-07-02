"""Scratch: build out/vamp.glb (+ .gltf) and the hero/exploded PNGs from the
generator's _render_parts(). Gitignored; run with the bundled .venv."""
import os
import cadquery as cq
import vamp_enclosure as V

OUT = V.OUT
os.makedirs(OUT, exist_ok=True)


def export_glb(explode=0.0):
    asm = cq.Assembly()
    for i, (shape, rgb) in enumerate(V._render_parts(cq, explode)):
        asm.add(cq.Workplane(obj=shape), name=f"p{i}", color=cq.Color(*rgb, 1.0))
    asm.save(os.path.join(OUT, "vamp.gltf"))   # writes .gltf + .bin
    asm.save(os.path.join(OUT, "vamp.glb"))    # binary glTF for the viewer
    print("  out/vamp.glb (+ .gltf)")


if __name__ == "__main__":
    print("Geometry assertions ...", end=" "); V._check(); print("ALL PASS")
    print("3D viewer assets:")
    export_glb(0.0)
    print("Shaded renders:")
    V.render_png(os.path.join(OUT, "_hero34.png"), direction=(-0.55, 0.32, 1.0))
    print("  out/_hero34.png")
    V.render_png(os.path.join(OUT, "_exploded.png"), direction=(-0.55, 0.32, 1.0), explode=120.0)
    print("  out/_exploded.png")
