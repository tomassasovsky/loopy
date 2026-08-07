#!/usr/bin/env python
"""FDM printability check for the enclosure STLs -- "will this warp, and where?"

Voxelises a binary STL by casting a vertical ray through the centre of every
grid column (closed mesh -> even/odd pairing gives the solid intervals), then
scores the geometry against the failure modes that actually kill big flat
prints:

  BED       first-layer contact vs. the part's own footprint. A part that
            touches the bed over a small fraction of what it spans has nothing
            holding its edges down while the mass above it contracts.
  WARP      per-column lever score: how far a piece of the part sits from the
            nearest bed-anchored column, weighted by the material stacked above
            it and by whether it lies on a free edge (edges peel first, corners
            peel first of all).
  THIN      local wall thickness from a 3-D distance transform -- features that
            come out under a couple of extrusion widths.
  ASPECT    tall unbraced walls (height / thickness).
  GAP       slots narrower than the nozzle: the slicer either fuses them or
            leaves a crack.
  BRIDGE    material that starts in mid-air with nothing underneath.
  ISLAND    a layer piece with NO support beneath it anywhere -- unlike a
            bridge there is nothing in its own layer to span to, so the head
            draws it into thin air and it drops.
  BODIES    solids that are not connected to each other at all.
  SUPPORT   down-facing surfaces shallower than the slicer's overhang limit,
            each sized by how far the extruder must reach unsupported. A face
            with a short reach bridges and wants no support however flat it
            is; the number to shrink is the reach, not the angle.

The WARP number is a calibrated heuristic against printing rules of thumb, not
a thermal-stress simulation. Treat the ranking as "look here first", not as a
prediction with a physical unit attached.

    python _print_check.py out/segno_mini_console_tray.stl --png out/_check.png
"""

from __future__ import annotations

import argparse
import math
import os
import struct
import sys

import numpy as np
from scipy import ndimage

# --- scoring thresholds (mm unless stated) --------------------------------
ADHESION_BAD = 0.25       # first-layer area / footprint below this = red
ADHESION_WARN = 0.60
LEVER_REF = 25.0          # unsupported run to an anchor that reads as "1.0"
STACK_REF = 20.0          # material height above that doubles the pull
EDGE_BAND = 2.5           # how far in from a free edge still counts as an edge
WARP_WARN, WARP_BAD = 1.5, 3.0
ASPECT_WARN, ASPECT_BAD = 20.0, 40.0
SUPPORT_ANGLE = 45.0      # slicer overhang limit, degrees from vertical
BRIDGE_REACH = 5.0        # unsupported reach a slicer bridges without help.
                          # Measured as the largest inscribed disc in the
                          # overhanging patch: an annular counterbore ceiling
                          # 2.5 mm wide bridges; a solid 12 mm disc does not.
NOISE_MM2 = 12.0          # a hit smaller than this is a cell or two at a corner
                          # -- grid dust, not a wall. Still listed, but it does
                          # not decide the verdict. Re-run at a finer --res to
                          # confirm anything that sits near the line.


# --- mesh -> occupancy grid ------------------------------------------------
def load_shape(path, tol=0.05):
    """Triangles from an STL *or* a STEP.

    STEP matters: slicers import it, so "I checked the STL" is no guarantee
    about the file that actually gets sliced. Check whichever one you are
    about to load into the slicer.
    """
    if os.path.splitext(path)[1].lower() in (".step", ".stp"):
        import cadquery as cq                      # only needed for STEP
        shape = cq.importers.importStep(path).val()
        vs, ts = shape.tessellate(tol)
        v = np.array([[p.x, p.y, p.z] for p in vs], dtype=np.float64)
        return v[np.array(ts, dtype=np.int64)]
    return load_stl(path)


