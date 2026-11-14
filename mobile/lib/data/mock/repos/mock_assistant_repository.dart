import '../../models/equipment.dart';
import '../../models/inspection.dart';
import '../../models/workflow.dart';
import '../../repositories/assistant_repository.dart';
import '../../repositories/change_feed.dart';
import '../mock_backend.dart';

/// Ассистент демонстрационного сервера: ответы только из данных истории, как детерминированный поиск сервера.
class MockAssistantRepository implements AssistantRepository {
  /// Создаёт репозиторий поверх [backend].
  MockAssistantRepository(this.backend);

  /// Демонстрационный сервер.
  final MockBackend backend;

  @override
  Future<List<String>> suggestions() => backend.read(() => List<String>.unmodifiable(backend.db.assistantSuggestions));

  @override
  Future<List<AssistantMessage>> dialog() => backend.read(() => List<AssistantMessage>.unmodifiable(backend.db.assistantDialog));

  @override
  Future<AssistantMessage> ask(String question, {String? unitId}) => backend.write([KvDomain.assistant], () {
        final String now = backend.timeNow;
        backend.db.assistantDialog.add(AssistantMessage(fromUser: true, text: question, time: now));
        final AssistantMessage a = _answer(question.toLowerCase());
        final AssistantMessage answer = AssistantMessage(
          fromUser: false,
          text: a.text,
          refs: a.refs,
          links: a.links,
          time: now,
          source: a.source,
          found: a.found,
          facts: a.facts,
        );
        backend.db.assistantDialog.add(answer);
        return answer;
      });

  /// Агрегат, названный в вопросе: «АМС-1», «н-101»; null - не назван.
  Equipment? _unitIn(String q) {
    for (final Equipment u in backend.db.units) {
      if (q.contains(u.code.toLowerCase()) || q.contains(u.id.toLowerCase())) {
        return u;
      }
    }
    return null;
  }

  AssistantMessage _answer(String q) {
    final Equipment n101 = backend.unitOf('N-101');
    if (q.contains('вибрац')) {
      return backend.db.assistantDialog.firstWhere((AssistantMessage m) => !m.fromUser, orElse: () => const AssistantMessage(fromUser: false, text: ''));
    }
    if (q.contains('ближайш') && q.contains('то')) {
      return _nearestMaintenance();
    }
    if (q.contains('муфт')) {
      final Equipment u = _unitIn(q) ?? backend.unitOf('AMS-1');
      final bool inHistory = (backend.db.history[u.id] ?? const <HistoryEvent>[])
          .any((HistoryEvent e) => '${e.title} ${e.text}'.toLowerCase().contains('муфт'));
      if (!inHistory) {
        return AssistantMessage(
          fromUser: false,
          found: false,
          text: 'В истории и паспорте ${u.code} нет замены муфты. Возможно, работы не вносились в систему.',
          links: [
            AssistantLink(title: 'История ${u.code}', deeplink: '/engineer/history/c-history/${u.id}', kind: 'history'),
            const AssistantLink(title: 'Спросить мастера', deeplink: '', kind: 'ask_master'),
          ],
          source: 'Проверено: история, паспорт, план ТО',
        );
      }
    }
    if (q.contains('то-2') || q.contains('то 2')) {
      final MaintenanceItem to2 = n101.maintenance.firstWhere((MaintenanceItem m) => m.code == 'ТО-2');
      return AssistantMessage(fromUser: false, text: 'ТО-2 для Н-101: ${to2.work}. Срок - через ${to2.inHours.round()} ч наработки (${to2.nextAt?.round()} ч).', refs: const ['Регламент ТО насосов in-line']);
    }
    if (q.contains('уплотнен')) {
      final MaintenanceItem rev = n101.maintenance.firstWhere((MaintenanceItem m) => m.code == 'Ревизия');
      return AssistantMessage(fromUser: false, text: 'Замена торцевого уплотнения входит в ревизию: ${rev.work.toLowerCase()}. Работы выполнять на остановленном агрегате по наряду.', refs: const ['Руководство по эксплуатации Wilo CronoLine-IL']);
    }
    if (q.contains('сравни') || q.contains('недел')) {
      return const AssistantMessage(fromUser: false, text: 'За неделю вибрация 1X Н-101 выросла с 2,4 до 3,1 мм/с, 10.11 был кратковременный пик 4,8 мм/с. Температура подшипника - с 71 до 78 °C.', refs: ['R08', 'S01']);
    }
    return AssistantMessage(
      fromUser: false,
      found: false,
      text: 'В истории, паспортах и плане ТО ответа нет. Попробуйте спросить: «${backend.db.assistantSuggestions.take(3).join('», «')}».',
      source: 'Проверено: история, паспорт, план ТО',
    );
  }

  /// Ближайшие работы по плану ТО и наработке: ремонт по плану, ТО-2 Н-101 и ТО АМС-1 по остатку наработки.
  AssistantMessage _nearestMaintenance() {
    final Equipment n101 = backend.unitOf('N-101');
    final Equipment ams1 = backend.unitOf('AMS-1');
    final Equipment ams2 = backend.unitOf('AMS-2');
    final PlanItem? repair = backend.db.plan.where((PlanItem p) => p.unitId == ams2.id && p.status == 'planned').firstOrNull;
    final MaintenanceItem to2 = n101.maintenance.firstWhere((MaintenanceItem m) => m.code == 'ТО-2');
    final List<AssistantFact> facts = [
      if (repair != null) AssistantFact(label: '${repair.date.substring(0, 5)}, ${repair.time}', text: '${ams2.code} · ремонт уплотнения'),
      AssistantFact(label: 'через ${_hours(to2.inHours)} ч', text: '${n101.code} · ТО-2 с объёмом ТО-1'),
      AssistantFact(label: 'через ${_hours(ams1.resource.left)} ч', text: '${ams1.code} · ТО по наработке'),
    ];
    return AssistantMessage(
      fromUser: false,
      text: 'Ближайшие работы по наработке:',
      facts: facts,
      links: [
        AssistantLink(title: 'Карточка ${n101.code}', deeplink: '/engineer/objects/card/${n101.id}', kind: 'card'),
        AssistantLink(title: 'Карточка ${ams2.code}', deeplink: '/engineer/objects/card/${ams2.id}', kind: 'card'),
      ],
      source: 'По плану ТО и наработке',
    );
  }

  /// Часы с разрядами через неразрывный пробел: «1 200».
  static String _hours(double h) => h.round().toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (Match m) => ' ');
}
