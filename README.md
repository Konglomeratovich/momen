# momen

Публичный канал доставки проверенного установщика DIRECT-политики для Podkop.

## Quick Start

По умолчанию используется Podkop-секция `main` типа `proxy` или `vpn`:

```sh
sh -c 'f=/tmp/momen-install.$$; wget -q -T 20 -O "$f" https://raw.githubusercontent.com/Konglomeratovich/momen/main/install.sh && ash "$f" --configure-all; rc=$?; rm -f "$f"; exit $rc'
```

Другая proxy/VPN-секция:

```sh
sh -c 'f=/tmp/momen-install.$$; wget -q -T 20 -O "$f" https://raw.githubusercontent.com/Konglomeratovich/momen/main/install.sh && ash "$f" --configure-all --download-proxy-section NAME; rc=$?; rm -f "$f"; exit $rc'
```

Скрипт принимает только проверенные Podkop `0.7.0`–`0.7.22` (также фирменную запись `v0.7.x` после строгой нормализации одного префикса), требует OpenWrt 24.10 или новее либо совместимую прошивку с точным `ID=openwrt` в `/etc/os-release`. Требование к месту вычисляется по размерам установленного Podkop и UCI-конфига: консервативная оценка записи плюс обязательный остаток 12 MiB. RouteRich 24.10.5 с Podkop `v0.7.22` проверен отдельной runtime-фикстурой. Более старые и будущие версии отклоняются до изменений с понятным сообщением. Перед изменениями проверяются HTTPS-загрузка каталога, SHA-256 и его содержимое. Создаются резервные копии, после применения выполняются `podkop reload`, ожидание, проверка sing-box, UCI, сгенерированного JSON и DNS.

Контрольный снимок прежнего `Russia outside` проверяется в закрытом build-процессе Vless и не встраивается plaintext в публичный `install.sh`. На роутере целостность единого каталога подтверждается закреплённым SHA-256 и ожидаемым числом правил. Из 724 правил 720 сохраняются в текстовом поле LuCI, а четыре кириллические Punycode-зоны — в `/etc/momen-r1-cyrillic-tlds.lst`, поскольку валидатор LuCI Podkop 0.7.22 не принимает одноуровневые TLD.

URL ветки `main` удобен для массовой установки, но является изменяемым. Для контролируемой волны развёртывания лучше заменить `main` в URL на заранее проверенный тег или commit SHA.

## Переход с Podkop на Forkop

Для OpenWrt 25.12.2 с `apk`, Podkop 0.7.22 и конфигурации, ранее подготовленной
этим репозиторием через `install.sh --configure-all`, доступна автоматическая
миграция на Forkop 1.0.5:

```sh
sh -c 'f=/tmp/momen-forkop.$$; wget -q -T 20 -O "$f" https://raw.githubusercontent.com/Konglomeratovich/momen/main/migrate-podkop-to-forkop.sh && ash "$f" --apply; rc=$?; rm -f "$f"; exit $rc'
```

Однострочник сам выполняет audit и план с `apk --simulate`, проверяет SHA-256
закреплённых APK, создаёт backup на роутере, переносит DNS, proxy/VPN-секцию и
724 правила DIRECT, сохраняет установленный `sing-box` как движок Forkop,
запускает и проверяет Forkop. Пакеты Podkop удаляются только
после успешной проверки Forkop. При ошибке после начала изменений запускается
автоматический rollback; backup не удаляется.

В тот же сценарий включена идемпотентная установка PPTP/GRE-поддержки:
`kmod-gre`, `kmod-pptp`, `ppp-mod-pptp`, `kmod-nf-nathelper`,
`kmod-nf-nathelper-extra` и диагностического `tcpdump`. Проверяются пакеты и
модули ядра. Rollback сохраняет пакеты, которые присутствовали до миграции, и
удаляет только добавленные самим скриптом.

До запуска на важном роутере рекомендуется отдельно прочитать
[подробную инструкцию](docs/podkop-to-forkop.md). Там приведены режимы только
для аудита и плана, состав backup, проверки результата и явная команда rollback.

Проекты:

- [Podkop](https://github.com/itdoginfo/podkop);
- [Forkop](https://github.com/ushan0v/forkop);
- [momen](https://github.com/Konglomeratovich/momen).

## HAPP

Каталог `happ/` содержит воспроизводимую сборку общей политики маршрутизации для
кроссплатформенного клиента HAPP:

- `happ/artifacts/happ-routing.json` — читаемый профиль маршрутизации;
- `happ/artifacts/happ-routing-link.txt` — импорт-ссылка
  `happ://routing/onadd/...`, которую можно скопировать в HAPP;
- `happ/data/momen-direct` — те же 724 DIRECT-домена, что находятся в
  `assets/r1.gz`, в формате domain-list-community;
- `happ/artifacts/manifest.json` — контрольные количества и SHA-256.

GitHub Actions собирает полный `momen-geosite.dat`, проверяет наличие категории
`geosite:momen-direct` и публикует файл вместе с профилем в GitHub Releases.
Стабильные адреса:

```text
https://github.com/Konglomeratovich/momen/releases/latest/download/momen-geosite.dat
https://github.com/Konglomeratovich/momen/releases/latest/download/happ-routing.json
https://github.com/Konglomeratovich/momen/releases/latest/download/happ-routing-link.txt
```

Персональные VLESS/XHTTP-ссылки в репозиторий не входят. Сначала пользователь
импортирует своё подключение в HAPP, затем импортирует общий routing-профиль из
текстового файла. Политика использует DIRECT по умолчанию, отдельную категорию
`momen-direct` для российских чувствительных сервисов и явный список сервисов,
которые должны идти через выбранное VPN-подключение.

Локальная проверка:

```sh
python happ/build.py
python -m unittest discover -s happ -p 'test_*.py'
ash tests/test-migrate-podkop-to-forkop.sh
```

`momen-geosite.dat` строится официальным компилятором
[`v2fly/domain-list-community`](https://github.com/v2fly/domain-list-community).
