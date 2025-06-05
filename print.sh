#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

separator="────────────────────────────────────────"

########################################
# Функция: Проверка привилегий и зависимостей
########################################
check_dependencies() {
  echo "$separator"
  echo ">>> Проверка прав и зависимостей"
  if [[ $EUID -ne 0 ]]; then
    echo "❌ Запусти с sudo или от root."
    exit 1
  fi
  echo "✔ Проверка прав доступа: пройдено"

  local required_cmds=(wget apt-get lpadmin lpinfo lpstat lpoptions hp-setup apt-repo rpm lsusb 7z)
  for cmd in "${required_cmds[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      echo "❌ Не найдено: $cmd"
      exit 1
    fi
  done
  echo "✔ Все нужные команды доступны"
  echo
}

########################################
# Функция: Обновление списка пакетов
########################################
update_packages() {
  echo "$separator"
  echo ">>> Обновление списка пакетов"
  if apt-get update -qq; then
    echo "✔ apt-get update OK"
  else
    echo "❌ Ошибка apt-get update"
    exit 1
  fi
  echo
}

########################################
# Функция: Проверка и удаление установленных принтеров
########################################
remove_existing_printers() {
  echo "$separator"
  echo ">>> Текущие очереди принтеров"
  local printers_output
  printers_output=$(lpstat -p 2>&1) || true
  if echo "$printers_output" | grep -qF "Нет добавленных назначений"; then
    echo "  принтеров нет"
  else
    echo "$printers_output" | sed 's/^/  /'
    read -r -p "Удалить принтер? [y/N]: " delq
    if [[ $delq =~ ^[Yy] ]]; then
      read -r -p "  Точное имя принтера для удаления: " delp
      if lpadmin -x "$delp"; then
        echo "  ✔ Удалён $delp"
      else
        echo "  ❌ '$delp' не найден"
      fi
    fi
  fi
  echo
}

########################################
# Функция: Тестовая печать
########################################
test_print() {
  echo "$separator"
  echo "Доступные принтеры:"
  lpstat -p 2>&1 || true
  echo
  read -r -p "Введите название принтера для тестовой печати или оставьте пустым для использования принтера по умолчанию: " chosen_printer
  if [[ -z "$chosen_printer" ]]; then
    chosen_printer=$(lpstat -d 2>/dev/null | awk -F': ' '{print $2}') || true
    if [[ -z "$chosen_printer" ]]; then
      echo "❌ Принтер по умолчанию не найден. Проверьте установку принтера."
      return
    else
      echo "Используется принтер по умолчанию: $chosen_printer"
    fi
  fi
  if lp -d "$chosen_printer" /usr/share/cups/data/testprint; then
    echo "✔ Тестовая страница отправлена на принтер '$chosen_printer'"
  else
    echo "❌ Не удалось отправить тестовую печать на '$chosen_printer'"
  fi
  echo "$separator"
  echo "Готово!"
}

########################################
# Функция: Проверка подключения принтера по lsusb
########################################
check_printer_connection() {
  echo "$separator"
  echo ">>> Проверка подключения принтера через lsusb"
  lsusb_output=$(lsusb)
  echo "$lsusb_output" | sed 's/^/  /'
  echo
  read -r -p "Принтер подключен? [y/N]: " resp
  if [[ ! $resp =~ ^[Yy] ]]; then
    echo "❌ Принтер не подключен. Завершаю работу."
    exit 1
  fi
}

########################################
# Функция: Добавление 'domain users' в группы
########################################
add_domain_users_to_groups() {
  echo "$separator"
  echo ">>> Добавление 'domain users' в группы: lp, camera, scanner"
  for group in lp camera scanner; do
    if ! roleadd 'domain users' "$group"; then
      echo "❌ Не удалось добавить 'domain users' в группу $group"
      exit 1
    fi
  done
  echo "✔ Доменные пользователи успешно добавлены в группы lp, camera, scanner"
}

