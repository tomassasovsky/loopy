// 3D body for the right-angle 5-pin DIN MIDI socket (MIDI_DIN5_RA footprint).
// Footprint: socket opening faces +X, body extends -X, pins span +/-Y.
// KiCad VRML frame: model X = footprint X, model Y = UP (board Z),
// model Z = footprint Y.  Footprint scale 0.3937 cancels the WRL unit factor.
$fn = 64;

bx0 = -11.5;  // body back  (model X)
bx1 = 2.0;    // body front (model X)
bh  = 15.0;   // body height (up, model Y)
bz  = 8.5;    // body half-depth (model Z = footprint Y)
ft  = 1.8;    // flange thickness
fw  = 21.0;   // flange size (square)
sr  = 7.6;    // socket radius
sz  = 8.0;    // socket centre height above board

color([0.12, 0.12, 0.13]) {
    // shielded metal body box
    translate([bx0, 0, -bz]) cube([bx1 - bx0, bh, 2 * bz]);
    // square front flange (faces +X)
    translate([bx1, 0, -fw/2]) cube([ft, fw, fw]);
}
// metal socket ring on the flange face
color([0.55, 0.55, 0.58])
    translate([bx1 + ft, sz, 0]) rotate([0, 90, 0]) cylinder(h = 0.7, r = sr);
// dark recessed socket with the 5 contact pin-holes
color([0.04, 0.04, 0.04])
    translate([bx1 + ft - 0.4, sz, 0]) rotate([0, 90, 0]) cylinder(h = ft + 0.6, r = sr - 1.4);
// the 5 contact pins poking down through the PCB (model -Y), at the pad sites
for (p = [[0,7.5],[0,0],[0,-7.5],[2.5,5],[2.5,-5]])
    color([0.7,0.7,0.72]) translate([p[0], -2.5, p[1]]) cylinder(h = 2.5, r = 0.45);
