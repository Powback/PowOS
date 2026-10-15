// PowOS on Linux/Wasm: Qt Quick (QML) on the canvas - the software scene graph on linuxfb (no GPU). Prints
// QMLHELLO READY when the scene is up, QMLHELLO CLICKED n / QMLHELLO TEXT t on input (test/linux-wasm-qt.mjs).
#include <QGuiApplication>
#include <QQmlApplicationEngine>
#include <QQuickWindow>
#include <cstdio>

int main(int argc, char **argv)
{
	QQuickWindow::setGraphicsApi(QSGRendererInterface::Software);
	QGuiApplication app(argc, argv);
	QQmlApplicationEngine engine;
	QObject::connect(&engine, &QQmlApplicationEngine::objectCreationFailed, &app, [] {
		printf("QMLHELLO FAILED\n");
		fflush(stdout);
		QCoreApplication::exit(1);
	}, Qt::QueuedConnection);
	engine.loadFromModule("PowOS.Hello", "Main");
	return app.exec();
}
