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

Скрипт принимает только проверенные Podkop `0.7.0`–`0.7.22`, требует OpenWrt 24.10 или новее и не менее 25 MiB свободного места. Более старые и будущие версии отклоняются до изменений с понятным сообщением. Перед изменениями проверяются HTTPS-загрузка каталога, SHA-256 и его содержимое. Создаются резервные копии, после применения выполняются `podkop reload`, ожидание, проверка sing-box, UCI, сгенерированного JSON и DNS.

URL ветки `main` удобен для массовой установки, но является изменяемым. Для контролируемой волны развёртывания лучше заменить `main` в URL на заранее проверенный тег или commit SHA.
