#pragma once
#include <cstdint>
#include <cstdio> 
#include <vector> 
#include <SDL.h> 

struct VgaTiming {
    int h_vis, h_fp, h_sync, h_bp; // pixels in line
    int v_vis, v_fp, v_sync, v_bp; // lines
    bool sync_active_low; 
    int bits_per_channel; 

    // 640x480 @ 60 Hz , 25 Mhz pixel clock for the DEO 4 bit color
    static VgaTiming vga640x480(){
        return {640, 16, 96, 48, 480, 10, 2, 33, true, 4}; 
    }

    // 800x600 @ 60 Hz, 40 MHz pixel clock, active high
    static VgaTiming svga800x600(){
        return {800, 40, 128, 88, 600, 1, 4, 23, false, 4}; 
    }
}; 

class VgaSim{
    public: 
        VgaSim(const VgaTiming& t, const char* title = "VGA Sim", int scale = 1): 
        t_(t), fb_(t.h_vis * t.v_vis, 0xFF000000){
            if(SDL_Init(SDL_INIT_VIDEO) != 0){
                printf("SDL_Init failed: %s\n", SDL_GetError()); 
                running_ = false; 
                return; 
            }
            
            // Create window
            win_ = SDL_CreateWindow(title, SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                t.h_vis * scale, t.v_vis * scale, 0);
            // Create hardware-accelerated 2D renderer
            ren_ = SDL_CreateRenderer(win_, -1, SDL_RENDERER_ACCELERATED);
            // Empty Texture (The Screen)
            tex_ = SDL_CreateTexture(ren_, SDL_PIXELFORMAT_ARGB8888,
                                    SDL_TEXTUREACCESS_STREAMING, t.h_vis, t.v_vis);
            // Max color value
            max_val_ = (1 << t.bits_per_channel) - 1;
            // Get current time
            t0_ = SDL_GetTicks();
        }
        
        // Destructor
        ~VgaSim(){
            printf("Rendered %d frames in %u ms\n", frames_, SDL_GetTicks() - t0_); 
            if (tex_) SDL_DestroyTexture(tex_);
            if (ren_) SDL_DestroyRenderer(ren_);
            if (win_) SDL_DestroyWindow(win_);
            SDL_Quit();
        }

        bool running() const { return running_; }
        int  frames()  const { return frames_; }
        int keys() const { return keys_; }

        void step(int hsync, int vsync, int r, int g, int b) {
        // Normalize so 1 = sync pulse active
        bool h = t_.sync_active_low ? !hsync : hsync;
        bool v = t_.sync_active_low ? !vsync : vsync;

        bool h_end = prev_h_ && !h;     // end of hsync pulse
        bool v_end = prev_v_ && !v;     // end of vsync pulse

        if (h_end) { x_ctr_ = 0; line_ctr_++; }
        else       { x_ctr_++; }
        if (v_end) { line_ctr_ = 0; }

        prev_h_ = h; prev_v_ = v;

        int x = x_ctr_ - t_.h_bp;
        int y = line_ctr_ - t_.v_bp;

        if (synced_ && x >= 0 && x < t_.h_vis && y >= 0 && y < t_.v_vis) {
            uint32_t r8 = r * 255 / max_val_;
            uint32_t g8 = g * 255 / max_val_;
            uint32_t b8 = b * 255 / max_val_;
            fb_[y * t_.h_vis + x] = 0xFF000000 | (r8 << 16) | (g8 << 8) | b8;
        }

        if (v_end) {
            if (synced_) present();
            synced_ = true;
            pollEvents();
        }
    }

    private:

    void present() {
        SDL_UpdateTexture(tex_, nullptr, fb_.data(), t_.h_vis * sizeof(uint32_t));
        SDL_RenderClear(ren_);
        SDL_RenderCopy(ren_, tex_, nullptr, nullptr);
        SDL_RenderPresent(ren_);
        frames_++;
    }

    void pollEvents() {
        SDL_Event e;
        while (SDL_PollEvent(&e)) {
            if (e.type == SDL_QUIT) running_ = false;
            if (e.type == SDL_KEYDOWN && e.key.keysym.sym == SDLK_ESCAPE)
                running_ = false;
        }
        const Uint8* ks = SDL_GetKeyboardState(nullptr);
        keys_ = (ks[SDL_SCANCODE_A]    ? 0x01 : 0) |   // fret 0 (green)
                (ks[SDL_SCANCODE_S]    ? 0x02 : 0) |   // fret 1 (red)
                (ks[SDL_SCANCODE_D]    ? 0x04 : 0) |   // fret 2 (yellow)
                (ks[SDL_SCANCODE_F]    ? 0x08 : 0) |   // fret 3 (blue)
                (ks[SDL_SCANCODE_G]    ? 0x10 : 0) |   // fret 4 (orange)
                (ks[SDL_SCANCODE_UP]   ? 0x20 : 0) |   // strum up
                (ks[SDL_SCANCODE_DOWN] ? 0x40 : 0);    // strum down


    }

    VgaTiming t_;
    std::vector<uint32_t> fb_;
    SDL_Window*   win_ = nullptr;
    SDL_Renderer* ren_ = nullptr;
    SDL_Texture*  tex_ = nullptr;

    int  x_ctr_ = 0, line_ctr_ = 0, frames_ = 0, max_val_ = 15;
    int keys_ = 0;
    bool prev_h_ = false, prev_v_ = false;
    bool synced_ = false, running_ = true;
    Uint32 t0_ = 0;
};