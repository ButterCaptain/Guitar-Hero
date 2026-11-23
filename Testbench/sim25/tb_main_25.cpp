// SIM25 copy of Testbench/tb_main.cpp -- Verilator only.
//
// Built together with sim25/vga_sync_25.sv instead of DE2/vga_sync.sv. That
// copy advances one pixel on EVERY clock, so this testbench steps the monitor
// after ONE tick instead of two. About half the work per frame.
//
// One other difference from tb_main.cpp: the score is printed as a signed
// number (tb_main.cpp shows -20 as 65516).
#include "Vguitar_top.h"
#include "verilated.h"
#include "../vga_sim.h"
#include <cstdint>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vguitar_top* top = new Vguitar_top;

    VgaSim vga(VgaTiming::vga640x480(), "Guitar Hero (25 MHz sim)");

    auto tick = [&]() {
        top->clk50 = 0; top->eval();
        top->clk50 = 1; top->eval();
    };

    top->fret = 0; top->strum_up = 0; top->strum_down = 0;
    top->rst = 1;
    for (int i = 0; i < 4; i++) tick();
    top->rst = 0;

    int last_score = 0;
    while (vga.running()) {
        int k = vga.keys();
        top->fret       = k & 0x1F;
        top->strum_up   = (k >> 5) & 1;
        top->strum_down = (k >> 6) & 1;
        tick();                                   // was tick(); tick();
        vga.step(top->hsync, top->vsync, top->r, top->g, top->b);

        int score = (int16_t)top->score;
        if (score != last_score) {
            last_score = score;
            printf("score = %d\n", last_score);
        }
    }

    top->final();
    delete top;
    return 0;
}
