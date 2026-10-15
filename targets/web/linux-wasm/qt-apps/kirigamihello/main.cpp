// PowOS on Linux/Wasm: a KDE Kirigami application on the canvas (software scene graph on linuxfb). Prints
// KIRIGAMIHELLO READY / TEXT t / CLICKED n through QML's console.log (test/linux-wasm-qt.mjs APP=kirigamihello).
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QQuickWindow>
#include <cstdio>

int main(int argc, char **argv)
{
	QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);
	QGuiApplication app(argc, argv);
	// Fusion (ships with Qt) until KDE's own controls style (qqc2-desktop-style, Breeze) is built for Wasm.
	if (qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_STYLE"))
		QQuickStyle::setStyle(QStringLiteral("Fusion"));
	QQmlApplicationEngine engine;
	QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] {
		printf("KIRIGAMIHELLO FAILED\n");
		fflush(stdout);
		QCoreApplication::exit(1);
	}, Qt::QueuedConnection);
	engine.loadFromModule("PowOS.KirigamiHello", "Main");
	return app.exec();
}
