# Shadow Force + CRT Adjust

This fork adds [rmonic79/MiSTer-CRT-Adjust](https://github.com/rmonic79/MiSTer-CRT-Adjust)
(core-side variant, `crt_adjust.sv`) to the Shadow Force core. It lets you
resize and move the analog (15 kHz) picture from the OSD so it fits your CRT.

## OSD (Video page)

| Option | Range | Status bits |
|---|---|---|
| CRT Adjust | Off / On | 101 |
| CRT H-Size | -16 … +15 (each step ≈ 2.1 %) | 100:96 |
| CRT H-Position | -48 … +48 px, 2 px steps | 84:79 |
| CRT V-Shift | -16 … +15 lines | 78:74 |

The amounts only show when CRT Adjust is On. With it Off the video is the
untouched native signal. While it is On, HDMI follows the adjustment too
(core-side variant). The module turns itself off when the scandoubler is in use
(31 kHz VGA output). When CRT Adjust is enabled, JTFRAME's built-in "CRT H/V
offset" and "CRT scale" options are not shown, so the two methods can't fight
each other and the OSD string stays under 1024 bytes.

Note: enlarging the picture (H-Size > 0) also pushes it to the right. Use a
negative H-Position to bring it back to the center, otherwise the right edge gets
clipped at the end of the line (there are only 32 px of front porch).

## Files

| File | What |
|---|---|
| `cores/shadfrce/hdl/crt_adjust.sv` | rmonic79's module. One fix: a `$signed()` so that a negative H-Position is sign-extended in CONTENTSHIFT mode (without it any negative value blanks the picture). |
| `cores/shadfrce/hdl/jtframe_crt_adjust.sv` | JTFRAME glue (from `examples/core_side_snippet.v`): OSD decode, read clock-enable (48 MHz / 7 MHz: period = (48+H-Size)/7 clocks), `vb_in` for the next line, OSD-anchored DE |
| `cores/shadfrce/cfg/macros.def` | `JTFRAME_CRT_ADJUST` plus timing parameters (448×272 total, CONTENTSHIFT) |
| `cores/shadfrce/cfg/files.yaml` | adds the two `.sv` files |
| `jtframe-patches/crt_adjust.patch` | patch for jtcores' `modules/jtframe` (`jtframe_mister.sv` and the MiSTer `cfgstr`). The module sits between `arcade_video` and `video_freak`. Nothing in `sys/` is touched. Everything is inside `ifdef JTFRAME_CRT_ADJUST`. |
| `.github/workflows/build-shadfrce.yml` | builds the `.rbf` on GitHub Actions (jotego/jtcore20 Quartus image) |

## Building

Automatic: every push that touches the core, or *Actions → Build Shadow Force
(CRT Adjust) → Run workflow*. The `.rbf` is uploaded as an artifact and
committed to `releases/ffshadfrce_YYYYMMDD.rbf`.

By hand, following [BUILD.md](BUILD.md) with jtcores at commit `a3c43159`:

```
cp -r cores/shadfrce <jtcores>/cores/shadfrce
git -C <jtcores> apply $PWD/jtframe-patches/crt_adjust.patch
cd <jtcores> && source setprj.sh
jtcore shadfrce --target mister --nodbg
```

## Simulation check

An Icarus Verilog testbench using Shadow Force's timing (448×272, 7 MHz pixel
from a 48 MHz clock) checked that, with CRT Adjust On:
- all 240 active lines (8…247) come out with 320 pixels each, and every pixel matches the source;
- H-Size +4 makes the active line 8.3 % wider (4/48);
- H-Position +20 moves it right by exactly 20 pixel periods;
- V-Shift +5 delays VSync by 5 lines;
- DE for the OSD is present on exactly 240 lines.

It has not been tested on a real CRT yet.
