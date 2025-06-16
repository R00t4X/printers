#!/bin/bash
# set -euo pipefail   # ← эту строку можно раскомментировать для строгой обработки ошибок
IFS=$'\n\t'

############################################################
# 1. Основные переменные и настройки
############################################################
LOG_FILE="/var/log/printer_install.log"
TMP_DIR="/tmp/printer_install"
REQUIRED_UTILS=(wget apt-get lpadmin lpinfo lpstat lpoptions hp-setup lsusb 7z)
GROUPS_TO_ADD=(lp scanner camera)
PRINTER_KEYWORDS="Printer|HP|Brother|Canon|Epson|Kyocera|Katusha|Pantum|Lexmark|Samsung|Ricoh|Xerox|OKI|Sharp|Toshiba|Dell|Fujitsu|Konica|Minolta|Zebra|Citizen|Star|Olivetti|Sindoh|SATO|Seiko|TSC|Bixolon|Dymo|Intermec|Datamax|Honeywell|Printek|Tally|Dascom|Mutoh|Roland|Summa|Graphtec|Mimaki|Anycubic|Creality|Flashforge|Phrozen|QIDI|Raise3D|Wanhao|Artillery|Snapmaker|Prusa|Ultimaker|Formlabs|Peopoly|Elegoo|Voxelab|Kingroon|Anet|Geeetech|Tronxy|BIQU|Voron|Ender|LulzBot|XYZprinting|Monoprice|Kodak|Polaroid|Leapfrog|MakerBot|BCN3D|CraftBot|Zortrax|Tevo|JGAurora|Qidi"

############################################################
# 2. Логирование
############################################################
log_info() {
    echo "[ИНФО] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE"
}

log_error() {
    echo "[ОШИБКА] $(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG_FILE" >&2
}

log_solution() {
    echo "[РЕШЕНИЕ] $*" | tee -a "$LOG_FILE"
}

############################################################
# 3. Проверка прав и зависимостей
############################################################
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт нужно запускать от root."
        log_solution "Попробуйте: sudo ./print.sh"
        return 1
    fi
}

check_dependencies() {
    for util in "${REQUIRED_UTILS[@]}"; do
        if ! command -v "$util" &>/dev/null; then
            log_info "Не хватает $util, устанавливаю..."
            apt-get update >>"$LOG_FILE" 2>&1
            if ! apt-get install -y "$util" >>"$LOG_FILE" 2>&1; then
                log_error "Не удалось установить $util"
                log_solution "Проверьте интернет и репозитории. Можно попробовать: apt-get install $util"
                continue
            fi
        fi
    done
}

############################################################
# 4. Работа с группами пользователей
############################################################
add_user_groups() {
  local domain_group="domain users"
  if getent group "$domain_group" >/dev/null; then
    for grp in "${GROUPS_TO_ADD[@]}"; do
      if ! getent group "$grp" >/dev/null; then
        log_info "Создаю группу $grp."
        groupadd "$grp"
      fi
    done

    if command -v roleadd &>/dev/null; then
      for grp in "${GROUPS_TO_ADD[@]}"; do
        log_info "Добавляю группу '$domain_group' в $grp через roleadd."
        roleadd "$domain_group" "$grp" >>"$LOG_FILE" 2>&1
      done
    fi

    for grp in "${GROUPS_TO_ADD[@]}"; do
      log_info "Добавляю '$domain_group' в группу $grp."
      gpasswd -a "$domain_group" "$grp" >>"$LOG_FILE" 2>&1
    done

    local domain_users
    domain_users=$(getent group "$domain_group" | awk -F: '{print $4}' | tr ',' '\n' | tr -d ' ')

    for user in $domain_users; do
      user_lc=$(echo "$user" | tr '[:upper:]' '[:lower:]')
      [[ -z "$user_lc" || "$user_lc" == "$domain_group" ]] && continue
      for grp in "${GROUPS_TO_ADD[@]}"; do
        if ! id -nG "$user_lc" | grep -qw "$grp"; then
          log_info "Добавляю пользователя '$user_lc' в группу $grp."
          gpasswd -a "$user_lc" "$grp" >>"$LOG_FILE" 2>&1
        fi
      done
    done
  else
    log_info "Группа '$domain_group' не найдена, пропускаю добавление пользователей в группы."
  fi
}

