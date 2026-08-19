#!/bin/bash
set -u

# ========================
# Wczytaj konfigurację z osobnego pliku
# ========================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/environments.txt"

# ========================
# Funkcje pomocnicze
# ========================

# Zapisuje wiadomość do pliku logów z datą i godziną
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Ścieżka do skryptu przeładowującego Asteriska
ASTERISK_RELOAD_SCRIPT="$(dirname "$0")/asterisk_reload.sh"

# Odczytuje aktualną metrykę primary z systemu (NIE zmienia jej!)
# Ustawia backupy z offsetem +10 / +20
prefer_primary(){
	local base_metric
	base_metric="$(route_metric_for_iface "$IFACE_PRIMARY")"
	if [[ -z "$base_metric" ]]; then
		base_metric=100  # fallback jak nie ma trasy
	fi
	local m_backup1=$(( base_metric + 10 ))
	local m_backup2=$(( base_metric + 20 ))

	ip -4 route replace default via "$GW_BACKUP1"  dev "$IFACE_BACKUP1"  metric "$m_backup1"
	if [[ -n "${IFACE_BACKUP2:-}" && -n "${GW_BACKUP2:-}" ]]; then
		ip -4 route replace default via "$GW_BACKUP2"  dev "$IFACE_BACKUP2"  metric "$m_backup2"
		log "Preferencja: PRIMARY($base_metric) -> BACKUP1($m_backup1) -> BACKUP2($m_backup2)"
	else
		log "Preferencja: PRIMARY($base_metric) -> BACKUP1($m_backup1)"
	fi
}

# Ustawia routing z priorytetem na backup1
# Backup1 = primary - 10 (niższa metryka = wyższy priorytet)
# Primary NIE jest dotykana
prefer_backup1(){
	local base_metric
	base_metric="$(route_metric_for_iface "$IFACE_PRIMARY")"
	if [[ -z "$base_metric" ]]; then
		base_metric=100
	fi
	local m_backup1=$(( base_metric - 10 ))
	local m_backup2=$(( base_metric + 5 ))

	ip -4 route replace default via "$GW_BACKUP1"  dev "$IFACE_BACKUP1"  metric "$m_backup1"
	if [[ -n "${IFACE_BACKUP2:-}" && -n "${GW_BACKUP2:-}" ]]; then
		ip -4 route replace default via "$GW_BACKUP2"  dev "$IFACE_BACKUP2"  metric "$m_backup2"
		log "Preferencja: BACKUP1($m_backup1) -> PRIMARY($base_metric) -> BACKUP2($m_backup2)"
	else
		log "Preferencja: BACKUP1($m_backup1) -> PRIMARY($base_metric)"
	fi
}

# Ustawia routing z priorytetem na backup2
# Backup2 = primary - 10 (niższa metryka = wyższy priorytet)
# Primary NIE jest dotykana
prefer_backup2(){
	local base_metric
	base_metric="$(route_metric_for_iface "$IFACE_PRIMARY")"
	if [[ -z "$base_metric" ]]; then
		base_metric=100
	fi
	local m_backup1=$(( base_metric + 5 ))
	local m_backup2=$(( base_metric - 10 ))

	ip -4 route replace default via "$GW_BACKUP2"  dev "$IFACE_BACKUP2"  metric "$m_backup2"
	ip -4 route replace default via "$GW_BACKUP1"  dev "$IFACE_BACKUP1"  metric "$m_backup1"
	log "Preferencja: BACKUP2($m_backup2) -> PRIMARY($base_metric) -> BACKUP1($m_backup1)"
}

# Wykonuje ping do podanego IP przez określony interfejs i zwraca liczbę odebranych pakietów
recv_count(){
	local ip="$1"
	local iface="$2"
	ping -n -I "$iface" -c "$PACKETS_COUNT" -i 0.1 "$ip" 2>/dev/null | grep -c 'ttl='
}

# Zwraca nazwę interfejsu używanego w aktualnej trasie domyślnej
current_default_dev(){
	ip -4 route show default 2>/dev/null | awk '/^default/ {print $5; exit}'
}

