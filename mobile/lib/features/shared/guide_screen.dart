import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/navigation/kv_nav.dart';
import '../../app/routes/entry_routes.dart';
import '../../app/shell/role_tabs.dart';
import '../../app/state/app_state.dart';
import '../../core/kv.dart';
import '../../data/models/people.dart';

/// Пункт инструкции: значок, название кнопки или экрана и что он делает.
typedef GuideItem = ({KvIcons icon, String title, String text});

/// Раздел инструкции «Как пользоваться».
@immutable
class GuideSection {
  /// Создаёт раздел [title] с пунктами [items]; [roles] - для каких ролей раздел главный (пусто - общий порядок работы).
  const GuideSection(this.title, this.items, {this.roles = const <KvRole>{}});

  /// Заголовок раздела.
  final String title;

  /// Пункты раздела.
  final List<GuideItem> items;

  /// Роли, для которых раздел показывается первым.
  final Set<KvRole> roles;
}

/// Общий порядок работы: вход, сканирование, карточка, осмотр, находки, итог и ассистент.
const List<GuideSection> kGuideCommon = <GuideSection>[
  GuideSection('Начало работы', <GuideItem>[
    (icon: KvIcons.mail, title: 'Вход', text: 'Введите рабочую почту и пароль и нажмите «Войти». Приложение откроет экран вашей роли.'),
    (
      icon: KvIcons.server,
      title: 'Кнопка сервера',
      text:
          'Значок сервера в правом верхнем углу экрана входа показывает, к какому цеховому серверу подключено приложение, '
          'и позволяет сменить адрес или включить демонстрационный режим.',
    ),
    (
      icon: KvIcons.finger,
      title: 'Вход по биометрии',
      text:
          'После первого входа с паролем приложение предложит входить по Face ID или отпечатку. Включить и выключить его можно '
          'в профиле. Ключ сеанса хранится защищённо на телефоне.',
    ),
    (icon: KvIcons.user, title: 'Профиль', text: 'Последняя вкладка внизу: настройки, тема, уведомления, эта инструкция и выход из учётной записи.'),
  ]),
  GuideSection('Как найти агрегат', <GuideItem>[
    (icon: KvIcons.scan, title: 'Сканер', text: 'Синяя круглая кнопка в центре нижней панели открывает камеру.'),
    (icon: KvIcons.camera, title: 'Распознать', text: 'Наведите камеру на шильдик или QR-код агрегата и нажмите «Распознать» - откроется его карточка.'),
    (icon: KvIcons.list, title: 'Из списка', text: 'Если шильдик не читается, выберите агрегат из списка объектов.'),
    (icon: KvIcons.hash, title: 'Ввести номер', text: 'Наберите заводской или инвентарный номер вручную.'),
    (
      icon: KvIcons.info,
      title: 'Как агрегат определён',
      text:
          '«По шильдику» - номер прочитан с таблички; «По QR-коду» - найден по коду; «Выбран вручную» - вы выбрали его сами. '
          'Подпись видна в шапке осмотра и в отчёте.',
    ),
  ]),
  GuideSection('Карточка агрегата', <GuideItem>[
    (icon: KvIcons.activity, title: 'Сейчас', text: 'Текущие показания датчиков, ресурс, ближайшее ТО и диагностика по правилам.'),
    (icon: KvIcons.wave, title: 'Графики', text: 'Показания за смену, сутки и месяц с порогами «норма», «внимание» и «авария».'),
    (icon: KvIcons.history, title: 'История', text: 'Прошлые осмотры, находки, ремонты и замены узлов.'),
    (
      icon: KvIcons.flag,
      title: 'Сначала проверьте',
      text:
          'Узлы, с которых стоит начать осмотр, и причина: прошлая находка, датчики, ресурс или план ТО. '
          'Кнопка «Проверить» открывает камеру с подсказкой на этот узел.',
    ),
    (icon: KvIcons.file, title: 'Паспорт агрегата', text: 'Модель, изготовитель, заводской номер, место, наработка и паспортные характеристики.'),
    (
      icon: KvIcons.more,
      title: 'Меню «Ещё»',
      text: 'Три точки в шапке: маршрут осмотра, «Записать работы», паспорт и документы PDF, отчёт по агрегату в PDF и показания в Excel.',
    ),
  ]),
  GuideSection('Осмотр с камерой', <GuideItem>[
    (icon: KvIcons.box, title: 'Синяя рамка', text: 'Узел агрегата распознан: подшипник, муфта, манометр и другие.'),
    (icon: KvIcons.alert, title: 'Жёлтая рамка «проверить»', text: 'Похоже на признак неисправности, но уверенности мало - посмотрите сами.'),
    (icon: KvIcons.alertCircle, title: 'Красная рамка «дефект»', text: 'Найден признак дефекта: течь, коррозия, перегрев и другие.'),
    (icon: KvIcons.route, title: 'Серые узлы', text: 'Узлы маршрута, которые ещё не осмотрены. Осмотренные отмечаются автоматически, когда попадают в кадр.'),
    (
      icon: KvIcons.tag,
      title: 'Подсказка типа',
      text: 'Подпись вроде «Насосный агрегат» или «Шкаф управления» - только подсказка, какой это агрегат; агрегат определяет шильдик.',
    ),
    (icon: KvIcons.gauge, title: 'Рамка манометра', text: 'Коснитесь рамки манометра: приложение прочитает стрелку и сравнит показание с датчиком.'),
    (icon: KvIcons.camera, title: 'Зафиксировать', text: 'Сохранить текущий кадр в осмотр, чтобы отметить находку вручную.'),
    (icon: KvIcons.mic, title: 'Записать шум', text: 'Запись звука агрегата: сервер ищет стук и гул неисправности.'),
    (icon: KvIcons.grid, title: 'Карточка', text: 'Открыть карточку агрегата, не завершая осмотр.'),
    (icon: KvIcons.wrench, title: 'Работы', text: '«Обслужил», «Заменил» узел или «Заметка» - запись о выполненной работе в осмотр.'),
    (icon: KvIcons.checkCircle, title: 'Завершить', text: 'Закончить осмотр и перейти к итогу.'),
  ]),
  GuideSection('Находки', <GuideItem>[
    (icon: KvIcons.check, title: 'Это дефект', text: 'Подтвердить признак: находка уйдёт мастеру с кадром и показаниями датчиков.'),
    (icon: KvIcons.close, title: 'Не дефект', text: 'Отклонить ложную рамку; причина помогает улучшать распознавание.'),
    (icon: KvIcons.edit, title: 'Комментарий', text: 'Добавьте пояснение к находке - его увидят мастер и отчёт.'),
  ]),
  GuideSection('Итог осмотра и отчёт', <GuideItem>[
    (icon: KvIcons.clipboard, title: 'Итог', text: 'Список осмотренных узлов, находки, работы и вердикт по агрегату.'),
    (
      icon: KvIcons.alert,
      title: 'Осмотр неполный',
      text: 'Так отмечен осмотр, в котором часть узлов маршрута не попала в кадр. Вернитесь к агрегату или укажите причину.',
    ),
    (icon: KvIcons.filePdf, title: 'PDF', text: 'Отчёт с кадрами, находками и графиками для печати и передачи.'),
    (icon: KvIcons.fileXls, title: 'Excel', text: 'Таблица показаний датчиков за период.'),
  ]),
  GuideSection('Ассистент', <GuideItem>[
    (
      icon: KvIcons.chat,
      title: 'Вкладка «Ассистент»',
      text: 'Отвечает прямо на телефоне, без интернета: где найти экран, что значат статусы и правила, что проверить при неисправности.',
    ),
    (icon: KvIcons.sparkle, title: 'Подсказки', text: 'Готовые вопросы над полем ввода - нажмите, чтобы спросить.'),
    (icon: KvIcons.link, title: 'Ссылки в ответе', text: 'Открывают нужный экран: карточку, диагностику, историю или маршрут осмотра.'),
  ]),
];

