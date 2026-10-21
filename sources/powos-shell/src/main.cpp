// powos-shell: the PowOS desktop shell's host (docs/DESKTOP-SHELL.md, docs/DESKTOP-WEB-SHELL.md). Next to
// plasmashell: everything you see is shell/; this process holds the slots and bridges KDE's models to it.
//
//   powos-shell [home] [panel]       the roles, one surface per screen each (default: home - the desktop's home, under
//                                    windows; panel: phase 0's bar, for when Plasma's own panel is gone)
//                                    the shell from ~/.config/powos/shell over /usr/share/powos/shell
//   POWOS_SHELL_DIR=~/src/shell ...  a checkout as the base instead (dev)
//   QTWEBENGINE_REMOTE_DEBUGGING=9222 powos-shell   DevTools / Playwright connectOverCDP
#include "bridge.h"
#include "home.h"
#include "panel.h"
#include "server.h"
#include "services.h"

#include <QApplication>
#include <QMultiHash>
#include <QJsonObject>
#include <QScreen>
#include <QWebEngineProfile>
#include <QWebEngineScript>
#include <QWebEngineScriptCollection>
#include <QWebEngineUrlScheme>

int main(int argc, char **argv)
{
    // Before the application exists (Chromium reads the scheme list at start). Secure + local: the page gets
    // localStorage, modules and fetch() on powos: as on https; nothing outside powos: can load it.
    QWebEngineUrlScheme scheme("powos");
    scheme.setSyntax(QWebEngineUrlScheme::Syntax::Host);
    scheme.setFlags(QWebEngineUrlScheme::SecureScheme | QWebEngineUrlScheme::LocalScheme | QWebEngineUrlScheme::LocalAccessAllowed
                    | QWebEngineUrlScheme::CorsEnabled | QWebEngineUrlScheme::ContentSecurityPolicyIgnored
                    | QWebEngineUrlScheme::FetchApiAllowed);
    QWebEngineUrlScheme::registerScheme(scheme);
    QCoreApplication::setAttribute(Qt::AA_ShareOpenGLContexts);
    // HACK: every window of this process is a layer surface, by Qt's shell-integration variable, not only the ones
    // LayerShellQt::Window::get() was called on. A QWebEngineView's top-level window starts as a raster surface and
    // QWidget re-creates it as an OpenGL one at the first show (its child renders through RHI); the re-created
    // platform window has lost the per-window layer-shell integration Window::get() set, and KWin got an xdg_toplevel
    // (a decorated window, no exclusive zone - seen in the nested KWin, 2026-10-20). Fine while the process has no
    // other windows. It's taken out of the environment again once the first window exists (the integration is
    // loaded then, once per process): left in, every app the launcher starts inherits it and opens as a bare layer
    // surface (seen: a KWrite with no frame, not in the window list). Real fix: the views as QtWebEngineQuick
    // WebEngineViews in QQuickWindows (OpenGL from creation, no re-create), or LayerShellQt re-applying its
    // integration when the platform window is re-created.
    const bool layerEnv = !qEnvironmentVariableIsSet("QT_WAYLAND_SHELL_INTEGRATION");
    if (layerEnv)
        qputenv("QT_WAYLAND_SHELL_INTEGRATION", "layer-shell");
    // Mixed / fractional scale per screen: each surface lives on one QScreen, Chromium follows its ratio (§3.5).
    QGuiApplication::setHighDpiScaleFactorRoundingPolicy(Qt::HighDpiScaleFactorRoundingPolicy::PassThrough);

    QApplication app(argc, argv);
    app.setApplicationName(QStringLiteral("powos-shell"));
    app.setOrganizationDomain(QStringLiteral("powos.org"));
    app.setDesktopFileName(QStringLiteral("org.powos.shell"));
    app.setQuitOnLastWindowClosed(false);

    QStringList roles = app.arguments().mid(1);
    if (roles.isEmpty())
        roles = {QStringLiteral("home")};
    auto *store = new Store(&app);
    Services services{new Apps(&app), new Windows(&app), store, new Theme(&app), new Ai(store, &app)};

    auto *profile = new QWebEngineProfile(QStringLiteral("powos-shell"), &app);
    profile->installUrlSchemeHandler("powos", new ShellServer(services.windows, &app));
    QWebEngineScript script;
    script.setName(QStringLiteral("powos-host"));
    script.setSourceCode(bridgeScript());
    script.setInjectionPoint(QWebEngineScript::DocumentCreation);
    script.setWorldId(QWebEngineScript::MainWorld);
    script.setRunsOnSubFrames(false);
    profile->scripts()->insert(script);

    // Each role's surface per screen, following screens as they come and go.
    QMultiHash<QScreen *, ShellView *> views;
    auto add = [&](QScreen *screen) {
        for (const QString &role : std::as_const(roles)) {
            ShellView *view = nullptr;
            if (role == QLatin1String("home"))
                view = new Home(screen, profile, services);
            else if (role == QLatin1String("panel"))
                view = new Panel(screen, profile, services);
            else
                qWarning().noquote() << "powos-shell: no role" << role << "(home, panel)";
            if (!view)
                continue;
            views.insert(screen, view);
            view->show();
        }
    };
    for (QScreen *screen : app.screens())
        add(screen);
    if (layerEnv)
        qunsetenv("QT_WAYLAND_SHELL_INTEGRATION");
    QObject::connect(&app, &QGuiApplication::screenAdded, &app, add);
    QObject::connect(&app, &QGuiApplication::screenRemoved, &app, [&](QScreen *screen) {
        for (ShellView *view : views.values(screen))
            view->deleteLater();
        views.remove(screen);
    });

    // Hot reload: a saved shell file reaches every page as "files.changed" (shell/hot.ts reloads or swaps the CSS).
    Watcher watcher(shellRoots());
    QObject::connect(&watcher, &Watcher::changed, &app, [&](const QString &path) {
        for (ShellView *view : std::as_const(views))
            view->bridge()->emitEvent(QStringLiteral("files.changed"), QJsonObject{{QStringLiteral("path"), path}});
    });

    const int rc = app.exec();
    qDeleteAll(views); // the pages go before their profile
    return rc;
}
