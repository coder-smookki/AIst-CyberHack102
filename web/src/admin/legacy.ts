/**
 * Модули веб-панели в порядке подключения: библиотека оформления, основа (сеанс, API, оболочка),
 * страницы ролей и запуск. Подключаются одним фрагментом уже в браузере, после появления узла #app.
 */
import "./js/boot.js";
import "./js/core.js";
import "./js/web.js";
import "./js/app.js";
import "./js/pages_common.js";
import "./js/pages_sec.js";
import "./js/pages_admin.js";
import "./js/start.js";
