#!/bin/bash
set -u

# ========================
# Skrypt przeładowujący konfigurację SIP/PJSIP w Asterisku
# ========================
# Wywoływany z main.sh po każdej zmianie routingu.
# Wczytuje konfigurację z config.sh (współdzielony plik konfiguracyjny).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "${SCRIPT_DIR}/environments.txt"

# Zapisuje wiadomość do pliku logów z datą i godziną
log(){ echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG_FILE"; }

# Znajdź binarkę Asteriska
BIN="${ASTERISK_BIN:-$(command -v asterisk || echo /usr/sbin/asterisk)}"

if [[ -x "$BIN" ]]; then
	$BIN -rx 'sip reload' >> "$LOG_FILE" 2>&1 || log "UWAGA: 'sip reload' zwrócił błąd"
	$BIN -rx 'pjsip reload' >> "$LOG_FILE" 2>&1 || true
	log "Asterisk: konfiguracja SIP/PJSIP przeładowana pomyślnie"
else
	log "UWAGA: nie znaleziono binarki asterisk ($BIN) – pomijam reload"
	exit 1
fi
