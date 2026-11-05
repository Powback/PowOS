# lanes: phone
# bf-onscreen.sh: (on the phone, adb shell; bf-pacing.sh / bf-quiet.sh push it) is a game's picture ON the screen, and
# where. One line: "onscreen <n> <how> <layer>" - n = the screen-sized game layers SurfaceFlinger composes on an active
# display now, how = task (its own task: KWin's window task, PowosWindowActivity's SurfaceView, the folded cover) or web
# (home's full-screen web window: powos-ww-<id>-linux under HomeShell - every Linux window on the unfolded inner
# screen, WebWindowSource.offer; docs/WEB_WINDOWS.md), or none.
# Why (11-05 19:49-22:36, every Broforce check unfolded ended "exit 3 ... in front=HomeShell, task surfaces=0"): the
# checks took "PowosWindowActivity in front" as the only way a game shows, but unfolded the game is home's full-screen
# web window - HomeShell IS in front then. A layer in the HWC list is one SurfaceFlinger composes this frame (hidden,
# detached or covered-and-culled ones are not there: the 21:38 game full screen on a dead surface had none), and
# "screen-sized" (>= 80 % of the display's largest frame) keeps a windowed Steam out.
dumpsys SurfaceFlinger 2>/dev/null | awk '
  /\(active\) HWC layers/ { p = 1; next }
  p && /^Display .*HWC layers/ { p = 0 }
  p && /^ [^ -]/ { n = $0; sub(/^ /, "", n); next }
  p && /\|/ && n != "" {
    split($0, c, "|"); split(c[6], f, " "); a = (f[3] - f[1]) * (f[4] - f[2]); if (a > big) big = a
    if (n ~ /SurfaceView\[com\.powos\.app\/andro\.marchy\.PowosWindowActivity\]/) { k[++m] = "task"; nm[m] = n; ar[m] = a }
    else if (n ~ /powos-ww-[0-9]+-linux/) { k[++m] = "web"; nm[m] = n; ar[m] = a }
    n = ""
  }
  END {
    cnt = 0; how = "none"; l = "-"
    for (i = 1; i <= m; i++) if (big > 0 && ar[i] * 10 >= big * 8) { cnt++; if (how == "none") { how = k[i]; l = nm[i] } }
    gsub(/ /, "_", l); print "onscreen", cnt, how, l
  }'
