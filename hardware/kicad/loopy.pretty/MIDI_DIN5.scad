// 3D body for the right-angle 5-pin DIN MIDI socket (MIDI_DIN5_RA footprint).
// KiCad VRML frame: model X = footprint X, model Y = UP (board Z),
// model Z = footprint Y (front-to-back). Socket opening faces the front (-Z).
// Footprint scale 0.3937 (=1/2.54) cancels KiCad's WRL 0.1-inch unit factor.
$fn = 56;

bw = 15.5;          // body width  (X)
bh = 15.0;          // body height (up, model Y)
by0 = -1.5;         // body front (model Z, toward the socket opening)
by1 = 13.0;         // body back  (model Z, over the PCB)
fw = 21.0;          // flange width
fh = 21.0;          // flange height
ft = 1.8;           // flange thickness
sr = 7.6;           // socket radius
sz = 9.0;           // socket centre height above board

color([0.13, 0.13, 0.14]) {
    // main body box
    translate([-bw/2, 0, by0]) cube([bw, bh, by1 - by0]);
    // square front flange
    translate([-fw/2, 0, by0 - ft]) cube([fw, fh, ft]);
}
// metal socket ring on the flange face
color([0.55, 0.55, 0.58])
    translate([0, sz, by0 - ft - 0.3]) cylinder(h = 0.7, r = sr);
// dark recessed socket
color([0.04, 0.04, 0.04])
    translate([0, sz, by0 - ft - 0.1]) cylinder(h = ft + 0.4, r = sr - 1.6);
