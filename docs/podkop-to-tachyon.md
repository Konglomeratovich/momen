# Контролируемая миграция Podkop → Tachyon

Эта инструкция описывает проверяемый переход с Podkop на Tachyon. Скрипт не
публикует и не отправляет наружу рабочие proxy/VPN credentials: конфигурация
читается и преобразуется только на самом роутере.

## Поддерживаемое исходное состояние

- OpenWrt `25.12.2` с `apk`;
- ARM64 (`aarch64*`); конкретная модель роутера не зашита в разрешение;
- `podkop 0.7.22-r1`;
- `luci-app-podkop 0.7.22-r1`;
- `luci-i18n-podkop-ru 0.7.22`;
- `sing-box 1.12.17-r1`;
- отсутствуют частично установленные пакеты Tachyon.

Устанавливаются Tachyon `1.7.11` и закреплённый
`sing-box extended-compressed 1.14.3-extended-2.7.3`. Иная версия, архитектура
или смешанное package-state останавливают процесс до изменений.

## Итоговая DIRECT-политика

Локально для 1.7.11 проверены: syntax/ShellCheck, readiness 11/11,
success/rollback fixtures 12/12 и 11/11, bootstrap 15/15, настоящая установка
APK и extended-compressed в OpenWrt 25.12.2 x86_64 контейнере. Offline preflight
с реальным генератором/ядром сохраняет полный каталог 724 и ручное дополнение,
добавляя отсутствующий Plex (726 итоговых правил). ARM64 startup/forwarding
и Remote Apply 1.7.11 этим не подтверждены; службы в transaction fixtures mock.

Вместо 724 встроенных доменов создаётся ссылка `domain_ip_lists` на
`https://raw.githubusercontent.com/Konglomeratovich/momen/main/assets/r1.lst`.
Каталог проверяется по SHA-256 до изменения пакетов. Локальные дополнения
сохраняются отдельно. `plex.tv` добавляется обязательно, даже если его нет
в исходном Podkop. Совокупность каталога и исключений покрывает все исходные
правила; дополнительные ручные домены не отбрасываются.

DNS, прокси и исключённые устройства берутся с мигрируемого роутера.
Tailscale и личные Mieru-подключения не копируются из чужой конфигурации.

## Почему используются две команды

Безопасная миграция не может быть полностью безусловным однострочником. Перед
удалением старых пакетов должна существовать проверенная копия rollback-набора
за пределами роутера. Скрипт способен проверить локальный комплект, но не может
доказать, что оператор действительно скопировал его на компьютер.

Поэтому workflow разделён на:

1. `--plan`: совместимость, расчёт места, загрузка и проверка rollback APK,
   создание конфигурационного backup;
2. ручное копирование rollback-каталога с роутера;
3. необязательный отдельный `--preflight`;
4. `--apply`, который ещё раз выполняет все неизменяющие проверки.

## Шаг 1. Plan и rollback-комплект

```sh
sh -c 'f=/tmp/momen-tachyon-bootstrap.$$; trap '\''rm -f "$f"'\'' EXIT; wget -q -T 30 -O "$f" https://raw.githubusercontent.com/Konglomeratovich/momen/main/scripts/bootstrap-podkop-to-tachyon.sh && echo "857d9cb58ebaa3c7e2c6ab75d7b9cf8338b08ba06246cee6093d7d766579bd79  $f" | sha256sum -c - && ash "$f" --plan'
```

Plan:

- проверяет точные версии и архитектуру;
- считает фактически свободное место overlay и `/tmp`, RAM и освобождаемый
  размер старого sing-box;
- скачивает точные APK Podkop, LuCI, перевода и исходного sing-box;
- сверяет SHA-256 каждого файла;
- сохраняет UCI, sing-box JSON, `/etc/apk/world` и внешний DIRECT-файл;
- запускает read-only readiness audit и миграционный plan;
- печатает `ROLLBACK_MANIFEST_SHA256` и `PLAN_OK=true`.

Plan пишет только временные проверочные файлы и rollback-набор в `/tmp`. Он не
меняет установленные пакеты, UCI, службы, nftables или policy routing.

## Шаг 2. Внешняя копия

Скопируйте весь каталог `/tmp/podkop-rollback` на компьютер через SCP, SFTP или
WinSCP. В каталоге должны находиться:

- `config-backup.tar.gz`;
- три APK Podkop/LuCI/перевода;
- исходный APK sing-box;
- `SHA256SUMS`.

Комплект содержит рабочие настройки и может содержать credentials. Его нельзя
публиковать в Git, облачном paste-сервисе или issue.

На Linux/WSL проверка скопированного каталога выполняется так:

```sh
cd podkop-rollback
sha256sum -c SHA256SUMS
```

