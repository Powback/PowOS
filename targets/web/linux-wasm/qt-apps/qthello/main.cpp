// PowOS on Linux/Wasm: the first Qt program - Qt Widgets drawn by linuxfb on /dev/fb0 (the page's canvas), keyboard
// and pointer from /dev/input (evdev plugins over wasminput). Prints QTHELLO READY once the window is shown, and
// QTHELLO CLICKED / QTHELLO TEXT <text> as the user interacts (test/linux-wasm-qt.mjs reads these).
#include <QApplication>
#include <QLabel>
#include <QLineEdit>
#include <QPushButton>
#include <QTimer>
#include <QVBoxLayout>
#include <QWidget>
#include <cstdio>

int main(int argc, char **argv)
{
	QApplication app(argc, argv);

	QWidget window;
	window.setWindowTitle("PowOS");
	auto *layout = new QVBoxLayout(&window);
	auto *title = new QLabel("<h1>PowOS on Linux/Wasm</h1>"
				 "<p>Qt Widgets, compiled to WebAssembly, drawing on the canvas.</p>");
	auto *edit = new QLineEdit;
	edit->setPlaceholderText("Type here");
	auto *button = new QPushButton("Click me");
	auto *status = new QLabel("Not clicked yet");
	layout->addWidget(title);
	layout->addWidget(edit);
	layout->addWidget(button);
	layout->addWidget(status);
	layout->addStretch();

	int clicks = 0;
	QObject::connect(button, &QPushButton::clicked, [&] {
		status->setText(QString("Clicked %1 time(s)").arg(++clicks));
		printf("QTHELLO CLICKED %d\n", clicks);
		fflush(stdout);
	});
	QObject::connect(edit, &QLineEdit::textChanged, [](const QString &t) {
		printf("QTHELLO TEXT %s\n", t.toUtf8().constData());
		fflush(stdout);
	});

	window.showFullScreen();
	QTimer::singleShot(0, [] {
		printf("QTHELLO READY\n");
		fflush(stdout);
	});
	return app.exec();
}
