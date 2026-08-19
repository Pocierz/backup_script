#!/bin/bash
set -u

# ========================
# Wczytaj konfigurację z osobnego pliku
# ========================
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/environments.txt"

# ========================
# Lock file — zapobiega jednoczesnemu uruchomieniu kilku instancji
# ========================
LOCK_FILE="${STATE_FILE}.lock"

# Sprawdź czy inna instancja już działa
if [[ -f "$LOCK_FILE" ]]; then
    old_pid=$(cat "$LOCK_FILE" 2>/dev/null)
    if [[ -n "$old_pid" ]] && kill -0 "$old_pid" 2>/dev/null; then
        exit 0  # inna instancja żyje — wyjdź
    fi
    rm -f "$LOCK_FILE"  # stary plik po zabitym procesie
fi

echo "$$" > "$LOCK_FILE"

# Usuń lock przy wyjściu (normalnym lub awaryjnym)
cleanup(){ rm -f "$LOCK_FILE"; }
trap cleanup EXIT INT TERM

# ========================
# Funkcje pomocnicze
# ========================

# Zapisuje wiadomość do pliku logów z datą i godziną
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Ścieżka do skryptu przeładowującego Asteriska
ASTERISK_RELOAD_SCRIPT="$(dirname "$0")/asterisk_reload.sh"

# Ustawia trasę domyślną dla danego interfejsu/gatewaya z podaną metryką.
# Najpierw usuwa WSZYSTKIE istniejące trasy default via GW dev IFACE,
# potem dodaje jedną z poprawną metryką.
# Działa też gdy trasa nie istnieje (del jest cichy, add zawsze zadziała).
set_default_route(){
	local gw="$1" iface="$2" metric="$3"
	ip -4 route del default via "$gw" dev "$iface" 2>/dev/null
	ip -4 route add default via "$gw" dev "$iface" metric "$metric" 2>/dev/null
}

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

	set_default_route "$GW_BACKUP1" "$IFACE_BACKUP1" "$m_backup1"
	if [[ -n "${IFACE_BACKUP2:-}" && -n "${GW_BACKUP2:-}" ]]; then
		set_default_route "$GW_BACKUP2" "$IFACE_BACKUP2" "$m_backup2"
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

	set_default_route "$GW_BACKUP1" "$IFACE_BACKUP1" "$m_backup1"
	if [[ -n "${IFACE_BACKUP2:-}" && -n "${GW_BACKUP2:-}" ]]; then
		set_default_route "$GW_BACKUP2" "$IFACE_BACKUP2" "$m_backup2"
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

	set_default_route "$GW_BACKUP2" "$IFACE_BACKUP2" "$m_backup2"
	set_default_route "$GW_BACKUP1" "$IFACE_BACKUP1" "$m_backup1"
	log "Preferencja: BACKUP2($m_backup2) -> PRIMARY($base_metric) -> BACKUP1($m_backup1)"
}

# Wykonuje ping do podanego IP przez określony interfejs i zwraca liczbę odebranych pakietów
recv_count(){
	local ip="$1"
	local iface="$2"
	ping -n -I "$iface" -c "$PACKETS_COUNT" -i 0.1 "$ip" 2>/dev/null | grep -c 'ttl='
}