def load_stl(path):
    """Return an (n, 3, 3) float array of triangles (binary or ASCII STL)."""
    with open(path, "rb") as fh:
        head = fh.read(80)
        if head.lstrip()[:5] == b"solid":
            fh.seek(0)
            txt = fh.read().decode("utf8", "replace").split()
            pts = [float(txt[i + 1]) for i, w in enumerate(txt) if w == "vertex"
                   for i in (i,)][:0]  # placeholder; rebuilt below
            vals, i = [], 0
            while i < len(txt):
                if txt[i] == "vertex":
                    vals.extend(float(v) for v in txt[i + 1:i + 4])
                    i += 4
                else:
                    i += 1
            return np.array(vals, dtype=np.float64).reshape(-1, 3, 3)
        n = struct.unpack("<I", fh.read(4))[0]
        raw = np.frombuffer(fh.read(n * 50), dtype=np.uint8).reshape(n, 50)
    return raw[:, 12:48].copy().view("<f4").reshape(n, 3, 3).astype(np.float64)


def voxelise(tris, res, dz):
    """Occupancy grid occ[z, y, x] plus the grid origin.

    One vertical ray per column at the cell centre; the sorted z-hits pair up
    into solid spans. Cell centres sit off the lattice, so rays essentially
    never graze a shared edge or vertex.
    """
    lo, hi = tris.reshape(-1, 3).min(0), tris.reshape(-1, 3).max(0)
    nx = max(1, int(math.ceil((hi[0] - lo[0]) / res)))
    ny = max(1, int(math.ceil((hi[1] - lo[1]) / res)))
    nz = max(1, int(math.ceil((hi[2] - lo[2]) / dz)))
    xs = lo[0] + (np.arange(nx) + 0.5) * res
    ys = lo[1] + (np.arange(ny) + 0.5) * res

    a, b, c = tris[:, 0], tris[:, 1], tris[:, 2]
    # skip vertical-ish facets: they carry no ray crossing information
    nrm = np.cross(b - a, c - a)
    live = np.abs(nrm[:, 2]) > 1e-9

    cols, zhit, wind = [], [], []
    for t in np.nonzero(live)[0]:
        p0, p1, p2 = a[t], b[t], c[t]
        x0 = max(0, int((min(p0[0], p1[0], p2[0]) - lo[0]) / res) - 1)
        x1 = min(nx, int((max(p0[0], p1[0], p2[0]) - lo[0]) / res) + 2)
        y0 = max(0, int((min(p0[1], p1[1], p2[1]) - lo[1]) / res) - 1)
        y1 = min(ny, int((max(p0[1], p1[1], p2[1]) - lo[1]) / res) + 2)
        if x1 <= x0 or y1 <= y0:
            continue
        gx, gy = np.meshgrid(xs[x0:x1], ys[y0:y1])
        # barycentric point-in-triangle in XY
        d = ((p1[1] - p2[1]) * (p0[0] - p2[0]) + (p2[0] - p1[0]) * (p0[1] - p2[1]))
        if abs(d) < 1e-12:
            continue
        w0 = ((p1[1] - p2[1]) * (gx - p2[0]) + (p2[0] - p1[0]) * (gy - p2[1])) / d
        w1 = ((p2[1] - p0[1]) * (gx - p2[0]) + (p0[0] - p2[0]) * (gy - p2[1])) / d
        w2 = 1.0 - w0 - w1
        inside = (w0 >= 0) & (w1 >= 0) & (w2 >= 0)
        if not inside.any():
            continue
        z = w0 * p0[2] + w1 * p1[2] + w2 * p2[2]
        iy, ix = np.nonzero(inside)
        cols.append((iy + y0) * nx + (ix + x0))
        zhit.append(z[inside])
        # +1 = ray enters solid here (facet faces down), -1 = leaves
        wind.append(np.full(iy.size, -1 if nrm[t, 2] > 0 else 1, dtype=np.int8))

    occ = np.zeros((nz, ny, nx), dtype=bool)
    if not cols:
        return occ, lo
    col = np.concatenate(cols)
    zv = np.concatenate(zhit)
    wd = np.concatenate(wind)
    order = np.lexsort((zv, col))
    col, zv, wd = col[order], zv[order], wd[order]
    # WINDING, not even/odd: unions leave coincident faces, so a column can hold
    # duplicate crossings that would flip an even/odd parity for everything
    # after them. Depth = running sum of the crossing directions; solid where
    # the depth is positive.
    cum = np.cumsum(wd)
    starts = np.r_[0, np.nonzero(col[1:] != col[:-1])[0] + 1]
    prior = np.where(starts > 0, cum[starts - 1], 0)   # depth carried in from prior columns
    depth = cum - np.repeat(prior, np.diff(np.r_[starts, col.size]))
    solid = depth > 0                             # span runs from this hit to the next
    flat = occ.reshape(nz, -1)
    last = np.r_[col[1:] != col[:-1], True]       # final hit of each column: no span
    sel = solid & ~last
    for z_lo, z_hi, cc in zip(zv[sel], zv[1:][sel[:-1]], col[sel]):
        k0 = int(math.ceil((z_lo - lo[2]) / dz - 0.5))
        k1 = int(math.floor((z_hi - lo[2]) / dz - 0.5))
        if k1 >= k0:
            flat[max(0, k0):min(nz, k1 + 1), cc] = True
    return occ, lo