# Zwraca adres bramki (gateway) używanej w aktualnej trasie domyślnej
current_default_gw(){
	ip -4 route show default 2>/dev/null | awk '
	/^default/ {
		for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}
	}'
}

# Zwraca aktualną metrykę trasy domyślnej (najniższa z dostępnych)
current_default_metric(){
	ip -4 route show default 2>/dev/null | awk '/^default/ {for(i=1;i<=NF;i++) if($i=="metric") print $(i+1); exit}'
}

# Pobiera metrykę trasy dla danego interfejsu (jeśli istnieje)
route_metric_for_iface(){
	local iface="$1"
	ip -4 route show default dev "$iface" 2>/dev/null | awk '/^default/ {for(i=1;i<=NF;i++) if($i=="metric") print $(i+1); exit}'
}

# ========================
# Inicjalizacja
# ========================
log "Uruchamiam skrypt"

# ========================
# Inicjalizacja stanu
# ========================
# Jeśli plik stanu nie istnieje, tworzymy go na podstawie aktualnego routingu.
# Możliwe stany: "up" (primary), "backup1", "backup2"
if [[ ! -f "$STATE_FILE" ]]; then
	cur_dev="$(current_default_dev)"
	if [[ "$cur_dev" == "$IFACE_BACKUP1" ]]; then
		echo "backup1" > "$STATE_FILE"
	elif [[ -n "${IFACE_BACKUP2:-}" && "$cur_dev" == "$IFACE_BACKUP2" ]]; then
		echo "backup2" > "$STATE_FILE"
	else
		echo "up" > "$STATE_FILE"
	fi
	log "Init: default via $(current_default_gw) dev ${cur_dev:-?}, zapisuję stan=$(cat "$STATE_FILE")"
fi

# Odczyt ostatniego zapisanego stanu
state="$(cat "$STATE_FILE" 2>/dev/null || echo up)"

# Czy backup2 jest skonfigurowany?
has_backup2=false
if [[ -n "${IFACE_BACKUP2:-}" && -n "${GW_BACKUP2:-}" ]]; then
	has_backup2=true
fi

# Utrzymaj spójność routingu z zapisanym stanem (np. po restarcie systemu)
cur_dev="$(current_default_dev)"
if [[ "$state" == "backup1" && "$cur_dev" != "$IFACE_BACKUP1" ]]; then
	prefer_backup1
elif [[ "$state" == "backup2" && "$cur_dev" != "$IFACE_BACKUP2" ]]; then
	prefer_backup2
elif [[ "$state" == "up" && "$cur_dev" != "$IFACE_PRIMARY" ]]; then
	prefer_primary
fi

# ========================
# Testowanie łączności na wszystkich interfejsach
# ========================
# Inicjalizacja liczników — ile IP „zawaliło" / „przeszło" na każdym interfejsie
bad_primary=0
good_primary=0
bad_backup1=0
good_backup1=0
bad_backup2=0
good_backup2=0

# Pętla po wszystkich testowanych adresach IP (obsługuje 1, 2, 3+ hostów)
for ip in "${IP_LIST[@]}"; do
	# Wykonaj ping przez każdy interfejs i policz odebrane pakiety
	received_p="$(recv_count "$ip" "$IFACE_PRIMARY")"
	received_b1="$(recv_count "$ip" "$IFACE_BACKUP1")"

	if $has_backup2; then
		received_b2="$(recv_count "$ip" "$IFACE_BACKUP2")"
		log "Ping $ip -> primary($IFACE_PRIMARY): ${received_p}/${PACKETS_COUNT}, backup1($IFACE_BACKUP1): ${received_b1}/${PACKETS_COUNT}, backup2($IFACE_BACKUP2): ${received_b2}/${PACKETS_COUNT}"

		# Oceniamy wynik dla interfejsu backup2
		if [[ ${received_b2:-0} -le $THRESHOLD_PING ]]; then
			((bad_backup2++))
		else
			((good_backup2++))
		fi
	else
		log "Ping $ip -> primary($IFACE_PRIMARY): ${received_p}/${PACKETS_COUNT}, backup1($IFACE_BACKUP1): ${received_b1}/${PACKETS_COUNT}"
	fi

	# Oceniamy wynik dla interfejsu primary
	if [[ ${received_p:-0} -le $THRESHOLD_PING ]]; then
		((bad_primary++))
	else
		((good_primary++))
	fi

	# Oceniamy wynik dla interfejsu backup1
	if [[ ${received_b1:-0} -le $THRESHOLD_PING ]]; then
		((bad_backup1++))
	else
		((good_backup1++))
	fi
