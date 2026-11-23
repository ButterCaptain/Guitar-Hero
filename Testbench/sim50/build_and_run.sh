#!/usr/bin/env bash
# Builds and runs the normal (50 MHz, same as the board) Verilator simulation.
# For a ~2x faster version see ../sim25/.
#
# Run from an MSYS2 CLANGARM64 shell (that is where Verilator + SDL2 live):
#     cd /c/Users/moses/Documents/guitar_hero/Guitar-Hero/Testbench/sim50
#     ./build_and_run.sh
#
# The build goes into this folder (sim50/obj_dir), never into DE2/. The program
# is started from DE2/ only because note_rom loads notes.hex and effects.hex
# from the folder it is run in -- nothing is written there.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
cd "$HERE/../../DE2"

verilator -Wno-WIDTH --cc --exe --build -j 8 \
    -O3 --x-assign fast --x-initial fast \
    --Mdir "$HERE/obj_dir" --top-module guitar_top \
    -CFLAGS "$(sdl2-config --cflags) -DVL_TIME_CONTEXT -O3 -mcpu=native" \
    -LDFLAGS "$(sdl2-config --libs)" \
    highway_pkg.sv vga_sync.sv highway_draw.sv note_rom.sv \
    note_feeder.sv hit_detect.sv guitar_top.sv "$HERE/../tb_main.cpp"

"$HERE/obj_dir/Vguitar_top.exe"
