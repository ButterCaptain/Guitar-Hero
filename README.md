# Guitar-Hero
Junior Design Competition




## Running the simulation (Verilator + SDL2)

This simulates the Guitar Hero design on your computer with no FPGA needed. Verilator converts the SystemVerilog into C++, and a small C++ testbench acts as the "monitor" (`vga_sim.h`), showing the VGA output in a live window and turning keyboard keys into the guitar's input pins.

### Prerequisites

- **Verilator** (check with `verilator --version`)
- **SDL2 development files** (check with `sdl2-config --version`)
  - Ubuntu/Debian/WSL: `sudo apt install libsdl2-dev`
  - macOS: `brew install sdl2`
- A C++ compiler and `make` (`g++` or `clang++`)

WSL users: you need WSLg (Windows 11) or an X server for the window to appear.

### Files used by the simulation

| File            | Purpose 
| `vga_sync.sv`   | VGA timing generator (sync signals, x/y position, frame tick) 
| `note_box.sv`   | One falling note, with hit detection and acceleration 
| `guitar_top.sv` | Game top level: 5 lanes, strum logic, score register 
| `vga_sim.h`     | C++ VGA monitor model (SDL2 window, keyboard input) 
| `tb_main.cpp`   | Testbench: generates the clock and connects keys to pins 

`de0_top.sv` and the Quartus files are for the real board only. **Do not** pass them to Verilator.

### Build and run

From the repo root:

```bash
rm -rf obj_dir
verilator -Wno-WIDTH --cc --exe --build --top-module guitar_top \
  -CFLAGS "$(sdl2-config --cflags)" -LDFLAGS "$(sdl2-config --libs)" \
  vga_sync.sv note_box.sv guitar_top.sv tb_main.cpp
./obj_dir/Vguitar_top
```

NOTE: The first build takes a while. Later builds only recompile what changed.

### What each part of the command means

| Part | What it does | How to fill it in \
| `verilator`               | Runs the tool | Always the same \
| `-Wno-WIDTH`              | Silences bit-width mismatch warnings (Verilator treats them as errors by default) | Keep it as is \
| `--cc`                    | Generate C++ output (as opposed to SystemC) | Always the same \
| `--exe`                   | Also build an executable, using the C++ file(s) you list | Always the same \
| `--build`                 | Run `make` automatically after translating | Always the same \
| `--top-module guitar_top` | Names the module that is the root of the design | Use the module name from your `.sv` file (not the file name). It must match exactly. \
| `-CFLAGS "$(sdl2-config --cflags)"`| Tells the C++ compiler where SDL2's headers are | Keep it as is. `sdl2-config` fills in the paths for your system. \
| `-LDFLAGS "$(sdl2-config --libs)"` | Tells the linker which SDL2 libraries to link | Keep it as is \
| `vga_sync.sv note_box.sv guitar_top.sv` | Your SystemVerilog sources | List every `.sv` file the design needs. Order doesn't matter. \
| `tb_main.cpp`             | Your C++ testbench | Exactly one file with `main()` \

### Where the output name comes from

Verilator names things after the top module:

- The generated header is `V<top>.h`, so `Vguitar_top.h`. The testbench includes it.
- The executable is `obj_dir/V<top>`, so `obj_dir/Vguitar_top`.

If you change `--top-module`, you must also change the `#include` and the class name in `tb_main.cpp`, and the name you run.

### Controls

| Key | FPGA pin |
|---|---|
| `A` `S` `D` `F` `G` | Fret buttons 0 to 4 (green, red, yellow, blue, orange) |
| `Up` arrow | Strum up |
| `Down` arrow | Strum down |
| `Esc` or close window | Quit |

Hold a fret key and tap an arrow key while a note is over the colored bar to hit it. The score is printed in the terminal each time it changes. Click the window first so it has keyboard focus.

### Troubleshooting

| Symptom | Likely cause |
|---|---|
| `SDL.h: No such file or directory` | `-CFLAGS` is missing, or SDL2 dev files aren't installed |
| Linker errors mentioning `SDL_...` | `-LDFLAGS` is missing |
| `no member named 'xyz' in 'Vguitar_top'` | The testbench uses a port name that doesn't match the SystemVerilog. Names must match exactly. |
| `Vguitar_top.h not found` | `--top-module` doesn't match the module name |
| Ran the program but no window appeared | You ran an old binary. Run `rm -rf obj_dir` and rebuild. |
| Window opens but is black | Check the sync polarity and porch values in `VgaTiming` against `vga_sync.sv` |
| Keys do nothing | Click the SDL window to give it focus |

### Changing the design

- **Add or rename a `.sv` file:** add it to the file list in the build command.
- **Change the number of lanes:** edit `NUM_LANES` and `LANE_W` in `guitar_top.sv`.
- **Change the resolution:** pass a different preset to `VgaSim`, such as `VgaTiming::svga800x600()`, and update `vga_sync.sv` to match.
- **Bigger window:** `VgaSim vga(VgaTiming::vga640x480(), "title", 2);` gives a 2x window.

The simulation runs slower than real time, so speeds and "seconds" are measured in simulated frames (60 frames is one simulated second).
