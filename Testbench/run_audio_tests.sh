#!/usr/bin/env bash
# Runs the SD card -> WAV -> WM8731 audio tests with Icarus Verilog.
#
#   cd Testbench && ./run_audio_tests.sh
#
# Needs python3 and iverilog (Ubuntu/WSL: sudo apt install iverilog).
# Set IVERILOG / VVP to use copies that are not on the PATH.
set -euo pipefail
cd "$(dirname "$0")"

IVERILOG=${IVERILOG:-iverilog}
VVP=${VVP:-vvp}
OUT=build_audio
SRC="tb_audio.sv sd_fake.v ../DE2/audio_top.sv ../DE2/wav_parser.sv ../DE2/audio_fifo.sv
     ../DE2/wm8731_config.sv ../DE2/i2s_out.sv
     ../DE2/sd_card/sd_file_reader.v ../DE2/sd_card/sd_reader.v ../DE2/sd_card/sdcmd_ctrl.v"

run() {   # name, make_sd_image args..., -- , vvp plusargs...
    local name=$1; shift
    local img=() plus=()
    while [[ $# -gt 0 && $1 != -- ]]; do img+=("$1"); shift; done
    [[ $# -gt 0 ]] && shift
    plus=("$@")
    echo "=== $name"
    python3 make_sd_image.py --out "$OUT/$name" "${img[@]}"
    $IVERILOG -g2012 -I "$OUT/$name" -o "$OUT/$name/sim.vvp" $SRC
    $VVP -n "$OUT/$name/sim.vvp" +DIR="$OUT/$name" "${plus[@]}" | tee "$OUT/$name/log.txt"
    grep -q '^PASS' "$OUT/$name/log.txt"
}

mkdir -p "$OUT"
fails=0
run stereo_48k   --rate 48000 --channels 2             || fails=$((fails+1))
run mono_44k     --rate 44100 --channels 1             || fails=$((fails+1))
run missing_file --name other.wav -- +EXPECT_FAIL      || fails=$((fails+1))

echo
if [[ $fails -eq 0 ]]; then echo "ALL AUDIO TESTS PASSED"; else echo "$fails AUDIO TEST(S) FAILED"; exit 1; fi
