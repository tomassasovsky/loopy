"""Model a clean SparkFun Pro Micro (33x18mm) in cadquery and export VRML for the
loopy_pedal_main J1 footprint, replacing the broken Blender-x3d-derived mesh.
Origin = PCB centre, PCB in XY, Z up (KiCad model convention); the footprint's
rotate/offset positions it on the pads."""
import cadquery as cq

L, W, T = 33.0, 18.0, 1.6                 # Pro Micro PCB
asm = cq.Assembly()

pcb = cq.Workplane("XY").box(L, W, T, centered=(True, True, False))   # PCB, bottom face z=0
asm.add(pcb, name="pcb", color=cq.Color(0.11, 0.11, 0.13))

# micro-USB connector, silver, overhanging the -X short edge
usb = cq.Workplane("XY").box(5.9, 7.5, 2.6, centered=(True, True, False)).translate((-L/2 - 0.8, 0, T))
asm.add(usb, name="usb", color=cq.Color(0.78, 0.79, 0.82))

# ATmega32U4 QFN + crystal (dark) for recognisability
asm.add(cq.Workplane("XY").box(7, 7, 1.0, centered=(True, True, False)).translate((3.5, 0, T)),
        name="mcu", color=cq.Color(0.07, 0.07, 0.08))
asm.add(cq.Workplane("XY").box(3.2, 2.5, 1.0, centered=(True, True, False)).translate((-4, 4, T)),
        name="xtal", color=cq.Color(0.7, 0.7, 0.72))

# two 12-pin header rows along the long edges; pins fill the gap down to the board (no up-poke)
PINS, PITCH, Y = 12, 2.54, W/2 - 1.5
x0 = -(PINS - 1) * PITCH / 2.0
pins = cq.Workplane("XY")
for i in range(PINS):
    for y in (Y, -Y):
        pins = pins.union(cq.Workplane("XY").box(0.64, 0.64, 8.5, centered=(True, True, False))
                            .translate((x0 + i * PITCH, y, -8.5)))
asm.add(pins, name="pins", color=cq.Color(0.85, 0.72, 0.33))

asm.save("../kicad/loopy.pretty/sparkfun_pro_micro.wrl", "VRML")
print("wrote sparkfun_pro_micro.wrl (clean cadquery Pro Micro, %gx%g mm)" % (L, W))