def overhangs(tris, res, zfloor, angle=SUPPORT_ANGLE):
    """Down-facing patches shallower than `angle`, sized by unsupported reach.

    Angle alone is a bad predictor: the flat annular ceiling of a counterbore
    is a 0 deg overhang that every slicer bridges, while a broad shallow face
    needs help. So each patch is measured by the largest inscribed disc it
    contains -- how far the extruder must reach with nothing under it.

    Faces sitting on the build plate are bed contact, not overhang, and are
    dropped.
    """
    a, b, c = tris[:, 0], tris[:, 1], tris[:, 2]
    n = np.cross(b - a, c - a)
    area = np.linalg.norm(n, axis=1) / 2.0
    with np.errstate(invalid="ignore", divide="ignore"):
        down = -n[:, 2] / np.maximum(np.linalg.norm(n, axis=1), 1e-12)
    zc = tris[:, :, 2].mean(1)
    # strictly shallower: a face AT the limit is the self-supporting boundary by
    # convention, and exact-45 geometry is common on purpose. The epsilon is
    # float slack (~0.1 deg), not a fudge factor.
    sel = (down > math.cos(math.radians(angle)) + 1e-3) & (zc > zfloor + 0.5)
    if not sel.any():
        return []

    lo2 = tris.reshape(-1, 3).min(0)
    hi2 = tris.reshape(-1, 3).max(0)
    nx = max(1, int(math.ceil((hi2[0] - lo2[0]) / res)))
    ny = max(1, int(math.ceil((hi2[1] - lo2[1]) / res)))
    out = []
    idx = np.nonzero(sel)[0]
    zb = np.round(zc[idx] / 1.0).astype(int)          # group by 1 mm of height
    for band in np.unique(zb):
        grp = idx[zb == band]
        mask = np.zeros((ny, nx), dtype=bool)
        for t in grp:                                  # rasterise the facet
            p = tris[t]
            x0 = max(0, int((p[:, 0].min() - lo2[0]) / res))
            x1 = min(nx, int((p[:, 0].max() - lo2[0]) / res) + 1)
            y0 = max(0, int((p[:, 1].min() - lo2[1]) / res))
            y1 = min(ny, int((p[:, 1].max() - lo2[1]) / res) + 1)
            mask[y0:y1 + 1, x0:x1 + 1] = True
        lab, k = ndimage.label(mask)
        for i in range(1, k + 1):
            comp = lab == i
            reach = float(ndimage.distance_transform_edt(
                comp, sampling=(res, res)).max())
            ys, xs = np.nonzero(comp)
            out.append({
                "area": float(area[grp].sum() * comp.sum() / max(mask.sum(), 1)),
                "reach": 2.0 * reach,
                "z": float(zc[grp].mean()),
                "x": lo2[0] + xs.mean() * res,
                "y": lo2[1] + ys.mean() * res,
            })
    return sorted(out, key=lambda d: d["reach"], reverse=True)


