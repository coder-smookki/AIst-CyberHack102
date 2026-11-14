"""Перечень прав доступа и системные роли «КСТ Визор».

Права зашиты в код: каждое право проверяется конкретными маршрутами сервера, поэтому придумать новое право
через интерфейс нельзя. Роли же - данные: администратор ИБ меняет набор прав любой роли и заводит свои роли,
а здесь описан только начальный набор пяти системных ролей, которые наполнение базы добавляет, если их нет.
"""

GROUPS = (
    ("inspection", "Осмотр"),
    ("findings", "Находки"),
    ("equipment", "Оборудование"),
    ("reports", "Отчёты"),
    ("assistant", "Ассистент"),
    ("system", "Система"),
    ("accounts", "Учётные записи"),
)

PERMISSIONS = {
    "inspect.run": ("inspection", "Проведение осмотров",
                    "Начинать и вести осмотр, распознавать узлы камерой, завершать свой осмотр"),
    "inspect.supervise": ("inspection", "Дополнение чужих осмотров",
                          "Дополнять и завершать осмотры, начатые другими сотрудниками"),
    "tasks.assign": ("inspection", "Назначение осмотров",
                     "Назначать инженерам осмотр агрегата и разбирать сообщения о неисправностях"),
    "findings.view": ("findings", "Просмотр замечаний", "Видеть осмотры, замечания и снимки к ним"),
    "findings.create": ("findings", "Фиксация замечаний", "Записывать в осмотр дефекты, проверки и выполненные работы"),
    "findings.confirm": ("findings", "Подтверждение замечаний",
                         "Переводить замечания по цепочке «открыто - в работе - устранено»"),
    "fault.report": ("findings", "Сообщение о неисправности",
                     "Сообщать о признаках неисправности агрегата без проведения осмотра"),
    "equipment.view": ("equipment", "Просмотр оборудования", "Видеть карточки оборудования, узлы и историю"),
    "equipment.mode": ("equipment", "Смена режима агрегата", "Переводить агрегат в работу или останавливать"),
    "telemetry.view": ("equipment", "Просмотр телеметрии", "Видеть показания датчиков, прогнозы, диагноз и ресурс"),
    "telemetry.control": ("equipment", "Управление лентой телеметрии",
                          "Выбирать сценарии демонстрации и переставлять время стенда"),
    "maintenance.plan": ("equipment", "Планирование обслуживания", "Планировать техническое обслуживание агрегатов"),
    "reports.own": ("reports", "Отчёты по своим осмотрам", "Выгружать PDF и Excel по осмотрам, проведённым самим"),
    "reports.all": ("reports", "Отчёты по всем осмотрам", "Выгружать PDF и Excel по любому осмотру"),
    "assistant.use": ("assistant", "Вопросы помощнику", "Задавать вопросы помощнику об оборудовании и истории"),
    "system.manage": ("system", "Обслуживание системы", "Видеть состояние сервера, базы данных и моделей распознавания"),
    "users.manage": ("accounts", "Управление учётными записями",
                     "Заводить, блокировать учётные записи, менять роль, сбрасывать пароль, закрывать сеансы"),
    "roles.manage": ("accounts", "Управление ролями", "Создавать роли и менять набор их прав"),
    "security.log": ("accounts", "Журнал безопасности", "Просматривать журнал входов и действий с учётными записями"),
    "security.policy": ("accounts", "Политика безопасности",
                        "Настраивать требования к паролям, блокировку входа и срок сеанса"),
}

GUARDIAN_PERMISSIONS = frozenset({"users.manage", "roles.manage"})

_ENGINEER = ("inspect.run", "findings.view", "findings.create", "equipment.view", "telemetry.view", "reports.own",
             "assistant.use")
_MASTER_EXTRA = ("inspect.supervise", "findings.confirm", "equipment.mode", "telemetry.control", "maintenance.plan",
                 "reports.all", "tasks.assign")

SYSTEM_ROLES = {
    "security_admin": ("Администратор ИБ",
                       "Ведёт учётные записи и роли, настраивает политику безопасности, просматривает журнал",
                       ("users.manage", "roles.manage", "security.log", "security.policy")),
    "admin": ("Администратор системы",
              "Системный программист: обслуживает сервер, базу и модели, управляет стендом демонстрации",
              ("system.manage", "equipment.view", "telemetry.view", "telemetry.control")),
    "master": ("Мастер",
               "Подтверждает замечания, меняет режим агрегатов, назначает осмотры и видит все отчёты",
               _ENGINEER + _MASTER_EXTRA),
    "engineer": ("Инженер", "Проводит осмотры оборудования и фиксирует замечания", _ENGINEER),
    "operator": ("Оператор", "Наблюдает за оборудованием и сообщает о признаках неисправности",
                 ("equipment.view", "telemetry.view", "findings.view", "fault.report", "assistant.use")),
}


def ordered(codes) -> list[str]:
    """Оставляет только известные права и располагает их в порядке перечня."""
    wanted = set(codes or ())
    return [code for code in PERMISSIONS if code in wanted]


def unknown(codes) -> list[str]:
    """Возвращает коды, которых нет в перечне прав."""
    return sorted({code for code in codes or () if code not in PERMISSIONS})


def title(code: str) -> str:
    """Русское название права по его коду."""
    return PERMISSIONS[code][1]


def catalogue() -> list[dict]:
    """Перечень прав, разложенный по группам, для экрана настройки ролей."""
    groups = []
    for group, group_title in GROUPS:
        entries = [{"code": code, "title": name, "description": text}
                   for code, (owner, name, text) in PERMISSIONS.items() if owner == group]
        groups.append({"code": group, "title": group_title, "permissions": entries})
    return groups