############################################################
# 5. Удаление принтеров
############################################################
remove_printers() {
    local mode="$1"
    local printers
    printers=$(lpstat -v | awk '{print $3}' | sed 's/:$//')
    if [[ -z "$printers" ]]; then
        log_info "Нет принтеров для удаления."
        return
    fi
    for p in $printers; do
        if [[ "$mode" == "manual" ]]; then
            read -rp "Удалить принтер $p? [y/N]: " ans
            [[ "$ans" =~ ^[Yy]$ ]] || continue
        fi
        log_info "Удаляю принтер $p"
        lpadmin -x "$p" >>"$LOG_FILE" 2>&1 || log_error "Не удалось удалить принтер $p"
    done
}

############################################################
# 6. Поиск принтера по USB
############################################################
detect_printer() {
    local found
    found=$(lsusb | grep -E "$PRINTER_KEYWORDS" || true)
    if [[ -z "$found" ]]; then
        log_error "Принтер по USB не найден."
        log_solution "Проверьте подключение и питание принтера."
        return 1
    fi
    log_info "Обнаружены принтер(ы): $found"
}

############################################################
# 7. Установка драйверов
############################################################
install_from_ppd() {
    local ppd_file="$1"
    local mode="$2"
    local printer_name
    printer_name="printer_$(date +%s)"
    log_info "Устанавливаю принтер из PPD: $ppd_file"
    if [[ "$mode" == "manual" ]]; then
        read -rp "Установить принтер $printer_name с $ppd_file? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] || return
    fi
    if ! lpadmin -p "$printer_name" -E -v usb://$(lsusb | grep -E "$PRINTER_KEYWORDS" | head -n1 | awk '{print $6}') -P "$ppd_file" >>"$LOG_FILE" 2>&1; then
        log_error "Не удалось установить принтер $printer_name"
        log_solution "Проверьте PPD-файл и права. Можно попробовать вручную через lpadmin."
        return
    fi
    lpoptions -d "$printer_name" >>"$LOG_FILE" 2>&1
    log_info "Принтер $printer_name установлен и выбран по умолчанию."
    log_info "Отправляю пробную страницу на $printer_name"
    lp -d "$printer_name" /usr/share/cups/data/testprint >>"$LOG_FILE" 2>&1
    if [[ "$mode" == "manual" ]]; then
        read -rp "Отправить ещё одну тестовую страницу? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] && lp -d "$printer_name" /usr/share/cups/data/testprint >>"$LOG_FILE" 2>&1
    fi
}

install_from_hplip() {
    local script_file="$1"
    local mode="$2"
    log_info "Установка принтера через HPLIP-скрипт: $script_file"
    chmod +x "$script_file"
    if [[ "$mode" == "manual" ]]; then
        read -rp "Запустить $script_file? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] || return
    fi
    if [[ "$(basename "$script_file")" == "hp-install.sh" ]]; then
        if ! "$script_file" --auto-setup >>"$LOG_FILE" 2>&1; then
            log_error "Ошибка выполнения hp-install.sh"
            log_solution "Проверьте совместимость скрипта с системой и попробуйте вручную."
            return
        fi
        log_info "Запуск hp-setup (интерактивно)"
        hp-setup < /dev/tty > /dev/tty 2>&1
    else
        if ! "$script_file" --auto-setup >>"$LOG_FILE" 2>&1; then
            log_error "Ошибка выполнения HPLIP-скрипта"
            log_solution "Проверьте совместимость скрипта с системой и попробуйте вручную."
            return
        fi
    fi
    local last_printer
    last_printer=$(lpstat -p | awk '{print $2}' | tail -n1)
    if [[ -n "$last_printer" ]]; then
        lpoptions -d "$last_printer" >>"$LOG_FILE" 2>&1
        log_info "Принтер $last_printer выбран по умолчанию."
        log_info "Отправляю пробную страницу на $last_printer"
        lp -d "$last_printer" /usr/share/cups/data/testprint >>"$LOG_FILE" 2>&1
    fi
}

