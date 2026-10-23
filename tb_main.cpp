#include "Vguitar_top.h"
#include "verilated.h"
#include "vga_sim.h"

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Vguitar_top* top = new Vguitar_top;

    VgaSim vga(VgaTiming::vga640x480(), "DE0 Guitar Hero");

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
        tick(); tick();
        vga.step(top->hsync, top->vsync, top->r, top->g, top->b);

        if (top->score != last_score) {
            last_score = top->score;
            printf("score = %d\n", last_score);
        }
    }

    top->final();
    delete top;
    return 0;
}