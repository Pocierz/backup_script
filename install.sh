#!/bin/bash
set -u

# ========================
# Skrypt instalacyjny — wykrywa konfigurację i pyta użytkownika
# ========================
# Uruchom: sudo bash install.sh   (wymaga root/sudo!)
# Dla każdej wykrytej wartości użytkownik może nacisnąć Enter (zaakceptuj)
# lub wpisać własną wartość (nadpisze wykrytą).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/environments.txt"

# Sprawdź czy skrypt jest uruchomiony jako root
if [[ $EUID -ne 0 ]]; then
	echo ""
	echo "⚠  Ten skrypt wymaga uprawnień root (uruchom: sudo bash install.sh)"
	echo "   Potrzebne do: ustawiania tras IP, tworzenia plików w /etc/cron.d/, logowania."
	exit 1
fi

# Pomocnicza funkcja do wyświetlania nagłówków sekcji
section(){
    echo ""
    echo "========================================"
    echo " $*"
    echo "========================================"
}

# Pyta użytkownika z podaną wartością domyślną (wykrytą automatycznie).
# Enter = zaakceptuj domyślną, inny wpis = nadpisz.
ask(){
    local prompt="$1"
    local default="$2"
    local value=""
    read -rp "  ${prompt} [${default}]: " value
    if [[ -z "$value" ]]; then
        echo "$default"
    else
        echo "$value"
    fi
}

section "Krok 1/4 — Interfejsy sieciowe"
echo ""
echo "Wykrywanie interfejsów z systemu..."

# Wykryj wszystkie dostępne interfejsy (poza loopback)
available_ifaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v lo | sort)
echo "Dostępne interfejsy: $(echo $available_ifaces | tr '\n' ' ')"

iface_primary="$(ask "IFACE_PRIMARY" "$(echo "$available_ifaces" | head -1)")"
iface_backup1="$(ask "IFACE_BACKUP1" "$(echo "$available_ifaces" | sed -n '2p')")"

# Pytaj czy użytkownik chce drugi backup (opcjonalny)
echo ""
read -rp "  Czy chcesz skonfigurować drugi interfejs backup (BACKUP2)? [T/n]: " want_backup2
iface_backup2=""
gw_backup2=""
if [[ "$want_backup2" != "n" && "$want_backup2" != "N" ]]; then
	iface_backup2="$(ask "IFACE_BACKUP2" "$(echo "$available_ifaces" | sed -n '3p')")"
else
	echo "  BACKUP2 pominięty — skrypt będzie działał z jednym backup-em."
fi

section "Krok 2/4 — Bramy domyślne (gatewaye)"
echo ""
echo "Wykrywanie gatewayi z tras domyślnych..."
echo ""

# Pobierz WSZYSTKIE trasy domyślne i pokaż użytkownikowi
declare -a all_gws=()
declare -a all_devs=()

while IFS= read -r line; do
    gw="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="via") print $(i+1)}')"
    dev="$(echo "$line" | awk '{for(i=1;i<=NF;i++) if($i=="dev") print $(i+1)}')"
    met="$(echo "$line" | awk '{print $NF}')"
    if [[ -n "$gw" && -n "$dev" ]]; then
        all_gws+=("$gw")
        all_devs+=("$dev")
        echo "  Wykryto: dev=$dev via=$gw metric=$met"
    fi
done < <(ip -4 route show default 2>/dev/null)

echo ""
echo "Powyższe gatewaye NIE są automatycznie przypisywane do interfejsów."
echo "Musisz ręcznie podać poprawne bramki dla swoich interfejsów."
echo ""

# Pytaj o każdą bramkę — domyślnie puste (użytkownik musi wpisać sam)
gw_primary="$(ask "GW_PRIMARY ($iface_primary):" "")"
gw_backup1="$(ask "GW_BACKUP1 ($iface_backup1):" "")"
if [[ -n "$iface_backup2" ]]; then
	gw_backup2="$(ask "GW_BACKUP2 ($iface_backup2):" "")"
fi

