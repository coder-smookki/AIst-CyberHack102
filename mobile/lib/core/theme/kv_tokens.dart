import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart';

/// Отступы дизайна (переменные --s1..--s8 и --gutter в css/app.css).
abstract final class KvSpace {
  /// 4 px.
  static const double s1 = 4;

  /// 8 px.
  static const double s2 = 8;

  /// 12 px.
  static const double s3 = 12;

  /// 16 px.
  static const double s4 = 16;

  /// 20 px.
  static const double s5 = 20;

  /// 24 px.
  static const double s6 = 24;

  /// 32 px.
  static const double s7 = 32;

  /// 40 px.
  static const double s8 = 40;

  /// Боковое поле экрана - 16 px.
  static const double gutter = 16;
}

/// Скругления дизайна (переменные --r-*).
abstract final class KvRadius {
  /// 8 px - рамки AR, мелкие элементы.
  static const double xs = 8;

  /// 12 px - значки строк, мелкие плашки.
  static const double sm = 12;

  /// 12 px - чипы.
  static const double chip = 12;

  /// 16 px - кнопки и сегменты.
  static const double btn = 16;

  /// 14 px - поля ввода.
  static const double field = 14;

  /// 20 px - карточки, списки, плитки.
  static const double card = 20;

  /// 24 px - диалоги и крупные блоки.
  static const double lg = 24;

  /// 28 px - листы снизу.
  static const double sheet = 28;

  /// Полностью скруглённая форма.
  static const double pill = 999;
}

/// Размеры каркаса экрана из прототипа.
abstract final class KvLayout {
  /// Наибольшая ширина колонки содержимого на планшете: списки, карточки и формы по центру экрана.
  static const double maxContent = 640;

  /// Ширина, начиная с которой экран считается планшетным.
  static const double tablet = 600;

  /// Боковой отступ, который центрирует колонку содержимого шириной [maxContent] на экране шириной [width].
  static double sideInset(double width) => width >= tablet && width > maxContent ? (width - maxContent) / 2 : 0;

  /// Высота строки состояния в рамке iPhone прототипа; в приложении её заменяет системный отступ.
  static const double statusBar = 54;

  /// Высота зоны индикатора «домой» в рамке iPhone прототипа.
  static const double homeIndicator = 34;

  /// Нижний отступ прокрутки, когда на экране есть плавающая панель вкладок.
  static const double tabBarSpace = 116;

  /// Нижний отступ прокрутки, когда на экране есть закреплённая кнопка.
  static const double footSpace = 104;

  /// Нижний отступ прокрутки, когда есть и панель вкладок, и закреплённая кнопка.
  static const double tabBarFootSpace = tabBarSpace + 76;

  /// Высота плавающей панели вкладок.
  static const double tabBarHeight = 68;

  /// Расстояние от панели вкладок до нижнего края экрана в рамке прототипа.
  static const double tabBarBottom = 24;

  /// Расстояние от закреплённой кнопки до верха панели вкладок (bottom: 92px у .scr-foot).
  static const double footAboveTabBar = 92;

  /// Минимальный размер области нажатия.
  static const double touch = 44;
}

/// Длительности и кривые анимаций (js/app.js и переменные --ease, --t-* в css/app.css).
abstract final class KvMotion {
  /// Основная кривая переходов cubic-bezier(0.2, 0.8, 0.2, 1).
  static const Curve ease = Cubic(0.2, 0.8, 0.2, 1);

  /// Кривая появления cubic-bezier(0.2, 0, 0, 1).
  static const Curve easeOut = Cubic(0.2, 0, 0, 1);

  /// Кривая листа снизу с лёгким перелётом cubic-bezier(0.22, 1.18, 0.36, 1).
  static const Curve easeSheet = Cubic(0.22, 1.18, 0.36, 1);

  /// Отклик на нажатие.
  static const Duration press = Duration(milliseconds: 120);

  /// Быстрые смены цвета (--t-fast).
  static const Duration fast = Duration(milliseconds: 120);

  /// Обычные смены состояния (--t-std).
  static const Duration std = Duration(milliseconds: 250);

  /// Переход вперёд и назад (--t-nav).
  static const Duration nav = Duration(milliseconds: 300);

  /// Подъём экрана снизу (сканер).
  static const Duration up = Duration(milliseconds: 380);

  /// Возврат экрана, поднятого снизу.
  static const Duration upBack = Duration(milliseconds: 340);

  /// Смена вкладки и замена экрана наплывом.
  static const Duration fade = Duration(milliseconds: 220);

  /// Появление листа снизу.
  static const Duration sheet = Duration(milliseconds: 420);

  /// Затемнение под листом и диалогом.
  static const Duration scrim = Duration(milliseconds: 260);

  /// Закрытие листа и диалога.
  static const Duration overlayClose = Duration(milliseconds: 260);

  /// Появление диалога.
  static const Duration dialog = Duration(milliseconds: 240);

  /// Въезд уведомления сверху и снизу.
  static const Duration toastIn = Duration(milliseconds: 380);

  /// Уход уведомления.
  static const Duration toastOut = Duration(milliseconds: 300);

  /// Сколько уведомление сверху остаётся на экране.
  static const Duration toast = Duration(milliseconds: 2500);

  /// Сколько уведомление снизу остаётся на экране.
  static const Duration snack = Duration(milliseconds: 3200);

  /// Ожидание кнопки со спиннером перед действием (data-wait).
  static const Duration wait = Duration(milliseconds: 900);

  /// Задержка действия после отпускания пальца (видно отклик нажатия).
  static const Duration tapDelay = Duration(milliseconds: 90);

  /// Появление содержимого экрана снизу вверх по очереди.
  static const Duration stagger = Duration(milliseconds: 420);

  /// Шаг очереди появления.
  static const Duration staggerStep = Duration(milliseconds: 45);

  /// Задержка начала очереди.
  static const Duration staggerDelay = Duration(milliseconds: 60);

  /// Прорисовка графика слева направо.
  static const Duration chartReveal = Duration(milliseconds: 1100);

  /// Смещение старого экрана при переходе вперёд, доля ширины.
  static const double pushShift = 0.28;

  /// Затемнение старого экрана при переходе вперёд.
  static const double pushDim = 0.22;
}

/// Перевод CSS box-shadow в тень Flutter с тем же размытием (CSS blur = 2 sigma).
BoxShadow kvCssShadow(double x, double y, double blur, Color color, {double spread = 0}) {
  final double sigma = blur / 2;
  final double radius = sigma <= 0.5 ? 0 : (sigma - 0.5) / 0.57735;
  return BoxShadow(color: color, offset: Offset(x, y), blurRadius: radius, spreadRadius: spread);
}
