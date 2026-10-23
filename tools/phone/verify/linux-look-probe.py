#!/usr/bin/env python3
"""linux-look-probe.py qt|gtk: what a Linux app started in this environment gets - one line of key=value.

Run on the phone inside PowOS by linux-look.sh, in the environment the PowOS drawer starts apps in (powos-run.sh's).
No window is shown: the toolkit connects to the display (QT_QPA_PLATFORM / GDK_BACKEND pick Wayland or X11) and
reports its theme, palette, font and scale.
  qt:  qpa style window(bg #rrggbb) text font pt ldpi dpr  (Wayland's screen dpr is wl_output's integer scale;
       windows get the fractional one)
  gtk: backend theme dark bg fg scale (monitor's integer scale) xftdpi font
"""
import sys


def hexc(r, g, b):
    return "#%02x%02x%02x" % (int(r), int(g), int(b))


def qt():
    from PySide6.QtGui import QPalette
    from PySide6.QtWidgets import QApplication

    app = QApplication(sys.argv[:1])
    p, f, s = app.palette(), app.font(), app.primaryScreen()
    w = p.color(QPalette.Window)
    print(f"qpa={app.platformName()} style={app.style().name()} bg={w.name()} text={p.color(QPalette.WindowText).name()} "
          f"font={f.family().replace(' ', '_')} pt={f.pointSizeF():g} ldpi={s.logicalDotsPerInch():g} dpr={s.devicePixelRatio():g}")


def gtk():
    import gi

    gi.require_version("Gtk", "3.0")
    gi.require_version("Gdk", "3.0")
    from gi.repository import Gdk, Gtk

    st = Gtk.Settings.get_default()
    ctx = Gtk.Window().get_style_context()
    ok, bg = ctx.lookup_color("theme_bg_color")
    ok2, fg = ctx.lookup_color("theme_fg_color")
    d = Gdk.Display.get_default()
    m = d.get_monitor(0)
    print(f"backend={type(d).__name__} theme={st.props.gtk_theme_name} dark={int(bool(st.props.gtk_application_prefer_dark_theme))} "
          f"bg={hexc(bg.red * 255, bg.green * 255, bg.blue * 255) if ok else 'none'} "
          f"fg={hexc(fg.red * 255, fg.green * 255, fg.blue * 255) if ok2 else 'none'} "
          f"scale={m.get_scale_factor() if m else 0} xftdpi={st.props.gtk_xft_dpi / 1024:g} "
          f"font={st.props.gtk_font_name.replace(' ', '_')}")


{"qt": qt, "gtk": gtk}[sys.argv[1]]()
