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

# ========================
# Wczytaj obecną konfigurację jako domyślne wartości (jeśli istnieje)
# ========================
existing_env=""
if [[ -f "$ENV_FILE" ]]; then
    echo ""
    echo "✓ Wykryto istniejący plik environments.txt — wczytuję obecne wartości."
    echo "  Możesz je nadpisać lub nacisnąć Enter, aby zachować."
    echo ""
    existing_env="yes"
    # Wczytaj obecną konfigurację (bezpiecznie, przez source)
    _src_env() {
        source "$ENV_FILE"
    }
fi

section "Krok 1/4 — Interfejsy sieciowe"
echo ""
echo "Wykrywanie interfejsów z systemu..."

# Wykryj wszystkie dostępne interfejsy (poza loopback)
available_ifaces=$(ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | grep -v lo | sort)
echo "Dostępne interfejsy: $(echo $available_ifaces | tr '\n' ' ')"

# Domyślne wartości — z istniejącego pliku LUB wykryte z systemu
_default_iface_primary=""
_default_iface_backup1=""
_default_iface_backup2=""
if [[ -n "$existing_env" ]]; then
    _src_env
    _default_iface_primary="${IFACE_PRIMARY:-$(echo "$available_ifaces" | head -1)}"
    _default_iface_backup1="${IFACE_BACKUP1:-$(echo "$available_ifaces" | sed -n '2p')}"
    _default_iface_backup2="${IFACE_BACKUP2:-}"
else
    _default_iface_primary="$(echo "$available_ifaces" | head -1)"
    _default_iface_backup1="$(echo "$available_ifaces" | sed -n '2p')"
fi

iface_primary="$(ask "IFACE_PRIMARY" "$_default_iface_primary")"
iface_backup1="$(ask "IFACE_BACKUP1" "$_default_iface_backup1")"

# Pytaj czy użytkownik chce drugi backup (opcjonalny)
echo ""
if [[ -n "$existing_env" && -n "${_default_iface_backup2:-}" ]]; then
    # BACKUP2 już istnieje — zapytaj czy go zachować
    read -rp "  Czy chcesz zachować BACKUP2 ($_default_iface_backup2)? [T/n]: " want_backup2
    want_backup2="${want_backup2:-}"
    if [[ "$want_backup2" == "n" || "$want_backup2" == "N" ]]; then
        echo "  BACKUP2 zostanie usunięty z konfiguracji."
        iface_backup2=""
        gw_backup2=""
    else
        iface_backup2="$_default_iface_backup2"
    fi
else
    read -rp "  Czy chcesz skonfigurować drugi interfejs backup (BACKUP2)? [t/N]: " want_backup2
    iface_backup2=""
    gw_backup2=""
    if [[ "$want_backup2" =~ ^[tTyY]$ ]]; then
        iface_backup2="$(ask "IFACE_BACKUP2" "$(echo "$available_ifaces" | sed -n '3p')")"
    else
        echo "  BACKUP2 pominięty — skrypt będzie działał z jednym backup-em."
    fi
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

# Domyślne gatewaye — z istniejącego pliku LUB puste
_default_gw_primary=""
_default_gw_backup1=""
_default_gw_backup2=""
if [[ -n "$existing_env" ]]; then
    _src_env
    _default_gw_primary="${GW_PRIMARY:-}"
    _default_gw_backup1="${GW_BACKUP1:-}"
    _default_gw_backup2="${GW_BACKUP2:-}"
fi

# Pytaj o każdą bramkę — domyślnie z istniejącej konfiguracji LUB puste
gw_primary="$(ask "GW_PRIMARY ($iface_primary):" "$_default_gw_primary")"
gw_backup1="$(ask "GW_BACKUP1 ($iface_backup1):" "$_default_gw_backup1")"
if [[ -n "$iface_backup2" ]]; then
	gw_backup2="$(ask "GW_BACKUP2 ($iface_backup2):" "${_default_gw_backup2:-}")"
fi

# Domyślne wartości z istniejącej konfiguracji LUB standardowe
_default_metric_primary="100"
_default_ip_list="1.1.1.1 8.8.8.8 9.9.9.9"
_default_packets_count="100"
_default_threshold_avail="60"
_default_state_file="/tmp/ip_monitor_state"
_default_log_file="/var/log/tester.log"
_default_matrix_url=""
_default_matrix_room_id=""
_default_matrix_token=""

