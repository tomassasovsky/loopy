// 3D body for the CUI SDS-50J right-angle 5-pin DIN MIDI socket.
// Datasheet: square flange 20 x 21.1 x 1.8 mm, Ø19 round boss, Ø7 contacts,
// body ~15.8 wide x 18 deep, black PBT.
//
// Frame derived empirically from rendering this very footprint (J8/J9, placed at
// 270 deg on the bottom edge):  scad +Z = board up,  the socket must face scad -Y
// (so it points out the board edge) and the body must extend scad +Y (into the
// board), with the flange wide in scad X.  Contact pins drop down scad -Z at the
// pad sites, where footprint pad (px,py) maps to scad (py, -px).  scale 0.3937 in
// the footprint cancels KiCad's WRL unit factor.
$fn = 72;

fw = 20.0;    // flange width  (scad X, along the board edge)
fh = 21.1;    // flange height (scad Z, up)
ft = 1.8;     // flange depth  (scad Y)
bw = 15.8;    // body width  (scad X)
bh = 16.5;    // body height (scad Z, up)
bd = 18.0;    // body depth  (scad Y, into board)
sc = 10.5;    // socket centre height (scad Z)
fy = -4.0;    // flange front face (scad Y)

color([0.10, 0.10, 0.11]) {
    translate([-fw/2, fy, 0]) cube([fw, ft, fh]);                  // square front flange
    translate([-bw/2, fy + ft, 0]) cube([bw, bd, bh]);            // body box behind flange
    translate([0, fy, sc]) rotate([90, 0, 0]) cylinder(h = 2.0, r = 9.5);  // Ø19 boss (faces -Y)
}
// recessed metal socket ring + dark bore
color([0.45, 0.45, 0.48]) translate([0, fy - 0.4, sc]) rotate([90, 0, 0]) cylinder(h = 0.7, r = 4.5);
color([0.02, 0.02, 0.02]) translate([0, fy + 1.0, sc]) rotate([90, 0, 0]) cylinder(h = 3.0, r = 3.6);
// five contact pins dropping through the PCB (footprint pad (px,py) -> scad (py,-px))
for (p = [[0,7.5],[0,0],[0,-7.5],[2.5,5],[2.5,-5]])
    color([0.72,0.72,0.74]) translate([p[1], -p[0], -3]) cylinder(h = 3, r = 0.5);
