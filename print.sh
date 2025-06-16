#!/bin/bash
# set -euo pipefail   # ← закомментируйте или удалите эту строку
IFS=$'\n\t'

############################################################
# 1. Константы и переменные
############################################################
LOG_FILE="/var/log/printer_install.log"
TMP_DIR="/tmp/printer_install"
REQUIRED_UTILS=(wget apt-get lpadmin lpinfo lpstat lpoptions hp-setup lsusb 7z)
GROUPS_TO_ADD=(lp scanner camera)
PRINTER_KEYWORDS="Printer|HP|Brother|Canon|Epson|Kyocera|Katusha|Pantum|Lexmark|Samsung|Ricoh|Xerox|OKI|Sharp|Toshiba|Dell|Fujitsu|Konica|Minolta|Zebra|Citizen|Star|Olivetti|Sindoh|SATO|Seiko|TSC|Bixolon|Dymo|Intermec|Datamax|Honeywell|Printek|Tally|Dascom|Mutoh|Roland|Summa|Graphtec|Mimaki|Anycubic|Creality|Flashforge|Phrozen|QIDI|Raise3D|Wanhao|Artillery|Snapmaker|Prusa|Ultimaker|Formlabs|Peopoly|Elegoo|Voxelab|Kingroon|Anet|Geeetech|Tronxy|BIQU|Voron|Ender|LulzBot|XYZprinting|Monoprice|Kodak|Polaroid|Leapfrog|MakerBot|BCN3D|CraftBot|Zortrax|Tevo|JGAurora|Qidi"

############################################################
# 2. Логирование и вывод сообщений
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
# 3. Проверки окружения и зависимостей
############################################################
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "Скрипт должен быть запущен от root."
        log_solution "Запустите скрипт от имени пользователя root (например: su -c './main.sh ...')."
        return 1
    fi
}

check_dependencies() {
    for util in "${REQUIRED_UTILS[@]}"; do
        if ! command -v "$util" &>/dev/null; then
            log_info "Устанавливаю отсутствующую утилиту: $util"
            apt-get update >>"$LOG_FILE" 2>&1
            if ! apt-get install -y "$util" >>"$LOG_FILE" 2>&1; then
                log_error "Не удалось установить $util"
                log_solution "Проверьте подключение к интернету и наличие репозиториев. Установите $util вручную: apt-get install $util"
                # continue вместо exit
                continue
            fi
        fi
    done
}

############################################################
# 4. Работа с группами пользователей
############################################################
add_user_groups() {
    if getent group "domain users" >/dev/null; then
        for grp in "${GROUPS_TO_ADD[@]}"; do
            if ! getent group "$grp" >/dev/null; then
                log_info "Группа $grp не существует, создаю."
                groupadd "$grp"
            fi
            if ! id -nG "domain users" | grep -qw "$grp"; then
                log_info "Добавляю 'domain users' в группу $grp"
                gpasswd -a "domain users" "$grp" >>"$LOG_FILE" 2>&1
            fi
        done
    else
        log_info "Группа 'domain users' не найдена, пропускаю добавление в группы."
    fi
}

############################################################
# 5. Управление принтерами
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

detect_printer() {
    local found
    found=$(lsusb | grep -E "$PRINTER_KEYWORDS" || true)
    if [[ -z "$found" ]]; then
        log_error "Поддерживаемый принтер через USB не обнаружен."
        log_solution "Убедитесь, что принтер подключён и включён. Проверьте кабель и повторите попытку."
        return 1
    fi
    log_info "Обнаружены принтер(ы): $found"
}

############################################################
# 6. Установка драйверов принтера
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
        log_solution "Проверьте корректность PPD-файла и наличие прав. Попробуйте установить вручную через lpadmin."
        return
    fi
    lpoptions -d "$printer_name" >>"$LOG_FILE" 2>&1
    log_info "Принтер $printer_name установлен и выбран по умолчанию."
    if [[ "$mode" == "manual" ]]; then
        read -rp "Отправить тестовую страницу? [y/N]: " ans
        [[ "$ans" =~ ^[Yy]$ ]] || return
    fi
    if ! lp -d "$printer_name" /usr/share/cups/data/testprint >>"$LOG_FILE" 2>&1; then
        log_error "Ошибка тестовой печати"
        log_solution "Проверьте подключение принтера и корректность драйвера."
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
    if ! "$script_file" --auto-setup >>"$LOG_FILE" 2>&1; then
        log_error "Ошибка выполнения HPLIP-скрипта"
        log_solution "Проверьте совместимость скрипта с вашей системой и выполните его вручную для диагностики."
    fi
}

