// 3D body for the CUI SDS-50J right-angle 5-pin DIN MIDI socket.
// Datasheet (SDS-XXJ, SDS-50J): square flange 20 x 21.1 mm x 1.8 thick, Ø19 round
// boss, Ø7 contact circle, body ~15.8 wide x 18 deep, black PBT plastic.
// Footprint frame: socket opening faces +X, body extends -X, +Y = up (board Z),
// +Z = footprint Y. Footprint scale 0.3937 cancels KiCad's WRL unit factor.
$fn = 72;

fx  = 4.0;     // flange front face X
ft  = 1.8;     // flange thickness
fw  = 20.0;    // flange width  (along Z)
fh  = 21.1;    // flange height (along Y, up)
bd  = 18.0;    // body depth (extends -X)
bz  = 15.8;    // body width (Z)
bh  = 16.5;    // body height (Y)
scz = 10.5;    // socket centre height above the board

// black plastic shell
color([0.10, 0.10, 0.11]) {
    translate([fx - ft, 0, -fw/2]) cube([ft, fh, fw]);          // square front flange
    translate([fx - ft - bd, 0, -bz/2]) cube([bd, bh, bz]);     // body box behind flange
    translate([fx, scz, 0]) rotate([0,90,0]) cylinder(h = 2.0, r = 9.5);   // Ø19 round boss
}
// recessed metal socket ring (Ø7 contact bore)
color([0.45, 0.45, 0.48])
    translate([fx + 1.5, scz, 0]) rotate([0,90,0]) cylinder(h = 0.6, r = 4.5);
color([0.02, 0.02, 0.02])
    translate([fx - 1.0, scz, 0]) rotate([0,90,0]) cylinder(h = 3.0, r = 3.6);
// five contact pins poking down through the PCB at the pad sites
for (p = [[0,7.5],[0,0],[0,-7.5],[2.5,5],[2.5,-5]])
    color([0.72,0.72,0.74]) translate([p[0], -3, p[1]]) cylinder(h = 3, r = 0.5);