section "Krok 3/4 — Pozostała konfiguracja"
echo ""
echo "--- Metryki tras ---"
echo "Metryki są obliczane AUTOMATYCZNIE względem aktualnej trasy głównej:"
echo "  PRIMARY : aktualna metryka z systemu (np. 100)"
echo "  BACKUP1 : primary + 10 (np. 110)"
echo "  BACKUP2 : primary + 20 (np. 120)"
echo "Przy awarii backup dostaje metrykę o 10 mniejszą niż primary."
metric_primary="$(ask "METRIC_PRIMARY (bazowa, jeśli nie wykryta z systemu):" "100")

echo ""
echo "--- Testowanie łączności ---"
ip_list_input="$(ask "IP_LIST (adresy IP do pingowania, oddzielone spacą):" "1.1.1.1 8.8.8.8 8.8.4.4")"
packets_count="$(ask "PACKETS_COUNT (liczba pakietów ping):" "100")"
threshold_ping="$(ask "THRESHOLD_PING (>wartość = OK, <=wartość = problem):" "70")"

echo ""
echo "--- Pliki i ścieżki ---"
state_file="$(ask "STATE_FILE (plik stanu):" "/tmp/ip_monitor_state")"
log_file="$(ask "LOG_FILE (plik logów):" "/var/log/tester.log")"
# Ścieżka do skryptu Python — ustawiana automatycznie, bez pytania
python_script_path="${SCRIPT_DIR}/powiadomienie.py"

