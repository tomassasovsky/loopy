// 3D body for the CUI SDS-50J right-angle 5-pin DIN MIDI socket (FEMALE).
// Multi-part: render once per part for a multi-material .wrl (STL drops colour).
//   openscad -D part=0|1|2 -o <p>.stl this.scad   (0 body, 1 cavity, 2 metal)
//
// Frame (verified against the live 3D viewer, NOT the earlier axis probe which
// used a stale mesh): KiCad consumes this .wrl so scad +Y points INTO the board.
// So the socket must open toward scad -Y (which renders out the board edge) and
// the body extends +Y (inboard); board-up = scad +Z; footprint pad (px,py) ->
// scad (px,-py).  Plug face is a recessed Ø15 cavity with five FEMALE contact
// bores in the DIN-5 fan (pin 2 bottom, keyway top) - no protruding male pins.
part = 0;
$fn = 64;

fw = 20.0;  fh = 21.1;  ft = 1.8;     // square front flange (width X, depth Y, height Z)
bw = 15.8;  bh = 16.5;  bd = 18.0;    // body box
sc = 10.5;                            // socket centre height (Z)
front = -4.0;  boss_out = 2.5; boss_r = 9.5;  // flange front Y (-Y), Ø19 boss protrusion
cav_r = 7.5; cav_depth = 5.5;         // plug cavity (Ø15)
hole_r = 0.85;                        // female contact bore radius

bossouter = front - boss_out;         // -6.5  (boss outer face, the socket mouth)
cavfloor  = bossouter + cav_depth;    // -1.0  (cavity floor, inboard of the mouth)

// female contact fan on the face (X, Z-about-sc): 2 bottom, 4/5 mid, 1/3 top
fan = [[0,-2.5],[1.77,1.77],[-1.77,1.77],[2.27,-1.03],[-2.27,-1.03]];
sig = [[7.5,0],[0,0],[-7.5,0],[5,2.5],[-5,2.5]];   // signal pads (footprint coords)
gnd = [[2.5,-2.5],[-2.5,-2.5]];                     // shield/earth pads
mnt = [[7.5,-5],[-7.5,-5]];                          // Ø2.4 mounting posts

module ycyl(x, y0, z, len, r) translate([x, y0, z]) rotate([-90, 0, 0]) cylinder(h = len, r = r); // +Y
module ydp(x, y0, z, len, r) translate([x, y0, z]) rotate([ 90, 0, 0]) cylinder(h = len, r = r);  // -Y

if (part == 0) color([0.10, 0.10, 0.11]) {
    difference() {
        union() {
            translate([-fw/2, front, 0]) cube([fw, ft, fh]);            // flange (X wide, Z up)
            translate([-bw/2, front + ft, 0]) cube([bw, bd, bh]);       // body (extends +Y, inboard)
            ydp(0, front, sc, boss_out, boss_r);                        // Ø19 boss (toward -Y, the edge)
        }
        ycyl(0, bossouter - 0.5, sc, cav_depth + 1.0, cav_r);           // plug cavity (Ø15)
        for (f = fan) ycyl(f[0], cavfloor - 0.5, sc + f[1], 3.5, hole_r);// female bores
        translate([-1.6, bossouter - 0.5, sc + cav_r - 0.6]) cube([3.2, boss_out + cav_depth + 1, 2]); // keyway
    }
    for (m = mnt) translate([m[0], -m[1], -2.5]) cylinder(h = 2.5, r = 1.1);  // plastic posts
}

if (part == 1) color([0.20, 0.20, 0.22]) {
    difference() {
        ycyl(0, cavfloor - 2.0, sc, 1.8, cav_r - 0.3);                  // grey cavity floor (contrast)
        for (f = fan) ycyl(f[0], cavfloor - 3.0, sc + f[1], 5.0, hole_r);// dark female bores
    }
}

if (part == 2) color([0.68, 0.68, 0.72]) {
    difference() {                                                     // bright metal ground ring at mouth
        ydp(0, bossouter + 1.4, sc, 1.4, cav_r);
        ydp(0, bossouter + 1.6, sc, 2.0, cav_r - 1.1);
        translate([-1.7, bossouter - 0.5, sc + cav_r - 0.9]) cube([3.4, 3, 2]);  // keyway gap
    }
    for (f = fan) ycyl(f[0], cavfloor - 2.4, sc + f[1], 1.6, hole_r - 0.3); // contacts in the bores
    for (p = concat(sig, gnd)) translate([p[0], -p[1], -3.2]) cylinder(h = 3.4, r = 0.5);  // solder tails
}