if [[ -n "$existing_env" ]]; then
    _src_env
    _default_metric_primary="${METRIC_PRIMARY:-100}"
    # IP_LIST — odczyt z tablicy bash
    _default_ip_list=""
    for _ip in "${IP_LIST[@]}"; do
        _default_ip_list+="${_ip} "
    done
    _default_ip_list="${_default_ip_list% }"
    _default_packets_count="${PACKETS_COUNT:-100}"
    _default_threshold_avail="${THRESHOLD_AVAIL:-60}"
    _default_state_file="${STATE_FILE:-/tmp/ip_monitor_state}"
    _default_log_file="${LOG_FILE:-/var/log/tester.log}"
    _default_matrix_url="${MATRIX_URL:-}"
    _default_matrix_room_id="${MATRIX_ROOM_ID:-}"
    _default_matrix_token="${MATRIX_ACCESS_TOKEN:-}"
fi

section "Krok 3/4 — Pozostała konfiguracja"
echo ""
echo "--- Metryki tras ---"
echo "Metryki są obliczane AUTOMATYCZNIE względem aktualnej trasy głównej:"
echo "  PRIMARY : aktualna metryka z systemu (np. 100)"
echo "  BACKUP1 : primary + 10 (np. 110)"
echo "  BACKUP2 : primary + 20 (np. 120)"
echo "Przy awarii backup dostaje metrykę o 10 mniejszą niż primary."
metric_primary="$(ask "METRIC_PRIMARY (bazowa, jeśli nie wykryta z systemu):" "$_default_metric_primary")"

echo ""
echo "--- Testowanie łączności ---"
echo "Skrypt pinguje WSZYSTKIE podane IP i oblicza ŚREDNIĄ % dostępności."
echo "Jeśli średnia < progu → łącze jest uznawane za „martwe\" i przełączany jest backup."
echo "Liczba adresów: 1-10"
ip_list_input="$(ask "IP_LIST (adresy IP do pingowania, oddzielone spacą):" "$_default_ip_list")"
packets_count="$(ask "PACKETS_COUNT (liczba pakietów ping do KAŻDEGO IP):" "$_default_packets_count")"
threshold_avail="$(ask "THRESHOLD_AVAIL (% średniej dostępności, <wartość = awaria):" "$_default_threshold_avail")"

echo ""
echo "--- Pliki i ścieżki ---"
state_file="$(ask "STATE_FILE (plik stanu):" "$_default_state_file")"
log_file="$(ask "LOG_FILE (plik logów):" "$_default_log_file")"
# Ścieżka do skryptu Python — ustawiana automatycznie, bez pytania
python_script_path="${SCRIPT_DIR}/powiadomienie.py"

echo ""
echo "--- Asterisk ---"
echo "Po każdej zmianie łącza skrypt może automatycznie przeładować konfigurację SIP."
echo "Wyłącz tę opcję jeśli nie używasz Asteriska."
reload_asterisk="$(ask "RELOAD_ASTERISK (przeładowuj SIP po zmianie łącza)? [T/n]:" "${_default_reload_asterisk:-true}")"

section "Krok 4/4 — Matrix (powiadomienia)"
echo ""
echo "--- Serwer Matrix ---"
matrix_url="$(ask "MATRIX_URL (serwer Matrix, np. https://chat.example.com):" "$_default_matrix_url")"
matrix_room_id="$(ask "MATRIX_ROOM_ID (np. !xyz:server.com):" "$_default_matrix_room_id")"
# Pokaż token z istniejącej konfiguracji (obcięty + ...) LUB puste
_matrix_hint="${_default_matrix_token}"
if [[ -n "$_matrix_hint" ]]; then
    _matrix_hint="${_matrix_hint:0:10}..."
fi
matrix_access_token="$(ask "MATRIX_ACCESS_TOKEN (token dostępowy):" "$_matrix_hint")"

# Użyj podanej listy IP lub domyślnej
ip_list="${ip_list_input:-1.1.1.1 8.8.8.8 9.9.9.9}"

# Walidacja: 1-10 adresów IP
_ip_count=0
for _w in $ip_list; do ((_ip_count++)); done
if [[ $_ip_count -lt 1 || $_ip_count -gt 10 ]]; then
    echo ""
    echo "⚠  Liczba adresów IP ($_ip_count) musi być od 1 do 10."
    exit 1
fi

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
echo "  IP_LIST         = $ip_list  ($_ip_count adresów, limit: 1-10)"
echo "  PACKETS_COUNT   = $packets_count"
echo "  THRESHOLD_AVAIL = ${threshold_avail}% (średnia dostępność <wartość → awaria)"
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

# Progół średniej dostępności (wszystkie IP razem): <${threshold_avail}% = awaria, ≥${threshold_avail}% = OK
THRESHOLD_AVAIL=${threshold_avail}

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

# Czy przeładowywać Asteriska po każdej zmianie łącza? (true/false)
RELOAD_ASTERISK=${reload_asterisk}

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

# --- rp_filter=2 (weak-host mode, potrzebne przy wielu łączach z trasami domyślnymi) ---
echo ""
echo "--- Konfiguracja sysctl (rp_filter) ---"
current_rp=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo "?")
if [[ "$current_rp" != "2" ]]; then
    sysctl_dir="/etc/sysctl.d"
    conf_file="${sysctl_dir}/99-ip-monitor-rpfilter.conf"
    [[ ! -d "$sysctl_dir" ]] && mkdir -p "$sysctl_dir"
    echo "net.ipv4.conf.all.rp_filter = 2" > "$conf_file"
    sysctl -w net.ipv4.conf.all.rp_filter=2 >/dev/null 2>&1
    echo "  ✓ rp_filter ustawiony na 2 (przedtem: ${current_rp}, plik: $conf_file)"
