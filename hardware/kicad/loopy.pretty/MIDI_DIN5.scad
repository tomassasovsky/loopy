// 3D body for the CUI SDS-50J right-angle 5-pin DIN MIDI socket (FEMALE).
// Multi-part: render once per part for a multi-material .wrl (STL drops colour).
//   openscad -D part=0|1|2 -o <p>.stl this.scad   (0 body, 1 cavity, 2 metal)
//
// Frame = KiCad footprint frame: scad X = footprint X (along edge), scad Y =
// footprint Y, scad Z = board up.  Footprint socket opening faces +Y, so the
// boss/cavity face +Y; body extends -Y; pins drop -Z at the pad sites (px,py).
// Plug face is a recessed Ø14 cavity with five FEMALE contact bores in the DIN-5
// fan (pin 2 bottom, keyway top) - no protruding male pins.
part = 0;
$fn = 64;

fw = 20.0;  fh = 21.1;  ft = 1.8;     // square front flange (width X, depth Y, height Z)
bw = 15.8;  bh = 16.5;  bd = 18.0;    // body box
sc = 10.5;                            // socket centre height (Z)
fyf = 4.0;  boss_out = 2.5; boss_r = 9.5;   // flange front Y, Ø19 boss protrusion
cav_r = 7.5; cav_depth = 5.5;         // plug cavity (Ø15, shallow enough to see into)
hole_r = 0.85;                        // female contact bore radius

bossfront = fyf + boss_out;           // Y of boss outer face
cavfloor  = bossfront - cav_depth;    // Y of cavity floor

// female contact fan on the face (X, Z-about-sc): 2 bottom, 4/5 mid, 1/3 top
fan = [[0,-2.5],[-1.77,1.77],[1.77,1.77],[-2.27,-1.03],[2.27,-1.03]];
sig = [[7.5,0],[0,0],[-7.5,0],[5,2.5],[-5,2.5]];   // signal pads (footprint coords)
gnd = [[2.5,-2.5],[-2.5,-2.5]];                     // shield/earth pads
mnt = [[7.5,-5],[-7.5,-5]];                          // Ø2.4 mounting posts

module ycyl(x, y0, z, len, r) translate([x, y0, z]) rotate([-90, 0, 0]) cylinder(h = len, r = r);

if (part == 0) color([0.10, 0.10, 0.11]) {
    difference() {
        union() {
            translate([-fw/2, fyf - ft, 0]) cube([fw, ft, fh]);         // flange (X wide, Z up)
            translate([-bw/2, fyf - ft - bd, 0]) cube([bw, bd, bh]);    // body (extends -Y)
            ycyl(0, fyf, sc, boss_out, boss_r);                         // Ø19 boss (+Y)
        }
        ycyl(0, cavfloor, sc, cav_depth + 0.5, cav_r);                  // plug cavity (Ø14)
        for (f = fan) ycyl(f[0], cavfloor - 2.5, sc + f[1], 3.5, hole_r);// female bores
        translate([-1.6, cavfloor, sc + cav_r - 0.6]) cube([3.2, cav_depth + boss_out + 1, 2]); // keyway
    }
    for (m = mnt) translate([m[0], m[1], -2.5]) cylinder(h = 2.5, r = 1.1);  // plastic posts
}

if (part == 1) color([0.20, 0.20, 0.22]) {
    difference() {
        ycyl(0, cavfloor, sc, cav_depth - 0.4, cav_r - 0.25);           // grey cavity insert (contrast)
        ycyl(0, cavfloor + 1.2, sc, cav_depth, cav_r - 1.4);            // hollow the front
        for (f = fan) ycyl(f[0], cavfloor - 0.5, sc + f[1], cav_depth, hole_r);  // 5 female bores
    }
}

if (part == 2) color([0.68, 0.68, 0.72]) {
    // bright metal ground ring at the socket mouth - makes it read clearly as a socket
    difference() {
        ycyl(0, bossfront - 1.4, sc, 1.4, cav_r);
        ycyl(0, bossfront - 1.6, sc, 2.0, cav_r - 1.1);
        translate([-1.7, bossfront - 2, sc + cav_r - 0.9]) cube([3.4, 3, 2]);  // keyway gap
    }
    for (f = fan) ycyl(f[0], cavfloor + 0.6, sc + f[1], 2.2, hole_r - 0.3); // contacts near front
    for (p = concat(sig, gnd)) translate([p[0], p[1], -3.2]) cylinder(h = 3.4, r = 0.5);  // solder tails
}
