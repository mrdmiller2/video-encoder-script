#!/usr/local/bin/bash

IFS=$'\n'

# Reset
Color_Off='\033[0m'       # Text Reset

# Regular Colors
Red='\033[0;31m'          # Red
Green='\033[0;32m'        # Green

# Bold
BRed='\033[1;31m'         # Red
BGreen='\033[1;32m'       # Green


readarray -t raw < <(find . -type f -name "*.avi" -o -name "*.mp4" -o -name "*.mkv")

for r in "${raw[@]}"
do
  cooked=${r##*/}
  crispy=${cooked%.*}
  breading=$(dirname "$r")
  type=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$r")
    if [ "$type" != "av1" ]; then
        echo -e "Starting Atack Run on       ${Green}"$r"${Color_Off}"
        echo -e "Crispy Variable is set to:  ${Green}"$crispy"${Color_Off}"
        echo -e "The Breading is found:      ${Green}"$breading"${Color_Off}"
        echo -e "Video is a ${BGreen}"$type"${Color_Off} video file and will be transcoded"

        HandBrakeCLI -Z "AV1 MKV 2160p60 4K" --all-subtitles --all-audio -e svt_av1_10bit --encoder-preset 5 -q 35 -f mkv -m -O -E opus --lapsharp=light --ab 100 --enable-hw-decoding videotoolbox --encopts="enable-qm=1:film-grain-denoise=1:film-grain=12:qm-min=0:scd=1:enable-tf=0:keyint=15s:aq-mode=2:enable-variance-boost=1:variance-boost-strength=3:variance-octile=4:enable-overlays=1" --subtitle-burned=none --subtitle-default=none -6 opus -i "$r" -o "$r-av1"
        
        echo "Resting for 5 seconds"
        sleep 5
        echo "Editing the Metadata"
        mkvpropedit $crispy-av1 -v -e info --set "title=$crispy"
        echo "The new file has been encoded with: $type\n"
        echo " \n"
    elif [ "$type" = "av1" ]; then       
        echo -e "Video is a ${BGreen} $type ${Color_Off} video file and needs only metadata updated\n"
        mkvpropedit $r -v -e info --set "title=$crispy"        
    fi
done
