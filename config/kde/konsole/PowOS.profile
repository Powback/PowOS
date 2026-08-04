[Appearance]
ColorScheme=Breeze

[General]
Name=PowOS Default
Parent=FALLBACK/
# Note: no Directory / StartInCurrentSessionDir here on purpose. Konsole's
# default (StartInCurrentSessionDir=true) clones the current tab's directory
# into new tabs, which is the wanted behavior. The physical /var/home/<user>
# path that results is collapsed to /home/<user> (and ~) by
# /etc/profile.d/49-powos-home-path.sh.