# --- checks ----------------------------------------------------------------
def analyse(occ, lo, res, dz, nozzle):
    nz, ny, nx = occ.shape
    cell = res * res
    layer_area = occ.reshape(nz, -1).sum(1) * cell
    first = occ[0]
    footprint = occ.any(0)
    r = {
        "shape": (nx * res, ny * res, nz * dz),
        "layer_area": layer_area,
        "first_area": layer_area[0],
        "footprint_area": footprint.sum() * cell,
        "max_area": layer_area.max(),
        "volume": occ.sum() * cell * dz,
    }
    r["adhesion"] = r["first_area"] / max(r["footprint_area"], 1e-9)

    # area cliff: the layer where the cross-section suddenly blooms
    a = np.maximum(layer_area, 1e-9)
    ratio = a[1:] / a[:-1]
    k = int(np.argmax(ratio))
    r["cliff"] = (ratio[k], (k + 1) * dz + lo[2])

    # --- warp lever ---------------------------------------------------------
    d_anchor = ndimage.distance_transform_edt(~first, sampling=(res, res)) * 1.0
    stack = occ.sum(0) * dz
    edge = footprint & ~ndimage.binary_erosion(
        footprint, ndimage.generate_binary_structure(2, 1),
        iterations=max(1, int(EDGE_BAND / res)))
    # a convex corner of the footprint has few footprint neighbours around it
    nb = ndimage.uniform_filter(footprint.astype(np.float32),
                                size=max(3, int(2 * EDGE_BAND / res) | 1))
    corner = footprint & (nb < 0.45)
    warp = (d_anchor / LEVER_REF) * (1.0 + stack / STACK_REF)
    warp *= np.where(corner, 2.5, np.where(edge, 1.8, 1.0))
    warp[~footprint] = 0.0
    r["warp"] = warp
    r["d_anchor"] = np.where(footprint, d_anchor, 0.0)
    r["first"] = first
    r["footprint"] = footprint
    r["hot"] = _peaks(warp, lo, res, WARP_BAD)

    # --- in-plane thickness, walls and slots --------------------------------
    # Thickness that matters to FDM is measured in the layer plane, so sample
    # layers about every millimetre and take the local thickness of the solid
    # (walls) and of the free space (slots the nozzle cannot resolve).
    ceil_mm = max(4.0 * nozzle, 3.0)
    prof = []                             # per-column thickness, sampled layers
    thin_hits, gaps, thin_area = [], [], 0.0
    for z in range(0, nz, max(1, int(round(1.0 / dz)))):
        sel = occ[z]
        if not sel.any():
            continue
        lt = local_thickness(sel, res, ceil_mm)
        prof.append(np.where(sel, lt, np.nan))
        bad = sel & (lt < 2.0 * nozzle)
        if bad.any():
            thin_area += bad.sum() * res * res
            iy, ix = np.unravel_index(int(np.argmin(np.where(bad, lt, np.inf))),
                                      lt.shape)
            thin_hits.append((float(lt[iy, ix]), float(bad.sum()) * res * res,
                              lo[0] + ix * res, lo[1] + iy * res, z * dz + lo[2]))
        # slots: free space the part pinches down, ignoring the open air around
        # it. binary_closing (not fill_holes) so slots open at one end count.
        rad = max(1, int(round(2.0 * nozzle / res)))
        ball = np.hypot(*np.ogrid[-rad:rad + 1, -rad:rad + 1]) <= rad
        pinched = ndimage.binary_closing(sel, ball) & ~sel
        if pinched.any():
            gw = local_thickness(~sel, res, ceil_mm)
            gbad = pinched & (gw < 2.0 * nozzle) & (gw > 0)
            if gbad.any():
                iy, ix = np.unravel_index(
                    int(np.argmin(np.where(gbad, gw, np.inf))), gw.shape)
                gaps.append((z * dz + lo[2], float(gw[iy, ix]),
                             float(gbad.sum()) * res * res,
                             lo[0] + ix * res, lo[1] + iy * res))
    r["thin_min"] = min([t for t, a, *_ in thin_hits if a >= NOISE_MM2],
                        default=float("inf"))
    r["thin_area"] = thin_area
    r["thin_spots"] = sorted(thin_hits, key=lambda t: t[1], reverse=True)[:6]
    r["gaps"] = gaps

    # --- wall aspect (height carried on the slender section) ----------------
    # 20th percentile of the column's sampled layers, not the minimum: a sloped
    # roof always clips its topmost layer to a sliver, and one sliver layer
    # should not make a 3 mm wall read as 0.6 mm.
    with np.errstate(invalid="ignore", all="ignore"):
        tmap = (np.nanpercentile(np.dstack(prof), 20, axis=2)
                if prof else np.full((ny, nx), np.nan))
    # a real thin wall is thin over a contiguous patch; a lone thin cell is the
    # grid clipping a corner, so median-filter it away before scoring
    tmap = ndimage.median_filter(np.where(np.isfinite(tmap), tmap, 0.0), size=3)
    tmap[tmap <= 0] = np.inf
    with np.errstate(divide="ignore", invalid="ignore"):
        aspect = np.where(np.isfinite(tmap) & (tmap > 0), stack / tmap, 0.0)
    aspect[~footprint] = 0.0
    r["aspect"] = aspect
    r["thickness"] = np.where(np.isfinite(tmap), tmap, 0.0)
    r["slender"] = _peaks(aspect, lo, res, ASPECT_BAD)

    # --- unsupported starts -------------------------------------------------
    below = np.zeros_like(occ)
    below[1:] = occ[:-1]
    fresh = occ & ~below
    fresh[0] = False
    r["bridge_area"] = fresh.reshape(nz, -1).sum(1) * cell
    j = int(np.argmax(r["bridge_area"]))
    r["bridge_worst"] = (r["bridge_area"][j], j * dz + lo[2])

    # --- islands: layer pieces with NOTHING under them ----------------------
    # Distinct from BRIDGE. A bridge is anchored somewhere in its own layer and
    # the extruder can span to it; an island is a closed loop of perimeter with
    # no support anywhere beneath, so the head draws it into thin air and it
    # falls. Anything sitting on the bed is not an island.
    islands = []
    for z in range(1, nz):
        if not occ[z].any():
            continue
        lab, n = ndimage.label(occ[z])
        if n == 0:
            continue
        # a piece is supported if ANY of its cells has material directly below
        holds = ndimage.sum(occ[z - 1], lab, np.arange(1, n + 1))
        sizes = ndimage.sum(occ[z], lab, np.arange(1, n + 1))
        for i in np.nonzero(holds == 0)[0]:
            comp = lab == (i + 1)
            ys, xs = np.nonzero(comp)
            islands.append((float(sizes[i]) * cell, z * dz + lo[2],
                            lo[0] + xs.mean() * res, lo[1] + ys.mean() * res))
    r["islands"] = sorted(islands, key=lambda t: t[0], reverse=True)

    # --- separate bodies ----------------------------------------------------
    lab3, n3 = ndimage.label(occ)
    r["bodies"] = n3
    if n3 > 1:
        vols = ndimage.sum(occ, lab3, np.arange(1, n3 + 1)) * cell * dz
        r["body_vols"] = np.sort(vols)[::-1]
    r["overhangs"] = []
    return r


