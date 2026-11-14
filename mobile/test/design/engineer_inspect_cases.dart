import 'package:kst_vizor/data/models/people.dart';

import 'design_case.dart';

/// Снимки раздела «Инженер: осмотр» (engineer_inspect).
const List<DesignCase> engineerInspectCases = <DesignCase>[
  DesignCase('objects', route: '/engineer/objects', role: KvRole.engineer),
  DesignCase('card', route: '/engineer/objects/card/N-101', role: KvRole.engineer),
  DesignCase('card-ams1', route: '/engineer/objects/card/AMS-1', role: KvRole.engineer),
  DesignCase('card-ams2', route: '/engineer/objects/card/AMS-2', role: KvRole.engineer),
  DesignCase('card-menu', route: '/engineer/objects/card/N-101', role: KvRole.engineer, steps: <DesignStep>[TapLabel('Ещё')]),
];