# Oblicza średnią % dostępności dla danego interfejsu.
# Pinguje WSZYSTKIE IP z IP_LIST (sekwencyjnie, ale wyniki są sumowane).
# Zwraca procent: 0-100 (np. 85 = 85% pakietów dotarło)
availability_pct(){
	local iface="$1"
	local total_sent=0
	local total_recv=0

	for ip in "${IP_LIST[@]}"; do
		recv="$(recv_count "$ip" "$iface")"
		total_recv=$(( total_recv + ${recv:-0} ))
		total_sent=$(( total_sent + PACKETS_COUNT ))
		log "  Ping $ip via $iface: ${recv}/${PACKETS_COUNT}"
	done

	# Oblicz % (całkowitoliczbowa arytmetyka, zaokrąglenie w dół)
	if [[ $total_sent -gt 0 ]]; then
		echo $(( total_recv * 100 / total_sent ))
	else
		echo 0
	fi
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

# Przywróć trasy backupów na KAŻDYM uruchomieniu (nawet jeśli stan się nie zmienił).
# Zapewnia to że trasę backupa da się użyć gdy nagle zniknie.
if [[ "$state" == "backup1" ]]; then
	prefer_backup1
elif [[ "$state" == "backup2" ]]; then
	prefer_backup2
else
	prefer_primary  # stan = „up" lub inny — przywróć backupy z offsetem od primary
fi

# Liczba testowanych adresów IP (walidacja: 1-10)
ALL_IP="${#IP_LIST[@]}"
if [[ $ALL_IP -lt 1 || $ALL_IP -gt 10 ]]; then
    log "BŁĄD: IP_LIST ma ${ALL_IP} adres(ów) — wymagane 1-10."
    exit 1
fi

# ========================
# Testowanie łączności na wszystkich interfejsach
# ========================
# Dla każdego interfejsu obliczamy średnią % dostępności (wszystkie IP razem).
# Jeśli średnia < THRESHOLD_AVAIL → interfejs jest „martwy".

# Liczba testowanych adresów IP (walidacja: 1-10)
ALL_IP="${#IP_LIST[@]}"
if [[ $ALL_IP -lt 1 || $ALL_IP -gt 10 ]]; then
    log "BŁĄD: IP_LIST ma ${ALL_IP} adres(ów) — wymagane 1-10."
    exit 1
fi

log "Testuję łączność (próg: ${THRESHOLD_AVAIL}%, IP: ${IP_LIST[*]})"

# --- Primary ---
avail_primary="$(availability_pct "$IFACE_PRIMARY")"
log "Dostępność PRIMARY($IFACE_PRIMARY): ${avail_primary}%"

# --- Backup1 ---
avail_backup1="$(availability_pct "$IFACE_BACKUP1")"
log "Dostępność BACKUP1($IFACE_BACKUP1): ${avail_backup1}%"

# --- Backup2 (opcjonalny) ---
avail_backup2=0
if $has_backup2; then
	avail_backup2="$(availability_pct "$IFACE_BACKUP2")"
	log "Dostępność BACKUP2($IFACE_BACKUP2): ${avail_backup2}%"
fi

# ========================
# Decyzja o przełączeniu łącza
# ========================
# Primary jest OK jeśli średnia dostępność >= THRESHOLD_AVAIL
primary_ok=false
[[ $avail_primary -ge $THRESHOLD_AVAIL ]] && primary_ok=true

backup1_ok=false
[[ $avail_backup1 -ge $THRESHOLD_AVAIL ]] && backup1_ok=true

backup2_ok=false
if $has_backup2; then
	[[ $avail_backup2 -ge $THRESHOLD_AVAIL ]] && backup2_ok=true
fi

if $primary_ok; then
	# Primary OK — wracamy na łącze główne (jeśli tam nie jesteśmy)
	if [[ "$state" != "up" ]]; then
		log "Primary OK (${avail_primary}%) — wracam na PRIMARY ($IFACE_PRIMARY)"
		python3 "$PYTHON_SCRIPT_PATH" "[CENTRALA] Wracam na łącze główne (dostępność: ${avail_primary}%)"
		prefer_primary
		echo "up" > "$STATE_FILE"
		bash "$ASTERISK_RELOAD_SCRIPT"
	else
		log "Primary OK (${avail_primary}%), backup1 (${avail_backup1}%)$([ $has_backup2 ] && echo ", backup2 (${avail_backup2}%)") — bez zmian"
	fi
elif $backup1_ok; then
	# Primary nie działa, ale backup1 OK
	if [[ "$state" != "backup1" ]]; then
		log "Primary (${avail_primary}%), Backup1 OK (${avail_backup1}%) — przełączam na BACKUP1 ($IFACE_BACKUP1)"
		python3 "$PYTHON_SCRIPT_PATH" "[CENTRALA] Przełączam na łącze backup1 (dostępność: ${avail_backup1}%)"
		prefer_backup1
		echo "backup1" > "$STATE_FILE"
		bash "$ASTERISK_RELOAD_SCRIPT"
	else
		log "Backup1 OK (${avail_backup1}%) — bez zmian"
	fi
elif $has_backup2 && $backup2_ok; then
	# Backup1 nie działa, ale backup2 OK
	if [[ "$state" != "backup2" ]]; then
		log "Primary (${avail_primary}%), Backup1 (${avail_backup1}%), Backup2 OK (${avail_backup2}%) — przełączam na BACKUP2 ($IFACE_BACKUP2)"
		python3 "$PYTHON_SCRIPT_PATH" "[CENTRALA] Przełączam na łącze backup2 (dostępność: ${avail_backup2}%)"
		prefer_backup2
		echo "backup2" > "$STATE_FILE"
		bash "$ASTERISK_RELOAD_SCRIPT"
	else
		log "Backup2 OK (${avail_backup2}%) — bez zmian"
	fi
else
	# Żadne łącze nie osiąga progu
	if $has_backup2; then
		log "Primary (${avail_primary}%), Backup1 (${avail_backup1}%), Backup2 (${avail_backup2}%) < ${THRESHOLD_AVAIL}% — wszystkie poniżej progu, pozostaję na $(cat "$STATE_FILE")"
	else
		log "Primary (${avail_primary}%), Backup1 (${avail_backup1}%) < ${THRESHOLD_AVAIL}% — oba poniżej progu, pozostaję na $(cat "$STATE_FILE")"
	fi
fi
