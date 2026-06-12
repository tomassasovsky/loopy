# Running Loopy on Linux

Loopy runs natively on Linux (GTK). The native engine + miniaudio compile and
bundle as `libloopy_engine.so`; miniaudio selects the **PulseAudio** backend by
default, so on a PipeWire system Loopy talks to `pipewire-pulse`.

Most "it doesn't work on Linux" reports are **host/interface configuration**, not
Loopy. This doc captures what was learned bringing it up on a Focusrite Clarett+
8Pre, so the next person doesn't spend an evening on it.

## Renderer: Impeller is disabled

Impeller (the default renderer on Linux/GTK as of Flutter 3.44) mis-rasterizes the
bundled Material icon font — icons render as empty "tofu" boxes. The GTK runner
([linux/runner/main.cc](../linux/runner/main.cc)) forces the Skia backend by
appending `enable-impeller=false` to the engine switches, so no `flutter run` flag
is needed. Remove that call once Linux Impeller matures.

## Audio device selection

- **Pick your interface explicitly** as the input device in Audio Settings. Loopy
  pins the capture stream (miniaudio sets `PA_STREAM_DONT_MOVE`) so the host's
  stream-restore can't reroute it. An explicit input selection always wins over
  loopback auto-routing — important on PipeWire, where every output sink exposes a
  "Monitor of …" source that would otherwise be auto-picked.
- Keep the engine at **48 kHz** for the widest channel count on bus-powered /
  USB interfaces (see below).

## Focusrite (Clarett+/Scarlett) on Linux — the `scarlett2` driver

There is no Focusrite Control on Linux; the `snd-usb-audio` **`scarlett2`** mixer
(`alsamixer -c <card>`, `amixer -c <card>`) controls routing/levels instead. The
defaults differ from a macOS Focusrite-Control setup, which is why an identical
interface can look broken:

- **Channel count is sample-rate-dependent (USB altset).** The Clarett+ 8Pre
  exposes 18 in / 20 out only at 44.1/48 kHz; 14/16 at 88.2/96 kHz; 10/10 at
  176.4/192 kHz. Run at **48 kHz** for all channels.
- **Use the PipeWire "Pro Audio" profile** to expose all channels as raw
  multichannel: `pactl set-card-profile <card-id> pro-audio`. The default
  "Multichannel" profile may negotiate a reduced-channel altset.
- **Output routing:** physical outputs default to the internal **Mix** (e.g.
  `Analogue Output 01 ← Mix A`), not USB playback — so app audio is silent until
  you route them to PCM:
  `amixer -c <card> cset numid=<n> "PCM 1"` (find the `Analogue Output NN Playback
  Enum` numids with `amixer -c <card> controls`).
- **Capture routing** defaults are usually correct (`PCM 01 ← Analogue 1`, …);
  verify with the `PCM NN Capture Enum` controls.
- **Monitor level, input gain, and 48V phantom power are hardware-controlled** and
  **not exposed** by `scarlett2` for this model — use the knobs/buttons on the unit.
  A weak input that the gain knob barely changes is the classic symptom of a
  condenser mic with **48V off** (press it on the device).

### Diagnosing signal level (no Loopy needed)

PipeWire sources are shared, so you can measure in parallel with Loopy. Per-channel
input peak:

```bash
timeout 4 pw-record --target <node.name> --channels <n> --rate 48000 --format s16 /tmp/in.wav
python3 -c "import wave,array,math;w=wave.open('/tmp/in.wav');d=array.array('h');d.frombytes(w.readframes(w.getnframes()));ch=w.getnchannels()
print([round(max((abs(d[i+c]) for i in range(0,len(d),ch)),default=0)/32768,4) for c in range(ch)])"
```

Record the sink's `.monitor` to see exactly what Loopy is sending out. If the input
shows signal but the output `.monitor` is flat, the problem is Loopy; if both move
together, Loopy is fine and it's a host level/routing issue.
