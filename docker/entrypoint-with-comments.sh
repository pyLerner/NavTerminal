#!/bin/env bash

# set -e: Скрипт немедленно завершится, если любая команда вернет ошибку.
# Это гарантирует, что мы не продолжим работу при критическом сбое системы.
set -e

# Описываем функцию cleanup, которая сработает при выключении контейнера (docker stop).
cleanup() {
    echo "$(date -Iseconds) [INFO] Trapped SIGTERM. Stopping all processes..."
    # kill $(jobs -p): Находит PID всех фоновых процессов (&) и отправляет им сигнал завершения.
    # || true: Если процессов нет, команда не вызовет ошибку скрипта.
    kill $(jobs -p) 2>/dev/null || true
    # wait: Дожидается полной остановки приложений, чтобы Docker корректно закрыл контейнер.
    wait
    echo "$(date -Iseconds) [INFO] All processes stopped. Exiting."
    exit 0
}

# trap: "Слушает" системные сигналы SIGTERM и SIGINT (остановка контейнера).
# Как только сигнал придет, запустится функция cleanup.
trap cleanup SIGTERM SIGINT

# ==========================================
# 1. ЗАПУСК FASTAPI
# ==========================================
echo "$(date -Iseconds) [INFO] Starting NavAPI app..."
# Запускаем бинарник FastAPI. 
# &: Отправляем в фоновый режим, чтобы скрипт мог идти дальше и запускать Go.
/app/NavAPIServer/bin/naviapiserv.bin \
    --config /data/NavAPIServer/etc/navapiserv-config.toml &

# ==========================================
# 2. ПОДГОТОВКА К ЗАПУСКУ GO
# ==========================================

# shopt -s nullglob: Если файлов *.toml нет, bash вернет пустой список вместо строки "*.toml".
shopt -s nullglob
# Создаем массив configs, в который попадают все пути к найденным конфигам.
configs=(/data/NDTPClient/etc/*.toml)
# Выключаем nullglob, чтобы не влиять на остальной скрипт.
shopt -u nullglob

# Проверяем длину массива. Если файлов нет (0), пишем предупреждение.
if [ ${#configs[@]} -eq 0 ]; then
    echo "$(date -Iseconds) [WARNING] No .toml config files found in /data/NDTPClient/etc/."
    echo "$(date -Iseconds) [WARNING] Go NDTP_Client will NOT be started."
else
    echo "$(date -Iseconds) [INFO] Found ${#configs[@]} config file(s). Validating..."
    
    # Перебираем каждый найденный конфиг по очереди.
    for conf in "${configs[@]}"; do
        echo "----------------------------------------"
        echo "$(date -Iseconds) [INFO] Processing config: $conf"
        
        # AWK: Магия поиска секции. 
        # Находим [NDTP], включаем флаг (flag=1). Доходим до следующей '[' - выключаем флаг.
        # В переменную NDTP_SECTION попадет только текст внутри блока [NDTP].
        NDTP_SECTION=$(awk '/^\[NDTP\]/{flag=1;next}/^\[/{flag=0}flag' "$conf")
        
        # Из вырезанного блока достаем Host: ищем строку, берем значение после '=', удаляем кавычки и пробелы.
        HOST=$(echo "$NDTP_SECTION" | grep -i '^[[:space:]]*Host[[:space:]]*=' | head -n 1 | awk -F'=' '{print $2}' | tr -d ' "')
        # То же самое делаем для Port.
        PORT=$(echo "$NDTP_SECTION" | grep -i '^[[:space:]]*Port[[:space:]]*=' | head -n 1 | awk -F'=' '{print $2}' | tr -d ' "')
        
        # Если Host или Port пустые (не нашлись в секции [NDTP]).
        if [ -z "$HOST" ] || [ -z "$PORT" ]; then
            echo "$(date -Iseconds) [ERROR] Could not parse Host or Port inside [NDTP] section of $conf. Skipping."
            continue # Переходим к следующему файлу конфига.
        fi
        
        echo "$(date -Iseconds) [INFO] Extracted NDTP target $HOST:$PORT. Checking connection..."
        
        # Проверка связи через виртуальное устройство /dev/tcp.
        # timeout 3: Если сервер не ответит за 3 сек, команда прервется.
        # cat < /dev/tcp/host/port: Пытается открыть "трубу" к серверу. Если порт открыт - успех.
        if timeout 3 bash -c "cat < /dev/tcp/$HOST/$PORT" >/dev/null 2>&1; then
            echo "$(date -Iseconds) [INFO] Connection to $HOST:$PORT is OK. Starting NDTP_Client..."
            # Если связь есть, запускаем клиент для этого конфига в фоне (&).
            /app/NDTPClient/bin/NDTP_Client --config "$conf" &
        else
            # Если связи нет, просто пишем ошибку и НЕ запускаем этот экземпляр.
            echo "$(date -Iseconds) [ERROR] Cannot reach server at $HOST:$PORT. Skipping this config."
        fi
    done
fi

echo "----------------------------------------"
echo "$(date -Iseconds) [INFO] All startup checks completed. Monitoring processes."

# ==========================================
# 3. ФИНАЛ
# ==========================================
# wait без аргументов заставляет entrypoint.sh "зависнуть" и ждать, пока работают фоновые процессы.
# Если FastAPI и запущенные Go-клиенты работают, контейнер будет в статусе Running.
wait