def _peaks(field, lo, res, thresh, top=6, sep=15.0):
    """Local maxima of a 2-D score field, thinned so hits do not cluster."""
    out, work = [], field.copy()
    for _ in range(top):
        i = int(np.argmax(work))
        v = work.flat[i]
        if v < thresh:
            break
        y, x = np.unravel_index(i, work.shape)
        out.append((float(v), lo[0] + x * res, lo[1] + y * res))
        yy, xx = np.ogrid[:work.shape[0], :work.shape[1]]
        work[((yy - y) * res) ** 2 + ((xx - x) * res) ** 2 < sep ** 2] = 0
    return out


def local_thickness(mask, res, ceil_mm):
    """Diameter of the largest inscribed disc CONTAINING each cell.

    NOT 2 x distance-to-surface: that is the largest disc *centred* on the
    cell, so it calls the skin of a 20 mm block "0.6 mm thick" and every
    chamfer tangent line a thin wall. Walk radii downward and let each cell
    take the first (largest) disc that covers it. Anything at or above
    `ceil_mm` is clamped -- we only care about the thin end.
    """
    d = ndimage.distance_transform_edt(mask, sampling=(res, res))
    out = np.zeros(mask.shape, dtype=np.float32)
    step = max(res, 0.15)
    for r in np.arange(ceil_mm / 2.0, step * 0.5, -step):
        seeds = d >= r
        if not seeds.any():
            continue
        cover = ndimage.distance_transform_edt(~seeds, sampling=(res, res)) <= r
        out[cover & (out == 0)] = 2.0 * r
    rest = mask & (out == 0)
    out[rest] = 2.0 * d[rest]        # thinner than the smallest disc we tried
    out[~mask] = 0.0
    return out


