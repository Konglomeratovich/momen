# Gemini через userspace Tailscale в Tachyon 1.7.11

## Почему нужен отдельный скрипт

Tachyon 1.7.11 умеет создавать outbound `action=tailscale`: генератор строит
endpoint sing-box со своим каталогом состояния, `exit_node` и
`exit_node_allow_lan_access`. Однако LuCI этой версии не предлагает действие
`tailscale` в редакторе секции маршрута. Видимая форма Tailscale в мастере
серверов создаёт inbound и может рекламировать сам роутер как exit node — это
другая задача.

[`configure-tachyon-tailscale-gemini.sh`](../scripts/configure-tachyon-tailscale-gemini.sh)
создаёт раннюю секцию `GEMINI_TAILSCALE`, направляет только Tachyon List
`google_ai` через уже существующий exit node и убирает дублирующий preset из
`main`, только если он там ещё есть. В актуальной конфигурации, где
`google_ai` уже удалён из `main`, это безопасный no-op. Исключённые устройства
копируются из `main`, поэтому добавление новой прокси-секции не возвращает их
в VPN.

## Безопасность

- exit node передаётся при запуске и не хранится в репозитории;
- новый auth key передаётся только через файл с режимом `0600`, не через
  аргумент процесса;
- ключ нужен только для первой регистрации, после появления userspace-state
  он удаляется из UCI и входной файл уничтожается;
- непосредственно перед первой мутацией создаётся backup только
  `/etc/config/tachyon`; идемпотентный no-op Apply backup не создаёт;
- candidate дважды проверяется штатной командой `tachyon config_validate`:
  сначала для регистрации, затем без ключа;
- planner 1.7.11 ошибочно не разрешает `action=tailscale`. При таком отказе
  скрипт проверяет SHA-256 `service/config_plan.uc`
  (`997ee8ee8f667ae625c8c6d48d100169ddf518e612fb468ecde7cd258d51c4f0`),
  создаёт приватную копию в tmpfs и добавляет только `tailscale` в allowlist.
  Остальные проверки выполняются повторно. При неизвестном hash или любой
  оставшейся ошибке Apply останавливается. Установленный planner не изменяется.
  Маркер: `PLANNER_1_7_11_PRIVATE_COMPATIBILITY_FIX=true`;
- Apply требует swap, запас RAM/overlay и отсутствие совсем свежего OOM;
- при ошибке восстанавливается прежняя конфигурация и выполняется штатный
  reload; каталог Tailscale state автоматически не удаляется.

Скрипт не устанавливает native-пакет `tailscale` и не запускает отдельный
`tailscaled`: используется поддержка `with_tailscale` активного
`tachyon-core`.

## Однострочники из GitHub

Ручное копирование скрипта не требуется. Команды ниже загружают опубликованный
скрипт по неизменяемому commit, проверяют SHA-256 и удаляют временный файл.
Они выполняются на OpenWrt. Один раз задайте Tailscale IPv4 своего exit node:

```sh
TS_EXIT_NODE='<EXIT_NODE_TAILSCALE_IPV4>'
```

Plan — совместимость и ресурсы без изменения конфигурации:

```sh
sh -c 'umask 077; f=$(mktemp /tmp/momen-tailscale.XXXXXX) || exit 1; trap '\''rm -f "$f"'\'' EXIT; wget -q -T 30 -O "$f" https://raw.githubusercontent.com/Konglomeratovich/momen/aee3490e32f0f554a82de54bbab9da0b24c245b1/scripts/configure-tachyon-tailscale-gemini.sh && echo "dda3611149d54bd85ec1b709e468c2f90a9ec9e2a4a75d6edc0a6a8070c03110  $f" | sha256sum -c - && ash "$f" --plan --exit-node "$1"' sh "$TS_EXIT_NODE"
```

Первичный Apply — после Plan и создания `/tmp/tailscale-auth.key` скрытым
вводом из раздела Apply ниже. Выполняет reload служб:

```sh
sh -c 'umask 077; f=$(mktemp /tmp/momen-tailscale.XXXXXX) || exit 1; trap '\''rm -f "$f"'\'' EXIT; wget -q -T 30 -O "$f" https://raw.githubusercontent.com/Konglomeratovich/momen/aee3490e32f0f554a82de54bbab9da0b24c245b1/scripts/configure-tachyon-tailscale-gemini.sh && echo "dda3611149d54bd85ec1b709e468c2f90a9ec9e2a4a75d6edc0a6a8070c03110  $f" | sha256sum -c - && ash "$f" --apply --exit-node "$1" --auth-key-file /tmp/tailscale-auth.key --confirm CONFIGURE-GEMINI-TAILSCALE' sh "$TS_EXIT_NODE"
```

Повторный Apply с сохранённой регистрацией, без нового ключа. Внимание:
пересоздаёт базовые правила секции и сбрасывает ручные дополнения, как описано ниже:

```sh
sh -c 'umask 077; f=$(mktemp /tmp/momen-tailscale.XXXXXX) || exit 1; trap '\''rm -f "$f"'\'' EXIT; wget -q -T 30 -O "$f" https://raw.githubusercontent.com/Konglomeratovich/momen/aee3490e32f0f554a82de54bbab9da0b24c245b1/scripts/configure-tachyon-tailscale-gemini.sh && echo "dda3611149d54bd85ec1b709e468c2f90a9ec9e2a4a75d6edc0a6a8070c03110  $f" | sha256sum -c - && ash "$f" --apply --exit-node "$1" --confirm CONFIGURE-GEMINI-TAILSCALE' sh "$TS_EXIT_NODE"
```

Проверка текущего состояния — для обычной диагностики используйте её:

```sh
sh -c 'umask 077; f=$(mktemp /tmp/momen-tailscale.XXXXXX) || exit 1; trap '\''rm -f "$f"'\'' EXIT; wget -q -T 30 -O "$f" https://raw.githubusercontent.com/Konglomeratovich/momen/aee3490e32f0f554a82de54bbab9da0b24c245b1/scripts/configure-tachyon-tailscale-gemini.sh && echo "dda3611149d54bd85ec1b709e468c2f90a9ec9e2a4a75d6edc0a6a8070c03110  $f" | sha256sum -c - && ash "$f" --verify' sh "$TS_EXIT_NODE"
```

Загрузка скрипта требует работающего HTTPS-доступа к GitHub. Эти команды
не устанавливают native Tailscale и не обновляют ядро.

## Plan

Для закреплённого ядра передавайте Tailscale IPv4 exit node из `100.64.0.0/10`.
FQDN при первом запуске вызывает `cannot resolve exit node by hostname while
Tailscale is starting up`. Скрипт запрещает hostname. Плейсхолдер ниже
нужно заменить IP из Admin Console. Уже зарегистрированный клиент можно
перенастроить повторным Apply с IP без файла auth-key, сохранив state.

После копирования скрипта в `/tmp` сначала выполняется только план:

```sh
ash /tmp/configure-tachyon-tailscale-gemini.sh \
  --plan \
  --exit-node '<EXIT_NODE_TAILSCALE_IPV4>'
```

`PLAN_OK=true` означает только прохождение read-only гейтов. Конфигурация и
службы не меняются.

## Apply

Создайте новый одноразовый или reusable pre-auth key в Tailscale Admin Console
и поместите его на роутере в tmpfs, не вставляя в командную строку:

```sh
umask 077
read -r -s -p 'Tailscale auth key: ' ts_auth
printf '\n'
printf '%s\n' "$ts_auth" >/tmp/tailscale-auth.key
unset ts_auth
chmod 0600 /tmp/tailscale-auth.key

ash /tmp/configure-tachyon-tailscale-gemini.sh \
  --apply \
  --exit-node '<EXIT_NODE_TAILSCALE_IPV4>' \
  --auth-key-file /tmp/tailscale-auth.key \
  --confirm CONFIGURE-GEMINI-TAILSCALE
```

После успешного первого Apply входной файл с ключом удалён. Повторный запуск
идемпотентен и при готовом `/etc/tachyon/tailscale/GEMINI_TAILSCALE` не требует
нового ключа:

