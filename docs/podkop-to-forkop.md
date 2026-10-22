# Миграция Podkop 0.7.22 на Forkop 1.0.5

Скрипт `migrate-podkop-to-forkop.sh` предназначен для узкого, проверяемого
сценария: OpenWrt 25.12.2 с пакетным менеджером `apk`, Podkop 0.7.22 и каталог
DIRECT, ранее установленный командой `install.sh --configure-all` из этого
репозитория. Другие версии отклоняются до изменений.

Исходные проекты и закреплённые релизы:

- [Podkop](https://github.com/itdoginfo/podkop), [релиз 0.7.22](https://github.com/itdoginfo/podkop/releases/tag/0.7.22);
- [Forkop](https://github.com/ushan0v/forkop), [релиз 1.0.5](https://github.com/ushan0v/forkop/releases/tag/1.0.5);
- [momen](https://github.com/Konglomeratovich/momen).

## Что переносится

- proxy- или VPN-секция Podkop, включая ссылку подключения;
- тип DNS, DNS-сервер и bootstrap DNS;
- настройка загрузки списков через выбранную секцию подключения;
- секция DIRECT: 720 доменов в UCI и четыре Punycode TLD из
  `/etc/momen-r1-cyrillic-tlds.lst`;
- прежнее состояние автозапуска и запуска сервиса.

Действующий `/etc/config/podkop` не редактируется как источник: до переключения
он попадает в backup, затем копируется в `/etc/config/forkop`, и уже копия
преобразуется штатным мигратором Forkop. Удаление пакетов Podkop разрешается
только после проверки перенесённых значений и временного запуска Forkop.

Также сценарий устанавливает шесть согласованных пакетов OpenWrt:

| Пакет | Назначение |
| --- | --- |
| `kmod-gre` | Поддержка GRE protocol 47, по которому PPTP передаёт PPP-трафик |
| `kmod-pptp` | Поддержка PPTP в ядре OpenWrt |
| `ppp-mod-pptp` | Модуль PPTP для PPP и его MPPE/криптографические зависимости |
| `kmod-nf-nathelper` | Базовые Netfilter connection-tracking/NAT helpers |
| `kmod-nf-nathelper-extra` | Дополнительные helpers, включая `nf_conntrack_pptp` и `nf_nat_pptp` |
| `tcpdump` | Диагностика и перехват пакетов; для работы PPTP сам по себе не нужен |

Эквивалентные команды при ручной установке:

```sh
apk add kmod-gre
apk add kmod-pptp
apk add ppp-mod-pptp
apk add kmod-nf-nathelper
apk add kmod-nf-nathelper-extra
apk add tcpdump
```

Проверяемый однострочник для отдельной установки этих пакетов на OpenWrt 25:

```sh
sh -c 'set -eu; p="kmod-gre kmod-pptp ppp-mod-pptp kmod-nf-nathelper kmod-nf-nathelper-extra tcpdump"; m="gre ip_gre nf_conntrack_pptp nf_nat_pptp pptp pppox ppp_generic"; echo "До установки:"; for x in $p; do apk info -e "$x" >/dev/null 2>&1 && echo "  есть $x" || echo "  нет $x"; done; apk add --simulate $p >/dev/null; apk add $p; for x in $p; do apk info -e "$x" >/dev/null || { echo "Не установлен: $x" >&2; exit 1; }; done; for x in $m; do modprobe "$x"; done; l="$(lsmod)"; for x in $m; do printf "%s\n" "$l" | grep -q "^$x[[:space:]]" || { echo "Не загружен модуль: $x" >&2; exit 1; }; done; echo "После установки:"; printf "%s\n" "$l" | grep -E "^(gre|ip_gre|nf_conntrack_pptp|nf_nat_pptp|pptp|pppox|ppp_generic)[[:space:]]"; echo "PPTP_GRE_PACKAGES=passed"'
```

После установки скрипт загружает и проверяет модули `gre`, `ip_gre`,
`nf_conntrack_pptp`, `nf_nat_pptp`, `pptp`, `pppox` и `ppp_generic`. Ранее без
этих модулей роутер отвечал на входящий GRE сообщением
`ICMP protocol 47 unreachable`; после установки и перезагрузки ответ исчез.

Forkop сам преобразует старую схему: proxy/VPN становится
`action=connection`, Exclusion становится `action=bypass`, одиночные значения
DNS становятся списками. Секретная ссылка подключения не печатается в лог.

Название `common.dot.dns.yandex.net` не означает, что выбран DNS-over-TLS.
Это имя сервера Яндекса; транспорт определяется отдельным UCI-параметром
`dns_type`. Скрипт допускает миграцию только при `dns_type=doh` и после неё
повторно проверяет именно DoH.

## Автоматический запуск

```sh
sh -c 'f=/tmp/momen-forkop.$$; wget -q -T 20 -O "$f" https://raw.githubusercontent.com/Konglomeratovich/momen/main/migrate-podkop-to-forkop.sh && ash "$f" --apply; rc=$?; rm -f "$f"; exit $rc'
```

URL с `main` изменяемый. Для контролируемой установки замените `main` на
проверенный тег или полный commit SHA.

`--apply` автоматически выполняет:

1. Совместимость и аудит исходной конфигурации без изменений.
2. Загрузку APK обоих продуктов и проверку закреплённых SHA-256.
3. `apk add --simulate` для Forkop и `apk del --simulate` для Podkop.
4. `apk add --simulate` для шести пакетов PPTP/GRE.
5. Backup и установку с проверкой пакетов и модулей PPTP/GRE.
6. Остановку Podkop и восстановление его изменений dnsmasq.
7. Установку Forkop, перенос UCI и штатную миграцию схемы из Forkop.
8. Проверку DNS, секций подключения, всех 724 правил и состояния backend.
9. Удаление пакетов Podkop только после успешной проверки Forkop.

Повторный `--apply` не переустанавливает уже проверенный Forkop, а выполняет
проверку завершённой миграции.

## Предварительная проверка без изменений

Загрузите скрипт во временный файл и сначала выполните два режима:

```sh
f=/tmp/momen-forkop-audit.sh
wget -q -T 20 -O "$f" https://raw.githubusercontent.com/Konglomeratovich/momen/main/migrate-podkop-to-forkop.sh
ash "$f" --audit
ash "$f" --plan
rm -f "$f"
```

`--audit` только читает состояние. `--plan` дополнительно скачивает APK во
временный каталог, проверяет их и запускает обе симуляции `apk`; постоянные
файлы и пакеты не меняются.

## Backup и rollback

Перед первым изменением создаётся каталог вида:

```text
/root/momen-podkop-to-forkop-YYYYMMDD-HHMMSS
```

Он имеет права `0700`, его файлы — `0600`. В backup входят точные APK Podkop
0.7.22 для обратной установки, снимок конфигурации и файлов Podkop, конфигурация
dnsmasq, список установленных пакетов, состояние сервиса и SHA-256 архива.
Backup остаётся только на роутере и не отправляется наружу.

После успешной миграции скрипт печатает точную команду rollback. Пример:

```sh
ash /tmp/migrate-podkop-to-forkop.sh --rollback /root/momen-podkop-to-forkop-YYYYMMDD-HHMMSS
```

Если временный скрипт уже удалён, сначала снова загрузите ту же проверенную
версию, затем передайте ей `--rollback` и путь, напечатанный при миграции.
Rollback останавливает и удаляет Forkop, устанавливает закреплённые APK Podkop,
проверяет SHA-256 снимка, восстанавливает файлы и прежнее состояние сервиса.
Пакеты PPTP/GRE, существовавшие до миграции, сохраняются. Из этой группы
удаляются только пакеты, которые установил сам сценарий.

Backup содержит рабочую конфигурацию подключения. Не публикуйте его и удаляйте
только после ручной проверки стабильной работы Forkop.

## Проверка результата

```sh
ash /tmp/migrate-podkop-to-forkop.sh --verify
```

Успех обозначается строкой `VERIFY_RESULT=passed`. Скрипт проверяет отсутствие
пакетов Podkop, наличие пакетов и backend Forkop, DNS, DIRECT, путь TLD-списка и
секцию, через которую скачиваются списки, а также PPTP/GRE-пакеты и модули.

## Границы локальных тестов

В репозитории есть offline-тесты audit/plan/apply/verify/rollback, ошибки хеша,
неподдерживаемых версий и автоматического восстановления. Дополнительно
проверяются реальные APK и штатный модуль миграции Forkop в официальном rootfs
OpenWrt 25.12.2. Контейнерная проверка не заменяет запуск на конкретном роутере:
драйверы, свободное место, реальный proxy/VPN и сеть проверяются самим скриптом
перед удалением Podkop.
