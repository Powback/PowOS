# popup-proof.sh (sourced by ww-popups.sh and ww-popup-x11.sh): one matcher for "a popup's buffers reached the screen",
# so the two checks can't drift (11-10: ww-popup-x11 kept the pre-3.72 line after the layers came; then ww-popups).
#   popup_proof <N> <layers 0|1> <PowosPopups lines> <KWin "window task N live" lines>
# layers=1 (kwin 3.72+, N3b, WebWindowPopups): the app's layer consumer is up ("popup N layer up") and KWin imported
#   its buffers ("window task N live"). The app never sees a frame on this path - the buffers go straight to the
#   layer - so no "popup N buffer" line can exist.
# layers=0 (kwin < 3.72, N3a, PopupLog): "popup N buffer #..." (the offscreen reader counted one).
# The caller fetches KWin's lines (its own root wrapper, from its own log start) and defines say/bad.
popup_proof() {
  local n=$1 layers=$2 lines=$3 klive=$4 l
  if [ "$layers" = 1 ]; then
    l=$(grep -E "^popup $n layer up" <<<"$lines" | tail -1)
    [ -n "$l" ] && say "layer: $l" || bad "layer: no \"popup $n layer up\" (no layer consumer for it)"
    l=$(grep -a "window task $n live" <<<"$klive" | tail -1)
    [ -n "$l" ] && say "buffer: $l" || bad "buffer: KWin's popup surface $n never went live (no buffers from the app's layer)"
  else
    l=$(grep -E "^popup $n buffer #" <<<"$lines" | head -1)
    [ -n "$l" ] && say "buffer: $l" || bad "buffer: no buffer of popup $n reached the app's consumer"
  fi
}
