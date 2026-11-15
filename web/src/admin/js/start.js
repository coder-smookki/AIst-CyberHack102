/** Запуск панели: тема, восстановление сеанса из sessionStorage и выбор страницы по роли. */
(function () {
  'use strict';
  var A = window.WA;
  A.theme();
  A.enter = function () {
    if (!A.user) { A.go('login'); return; }
    if (A.user.must_change_password) { A.go('temp'); return; }
    if (!A.hasWeb()) { A.go('noaccess'); return; }
    var k = (location.hash || '').replace(/^#\/?/, '');
    var page = A.pages[k];
    A.go(page && !page.full && (!page.guard || page.guard()) ? k : A.home());
  };
  if (A.store.get('access') || A.store.get('refresh')) {
    A.api('GET', '/auth/me').then(function (me) { A.user = me; A.enter(); }, function () { A.user = null; A.clearTokens(); A.go('login'); });
  } else {
    A.go('login');
  }
})();