/// Разделы для ролей: что главное на их вкладках.
const List<GuideSection> kGuideRoles = <GuideSection>[
  GuideSection(
    'Мастер смены',
    roles: <KvRole>{KvRole.master},
    <GuideItem>[
      (icon: KvIcons.clipboard, title: 'Смена', text: 'Агрегаты смены, новые находки, осмотры и охват обхода.'),
      (icon: KvIcons.alertCircle, title: 'Находки', text: 'Находки ждут подтверждения: «Подтвердить», «Назначить» исполнителя или отклонить с комментарием.'),
      (icon: KvIcons.calendar, title: 'План ТО', text: 'Ближайшие ТО по наработке и календарь; пункт плана открывает объём работ.'),
      (icon: KvIcons.users, title: 'Бригада и отчёты', text: 'Из смены и профиля: кто где работает и отчёты за смену.'),
    ],
  ),
  GuideSection(
    'Старший инженер',
    roles: <KvRole>{KvRole.senior},
    <GuideItem>[
      (icon: KvIcons.grid, title: 'Объекты', text: 'Все агрегаты и их состояние.'),
      (icon: KvIcons.alertCircle, title: 'Находки', text: 'Проверка находок инженеров перед передачей мастеру.'),
    ],
  ),
  GuideSection(
    'Оператор',
    roles: <KvRole>{KvRole.operator},
    <GuideItem>[
      (icon: KvIcons.grid, title: 'Объекты', text: 'Агрегаты и живые показания; список обновляется сам каждые несколько секунд.'),
      (icon: KvIcons.megaphone, title: 'Сообщить', text: 'Центральная кнопка: сообщить о неисправности - что заметили, где, фото. Сообщение уйдёт мастеру.'),
      (icon: KvIcons.clock, title: 'История', text: 'Ваши сообщения и что с ними сделали.'),
      (icon: KvIcons.chat, title: 'Ассистент', text: 'Подскажет, что значат показания и что делать при неисправности.'),
    ],
  ),
  GuideSection(
    'Администратор системы',
    roles: <KvRole>{KvRole.admin},
    <GuideItem>[
      (icon: KvIcons.server, title: 'Система', text: 'Состояние сервера, каналов данных и устройств, обслуживание и обновление.'),
      (icon: KvIcons.plug, title: 'Источники', text: 'Подключение датчиков и привязка тегов к агрегатам.'),
      (icon: KvIcons.cpu, title: 'Модели', text: 'Модели распознавания: версии, качество и отпечаток набора моделей.'),
      (icon: KvIcons.list, title: 'Журнал', text: 'События сервера и действия пользователей.'),
    ],
  ),
  GuideSection(
    'Администратор ИБ',
    roles: <KvRole>{KvRole.sec},
    <GuideItem>[
      (icon: KvIcons.users, title: 'Пользователи', text: 'Создание учётных записей, временные пароли, блокировка и сеансы.'),
      (icon: KvIcons.key, title: 'Роли', text: 'Права каждой роли; изменения действуют со следующего запроса.'),
      (icon: KvIcons.list, title: 'Журнал', text: 'Журнал безопасности: входы, ошибки, блокировки.'),
      (icon: KvIcons.shield, title: 'Политика', text: 'Требования к паролям, число попыток входа и вход по биометрии.'),
    ],
  ),
];

