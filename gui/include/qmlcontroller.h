#pragma once

#include "controllermanager.h"

#include <QVariantMap>

class QTimer;

class QmlController : public QObject
{
    Q_OBJECT
    Q_PROPERTY(bool dualSense READ isDualSense CONSTANT)
    Q_PROPERTY(bool handheld READ isHandheld CONSTANT)
    Q_PROPERTY(bool steamVirtual READ isSteamVirtual CONSTANT)
    Q_PROPERTY(bool dualSenseEdge READ isDualSenseEdge CONSTANT)
    Q_PROPERTY(bool playStation READ isPS CONSTANT)
    // AnyPlay: назва геймпада і що на ньому зараз натиснуто (екран клавіш поза грою світить ті самі кнопки)
    Q_PROPERTY(QString name READ name CONSTANT)
    Q_PROPERTY(QVariantMap padState READ padState NOTIFY padStateChanged)

public:
    QmlController(Controller *controller, uint32_t shortcut, QObject *target, QObject *parent = nullptr);
    ~QmlController();

    bool isDualSense() const;
    bool isHandheld() const;
    bool isSteamVirtual() const;
    bool isDualSenseEdge() const;
    bool isPS() const;
    void setEscapeShortcut(uint32_t shortcut) { escape_shortcut = shortcut; };
    QString GetGUID() const;
    QString GetVIDPID() const;
    QString name() const;
    QVariantMap padState() const { return pad_state; }

signals:
    void padStateChanged();

private:
    void sendKey(Qt::Key key, Qt::KeyboardModifiers modifiers = Qt::NoModifier);

    QObject *target = {};
    uint32_t escape_shortcut = 0;
    uint32_t old_buttons = 0;
    Controller *controller = {};
    QTimer *repeat_timer = {};
    int repeat_running = 0;
    Qt::Key pressed_key = Qt::Key_unknown;
    QVariantMap pad_state;
    void updatePadState(const ChiakiControllerState &state);
};