install_from_zip() {
    local zip_file="$1"
    local mode="$2"
    local printer_dir
    printer_dir="$(basename "$zip_file")"
    printer_dir="${printer_dir%%.*}"
    local unzip_dir="/tmp/${printer_dir}"
    log_info "Распаковываю архив: $zip_file в $unzip_dir"
    rm -rf "$unzip_dir"
    mkdir -p "$unzip_dir"

    case "$zip_file" in
        *.zip)
            if ! 7z x "$zip_file" -o"$unzip_dir" >>"$LOG_FILE" 2>&1; then
                log_error "Ошибка распаковки ZIP-архива $zip_file"
                log_solution "Проверьте архив и наличие 7z."
                return 1
            fi
            ;;
        *.tar.gz|*.tgz)
            if ! tar -xzf "$zip_file" -C "$unzip_dir" >>"$LOG_FILE" 2>&1; then
                log_error "Ошибка распаковки TAR.GZ-архива $zip_file"
                log_solution "Проверьте архив и наличие tar."
                return 1
            fi
            ;;
        *.tar)
            if ! tar -xf "$zip_file" -C "$unzip_dir" >>"$LOG_FILE" 2>&1; then
                log_error "Ошибка распаковки TAR-архива $zip_file"
                log_solution "Проверьте архив и наличие tar."
                return 1
            fi
            ;;
        *)
            if ! 7z x "$zip_file" -o"$unzip_dir" >>"$LOG_FILE" 2>&1; then
                log_error "Ошибка распаковки архива $zip_file неизвестного типа"
                log_solution "Проверьте архив и наличие 7z."
                return 1
            fi
            ;;
    esac

    log_info "Содержимое архива:"
    ls -lR "$unzip_dir" | tee -a "$LOG_FILE"
    local found_ppd found_sh
    found_ppd=$(find "$unzip_dir" -type f -name "*.ppd" | head -n1 || true)
    found_sh=$(find "$unzip_dir" -type f \( -name "*.sh" -o -name "*.run" \) | head -n1 || true)
    if [[ -n "$found_ppD" ]]; then
        install_from_ppD "$found_ppd" "$mode"
    elif [[ -n "$found_sh" ]]; then
        install_from_hplip "$found_sh" "$mode"
    else
        log_error "В архиве нет подходящих файлов для установки."
        log_solution "Проверьте архив: нужны .ppd, .sh или .run."
        return 1
    fi
}

