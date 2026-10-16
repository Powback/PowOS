// PowOS phone: the desktop shows Android's wallpaper (org.powos.transparent). A Plasma update script: plasmashell
// runs it once per user (contents/updates/, remembered in plasmashellrc); picking another wallpaper later sticks.
var ds = desktops();
for (var i = 0; i < ds.length; i++) ds[i].wallpaperPlugin = "org.powos.transparent";
