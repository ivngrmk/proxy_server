# Proxy server

Небольшой HTTP CONNECT прокси на стандартной библиотеке Python.
Он создаёт TCP-туннели, в том числе для HTTPS, и не расшифровывает TLS.
Обычные HTTP-запросы без CONNECT не поддерживаются.

## Структура

```text
src/proxy_server.py                   Код прокси
deploy/systemd/proxy-server.service   Служба systemd
deploy/proxy-server.env.example       Пример настроек
scripts/install.sh                   Установка и обновление службы
scripts/uninstall.sh                 Удаление службы
tests/test_proxy.py                  Проверки соединений
```

## Развёртывание на VPS

Требуются Linux с systemd, Git, Bash, Python 3.9+ по пути `/usr/bin/python3`
и права root через `sudo`. Сторонних Python-зависимостей нет.

Подключитесь к VPS по SSH. Клонируйте репозиторий, перейдите в каталог проекта
и запустите установщик:

```bash
git clone https://github.com/ivngrmk/proxy_server.git
cd proxy_server
sudo bash scripts/install.sh
```

Установщик проверяет Python и синтаксис исходника, копирует код в
`/opt/proxy-server`, устанавливает службу и сразу запускает её.
Служба включается в автозапуск и перезапускается через 5 секунд после завершения процесса.
Работа не зависит от открытого SSH-сеанса.

Служба использует отдельного пользователя, которого выделяет systemd
через `DynamicUser=yes`. Каталог данных `/var/lib/proxy-server` создаётся
systemd и сохраняется между перезапусками. Код принадлежит root и доступен
службе только для чтения.

## Настройки

При первой установке создаётся `/etc/proxy-server.env`.
Повторная установка сохраняет этот файл.

```bash
sudo nano /etc/proxy-server.env
sudo systemctl restart proxy-server
```

| Переменная | Значение в службе | Назначение |
| --- | --- | --- |
| `PROXY_BIND_HOST` | `127.0.0.1` | Адрес прослушивания |
| `PROXY_BIND_PORT` | `18181` | TCP-порт |
| `PROXY_DIR` | `/var/lib/proxy-server` | Каталог данных, содержащий `logs/` |
| `PROXY_HEARTBEAT_SECONDS` | `180` | Интервал записи о работе, секунды |
| `PROXY_MAX_LOG_BYTES` | `1048576` | Порог сокращения журнала, байты |
| `PROXY_KEEP_LOG_BYTES` | `262144` | Сколько последних байтов сохранять |

Используйте положительные значения интервалов и размеров, порт от 1 до 65535,
а `PROXY_KEEP_LOG_BYTES` задавайте меньше `PROXY_MAX_LOG_BYTES`.
Файл настроек использует синтаксис systemd: `KEY=value`, без `export` и
подстановок shell. Путь `PROXY_DIR` согласован с `StateDirectory` службы;
для смены каталога нужно также изменить unit и разрешения на запись.

По умолчанию прокси доступен только на VPS. В нём нет авторизации:
публикация порта в интернете даст другим пользователям доступ к прокси.
Для доступа со своего компьютера можно открыть SSH-туннель:

```bash
ssh -N -L 18181:127.0.0.1:18181 user@VPS_IP
```

Пока туннель открыт, используйте HTTP-прокси `http://127.0.0.1:18181`.

## Управление

```bash
sudo systemctl status proxy-server --no-pager
sudo systemctl restart proxy-server
sudo systemctl stop proxy-server
sudo systemctl start proxy-server
```

Ошибки процесса доступны в journald, подключения и сообщения о работе — в файле:

```bash
sudo journalctl -u proxy-server -n 50 --no-pager
sudo tail -f /var/lib/proxy-server/logs/proxy.log
```

## Обновление и удаление

В каталоге клонированного репозитория получите изменения и повторно запустите установщик:

```bash
git pull --ff-only
sudo bash scripts/install.sh
```

Код и unit обновятся, настройки и журналы сохранятся. Служба перезапустится;
текущие соединения при этом закроются. При ошибке запуска смотрите `status`
и `journalctl`; установщик завершится с ошибкой и не выполняет откат.

Удаление службы и установленного кода:

```bash
sudo bash scripts/uninstall.sh
```

Настройки `/etc/proxy-server.env` и каталог данных `/var/lib/proxy-server`
остаются на сервере. Удалите их вручную, если они больше не нужны.

## Локальный запуск и проверки

Из корня проекта:

```bash
python src/proxy_server.py
python -m unittest discover -s tests -v
```

При прямом запуске настройки берутся из переменных окружения;
`/etc/proxy-server.env` автоматически не читается. По умолчанию журнал создаётся
в `src/logs/`. Пример локального запуска в PowerShell:

```powershell
$env:PROXY_BIND_PORT = "18181"
python src/proxy_server.py
```

Описание параметров службы: [systemd.service](https://freedesktop.org/software/systemd/man/latest/systemd.service.html),
[systemd.exec](https://freedesktop.org/software/systemd/man/latest/systemd.exec.html).
