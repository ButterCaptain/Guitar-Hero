#!/usr/bin/env bash
# Runs the SD card -> WAV -> WM8731 audio tests.
#
#   cd Testbench && ./run_audio_tests.sh
#   ./run_audio_tests.sh ../DE2/mysong.wav 2     # also test 2 s of a real WAV
#
# Simulator: Verilator (default when found; on this machine run from an MSYS2
# CLANGARM64 shell) or Icarus Verilog (SIM=iverilog). Needs python3 or py.
set -euo pipefail
cd "$(dirname "$0")"

SONG=${1:-}
SONG_SECONDS=${2:-2}
OUT=build_audio
PY=$(command -v python3 || command -v py)
if [[ -z ${SIM:-} ]]; then
    if command -v verilator >/dev/null; then SIM=verilator; else SIM=iverilog; fi
fi

SRC="tb_audio.sv sd_fake.v ../DE2/audio_top.sv ../DE2/wav_parser.sv ../DE2/audio_fifo.sv
     ../DE2/wm8731_config.sv ../DE2/i2s_out.sv
     ../DE2/sd_card/sd_file_reader.v ../DE2/sd_card/sd_reader.v ../DE2/sd_card/sdcmd_ctrl.v"

run() {   # name, make_sd_image args..., -- , plusargs...
    local name=$1; shift
    local img=() plus=()
    while [[ $# -gt 0 && $1 != -- ]]; do img+=("$1"); shift; done
    [[ $# -gt 0 ]] && shift
    plus=("$@")
    local dir="$OUT/$name"
    echo "=== $name"
    mkdir -p "$dir"
    "$PY" make_sd_image.py --out "$dir" "${img[@]}"
    if [[ $SIM == verilator ]]; then
        mkdir -p "$dir/obj"
        verilator --binary --timing -j 8 -O3 -Wno-fatal -Wno-WIDTH -Wno-CASEINCOMPLETE \
            --top-module tb_audio -I"$dir" --Mdir "$dir/obj" $SRC > "$dir/build.log" 2>&1 \
            || { cat "$dir/build.log"; return 1; }
        "$dir/obj/Vtb_audio" +DIR="$dir" "${plus[@]}" | tee "$dir/log.txt"
    else
        iverilog -g2012 -I "$dir" -o "$dir/sim.vvp" $SRC
        vvp -n "$dir/sim.vvp" +DIR="$dir" "${plus[@]}" | tee "$dir/log.txt"
    fi
    grep -q '^PASS' "$dir/log.txt"
}

mkdir -p "$OUT"
fails=0
run stereo_48k   --rate 48000 --channels 2             || fails=$((fails+1))
run mono_44k     --rate 44100 --channels 1             || fails=$((fails+1))
run missing_file --name other.wav -- +EXPECT_FAIL      || fails=$((fails+1))
if [[ -n $SONG ]]; then
    run real_song --wav "$SONG" --seconds "$SONG_SECONDS" || fails=$((fails+1))
fi

echo
if [[ $fails -eq 0 ]]; then echo "ALL AUDIO TESTS PASSED ($SIM)"; else echo "$fails AUDIO TEST(S) FAILED ($SIM)"; exit 1; fi
