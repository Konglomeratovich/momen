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
