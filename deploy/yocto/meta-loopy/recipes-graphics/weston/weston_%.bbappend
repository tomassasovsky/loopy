# Raspberry Pi 4 floor-console (Tier 3a spike): weston 14 on vc4/V3D KMS aborts
# in the DRM plane-assignment path (assert(fb) in drm_output_find_plane_for_view)
# as soon as a client sets a pointer cursor, crashing the compositor on mouse
# input. The patch pins weston's cursors_are_broken/sprites_are_broken flags so
# the cursor and overlays are GL-composited instead of assigned to KMS planes.
# See the patch header for the full rationale.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

SRC_URI += "file://0001-loopy-vc4-cursor-planes-broken.patch"