/// Разделы инструкции по порядку для роли [role]: сначала раздел роли, затем общий порядок работы, затем другие роли.
/// Без входа - общий порядок работы и разделы ролей.
List<GuideSection> guideSections(KvRole? role) {
  final List<GuideSection> mine = role == null ? const <GuideSection>[] : kGuideRoles.where((GuideSection s) => s.roles.contains(role)).toList();
  final List<GuideSection> others = kGuideRoles.where((GuideSection s) => !mine.contains(s)).toList();
  return <GuideSection>[...mine, ...kGuideCommon, ...others];
}

/// Экран «Как пользоваться»: какие кнопки за что отвечают, по разделам; раздел текущей роли первым.
class GuideScreen extends ConsumerWidget {
  /// Создаёт экран инструкции.
  const GuideScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final KvRole? role = ref.watch(sessionProvider.select((AuthSession? s) => s?.user.role));
    final List<GuideSection> sections = guideSections(role);
    return KvScreen(
      header: KvHeader(
        title: 'Как пользоваться',
        subtitle: role == null ? 'Порядок работы в приложении' : 'Сначала - для роли «${role.label}»',
        onBack: () => context.kvBack(role == null ? EntryPaths.login : kvRoleHome(role)),
      ),
      children: [
        for (final GuideSection s in sections) ...[
          KvSectionLabel(s.title),
          KvCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (int i = 0; i < s.items.length; i++) ...[if (i > 0) const SizedBox(height: KvSpace.s3), _GuideRow(item: s.items[i])],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

/// Строка инструкции: значок в плашке, название кнопки и пояснение.
class _GuideRow extends StatelessWidget {
  const _GuideRow({required this.item});

  final GuideItem item;

  @override
  Widget build(BuildContext context) {
    final KvColors c = context.kv;
    final KvTextStyles t = context.kvText;
    return Semantics(
      container: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            alignment: Alignment.center,
            decoration: BoxDecoration(color: c.tint2, borderRadius: BorderRadius.circular(10)),
            child: KvIcon(item.icon, size: 18, color: c.brand),
          ),
          const SizedBox(width: KvSpace.s3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(KvFormat.typo(item.title), style: t.base.copyWith(fontWeight: FontWeight.w600)),
                const SizedBox(height: 2),
                Text(KvFormat.typo(item.text), style: t.sm.copyWith(color: c.text2)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
