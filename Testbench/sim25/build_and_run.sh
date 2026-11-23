#!/usr/bin/env bash
# Builds and runs the faster 25 MHz Verilator simulation.
#
# Run from an MSYS2 CLANGARM64 shell (that is where Verilator + SDL2 live):
#     cd /c/Users/moses/Documents/guitar_hero/Guitar-Hero/Testbench/sim25
#     ./build_and_run.sh
#
# Uses the real design files from DE2/ except vga_sync.sv, which is swapped for
# vga_sync_25.sv here. Runs from DE2/ so notes.hex and effects.hex are found.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../../DE2"

verilator -Wno-WIDTH --cc --exe --build -j 8 \
    -O3 --x-assign fast --x-initial fast \
    --Mdir "$HERE/obj_dir" --top-module guitar_top \
    -CFLAGS "$(sdl2-config --cflags) -DVL_TIME_CONTEXT -O3 -mcpu=native" \
    -LDFLAGS "$(sdl2-config --libs)" \
    highway_pkg.sv "$HERE/vga_sync_25.sv" highway_draw.sv note_rom.sv \
    note_feeder.sv hit_detect.sv guitar_top.sv "$HERE/tb_main_25.cpp"

"$HERE/obj_dir/Vguitar_top.exe"
