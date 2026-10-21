# bf-stop.sh: (in the PowOS session as powos) close Broforce + Steam, drop the never-sleep entry
pkill -f Broforce_beta.exe; sleep 3; pkill -9 -f Broforce_beta.exe
steam -shutdown >/dev/null 2>&1
for i in $(seq 40); do pgrep -f 'steam -cef|steamwebhelper|ubuntu12_32/steam' >/dev/null || break; sleep 1; done
pkill -9 -f steamwebhelper; pkill -9 -f 'ubuntu12_32/steam'; pkill -f wineserver
powos sleep never --remove steam 2>&1 | tail -2
pgrep -af 'steam|Broforce|wineserver' | grep -v pgrep | head -5; echo stopped
