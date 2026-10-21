#!/bin/bash
# frames.sh <video.mp4> gaps                 frame times + every gap > 50 ms (screenrecord is variable-rate)
# frames.sh <video.mp4> sheet T0 T1 [out]    every frame between T0 and T1 s, numbered "<n> <pts>", 13 per row
# frames.sh <video.mp4> overview [out]       4 fps overview sheet of the whole clip
# ffmpeg runs in a container (linuxserver/ffmpeg); the video must be under $HOME. Read the sheets as images.
set -euo pipefail
v=$(cd "$(dirname "$1")" && pwd)/$(basename "$1"); d=$(dirname "$v"); f=$(basename "$v")
ff() { docker run --rm -v "$d":/w -w /w --entrypoint "$1" linuxserver/ffmpeg:latest "${@:2}"; }
lab="drawtext=text='%{n} %{pts\:flt}':x=2:y=2:fontsize=11:fontcolor=yellow:box=1:boxcolor=black"
case "${2:-gaps}" in
  gaps) ff ffprobe -v error -select_streams v -show_entries frame=pts_time -of csv=p=0 "$f" |
          awk '{t[NR]=$1} END{print NR" frames"; for(i=2;i<=NR;i++){g=t[i]-t[i-1]; if(g>0.05) printf "gap before frame %d at %.3fs: %.0f ms\n", i-1, t[i], g*1000}}' ;;
  sheet) o=${5:-${f%.mp4}-$3-$4.png}; ff ffmpeg -loglevel error -y -i "$f" -vf "select='between(t\,$3\,$4)',scale=140:-1,$lab,tile=13x4" -fps_mode passthrough -frames:v 1 "$o"; echo "$d/$o" ;;
  overview) o=${3:-${f%.mp4}-overview.png}; ff ffmpeg -loglevel error -y -i "$f" -vf "fps=4,scale=140:-1,drawtext=text='%{pts\:flt}':x=2:y=2:fontsize=12:fontcolor=yellow:box=1:boxcolor=black,tile=12x3" -frames:v 1 "$o"; echo "$d/$o" ;;
  *) sed -n '2,5p' "$0"; exit 2 ;;
esac