########################################
# Функция: Установка дополнительных пакетов для моделей из списка
########################################
install_additional_packages_for_model() {
  local model="$1"
  local allowed_patterns=(
    "Brother DCP-1510" "Brother DCP-1600" "Brother DCP-7020" "Brother DCP-7030"
    "Brother DCP-7040" "Brother DCP-7055" "Brother DCP-7055W" "Brother DCP-7060D"
    "Brother DCP-7065DN" "Brother DCP-7070DW" "Brother DCP-7080" "Brother DCP-L2500D"
    "Brother DCP-L2510D" "Brother DCP-L2520D" "Brother DCP-L2520DW" "Brother DCP-L2537DW"
    "Brother DCP-L2540DW" "Brother DCP-L2550DW" "Brother HL-1110" "Brother HL-1200"
    "Brother HL-2030" "Brother HL-2130" "Brother HL-2140" "Brother HL-2220"
    "Brother HL-2230" "Brother HL-2240D" "Brother HL-2250DN" "Brother HL-2270DW"
    "Brother HL-2280DW" "Brother HL-5030" "Brother HL-5040" "Brother HL-L2300D"
    "Brother HL-L2305" "Brother HL-L2310D" "Brother HL-L2320D" "Brother HL-L2340D"
    "Brother HL-L2350DW" "Brother HL-L2360D" "Brother HL-L2375DW" "Brother HL-L2380DW"
    "Brother HL-L2390DW" "Brother MFC-1810" "Brother MFC-1910W" "Brother MFC-7240"
    "Brother MFC-7320" "Brother MFC-7340" "Brother MFC-7360N" "Brother MFC-7365DN"
    "Brother MFC-7420" "Brother MFC-7440N" "Brother MFC-7460DN" "Brother MFC-7840W"
    "Brother MFC-8710DW" "Brother MFC-8860DN" "Brother MFC-L2700DN" "Brother MFC-L2700DW"
    "Brother MFC-L2710DN" "Brother MFC-L2710DW" "Brother MFC-L2750DW" "Brother MFC-L3750CDW"
    "Lenovo LJ2650DN" "Lenovo M7605D" "Fuji Xerox DocuPrint P265 DW"
  )
  for pattern in "${allowed_patterns[@]}"; do
    if [[ "$model" == *"$pattern"* ]]; then
      echo "→ Обнаружена модель '$model', требующая установки дополнительных пакетов."
      apt-get -y install printer-driver-brlaser mupdf
      return 0
    fi
  done
  return 1
}

########################################
# Функция: Автоматическая установка дополнительных пакетов для Brother
########################################
auto_install_brother_packages() {
  echo "$separator"
  echo ">>> Автоматическая проверка драйверов Brother для установки дополнительных пакетов"
  local brother_drivers
  brother_drivers=$(lpinfo -m | grep '^Brother')
  if [[ -z "$brother_drivers" ]]; then
    echo "Нет найденных драйверов Brother"
    return
  fi
  local allowed_patterns=(
    "Brother DCP-1510" "Brother DCP-1600" "Brother DCP-7020" "Brother DCP-7030"
    "Brother DCP-7040" "Brother DCP-7055" "Brother DCP-7055W" "Brother DCP-7060D"
    "Brother DCP-7065DN" "Brother DCP-7070DW" "Brother DCP-7080" "Brother DCP-L2500D"
    "Brother DCP-L2510D" "Brother DCP-L2520D" "Brother DCP-L2520DW" "Brother DCP-L2537DW"
    "Brother DCP-L2540DW" "Brother DCP-L2550DW" "Brother HL-1110" "Brother HL-1200"
    "Brother HL-2030" "Brother HL-2130" "Brother HL-2140" "Brother HL-2220"
    "Brother HL-2230" "Brother HL-2240D" "Brother HL-2250DN" "Brother HL-2270DW"
    "Brother HL-2280DW" "Brother HL-5030" "Brother HL-5040" "Brother HL-L2300D"
    "Brother HL-L2305" "Brother HL-L2310D" "Brother HL-L2320D" "Brother HL-L2340D"
    "Brother HL-L2350DW" "Brother HL-L2360D" "Brother HL-L2375DW" "Brother HL-L2380DW"
    "Brother HL-L2390DW" "Brother MFC-1810" "Brother MFC-1910W" "Brother MFC-7240"
    "Brother MFC-7320" "Brother MFC-7340" "Brother MFC-7360N" "Brother MFC-7365DN"
    "Brother MFC-7420" "Brother MFC-7440N" "Brother MFC-7460DN" "Brother MFC-7840W"
    "Brother MFC-8710DW" "Brother MFC-8860DN" "Brother MFC-L2700DN" "Brother MFC-L2700DW"
    "Brother MFC-L2710DN" "Brother MFC-L2710DW" "Brother MFC-L2750DW" "Brother MFC-L3750CDW"
  )
  local found=0
  while IFS= read -r line; do
    for pattern in "${allowed_patterns[@]}"; do
      if [[ "$line" == *"$pattern"* ]]; then
        echo "→ Обнаружен драйвер: $line, совпадающий с шаблоном: $pattern"
        found=1
        break 2
      fi
    done
  done <<< "$brother_drivers"
  if [[ $found -eq 1 ]]; then
    echo "→ Устанавливаю дополнительные пакеты для Brother принтера..."
    apt-get -y install printer-driver-brlaser mupdf
  else
    echo "Драйверы Brother не соответствуют списку для установки дополнительных пакетов."
  fi
}