# --- report ----------------------------------------------------------------
def verdict(v, warn, bad, invert=False):
    if invert:
        return "OK  " if v >= warn else ("WARN" if v >= bad else "FAIL")
    return "OK  " if v < warn else ("WARN" if v < bad else "FAIL")


def report(name, r, res, dz, nozzle, support_angle=SUPPORT_ANGLE):
    W, D, H = r["shape"]
    print(f"\n=== printability: {name} ===")
    print(f"    envelope {W:.1f} x {D:.1f} x {H:.1f} mm   "
          f"solid {r['volume']/1000:.1f} cm3 "
          f"(~{r['volume']*1.24*0.25/1000:.0f} g PLA at 15% infill, "
          f"{r['volume']*1.24/1000:.0f} g solid)")
    print(f"    grid {res} mm xy / {dz} mm z, nozzle {nozzle} mm\n")

    ad = r["adhesion"]
    print(f"[{verdict(ad, ADHESION_WARN, ADHESION_BAD, invert=True)}] BED     "
          f"first layer {r['first_area']:.0f} mm2 = {100*ad:.1f}% of the "
          f"{r['footprint_area']:.0f} mm2 footprint")
    cr, cz = r["cliff"]
    if cr > 3.0:
        print(f"          cross-section jumps {cr:.0f}x at z={cz:.2f} -- the part "
              f"widens far above its grip on the bed")

    hot = r["hot"]
    lab = verdict(max([h[0] for h in hot], default=0.0), WARP_WARN, WARP_BAD)
    print(f"[{lab}] WARP    peak lever score "
          f"{max([h[0] for h in hot], default=0.0):.1f} "
          f"(warn {WARP_WARN}, fail {WARP_BAD}); "
          f"max run to an anchored column {r['d_anchor'].max():.0f} mm")
    for v, x, y in hot:
        print(f"          score {v:5.1f} at x={x:6.1f} y={y:6.1f}")

    tm = r["thin_min"]
    if not np.isfinite(tm):
        print(f"[OK  ] THIN    every wall carries at least {2*nozzle:.1f} mm "
              f"(one bead each side)")
    else:
        print(f"[{verdict(tm, 2*nozzle, 1.5*nozzle, invert=True)}] THIN    "
              f"thinnest wall {tm:.2f} mm ({tm/nozzle:.1f} extrusion widths); "
              f"{r['thin_area']:.0f} mm2 of layer area under {2*nozzle:.1f} mm")
    for t, a, x, y, z in r["thin_spots"]:
        print(f"          {t:4.2f} mm wall at x={x:6.1f} y={y:6.1f} z={z:5.1f} "
              f"({a:.0f} mm2 in that layer)"
              + ("   [grid dust]" if a < NOISE_MM2 else ""))

    sl = r["slender"]
    print(f"[{verdict(max([s[0] for s in sl], default=0.0), ASPECT_WARN, ASPECT_BAD)}]"
          f" ASPECT  tallest slenderness "
          f"{max([s[0] for s in sl], default=0.0):.0f}:1")
    for v, x, y in sl:
        print(f"          {v:5.0f}:1 at x={x:6.1f} y={y:6.1f}")

    g = r["gaps"]
    tight = min([w for _, w, a, _, _ in g if a >= NOISE_MM2], default=9e9)
    print(f"[{'OK  ' if not g else verdict(tight, 2*nozzle, nozzle, invert=True)}]"
          f" GAP     {len(g)} sampled layers hold a slot under "
          f"{2*nozzle:.1f} mm (one bead each side)")
    for z, w, a, x, y in sorted(g, key=lambda t: t[2], reverse=True)[:5]:
        print(f"          {w:4.2f} mm slot at x={x:6.1f} y={y:6.1f} z={z:5.1f} "
              f"({a:.0f} mm2 in that layer)"
              + ("   [grid dust]" if a < NOISE_MM2 else ""))

    ba, bz = r["bridge_worst"]
    print(f"[{verdict(ba, 200, 800)}] BRIDGE  worst unsupported start "
          f"{ba:.0f} mm2 at z={bz:.2f}")

    isl = [i for i in r["islands"] if i[0] >= NOISE_MM2]
    print(f"[{'OK  ' if not isl else 'FAIL'}] ISLAND  {len(isl)} layer piece(s) "
          f"with nothing at all underneath")
    for a, z, x, y in isl[:6]:
        print(f"          {a:6.1f} mm2 floating at x={x:6.1f} y={y:6.1f} z={z:5.1f}")
    if r["bodies"] > 1:
        v = ", ".join(f"{x:.0f}" for x in r["body_vols"][:5])
        print(f"[FAIL] BODIES  {r['bodies']} separate solids in one file "
              f"(mm3: {v}) -- loose pieces, not one part")

    ov = r["overhangs"]
    need = [o for o in ov if o["reach"] > BRIDGE_REACH and o["area"] >= NOISE_MM2]
    tot = sum(o["area"] for o in ov)
    print(f"[{'OK  ' if not need else 'FAIL'}] SUPPORT {tot:.0f} mm2 faces "
          f"shallower than {support_angle:.0f} deg above the bed; "
          f"{len(need)} patch(es) reach further than {BRIDGE_REACH:.0f} mm "
          f"and would want support")
    for o in ov[:6]:
        if o["area"] < NOISE_MM2:
            continue
        tag = "NEEDS SUPPORT" if o["reach"] > BRIDGE_REACH else "bridges"
        print(f"          {o['area']:6.0f} mm2, reach {o['reach']:5.1f} mm "
              f"at x={o['x']:6.1f} y={o['y']:6.1f} z={o['z']:5.1f}   {tag}")


