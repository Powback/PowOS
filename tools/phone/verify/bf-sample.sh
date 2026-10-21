# bf-sample.sh <secs> <out>: (on the phone, root) every 15 s: MemAvailable, DMA-BUF total, Xwayland dma-buf fds, Broforce pid
end=$(( $(date +%s) + $1 ))
while [ $(date +%s) -le $end ]; do
  ma=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
  db=$(dmabuf_dump -b 2>/dev/null | sed -nE 's/.*Total DMA-BUF size\(bytes\): ([0-9]+).*/\1/p'); db=$(( ${db:-0} / 1048576 ))
  X=$(pidof Xwayland); xf=$(ls -l /proc/$X/fd 2>/dev/null | grep -c dmabuf)
  g=$(pgrep -f Broforce_beta.exe | head -1)
  echo "$(date +%H:%M:%S) memavail=${ma}MB dmabuf=${db}MB xwl_dmabuf_fds=$xf game=${g:-none}" >> $2
  sleep 15
done
