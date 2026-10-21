# bf-start.sh: (in the PowOS session as powos) keep Steam awake for the test and start Steam + Broforce (274190)
mkdir -p /tmp/bflog
powos sleep never steam 2>&1 | tail -2
cd /home/powos; setsid -f steam steam://rungameid/274190 >/tmp/bflog/steam-start.out 2>&1 < /dev/null
echo started