############################################################
# 7. Основная логика работы скрипта
############################################################
main() {
    # Выводим информацию об АРМ через inxi -M
    echo "===== Информация об аппаратной платформе (inxi -M) ====="
    if command -v inxi &>/dev/null; then
        inxi -M
    else
        echo "Утилита inxi не установлена. Для подробной информации выполните: apt-get install inxi"
    fi
    echo "======================================================="
    sleep 2

    check_root || { log_solution "Запустите скрипт с правами root."; return 1; }

    mkdir -p "$TMP_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    local url mode file_ext file_path

    while true; do
        # Меню выбора режима
        if [[ $# -lt 1 ]]; then
            while true; do
                echo "========== МЕНЮ УСТАНОВКИ ПРИНТЕРА =========="
                echo "1) Автоматически (по ссылке)"
                echo "2) Ручной выбор типа установки"
                echo "0) Выйти"
                read -rp "Выберите действие: " main_choice
                case "$main_choice" in
                    1)
                        read -rp "Введите ссылку на драйвер: " url
                        mode="auto"
                        break
                        ;;
                    2)
                        while true; do
                            echo "----- Выберите тип установки -----"
                            echo "1) PPD-файл"
                            echo "2) SH/RUN-скрипт"
                            echo "3) ZIP-архив"
                            echo "0) Назад"
                            read -rp "Ваш выбор: " type_choice
                            case "$type_choice" in
                                1) file_ext="ppd";;
                                2) file_ext="sh";;
                                3) file_ext="zip";;
                                0) continue 2;;
                                *) echo "Некорректный выбор"; continue;;
                            esac
                            read -rp "Введите ссылку на файл: " url
                            mode="manual"
                            break 2
                        done
                        ;;
                    0)
                        echo "Выход."
                        exit 0
                        ;;
                    *)
                        echo "Некорректный выбор"
                        ;;
                esac
            done
            if [[ "$mode" == "manual" && -n "$file_ext" ]]; then
                file_path="$TMP_DIR/driver.$file_ext"
            fi
        else
            url="$1"
            mode="${2:-auto}"
            if [[ "$mode" != "auto" && "$mode" != "manual" ]]; then
                log_error "Режим должен быть 'auto' или 'manual'"
                log_solution "Укажите режим: auto (автоматически) или manual (с подтверждением действий)."
                continue
            fi
        fi

        check_dependencies
        # Установка rastertokpsl-re для Kyocera (по инструкции)
        if [[ "$url" =~ [Kk]yocera ]]; then
            if dpkg -s rastertokpsl-re &>/dev/null; then
                log_info "rastertokpsl-re уже установлен"
            else
                if apt-get install -y rastertokpsl-re >>"$LOG_FILE" 2>&1; then
                    log_info "rastertokpsl-re установлен"
                else
                    log_error "rastertokpsl-re не установлен"
                fi
            fi
        fi
        if [[ "$url" =~ [Cc]anon ]]; then
            # Проверка наличия нужного репозитория
            local canon_repo_found=0
            if command -v apt-repo &>/dev/null; then
                repo_out=$(apt-repo 2>/dev/null)
                if echo "$repo_out" | grep -q "http://repo.proc.ru/mirror c10f1/branch/x86_64-i586 classic"; then
                    canon_repo_found=1
                    log_info "Репозиторий Canon уже добавлен"
                fi
            fi
            if [[ $canon_repo_found -eq 0 ]]; then
                log_info "Добавляю репозиторий Canon: rpm [cert8] http://repo.proc.ru/mirror c10f1/branch/x86_64-i586 classic"
                apt-repo add "rpm [cert8] http://repo.proc.ru/mirror c10f1/branch/x86_64-i586 classic" >>"$LOG_FILE" 2>&1
                apt-get update >>"$LOG_FILE" 2>&1
            fi
            # Проверка и установка пакетов
            if dpkg -s canon-printer-drivers &>/dev/null && dpkg -s cnijfilter2 &>/dev/null; then
                log_info "canon-printer-drivers и cnijfilter2 уже установлены"
            else
                if apt-get install -y canon-printer-drivers cnijfilter2 >>"$LOG_FILE" 2>&1; then
                    log_info "canon-printer-drivers и cnijfilter2 установлены"
                else
                    log_error "canon-printer-drivers или cnijfilter2 не установлены"
                fi
            fi
        fi
        # add_user_groups   # ← закомментировано на время тестов

        if [[ "$mode" == "auto" ]]; then
            remove_printers "auto"
        else
            remove_printers "manual"
        fi

        # Новый запрос на удаление принтеров
        local remove_choice
        echo "Хотите удалить установленные в системе принтеры? [y/N]"
        read -r remove_choice
        if [[ "$remove_choice" =~ ^[Yy]$ ]]; then
            remove_printers "manual"
        fi

        # Новый интерактивный этап проверки подключения принтера
        local printer_confirmed=0
        for attempt in {1..10}; do
            clear
            echo "===== Проверка подключения принтера ====="
            echo "Текущее состояние USB-устройств:"
            lsusb | awk '{printf "%-10s %-40s %-40s\n", $2, $6, substr($0, index($0,$7))}'
            echo
            if detect_printer; then
                printer_confirmed=1
                break
            fi
            echo "Принтер не обнаружен. Автоматическая повторная проверка через: "
            for t in {3..1}; do
                echo -ne "$t\033[0K\r"
                sleep 1
            done
        done

        if [[ $printer_confirmed -ne 1 ]]; then
            # После 10 попыток — ручной запрос пользователю
            while true; do
                clear
                echo "===== Проверка подключения принтера (ручной режим) ====="
                echo "Текущее состояние USB-устройств:"
                lsusb | awk '{printf "%-10s %-40s %-40s\n", $2, $6, substr($0, index($0,$7))}'
                echo
                read -rp "Подключен ли нужный принтер? [y/N]: " usb_ans
                if [[ "$usb_ans" =~ ^[Yy]$ ]]; then
                    if detect_printer; then
                        break
                    else
                        echo "Принтер не обнаружен системой. Проверьте кабель и питание."
                        sleep 2
                    fi
                else
                    echo -n "Повторная проверка через: "
                    for t in {3..1}; do
                        echo -ne "$t\033[0K\r"
                        sleep 1
                    done
                fi
            done
        fi

        if [[ -z "$file_ext" ]]; then
            file_ext="${url##*.}"
            file_path="$TMP_DIR/driver.$file_ext"
        fi

        log_info "Скачиваю драйвер с $url"
        if ! wget -O "$file_path" "$url" >>"$LOG_FILE" 2>&1; then
            log_error "Не удалось скачать файл с $url"
            log_solution "Проверьте корректность URL и доступность файла. Попробуйте скачать вручную."
            continue
        fi

        case "$file_ext" in
            ppd)
                install_from_ppd "$file_path" "$mode" || continue
                ;;
            sh|run)
                install_from_hplip "$file_path" "$mode" || continue
                ;;
            zip)
                install_from_zip "$file_path" "$mode" || continue
                ;;
            *)
                log_error "Неподдерживаемое расширение файла: $file_ext"
                log_solution "Поддерживаются расширения: ppd, sh, run, zip."
                continue
                ;;
        esac

        log_info "Установка принтера завершена."
        # После успешной попытки спрашиваем, повторить ли установку
        echo "Хотите выполнить ещё одну установку? [y/N]"
        read -r again
        [[ "$again" =~ ^[Yy]$ ]] || break
        # Очистка переменных для новой итерации
        url=""; mode=""; file_ext=""; file_path=""
    done

    # Меню выбора принтера для установки по умолчанию и тестовой печати
    local printers printer_names printer_count printer_default
    printers=$(lpstat -p | awk '{print $2}')
    if [[ -n "$printers" ]]; then
        echo "Выберите принтер, который нужно сделать по умолчанию и отправить пробную страницу:"
        select printer_default in $printers "Пропустить"; do
            if [[ "$printer_default" == "Пропустить" || -z "$printer_default" ]]; then
                echo "Действие пропущено."
                break
            elif [[ -n "$printer_default" ]]; then
                lpoptions -d "$printer_default" >>"$LOG_FILE" 2>&1
                log_info "Принтер $printer_default выбран по умолчанию."
                log_info "Отправляю пробную страницу на $printer_default"
                lp -d "$printer_default" /usr/share/cups/data/testprint >>"$LOG_FILE" 2>&1
                break
            else
                echo "Некорректный выбор."
            fi
        done
    fi
}

############################################################
# 8. Точка входа
############################################################
main "$@"