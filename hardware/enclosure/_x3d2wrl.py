"""Convert a Blender-exported X3D mesh to VRML97 (.wrl) for kicad-cli (reads .wrl/.step,
not .x3d). Blender nests shapes in <Transform> nodes and reuses geometry via DEF/USE, so a
flat copy collapses everything to the origin. Here we BAKE: resolve USE, accumulate the
Transform matrices, and emit flat world-space IndexedFaceSets. Coordinates are preserved
1:1, so the footprint's existing offset/scale/rotate still position it."""
import sys, re
import numpy as np
import xml.etree.ElementTree as ET

src, dst = sys.argv[1], sys.argv[2]
raw = re.sub(r'<!DOCTYPE.*?>', '', open(src).read(), flags=re.S)
root = ET.fromstring(raw)
def tg(e): return e.tag.split('}')[-1]

defs = {e.get('DEF'): e for e in root.iter() if e.get('DEF')}

def xform(e):
    tr = [float(x) for x in (e.get('translation') or '0 0 0').split()]
    ro = [float(x) for x in (e.get('rotation') or '0 0 1 0').split()]
    sc = [float(x) for x in (e.get('scale') or '1 1 1').split()]
    S = np.diag([sc[0], sc[1], sc[2], 1.0])
    R = np.eye(4)
    ax = np.array(ro[:3]); ang = ro[3]; n = np.linalg.norm(ax)
    if n > 1e-9 and abs(ang) > 1e-12:
        x, y, z = ax / n; c, s, C = np.cos(ang), np.sin(ang), 1 - np.cos(ang)
        R[:3, :3] = [[c+x*x*C, x*y*C-z*s, x*z*C+y*s],
                     [y*x*C+z*s, c+y*y*C, y*z*C-x*s],
                     [z*x*C-y*s, z*y*C+x*s, c+z*z*C]]
    T = np.eye(4); T[:3, 3] = tr
    return T @ R @ S

def deref(e): return defs.get(e.get('USE')) if e.get('USE') else e

shapes = []
def walk(e, M):
    e = deref(e)
    if e is None: return
    t = tg(e)
    if t == 'Transform':
        M = M @ xform(e)
    if t == 'Shape':
        col = [0.6, 0.6, 0.6]; ifs = None
        for d in e.iter():
            if tg(d) == 'Material' and d.get('diffuseColor'):
                col = [float(x) for x in d.get('diffuseColor').split()]
            if tg(d) == 'IndexedFaceSet': ifs = deref(d)
        if ifs is not None:
            coord = next((deref(d) for d in ifs.iter() if tg(d) == 'Coordinate'), None)
            if coord is not None and coord.get('point'):
                pts = np.array([float(x) for x in re.split(r'[\s,]+', coord.get('point').strip()) if x]).reshape(-1, 3)
                wp = (M @ np.hstack([pts, np.ones((len(pts), 1))]).T).T[:, :3]
                faces, cur = [], []
                for i in (int(x) for x in ifs.get('coordIndex', '').split()):
                    if i == -1:
                        if len(cur) >= 3: faces.append(cur)
                        cur = []
                    else: cur.append(i)
                shapes.append((col, wp, faces))
        return
    for c in e: walk(c, M)

walk(root, np.eye(4))

out = ["#VRML V2.0 utf8\n"]
for col, wp, faces in shapes:
    pstr = ', '.join('%.5f %.5f %.5f' % tuple(p) for p in wp)
    istr = ', '.join(' '.join(map(str, f)) + ', -1' for f in faces)
    out.append("Shape { appearance Appearance { material Material { diffuseColor %.3f %.3f %.3f } }"
               " geometry IndexedFaceSet { coord Coordinate { point [ %s ] } coordIndex [ %s ] } }\n"
               % (col[0], col[1], col[2], pstr, istr))
open(dst, 'w').write('\n'.join(out))
allp = np.vstack([wp for _, wp, _ in shapes])
print("shapes %d  extent mm: X %.1f Y %.1f Z %.1f" % (
    len(shapes), np.ptp(allp[:,0]), np.ptp(allp[:,1]), np.ptp(allp[:,2])))