install_from_zip() {
    local zip_file="$1"
    local mode="$2"
    log_info "Распаковываю ZIP: $zip_file"
    if ! 7z x "$zip_file" -o"$TMP_DIR/unzipped" >>"$LOG_FILE" 2>&1; then
        log_error "Ошибка распаковки архива $zip_file"
        log_solution "Проверьте целостность архива и наличие утилиты 7z."
        return 1
    fi
    log_info "Содержимое распакованного архива:"
    ls -lR "$TMP_DIR/unzipped" | tee -a "$LOG_FILE"
    local found_ppd found_sh
    found_ppd=$(find "$TMP_DIR/unzipped" -type f -name "*.ppd" | head -n1 || true)
    found_sh=$(find "$TMP_DIR/unzipped" -type f \( -name "*.sh" -o -name "*.run" \) | head -n1 || true)
    if [[ -n "$found_ppD" ]]; then
        install_from_ppD "$found_ppD" "$mode"
    elif [[ -n "$found_sh" ]]; then
        install_from_hplip "$found_sh" "$mode"
    else
        log_error "В ZIP не найдено поддерживаемых файлов для установки."
        log_solution "Проверьте содержимое архива. Ожидаются файлы .ppd, .sh или .run."
        return 1
    fi
}

############################################################
# 7. Основная логика работы скрипта
############################################################
main() {
    check_root || log_solution "Запустите скрипт с правами root."
    mkdir -p "$TMP_DIR"
    touch "$LOG_FILE"
    chmod 600 "$LOG_FILE"

    local url mode file_ext file_path

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
                            1)
                                file_ext="ppd"
                                ;;
                            2)
                                file_ext="sh"
                                ;;
                            3)
                                file_ext="zip"
                                ;;
                            0)
                                continue 2
                                ;;
                            *)
                                echo "Некорректный выбор"; continue
                                ;;
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
        # Если ручной режим, подменяем file_ext для дальнейшей логики
        if [[ "$mode" == "manual" && -n "$file_ext" ]]; then
            file_path="$TMP_DIR/driver.$file_ext"
        fi
    else
        url="$1"
        mode="${2:-auto}"
        if [[ "$mode" != "auto" && "$mode" != "manual" ]]; then
            log_error "Режим должен быть 'auto' или 'manual'"
            log_solution "Укажите режим: auto (автоматически) или manual (с подтверждением действий)."
            return 1
        fi
    fi

    check_dependencies
    # add_user_groups   # ← закомментировано на время тестов

    if [[ "$mode" == "auto" ]]; then
        remove_printers "auto"
    else
        remove_printers "manual"
    fi

    detect_printer || log_solution "Подключите поддерживаемый принтер и повторите попытку."

    # Если не задан file_ext (автоматический режим), определяем его из ссылки
    if [[ -z "$file_ext" ]]; then
        file_ext="${url##*.}"
        file_path="$TMP_DIR/driver.$file_ext"
    fi

    log_info "Скачиваю драйвер с $url"
    if ! wget -O "$file_path" "$url" >>"$LOG_FILE" 2>&1; then
        log_error "Не удалось скачать файл с $url"
        log_solution "Проверьте корректность URL и доступность файла. Попробуйте скачать вручную."
        return 1
    fi

    case "$file_ext" in
        ppd)
            install_from_ppd "$file_path" "$mode"
            ;;
        sh|run)
            install_from_hplip "$file_path" "$mode"
            ;;
        zip)
            install_from_zip "$file_path" "$mode"
            ;;
        *)
            log_error "Неподдерживаемое расширение файла: $file_ext"
            log_solution "Поддерживаются расширения: ppd, sh, run, zip."
            return 1
            ;;
    esac

    log_info "Установка принтера завершена."
}

############################################################
# 8. Точка входа
############################################################
main "$@"