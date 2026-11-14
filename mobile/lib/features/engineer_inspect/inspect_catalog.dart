import 'package:flutter/foundation.dart';

import '../../core/kv.dart';

/// Класс признака дефекта модели распознавания: что показать инженеру и что записать в находку.
@immutable
class DefectClass {
  /// Создаёт класс признака.
  const DefectClass({
    required this.title,
    required this.nodeId,
    required this.node,
    required this.ruleId,
    required this.ruleShort,
    required this.findingTitle,
    required this.seen,
    required this.kind,
    required this.comment,
    this.icon = KvIcons.drop,
    this.closeUp = true,
    this.closeUpView = const KvCamView(k: 2.2, cx: 0.38, cy: 0.62, ty: 0.34),
  });

  /// Заголовок признака на панели камеры: «Признаки течи у вала».
  final String title;

  /// Узел агрегата по умолчанию.
  final String nodeId;

  /// Название узла: «Торцевое уплотнение».
  final String node;

  /// Правило, к которому относится признак.
  final String ruleId;

  /// Короткое название правила в форме дефекта: «деградация уплотнения».
  final String ruleShort;

  /// Заголовок находки для мастера.
  final String findingTitle;

  /// Что видно на кадре: «Капли и влажное пятно».
  final String seen;

  /// Тип дефекта в форме: «Течь», «Коррозия», «Подгорание», «Повреждение», «Другое».
  final String kind;

  /// Комментарий инженера, предложенный по кадру.
  final String comment;

  /// Значок признака.
  final KvIcons icon;

  /// Признак подтверждается с крупного плана камеры; иначе касание рамки открывает разбор правила.
  final bool closeUp;

  /// Участок кадра для крупного плана признака.
  final KvCamView closeUpView;
}

/// Классы признаков дефектов по подписи рамки распознавания.
const Map<String, DefectClass> kDefectClasses = {
  'Течь у вала': DefectClass(
    title: 'Признаки течи у вала',
    nodeId: 'seal',
    node: 'Торцевое уплотнение',
    ruleId: 'R01',
    ruleShort: 'деградация уплотнения',
    findingTitle: 'Деградация уплотнения вала',
    seen: 'Капли и влажное пятно',
    kind: 'Течь',
    comment: 'Капли и влажное пятно у вала со стороны всасывания.',
  ),
  'Лужа под агрегатом': DefectClass(
    title: 'Признаки течи у вала',
    nodeId: 'seal',
    node: 'Торцевое уплотнение',
    ruleId: 'R01',
    ruleShort: 'деградация уплотнения',
    findingTitle: 'Течь торцевого уплотнения',
    seen: 'Лужа под агрегатом, капли со стороны вала',
    kind: 'Течь',
    comment: 'Лужа под агрегатом, капли со стороны вала.',
    closeUpView: KvCamView(k: 2.6, cx: 0.3, cy: 0.8, ty: 0.3),
  ),
  'Следы перегрева клемм': DefectClass(
    title: 'Следы перегрева клемм',
    nodeId: 'terminal_box',
    node: 'Клеммная коробка',
    ruleId: 'R04',
    ruleShort: 'плохой контакт в клеммной коробке',
    findingTitle: 'Плохой контакт в клеммной коробке',
    seen: 'Потемнение изоляции у клемм',
    kind: 'Подгорание',
    comment: 'Потемнение изоляции у клемм.',
    icon: KvIcons.flash,
    closeUp: false,
  ),
};

/// Признак, с которым открываются экраны признака и формы дефекта без параметра: течь у вала Н-101.
const String kDefaultSign = 'Течь у вала';

/// Типы дефекта в форме «Новый дефект».
const List<String> kDefectKinds = ['Течь', 'Коррозия', 'Подгорание', 'Повреждение', 'Другое'];

/// Уровни критичности в форме «Новый дефект»: индекс + 1 - тяжесть находки.
const List<String> kDefectLevels = ['Низкая', 'Средняя', 'Высокая'];

/// Положение подписи рамки на живом видео: подписи не перекрывают друг друга и узлы.
const Map<String, KvArLabelPosition> kArLabelPositions = {
  'Электродвигатель': KvArLabelPosition.above,
  'Кожух муфты': KvArLabelPosition.left,
  'Корпус насоса': KvArLabelPosition.edge,
  'Следы перегрева клемм': KvArLabelPosition.below,
  'Течь у вала': KvArLabelPosition.left,
};

/// Закладки документов: страница, найденная по сработавшему правилу.
const Map<String, String> kDocumentBookmarks = {'Паспорт насоса IL 65/160': 'с. 34 - уплотнение вала'};

/// Пояснения к графикам Н-101 по показаниям: что видно и что рекомендуется.
const Map<String, String> kChartNotes = {
  'vib1x': '10.11 вибрация 1X кратко превышала аварийную уставку 4,5 мм/с и снова растёт. Рекомендуется проверка подшипника.',
  'tBearing': 'Температура подшипника выше уставки 75 °C с 12.11 и продолжает расти. Рекомендуется проверка смазки.',
  'pressOut': 'Давление нагнетания держится около 4,6 бар, совпадает с манометром.',
  'tWinding': 'Температура обмоток 84 °C, ниже уставки 90 °C.',
};

/// Подпись манометра на живом видео: «4,6 бар» из «Манометр · 4,6 бар».
String gaugeValueOf(String label) => label.contains(' · ') ? label.split(' · ').last : label;

/// Страница документа, открытая по закладке: раздел, найденный по правилу, и соседние страницы.
@immutable
class DocPage {
  /// Создаёт страницу.
  const DocPage({
    required this.title,
    required this.page,
    required this.pages,
    required this.section,
    required this.heading,
    required this.ruleId,
    required this.text,
    required this.prev,
    required this.next,
  });

  /// Заголовок экрана: «Паспорт IL 65/160».
  final String title;

  /// Номер страницы.
  final int page;

  /// Всего страниц.
  final int pages;

  /// Колонтитул: «Wilo CronoLine-IL · раздел 6».
  final String section;

  /// Заголовок раздела на странице.
  final String heading;

  /// Правило, по которому найдена страница.
  final String ruleId;

  /// Выделенный абзац.
  final String text;

  /// Раздел на предыдущей странице.
  final String prev;

  /// Раздел на следующей странице.
  final String next;
}

/// Страницы документов по закладкам: паспорт насоса Н-101, раздел о замене торцевого уплотнения.
const Map<String, DocPage> kDocPages = {
  'Паспорт насоса IL 65/160': DocPage(
    title: 'Паспорт IL 65/160',
    page: 34,
    pages: 48,
    section: 'Wilo CronoLine-IL · раздел 6',
    heading: '6.3 Замена торцевого уплотнения',
    ruleId: 'R01',
    text: 'Перед заменой отключить двигатель, закрыть задвижки на всасывании и нагнетании, сбросить давление. Уплотнение (поз. 12) менять в сборе.',
    prev: '6.2 Проверка подшипникового узла',
    next: '6.4 Сборка и пробный пуск',
  ),
};
