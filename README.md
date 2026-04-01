# L2TP/IPsec VPN Server — Auto Installer

Bash-скрипт для автоматической установки и настройки L2TP/IPsec VPN сервера на Ubuntu 22.04 / 24.04.

## Быстрый старт

```bash
wget https://raw.githubusercontent.com/omichs/l2tp-isntaller/main/install2tpv3.sh && chmod +x install2tpv3.sh && sudo bash install2tpv3.sh
```

Или через `curl`:

```bash
curl -fsSL https://raw.githubusercontent.com/omichs/l2tp-isntaller/main/install2tpv3.sh | sudo bash
```

После завершения все данные подключения сохраняются в `/root/vpn-info.txt`.

---

## Что делает скрипт

- Устанавливает и настраивает **StrongSwan** (IPsec) + **xl2tpd** (L2TP) + **ppp**
- Генерирует случайный **Pre-Shared Key** и учётные записи пользователей
- Настраивает **iptables**: NAT, форвардинг, корректное закрытие порта 1701 за IPsec
- Включает **IP Forwarding** через `/etc/sysctl.d/`
- Сохраняет правила firewall через `netfilter-persistent`
- Проверяет статус сервисов после запуска

---

## Требования

| | |
|---|---|
| ОС | Ubuntu 22.04 / 24.04 |
| Права | root |
| Зависимости | устанавливаются автоматически |
| Порты | UDP 500, UDP 4500, ESP (протокол 50) |

---

## Настройка через переменные окружения

Параметры можно переопределить без редактирования скрипта:

```bash
VPN_USER_COUNT=10 \
VPN_LOCAL_IP=10.10.0.1 \
VPN_IP_RANGE=10.10.0.10-10.10.0.100 \
sudo -E bash install2tpv3.sh
```

| Переменная | По умолчанию | Описание |
|---|---|---|
| `VPN_USER_COUNT` | `5` | Количество создаваемых пользователей |
| `VPN_LOCAL_IP` | `192.168.42.1` | Локальный IP сервера в туннеле |
| `VPN_IP_RANGE` | `192.168.42.10-192.168.42.200` | Диапазон IP для клиентов |

---

## Совместимость клиентов

| Платформа | Статус |
|---|---|
| Windows 10 / 11 | ✅ |
| Android | ✅ |
| iOS / macOS | ✅ |
| Linux (`strongswan`, `networkmanager`) | ✅ |
| Windows 7 / 8 | ✅ |

### Windows: если не подключается

По умолчанию Windows ограничивает алгоритмы согласования. Добавьте ключ реестра:

```
HKLM\System\CurrentControlSet\Services\Rasman\Parameters
Тип:  DWORD
Имя:  NegotiateDH2048_AES256
Значение: 1
```

После этого перезагрузите компьютер.

---

## Добавление пользователей вручную

Откройте файл `/etc/ppp/chap-secrets` и добавьте строку:

```
username * "password" *
```

Перезапускать сервисы не нужно — файл читается при каждом подключении.

---

## Используемые пакеты

- [`strongswan`](https://www.strongswan.org/) — IPsec (IKEv1)
- [`xl2tpd`](https://github.com/xelerance/xl2tpd) — L2TP сервер
- `ppp` — PPP с аутентификацией MSCHAPv2
- `iptables-persistent` / `netfilter-persistent` — сохранение правил firewall

---

## Безопасность

- Порт **1701 (L2TP) не открыт** напрямую — принимается только внутри IPsec-туннеля
- Файлы `/etc/ipsec.secrets` и `/etc/ppp/chap-secrets` создаются с правами `600`
- PSK генерируется как 40-символьная случайная строка (`openssl rand -hex 20`)
- Данные подключения сохраняются в `/root/vpn-info.txt` с правами `600`

---

## Лицензия

MIT