def draw(path, r, lo, res):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    ext = [lo[0], lo[0] + r["footprint"].shape[1] * res,
           lo[1], lo[1] + r["footprint"].shape[0] * res]
    fig, ax = plt.subplots(1, 3, figsize=(16, 5.6))
    ax[0].imshow(r["footprint"], origin="lower", extent=ext, cmap="Greys", alpha=.35)
    ax[0].imshow(np.ma.masked_where(~r["first"], r["first"]), origin="lower",
                 extent=ext, cmap="autumn")
    ax[0].set_title(f"bed contact {100*r['adhesion']:.1f}% of footprint")
    im = ax[1].imshow(np.ma.masked_where(~r["footprint"], r["d_anchor"]),
                      origin="lower", extent=ext, cmap="viridis")
    ax[1].set_title("distance to nearest bed-anchored column (mm)")
    fig.colorbar(im, ax=ax[1], shrink=.8)
    im = ax[2].imshow(np.ma.masked_where(~r["footprint"], r["warp"]),
                      origin="lower", extent=ext, cmap="inferno",
                      vmin=0, vmax=max(WARP_BAD * 1.5, r["warp"].max()))
    ax[2].set_title("warp lever score")
    fig.colorbar(im, ax=ax[2], shrink=.8)
    for a in ax:
        a.set_aspect("equal")
        a.set_xlabel("x (mm)")
    fig.tight_layout()
    fig.savefig(path, dpi=110)
    print(f"\n    map -> {path}")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("stl", nargs="+", help="STL or STEP files")
    ap.add_argument("--res", type=float, default=0.6, help="xy grid (mm)")
    ap.add_argument("--dz", type=float, default=0.4, help="z grid (mm)")
    ap.add_argument("--nozzle", type=float, default=0.4)
    ap.add_argument("--support-angle", type=float, default=SUPPORT_ANGLE,
                    dest="support_angle", help="slicer overhang limit (deg)")
    ap.add_argument("--png", default=None, help="write a map for the FIRST stl")
    a = ap.parse_args(argv)

    worst = 0
    for i, p in enumerate(a.stl):
        tris = load_shape(p)
        occ, lo = voxelise(tris, a.res, a.dz)
        r = analyse(occ, lo, a.res, a.dz, a.nozzle)
        r["overhangs"] = overhangs(tris, a.res, lo[2], a.support_angle)
        report(os.path.basename(p), r, a.res, a.dz, a.nozzle, a.support_angle)
        if r["adhesion"] < ADHESION_BAD or any(h[0] >= WARP_BAD for h in r["hot"]):
            worst = 1
        if a.png and i == 0:
            draw(a.png, r, lo, a.res)
    return worst


if __name__ == "__main__":
    sys.exit(main())