########################################
# Функция: Настройка репозитория для Canon
########################################
setup_canon_repo() {
  echo "$separator"
  echo ">>> Проверка и добавление репозитория для Canon драйверов"
  if apt-repo list | grep -q "http://repo.proc.ru/mirror c10f1/branch/x86_64-i586 classic"; then
    echo "Репозиторий уже добавлен."
  else
    echo "Добавляю репозиторий для Canon драйверов..."
    apt-repo add rpm "[cert8]" "http://repo.proc.ru/mirror c10f1/branch/x86_64-i586 classic"
    apt-get update
  fi
}

########################################
# Функция: Скачивание файла по URL
########################################
download_file() {
  local url="$1"
  local dest_dir="/tmp/printer_install"
  local filename
  mkdir -p "$dest_dir"
  filename=$(basename "$url")
  local dest_file="$dest_dir/$filename"
  >&2 echo ">>> Скачивание файла"
  >&2 echo "→ URL: $url"
  >&2 echo "→ В файл: $dest_file"
  if wget -q "$url" -O "$dest_file"; then
    >&2 echo "✔ Файл успешно скачан"
    echo "$dest_file"
    return 0
  else
    >&2 echo "❌ Ошибка скачивания файла"
    rm -f "$dest_file"
    return 1
  fi
}

########################################
# Функция: Извлечение и поиск файлов в архиве
########################################
extract_and_search() {
  local archive="$1"
  local dest_dir="$2"
  echo "$separator"
  echo ">>> Извлечение архива в временную директорию"
  echo "→ Архив: $archive"
  echo "→ Каталог: $dest_dir"
  if [[ ! -f "$archive" ]]; then
    echo "❌ Архив не найден: $archive"
    exit 1
  fi
  mkdir -p "$dest_dir"
  if ! 7z x "$archive" -o"$dest_dir" >/dev/null; then
    echo "❌ Ошибка извлечения архива"
    exit 1
  fi
  echo "✔ Архив успешно извлечён"
  recursive_extract_archives "$dest_dir"
  find "$dest_dir" -type f -name "*.sh" -exec chmod +x {} \;
  find_install_files "$dest_dir"
}

recursive_extract_archives() {
  local dir="$1"
  find "$dir" -type f \( -iname "*.tar" -o -iname "*.tar.gz" -o -iname "*.tgz" -o -iname "*.zip" -o -iname "*.7z" \) | while read -r archive; do
    local parent_dir
    parent_dir=$(dirname "$archive")
    echo "$separator"
    echo ">>> Рекурсивное извлечение: $archive"
    if ! 7z x "$archive" -o"$parent_dir" >/dev/null; then
      echo "❌ Ошибка извлечения: $archive"
      exit 1
    fi
    rm -f "$archive"
    recursive_extract_archives "$parent_dir"
  done
}