done

# Liczba wszystkich testowanych adresów IP
ALL_IP="${#IP_LIST[@]}"

# ========================
# Decyzja o przełączeniu łącza
# ========================
if (( good_primary == ALL_IP )); then
	# Wszystkie IP przeszły przez primary — wracamy na łącze główne (jeśli tam nie jesteśmy)
	if [[ "$state" != "up" ]]; then
		log "Primary OK — wracam na PRIMARY ($IFACE_PRIMARY)"
		python3 "$PYTHON_SCRIPT_PATH" "[CENTRALA] Wracam na łącze główne"
		prefer_primary
		echo "up" > "$STATE_FILE"
		bash "$ASTERISK_RELOAD_SCRIPT"
	fi
# Jeśli primary zawodzi na WSZYSTKICH IP...
elif (( bad_primary == ALL_IP )); then
	# Sprawdź czy backup1 działa poprawnie na wszystkich IP
	if (( good_backup1 == ALL_IP )); then
		if [[ "$state" != "backup1" ]]; then
			log "Primary NIE DZIAŁA, Backup1 OK — przełączam na BACKUP1 ($IFACE_BACKUP1)"
			python3 "$PYTHON_SCRIPT_PATH" "[CENTRALA] Przełączam na łącze backup1"
			prefer_backup1
			echo "backup1" > "$STATE_FILE"
			bash "$ASTERISK_RELOAD_SCRIPT"
		fi
	# Sprawdź czy backup2 działa poprawnie na wszystkich IP (tylko jeśli jest skonfigurowany)
	elif $has_backup2 && (( good_backup2 == ALL_IP )); then
		if [[ "$state" != "backup2" ]]; then
			log "Primary NIE DZIAŁA, Backup2 OK — przełączam na BACKUP2 ($IFACE_BACKUP2)"
			python3 "$PYTHON_SCRIPT_PATH" "[CENTRALA] Przełączam na łącze backup2"
			prefer_backup2
			echo "backup2" > "$STATE_FILE"
			bash "$ASTERISK_RELOAD_SCRIPT"
		fi
	# Żadne łącze nie działa poprawnie — pozostajemy na obecnym
	else
		if $has_backup2; then
			log "Primary, Backup1 i Backup2 NIE DZIAŁAJĄ — pozostaję na $(cat "$STATE_FILE")"
		else
			log "Primary i Backup1 NIE DZIAŁAJĄ — pozostaję na $(cat "$STATE_FILE")"
		fi
	fi
# Primary działa (przynajmniej na jednym IP), ale backupy też są testowane...
elif (( good_backup1 < ALL_IP )); then
	# Backup1 nie działa idealnie — sprawdź czy backup2 jest lepszy (tylko jeśli istnieje)
	if $has_backup2 && (( good_backup2 == ALL_IP )) && [[ "$state" != "backup2" ]]; then
		log "Backup1 słaby, Backup2 OK — przełączam na BACKUP2 ($IFACE_BACKUP2)"
		python3 "$PYTHON_SCRIPT_PATH" "[CENTRALA] Przełączam na łącze backup2 (backup1 słaby)"
		prefer_backup2
		echo "backup2" > "$STATE_FILE"
		bash "$ASTERISK_RELOAD_SCRIPT"
	fi
fi
