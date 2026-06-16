// 3D body for the 5-pin DIN MIDI socket (SDS-50J footprint).
// Authored in KiCad's VRML frame: model X = footprint X, model Y = UP (board Z),
// model Z = footprint -Y (so the socket opening, at footprint -Y, is +Z here).
// The footprint scale 0.3937 (=1/2.54) cancels KiCad's WRL 0.1-inch unit factor,
// so these numbers are effectively millimetres.
$fn = 56;
cx = 7.5;     // body centre over footprint X (between the pins)
r  = 7.6;     // shell radius (~15 mm round body)

color([0.74, 0.74, 0.78]) {
    // round metal shell: axis along model Z = footprint Y (lies flat, front-to-back)
    translate([cx, r, 4.5]) cylinder(h = 14, r = r, center = true);
    // rim around the socket opening (footprint -Y -> +Z)
    translate([cx, r, 11.0]) cylinder(h = 2.5, r = r + 0.8, center = true);
}
// black insert with the contact holes, recessed in the front face
color([0.1, 0.1, 0.1])
    translate([cx, r, 11.8]) cylinder(h = 1.2, r = r - 1.3, center = true);