########################################
# Функция: Поиск установочных файлов в каталоге
########################################
find_install_files() {
  local search_dir="$1"
  local found_files=()
  echo "$separator"
  echo ">>> Поиск установочных файлов в распакованном архиве"
  while IFS= read -r -d '' file; do
    found_files+=("$file")
  done < <(find "$search_dir" -type f \( -name "*.ppd" -o -name "*.rpm" -o -name "*.sh" \) -print0)
  if (( ${#found_files[@]} > 0 )); then
    echo "✔ Найдено файлов: ${#found_files[@]}"
    if (( ${#found_files[@]} == 1 )); then
      echo "→ Найден файл: ${found_files[0]}"
      choose_stage_by_link_auto "${found_files[0]}"
    else
      echo "Найдено несколько файлов:"
      for i in "${!found_files[@]}"; do
        local file="${found_files[$i]}"
        local ext="${file##*.}"
        printf "%3d) [%s] %s\n" $((i+1)) "$ext" "$file"
      done
      read -r -p "Выберите номер файла для установки: " choice
      if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice > 0 && choice <= ${#found_files[@]} )); then
        choose_stage_by_link_auto "${found_files[choice-1]}"
      else
        echo "❌ Неверный выбор"
        exit 1
      fi
    fi
  else
    echo "❌ Установочные файлы не найдены в архиве"
    echo "Содержимое распакованного архива:"
    find "$search_dir" -type f | sed 's/^/  /'
    exit 1
  fi
}

########################################
# Функция: Автоматическая установка из PPD
########################################
install_from_ppd_auto() {
  local ppd_file="$1"
  echo "$separator"
  echo ">>> Автоматическая установка из PPD: $ppd_file"
  echo "→ Устанавливаю пакет rastertokpsl-re..."
  if apt-get install -y rastertokpsl-re; then
    echo "✔ Пакет rastertokpsl-re установлен"
  else
    echo "❌ Ошибка установки rastertokpsl-re"
    exit 1
  fi
  mkdir -p /usr/share/ppd
  cp "$ppd_file" /usr/share/ppd/ || { echo "❌ Ошибка копирования $ppd_file"; exit 1; }
  local base
  base=$(basename "$ppd_file" .ppd)
  if echo "$base" | grep -qi "brother"; then
    install_additional_packages_for_model "$base"
  fi
  local uri
  uri=$(lpinfo -v | sed -n 's/.*\(usb:\/\/[^[:space:]]\+\).*/\1/p' | head -n 1)
  if [[ -z "$uri" ]]; then
    echo "❌ USB-URI не найден. Проверьте подключение принтера."
    exit 1
  fi
  if lpadmin -p "$base" -E -v "$uri" -P "/usr/share/ppd/$(basename "$ppd_file")"; then
    echo "✔ Принтер '$base' установлен из PPD"
    local default_printer
    default_printer=$(lpstat -d 2>/dev/null | awk -F': ' '{print $2}')
    if [[ -z "$default_printer" ]]; then
      lpoptions -d "$base"
      echo "✔ Принтер '$base' выставлен по умолчанию"
    else
      echo "✔ Принтер по умолчанию уже установлен: $default_printer"
    fi
    test_print
  else
    echo "❌ Ошибка установки принтера из PPD"
    exit 1
  fi
}

########################################
# Функция: Режим HPLIP (интерактивная установка)
########################################
install_hplip() {
  echo "$separator"
  echo ">>> Режим HPLIP"
  read -r -p "URL hp-setup.sh: " PLUGIN_URL
  [[ -z "$PLUGIN_URL" ]] && { echo "❌ URL не указан"; exit 1; }
  local D="/tmp/$(basename "$PLUGIN_URL")"
  if ! wget -q "$PLUGIN_URL" -O "$D"; then
    echo "❌ Ошибка скачивания"
    exit 1
  fi
  chmod +x "$D"
  echo "→ Запускаю плагин..."
  if ! "$D"; then
    echo "❌ Ошибка плагина"
    exit 1
  fi
  echo "→ Запускаю hp-setup..."
  hp-setup
}

########################################
# Функция: Автоматическая установка через RPM
########################################
install_rpm_auto() {
  local rpm_file="$1"
  echo "$separator"
  echo ">>> Автоматическая установка RPM: $rpm_file"
  if ! apt-get install -y "$rpm_file"; then
    echo "❌ Ошибка установки RPM-пакета"
    exit 1
  fi
  echo "✔ RPM-пакеты установлены"
  echo "$separator"
  echo ">>> Обнаруженные USB-устройства:"
  mapfile -t devs < <(lsusb)
  for i in "${!devs[@]}"; do
    printf "%3d) %s\n" $((i+1)) "${devs[i]}"
  done
  read -r -p "Введите номер устройства для поиска драйвера: " idx
  local device="${devs[idx-1]}"
  echo "▶ Выбранное устройство: $device"
  local model_full
  model_full=$(echo "$device" | sed -En 's/.*ID[[:space:]]+[0-9a-fA-F]{4}:[0-9a-fA-F]{4}[[:space:]]+(.+)/\1/p')
  if [[ -z "$model_full" ]]; then
    echo "❌ Не удалось определить модель устройства"
    exit 1
  else
    echo "▶ Определена модель: $model_full"
  fi
  read -r -p "Введите производителя (например, hp, canon) или оставьте пустым: " manufacturer
  local pattern
  if [[ -n "$manufacturer" ]]; then
    pattern="(?i)${manufacturer}.*\b${model_full}\b"
  else
    pattern="(?i)\b${model_full}\b"
  fi
  mapfile -t drivers < <(lpinfo -m | grep -E "$pattern")
  if (( ${#drivers[@]} == 0 )); then
    read -r -p "Драйверы не найдены автоматически. Введите полное название модели для поиска: " model_manual
    if [[ -z "$model_manual" ]]; then
      echo "❌ Не введено название модели"
      exit 1
    fi
    pattern="(?i)\b${model_manual}\b"
    mapfile -t drivers < <(lpinfo -m | grep -E "$pattern")
    if (( ${#drivers[@]} == 0 )); then
      echo "❌ Драйверы по указанному названию не найдены"
      exit 1
    fi
  fi
  echo "▶ Найдено драйверов: ${#drivers[@]}"
  local driver
  if (( ${#drivers[@]} > 1 )); then
    echo "Выберите драйвер:"
    for i in "${!drivers[@]}"; do
      printf "%3d) %s\n" $((i+1)) "${drivers[i]}"
    done
    read -r -p "Введите номер драйвера: " driver_idx
    driver="${drivers[driver_idx-1]}"
  else
    driver="${drivers[0]}"
    echo "✔ Выбран драйвер: $driver"
  fi
  if echo "$driver" | grep -qi "brother"; then
    install_additional_packages_for_model "$driver"
  fi
  mapfile -t uris < <(lpinfo -v | sed -n 's/.*\(usb:\/\/[^[:space:]]\+\).*/\1/p')
  local uri
  if (( ${#uris[@]} > 1 )); then
    echo "Выберите USB-URI:"
    for i in "${!uris[@]}"; do
      printf "%3d) %s\n" $((i+1)) "${uris[i]}"
    done
    read -r -p "Введите номер URI: " uri_idx
    uri="${uris[uri_idx-1]}"
  elif (( ${#uris[@]} == 1 )); then
    uri="${uris[0]}"
  else
    echo "❌ USB-URI не найден. Проверьте подключение принтера."
    exit 1
  fi
  local printer_name="${driver%% *}"
  printer_name="${printer_name//\//_}"
  if lpadmin -p "$printer_name" -E -v "$uri" -m "$driver"; then
    echo "✔ Принтер '$printer_name' установлен через RPM-метод"
    test_print
  else
    echo "❌ Ошибка установки принтера '$printer_name'"
    exit 1
  fi
}

########################################
# Функция: Автоматическая установка Canon через .sh
########################################
install_canon_auto() {
  local canon_sh="$1"
  echo "$separator"
  echo ">>> Автоматическая установка Canon драйвера из .sh: $canon_sh"
  setup_canon_repo
  if [[ ! -x "$canon_sh" ]]; then
    chmod +x "$canon_sh"
  fi
  if bash "$canon_sh"; then
    echo "✔ Canon-драйвер установлен"
    test_print
  else
    echo "❌ Ошибка установки Canon-драйвера"
    exit 1
  fi
}

########################################
# Функция: Автоматическая установка драйвера из .sh файла
########################################
install_sh_driver() {
  local sh_file="$1"
  echo "$separator"
  echo ">>> Автоматическая установка драйвера из .sh файла: $sh_file"
  if [[ ! -x "$sh_file" ]]; then
    chmod +x "$sh_file"
  fi
  if bash "$sh_file"; then
    echo "✔ Скрипт выполнен успешно"
    if command -v hp-setup &>/dev/null; then
      echo "✔ HPLIP обнаружен. Переход к этапу дальнейшей настройки..."
      echo "→ Запускаю hp-setup для завершения настройки..."
      hp-setup
      local default_printer
      default_printer=$(lpstat -d 2>/dev/null | awk -F': ' '{print $2}')
      if [[ -z "$default_printer" ]]; then
        read -r -p "Принтер по умолчанию не задан. Установить первый найденный принтер по умолчанию? [y/N]: " set_def
        if [[ $set_def =~ ^[Yy] ]]; then
          local printer_list
          printer_list=( $(lpstat -p 2>/dev/null | awk '{print $2}') )
          if (( ${#printer_list[@]} > 0 )); then
            default_printer="${printer_list[0]}"
            lpoptions -d "$default_printer"
            echo "✔ Принтер '$default_printer' установлен по умолчанию"
          else
            echo "❌ Не удалось получить список установленных принтеров"
          fi
        fi
      else
        echo "✔ Принтер по умолчанию уже установлен: $default_printer"
      fi
      test_print
      return 0
    fi
    local attempts=0
    local max_attempts=10
    local driver_found=""
    while (( attempts < max_attempts )); do
      echo "Попытка $((attempts+1)) поиска драйвера..."
      local device
      device=$(lsusb | head -n 1)
      local model_full
      model_full=$(echo "$device" | sed -En 's/.*ID[[:space:]]+[0-9a-fA-F]{4}:[0-9a-fA-F]{4}[[:space:]]+(.+)/\1/p')
      if [[ -n "$model_full" ]]; then
        echo "Определена модель: $model_full"
        read -r -p "Введите производителя (например, hp, canon) или оставьте пустым: " manufacturer
        local clean_model
        clean_model=$(echo "$model_full" | sed -E 's/\b(ltd|inc|corp)\b//Ig' | tr -s ' ' | sed 's/^ *//;s/ *$//')
        IFS=' ' read -r -a tokens <<< "$clean_model"
        local dynamic_pattern="(?i)"
        for token in "${tokens[@]}"; do
          dynamic_pattern+="${token}.*"
        done
        if [[ -n "$manufacturer" ]]; then
          dynamic_pattern="(?i)${manufacturer}.*${dynamic_pattern}"
        fi
        echo "Используем паттерн для поиска драйвера: $dynamic_pattern"
        mapfile -t drivers < <(lpinfo -m | grep -E "$dynamic_pattern")
        if (( ${#drivers[@]} > 0 )); then
          driver_found="${drivers[0]}"
          echo "✔ Найден драйвер: $driver_found"
          break
        else
          echo "Драйвер не найден, повторная попытка..."
        fi
      else
        echo "Не удалось определить модель устройства, повторная попытка..."
      fi
      ((attempts++))
      sleep 1
    done
    if [[ -z "$driver_found" ]]; then
      echo "❌ Драйвер для принтера не найден после $attempts попыток"
      exit 1
    fi
    local uri
    uri=$(lpinfo -v | sed -n 's/.*\(usb:\/\/[^[:space:]]\+\).*/\1/p' | head -n 1)
    if [[ -z "$uri" ]]; then
      echo "❌ USB-URI не найден. Проверьте подключение принтера."
      exit 1
    fi
    local printer_name="${driver_found%% *}"
    printer_name="${printer_name//\//_}"
    if lpadmin -p "$printer_name" -E -v "$uri" -m "$driver_found"; then
      echo "✔ Принтер '$printer_name' установлен с найденным драйвером"
      test_print
    else
      echo "❌ Ошибка установки принтера '$printer_name'"
      exit 1
    fi
  else
    echo "❌ Ошибка выполнения скрипта $sh_file"
    exit 1
  fi
}

########################################
# Функция: Автоматическое определение этапа установки по файлу
########################################
choose_stage_by_link_auto() {
  local file_link="$1"
  echo "$separator"
  echo ">>> Автоматическое определение этапа установки для файла: $file_link"
  local actual_file
  if [[ "$file_link" =~ ^https?:// ]]; then
    actual_file=$(download_file "$file_link") || exit 1
  else
    actual_file="$file_link"
  fi
  [[ ! -f "$actual_file" ]] && { echo "❌ Файл не найден: $actual_file"; exit 1; }
  if [[ "$actual_file" =~ \.ppd$ ]]; then
    echo "-> Режим: Установка из PPD"
    install_from_ppd_auto "$actual_file"
  elif [[ "$actual_file" =~ \.(tar\.gz|tgz|tar|7z|zip)$ ]]; then
    echo "-> Режим: Извлечение архива"
    local tmp_dir="/tmp/drivers"
    mkdir -p "$tmp_dir"
    extract_and_search "$actual_file" "$tmp_dir"
  elif [[ "$actual_file" =~ \.rpm$ ]]; then
    echo "-> Режим: Установка через RPM"
    install_rpm_auto "$actual_file"
  elif [[ "$actual_file" =~ \.sh$ ]]; then
    echo "-> Режим: Установка драйвера из .sh файла"
    install_sh_driver "$actual_file"
  else
    echo "❌ Неизвестный формат файла"
    exit 1
  fi
}

########################################
# Главное интерактивное меню
########################################
main_menu() {
  echo "$separator"
  echo "Выберите режим работы:"
  echo "  1) Стандартная установка принтера"
  echo "  2) Установка через выбор этапа по файлу"
  read -r -p "Ваш выбор [1-2]: " MODE
  echo
  case "$MODE" in
    1)
      check_dependencies
      update_packages
      remove_existing_printers
      echo "$separator"
      echo ">>> Метод установки"
      echo "  1) Из PPD-файла"
      echo "  2) Через HPLIP"
      echo "  3) RPM-пакеты"
      echo "  4) Скрипт установки (.sh файл)"
      read -r -p "Выбор [1-4]: " METHOD
      echo
      case "$METHOD" in
        1)
          read -r -p "Путь к PPD-файлу: " file_ppd
          install_from_ppd_auto "$file_ppd"
          ;;
        2) install_hplip ;;
        3)
          read -r -p "Путь к RPM-пакету: " file_rpm
          install_rpm_auto "$file_rpm"
          ;;
        4)
          read -r -p "Путь к скрипту (.sh) файла: " file_sh
          install_sh_driver "$file_sh"
          ;;
        *) echo "❌ Неверный выбор"; exit 1 ;;
      esac
      ;;
    2)
      read -r -p "Введите путь к файлу (или ссылку на файл) для автоматической установки: " chosen_file
      choose_stage_by_link_auto "$chosen_file"
      ;;
    *)
      echo "❌ Неверный выбор"
      exit 1
      ;;
  esac
}

########################################
# Точка входа
########################################
add_domain_users_to_groups
check_printer_connection
auto_install_brother_packages

if [[ $# -gt 0 ]]; then
  chosen_file="$1"
  choose_stage_by_link_auto "$chosen_file"
else
  main_menu
fi