## Шаг 3. Отдельный preflight

Команда ниже сверяет неизменность rollback manifest, создаёт приватную копию
UCI, запускает штатное преобразование Tachyon, сравнивает DIRECT-правила и
проверяет сгенерированный конфиг точным будущим ядром. Система не изменяется.

```sh
sh -c 'f=/tmp/momen-tachyon-bootstrap.$$; trap '\''rm -f "$f"'\'' EXIT; wget -q -T 30 -O "$f" https://raw.githubusercontent.com/Konglomeratovich/momen/main/scripts/bootstrap-podkop-to-tachyon.sh && echo "857d9cb58ebaa3c7e2c6ab75d7b9cf8338b08ba06246cee6093d7d766579bd79  $f" | sha256sum -c - && m="$(sha256sum /tmp/podkop-rollback/SHA256SUMS | awk '\''{print $1}'\'')" && ash "$f" --preflight --rollback-manifest-sha256 "$m" --confirm-backup COPIED-OFF-ROUTER'
```

Ожидаемый финальный маркер: `BOOTSTRAP_PREFLIGHT_OK=true`.

## Шаг 4. Apply

Запускайте только после успешного plan, внешней копии и проверки preflight:

```sh
sh -c 'f=/tmp/momen-tachyon-bootstrap.$$; trap '\''rm -f "$f"'\'' EXIT; wget -q -T 30 -O "$f" https://raw.githubusercontent.com/Konglomeratovich/momen/main/scripts/bootstrap-podkop-to-tachyon.sh && echo "857d9cb58ebaa3c7e2c6ab75d7b9cf8338b08ba06246cee6093d7d766579bd79  $f" | sha256sum -c - && m="$(sha256sum /tmp/podkop-rollback/SHA256SUMS | awk '\''{print $1}'\'')" && ash "$f" --apply --rollback-manifest-sha256 "$m" --confirm-backup COPIED-OFF-ROUTER --confirm MIGRATE-PODKOP-TO-TACHYON'
```

Apply повторяет readiness, plan и preflight. Затем он:

1. создаёт свежий snapshot в tmpfs;
2. устанавливает Tachyon без раннего первого запуска;
3. переносит настройки и DIRECT-каталог, включая добавленные вручную правила;
4. удаляет stale autostart state и возможные взаимные binary links;
5. устанавливает точную compressed-версию ядра;
6. запускает Tachyon и проверяет пакетное состояние, ядро, DNS, nftables и
   policy routing;
7. при любой ошибке после начала Apply автоматически восстанавливает исходные
   APK, конфигурацию, `/etc/apk/world` и Podkop.

Успешный финальный маркер: `BOOTSTRAP_MIGRATION_OK=true`.

## Повторный запуск

Если точный Tachyon и закреплённое ядро уже установлены, bootstrap не начинает
миграцию заново. Он проверяет версию ядра, службы, `TachyonTable` и policy rule
и возвращает:

```text
ALREADY_MIGRATED=true
IDEMPOTENT_HEALTHCHECK_OK=true
```

Смешанное состояние, при котором одновременно установлены Podkop и Tachyon,
считается ошибкой и автоматически не исправляется.

## Закреплённые SHA-256

```text
857d9cb58ebaa3c7e2c6ab75d7b9cf8338b08ba06246cee6093d7d766579bd79  scripts/bootstrap-podkop-to-tachyon.sh
172249a0b2f7a1fad639c5d2c551cdeca8638bbfd368a79f06a0cccb68ad3d45  scripts/audit-tachyon-readiness.sh
511737e5f1315fd6f7c764cf4486b7813ef4f330e4244bb2d4bc5dc0c5efb197  scripts/migrate-podkop-to-tachyon.sh
```

URL ветки `main` изменяемый. Для контролируемой волны развёртывания вместо
`main` следует использовать предварительно проверенный commit SHA и обновить
ожидаемый hash bootstrap только после повторных тестов.

## Границы локального тестирования

Сценарий проверен в официальном `openwrt/rootfs:x86_64-25.12.2` контейнере:

- fixture bootstrap: `PASS=15 FAIL=0`;
- readiness regression: `PASS=11 FAIL=0`;
- успешная mock-транзакция: `PASS=12 FAIL=0`;
- принудительный rollback: `PASS=11 FAIL=0`;
- реальная установка Tachyon и compressed-ядра:
  `ACTUAL_PACKAGE_AND_ENGINE_MIGRATION=PASS`.

Контейнер подтверждает APK/userspace, UCI migration, pinning и rollback-порядок,
но не эмулирует ядро конкретного ARM64-роутера, Wi-Fi, аппаратный offload или
реальный TProxy-трафик домашней сети. Именно поэтому Apply сохраняет финальные
health-check и автоматический rollback.
