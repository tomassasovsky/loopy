// 3D body for the CUI SDS-50J right-angle 5-pin DIN MIDI socket.
// Multi-part so each colour can be exported separately and combined into a
// multi-material .wrl (STL export drops colour, so one mesh = one colour).
// Render once per part:  openscad -D part=0|1|2 -o <p>.stl this.scad  (0 body, 1 cavity, 2 metal)
//
// Frame (derived by rendering J8/J9 placed at 270 deg on the bottom edge):
//   scad +Z = board up, socket faces scad -Y (out the board edge), body extends
//   scad +Y (into the board), pins drop scad -Z.  Footprint pad (px,py) -> scad
//   (py,-px).  scale 0.3937 in the footprint cancels KiCad's WRL unit factor.
part = 0;   // 0 body, 1 cavity, 2 metal
$fn = 64;

fw = 20.0;  fh = 21.1;  ft = 1.8;     // square front flange
bw = 15.8;  bh = 16.5;  bd = 18.0;    // body box
sc = 10.5;  fy = -4.0;                // socket centre height, flange front Y
boss_r = 9.5;  boss_out = 2.0;        // Ø19 round boss, protrusion past flange
cav_r = 7.0;   cav_depth = 7.0;       // plug-in cavity (Ø14)
contact_r = 0.6;                      // female contact tube radius

// DIN-5 180deg contact layout on the face (x,z offset from socket centre):
// pin 2 bottom, 4/5 mid, 1/3 upper  ->  the classic MIDI fan
din = [[0,-2.5],[-2.17,-1.25],[2.17,-1.25],[-2.17,1.25],[2.17,1.25]];
sig = [[0,7.5],[0,0],[0,-7.5],[2.5,5],[2.5,-5]];   // 5 signal solder pins (footprint coords)
gnd = [[-10,2.5],[-10,-2.5]];                       // 2 shield/earth solder tabs
mnt = [[-5,7.5],[-5,-7.5]];                          // 2 plastic locating posts

module ycyl(x, y0, z, len, r) translate([x, y0, z]) rotate([-90, 0, 0]) cylinder(h = len, r = r);

if (part == 0) color([0.10, 0.10, 0.11]) {
    difference() {
        union() {
            translate([-fw/2, fy, 0]) cube([fw, ft, fh]);            // flange
            translate([-bw/2, fy + ft, 0]) cube([bw, bd, bh]);       // body
            ycyl(0, fy - boss_out, sc, boss_out + ft, boss_r);       // Ø19 boss
        }
        ycyl(0, fy - boss_out - 0.1, sc, cav_depth, cav_r);          // plug cavity
        translate([-1.6, fy - boss_out - 0.1, sc + cav_r - 0.6]) cube([3.2, 2.4, 2]);  // top keyway notch
    }
    for (m = mnt) translate([m[1], -m[0], -2.5]) cylinder(h = 2.5, r = 1.1);   // plastic posts
}

if (part == 1) color([0.04, 0.04, 0.05]) {
    ycyl(0, fy - boss_out + cav_depth - 0.8, sc, 0.8, cav_r - 0.15);           // cavity floor
    difference() {                                                            // cavity inner wall
        ycyl(0, fy - boss_out + 0.5, sc, cav_depth - 1.0, cav_r - 0.15);
        ycyl(0, fy - boss_out + 0.4, sc, cav_depth, cav_r - 0.9);
    }
}

if (part == 2) color([0.62, 0.62, 0.66]) {
    for (d = din) ycyl(d[0], fy - boss_out + 2.5, sc + d[1], 3.0, contact_r);  // 5 face contacts
    for (p = concat(sig, gnd)) translate([p[1], -p[0], -3.2]) cylinder(h = 3.4, r = 0.5);  // 7 solder pins
}