else
    echo "  ✓ rp_filter już ustawiony na 2 — pomijam"
fi

# --- Systemd timer (profesjonalny sposób na interwały < 1 min) ---
echo ""
echo "--- Konfiguracja uruchamiania (systemd timer) ---"
echo ""
echo "Systemd timer to profesjonalny sposób na częste uruchamianie skryptu."
echo "Obsługuje interwały od sekund, ma status/start/stop przez systemctl,"
echo "a lock file w skrypcie zapobiegnie zduplikowaniu instancji."
SCRIPT_ABS_PATH="$(cd "$SCRIPT_DIR" && pwd)/main.sh"
TIMER_NAME="ip-monitor"

# Wykryj obecny interwał timera (jeśli istnieje)
_existing_timer_seconds="10"
if systemctl get-property "ip-monitor.timer" OnUnitActiveSec >/dev/null 2>&1; then
    _val=$(systemctl get-property --value "ip-monitor.timer" OnUnitActiveSec 2>/dev/null || echo "")
    # systemd zwraca np. "10s" lub "500ms" — wyciągnij liczbę sekund
    if [[ "$_val" =~ ^([0-9]+)s$ ]]; then
        _existing_timer_seconds="${BASH_REMATCH[1]}"
    fi
fi

echo ""
if systemctl is-active --quiet "ip-monitor.timer" 2>/dev/null; then
    echo "✓ Wykryto istniejący timer: ${TIMER_NAME}.timer (interwał: ${_existing_timer_seconds}s)"
else
    echo "Timer ${TIMER_NAME}.timer nie jest aktywny — konfiguruję od początku."
fi
echo ""
read -rp "  Co ile sekund ma uruchamiać się skrypt? [${_existing_timer_seconds}]: " timer_seconds
timer_seconds="${timer_seconds:-$_existing_timer_seconds}"

# --- Stwórz service file ---
cat > /etc/systemd/system/${TIMER_NAME}.service <<EOF
[Unit]
Description=Network Failover Monitor — main.sh
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/bash ${SCRIPT_ABS_PATH}
TimeoutSec=300
EOF

# --- Stwórz timer file ---
cat > /etc/systemd/system/${TIMER_NAME}.timer <<EOF
[Unit]
Description=Uruchamia ${TIMER_NAME}.service co ${timer_seconds}s

[Timer]
OnBootSec=5
OnUnitActiveSec=${timer_seconds}
AccuracySec=1

[Install]
WantedBy=timers.target
EOF

# --- Włącz i uruchom timer ---
systemctl daemon-reload
systemctl enable --now ${TIMER_NAME}.timer

echo "  ✓ Systemd timer dodany: ${TIMER_NAME}.timer (co ${timer_seconds}s)"
echo ""
echo "Zarządzanie:"
echo "  systemctl status ${TIMER_NAME}.timer    — status + następne uruchomienie"
echo "  systemctl stop ${TIMER_NAME}.timer       — zatrzymaj"
echo "  systemctl start ${TIMER_NAME}.timer      — uruchom ponownie"
echo "  journalctl -u ${TIMER_NAME}.service       — logi z wykonania"

echo ""
