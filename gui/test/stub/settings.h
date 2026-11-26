// Заглушка settings.h для тесту рушія клавіш (anyplay_engine_test.cpp): з усіх налаштувань рушію треба лише фізична клавіша
#ifndef ANYPLAY_TEST_SETTINGS_H
#define ANYPLAY_TEST_SETTINGS_H
#include <QKeyEvent>
class Settings
{
	public:
		static Qt::Key PhysicalKey(const QKeyEvent *event) { return event ? Qt::Key(event->key()) : Qt::Key(0); }
};
#endif