```sh
ash /tmp/configure-tachyon-tailscale-gemini.sh \
  --apply \
  --exit-node '<EXIT_NODE_TAILSCALE_IPV4>' \
  --confirm CONFIGURE-GEMINI-TAILSCALE
```

## Проверка

### Итоговая схема после настройки через UI

В условии `cond_GEMINI_TAILSCALE` должен оставаться именно preset `google_ai`
(Google AI / Gemini / NotebookLM), а не `openai` (ChatGPT / Sora). Дополнительно
для единого выхода при авторизации и проверке Google добавляются точные домены:

```text
full:gemini.google.com
full:www.google.com
full:accounts.google.com
```

Это направляет также поиск на `www.google.com` через Tailscale. После любого
сохранения в UI нужно повторить `route_explain`: скрытые поля этой формы
могут изменить набор preset. Подтверждённое итоговое поведение:
Gemini и NotebookLM совпадают с `GEMINI_TAILSCALE`, ChatGPT — с `main`.
Полный end-to-end результат после последнего изменения условия ещё не подтверждён.

Скрипт создаёт базовую секцию заново: повторный Apply после ручной настройки
сбрасывает добавленные домены этой секции/условия. Сначала экспортируйте снапшот;
после Apply восстановите указанные локальные дополнения и проверьте маршруты.
Не используйте повторный Apply как обычную проверку: для этого есть `--verify`.

В 1.7.11 строка Engine в `route_explain` может показывать `direct-out`, потому
что ищет только в `outbounds`, игнорируя `endpoints`. Проверяйте наличие
Tailscale endpoint и фактическое соединение, а не только эту строку.

```sh
ash /tmp/configure-tachyon-tailscale-gemini.sh --verify
```

Проверка требует работающие Tachyon и tachyon-core, непустой userspace-state и
решение `PROXIED` через секцию `GEMINI_TAILSCALE` для `gemini.google.com`.
Она не доказывает внешний IP exit node: это отдельная фактическая проверка
клиентского запроса после Remote Apply.

## Rollback

Путь backup печатается как `BACKUP_DIR`. Для ручного возврата:

```sh
cp -p '<BACKUP_DIR>/tachyon' /etc/config/tachyon
chmod 0600 /etc/config/tachyon
tachyon reload tailscale-gemini-manual-rollback
```

После проверки возврата неиспользуемый каталог
`/etc/tachyon/tailscale/GEMINI_TAILSCALE` можно удалить отдельно. Скрипт не
делает этого автоматически, чтобы не уничтожить рабочую identity при ложном
отказе проверки.

## Граница локальных тестов

Отказ исходного planner воспроизведён в контейнере. Приватная исправленная
копия принимает `tailscale` и отклоняет неизвестное действие. Все семь
workflow-сценариев выполнены также с реальным planner вместо mock-валидации.
Регистрация и reload остаются mock и не подтверждают соединение с Tailnet.

Fixture-тесты подтверждают plan/apply/verify, удаление ключа, копирование
исключённых устройств, идемпотентность и восстановление конфигурации при
ошибке reload. Отдельный сценарий повторяет актуальное состояние, в котором
`google_ai` уже отсутствует в `main` и `cond_main`. Exact-source тест Tachyon
1.7.11 (commit `7a8843fbf9475374ce5fffce354b060fcb33b431`) подтверждает, что генератор
создаёт endpoint `type=tailscale`, `exit_node` и правило Google AI на этот
endpoint. Проверка бинарником sing-box подтверждает синтаксис сгенерированной
модели.

Контейнер не регистрируется в реальном Tailnet, не связывается с exit node и не
проверяет внешний IP. Эти свойства подтверждаются только на роутере после
отдельного разрешения.

Проверяемая комбинация: OpenWrt 25.12.2, Tachyon 1.7.11 и
sing-box `1.14.3-extended-2.7.3` с `with_tailscale`. Скрипт проверяет эти версии
до изменения конфигурации. Обновление самого ядра этой процедурой не выполняется.
Источник контракта — [tag 1.7.11](https://github.com/Dushnilin/tachyon/tree/1.7.11).