section "Krok 4/4 — Matrix (powiadomienia)"
echo ""
echo "--- Serwer Matrix ---"
matrix_url="$(ask "MATRIX_URL (serwer Matrix, np. https://chat.example.com):" "")"
matrix_room_id="$(ask "MATRIX_ROOM_ID (np. !xyz:server.com):" "")"
matrix_access_token="$(ask "MATRIX_ACCESS_TOKEN (token dostępowy):" "")"

# Użyj podanej listy IP lub domyślnej
ip_list="${ip_list_input:-1.1.1.1 8.8.8.8 8.8.4.4}"

# --- Podsumowanie konfiguracji ---
section "Podsumowanie — czy wszystko jest OK?"
echo ""
echo "  IFACE_PRIMARY   = $iface_primary     GW_PRIMARY   = $gw_primary    METRIC = auto (${metric_primary} + offsety)"
echo "  IFACE_BACKUP1   = $iface_backup1     GW_BACKUP1    = $gw_backup1    METRIC = primary + 10"
if [[ -n "$iface_backup2" ]]; then
	echo "  IFACE_BACKUP2   = $iface_backup2     GW_BACKUP2    = $gw_backup2    METRIC = primary + 20"
else
	echo "  (BACKUP2 nie jest skonfigurowany)"
fi
echo ""
echo "  IP_LIST         = $ip_list"
echo "  PACKETS_COUNT   = $packets_count"
echo "  THRESHOLD_PING  = $threshold_ping"
echo ""
echo "  STATE_FILE      = $state_file"
echo "  LOG_FILE        = $log_file"
echo "  PYTHON_SCRIPT   = $python_script_path"
echo ""
echo "  MATRIX_URL      = $matrix_url"
echo "  MATRIX_ROOM_ID  = $matrix_room_id"
echo "  MATRIX_TOKEN    = ${matrix_access_token:0:10}..."
echo ""

read -rp "  Czy chcesz wygenerować environments.txt z powyższymi danymi? [T/n]: " confirm
if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
    echo "Anulowano. Plik environments.txt nie został wygenerowany."
    exit 0
fi

section "Generowanie pliku environments.txt"

# Formatuj listę IP jako tablicę bash
formatted_ip_list=""
for ip in $ip_list; do
    formatted_ip_list+="\"${ip}\" "
done
formatted_ip_list="${formatted_ip_list% }"  # usuń ostatnią spację

# Wygeneruj plik environments.txt
{
cat <<HEADER
# ========================
# Konfiguracja globalna — współdzielona między skryptami
# ========================
# Edytuj ten plik, aby zmienić ustawienia bez modyfikowania logiki skryptów.
# Wszystkie zmienne są wielkimi literami (konwencja zmiennych globalnych).
# Wygenerowane przez install.sh w $(date '+%Y-%m-%d %H:%M:%S')

# --- Sieć ---

# Lista adresów IP do testowania łączności (ping)
IP_LIST=(${formatted_ip_list})

# Interfejsy sieciowe
IFACE_PRIMARY="${iface_primary}"
IFACE_BACKUP1="${iface_backup1}"
HEADER

if [[ -n "$iface_backup2" ]]; then
cat <<BACKUP2
IFACE_BACKUP2="${iface_backup2}"
BACKUP2
else
echo "# IFACE_BACKUP2=\"\"  # drugi backup (opcjonalny, zakomentowany)"
fi

cat <<GW_HEADER

# Bramy domyślne (gatewaye) dla każdego interfejsu
GW_PRIMARY="${gw_primary}"
GW_BACKUP1="${gw_backup1}"
GW_HEADER

if [[ -n "$iface_backup2" ]]; then
echo "GW_BACKUP2=\"${gw_backup2}\""
else
    echo "# GW_BACKUP2=\"\"  # drugi backup (opcjonalny, zakomentowany)"
fi

cat <<METRIC_HEADER

# Metryki tras — niższa metryka = wyższy priorytet
# Metryki backupów są obliczane AUTOMATYCZNIE jako primary + offset:
#   BACKUP1 = METRIC_PRIMARY + 10
#   BACKUP2 = METRIC_PRIMARY + 20
# Przy awarii backup dostaje metrykę o 10 mniejszą niż primary.
METRIC_PRIMARY=${metric_primary}
METRIC_HEADER

cat <<FOOTER

# --- Testowanie łączności ---

# Liczba pakietów ping wysyłanych do każdego IP w teście
PACKETS_COUNT=${packets_count}

# Progół akceptowalnej straty pakietów: >70 = OK, ≤70 = problem (strata ≥30%)
THRESHOLD_PING=${threshold_ping}

# --- Pliki i ścieżki ---

# Plik przechowujący aktualny stan systemu (up / backup1 / backup2)
STATE_FILE="${state_file}"

# Plik logów
LOG_FILE="${log_file}"

# Skrypt Pythona do wysyłania powiadomień
PYTHON_SCRIPT_PATH="${python_script_path}"

# Ścieżka do katalogu ze skryptami (ustawiana dynamicznie w main.sh)
SCRIPT_DIR="\${SCRIPT_DIR:-\$(cd "\$(dirname "\$0")" && pwd)}"
ASTERISK_RELOAD_SCRIPT="\${SCRIPT_DIR}/asterisk_reload.sh"

# --- Matrix (powiadomienia) ---

# URL serwera Matrix
MATRIX_URL="${matrix_url}"

# ID pokoju Matrix
MATRIX_ROOM_ID="${matrix_room_id}"

# Token dostępowy do pokoju Matrix
MATRIX_ACCESS_TOKEN="${matrix_access_token}"
FOOTER
} > "$ENV_FILE"

echo ""
echo "Plik environments.txt został wygenerowany pomyślnie: ${ENV_FILE}"

# --- Dodaj wpis do cron ---
echo ""
echo "--- Konfiguracja crona ---"
read -rp "  Co ile minut ma uruchamiać się skrypt monitorujący? [1]: " cron_interval
cron_interval="${cron_interval:-1}"

CRON_FILE="/etc/cron.d/backup_script"
SCRIPT_ABS_PATH="$(cd "$SCRIPT_DIR" && pwd)/main.sh"

echo "Tworzenie wpisu w ${CRON_FILE} ..."
cat > "$CRON_FILE" <<EOF
# Skrypt monitorujący łączność — uruchamiany co ${cron_interval} min
*/${cron_interval} * * * * root bash ${SCRIPT_ABS_PATH}
EOF

echo "  ✓ Cron dodany: */${cron_interval} * * * * root bash ${SCRIPT_ABS_PATH}"
echo "  (plik: ${CRON_FILE})"

echo ""
echo "Możesz teraz ręcznie uruchomić skrypt (lub poczekać na cron):"
echo "  bash ${SCRIPT_DIR}/main.sh"
