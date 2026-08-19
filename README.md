# System monitorowania i przełączania łącza internetowego

Automatyczny system wykrywania awarii łącza internetowego i przełączania na łącze zapasowe.

## Jak to działa

System stale monitoruje dostępność internetu na głównym łączu sieciowym. Gdy wykryje problem, automatycznie przekierowuje ruch przez łącze zapasowe. Po naprawie głównego łącza ruch wraca na nie automatycznie.

### Co się dzieje krok po kroku

1. **Testowanie** — skrypt wysyła pakiety testowe do kilku serwerów (np. 1.1.1.1, 8.8.8.8, 9.9.9.9) przez każde dostępne łącze i oblicza średnią dostępność w procentach.

2. **Decyzja** — jeśli średnia dostępność głównego łącza spadnie poniżej ustawionego progu (domyślnie 60%), system uznaje je za niedziałające.

3. **Przełączenie** — ruch jest przekierowywany na pierwsze łącze zapasowe. Jeśli też nie działa, system próbuje drugiego łącza zapasowego (jeśli jest skonfigurowane).

4. **Powrót** — gdy główne łącze zacznie ponownie działać poprawnie, ruch wraca na nie automatycznie.

5. **Powiadomienia** — o każdej zmianie połączenia system wysyła powiadomienie przez Matrix (opcjonalnie).

## Priorytety łącz

System zawsze próbuje użyć łącza w kolejności:

1. **Główne (PRIMARY)** — preferowane łącze
2. **Zapasowe 1 (BACKUP1)** — awaryjne, używane gdy główne nie działa
3. **Zapasowe 2 (BACKUP2)** — opcjonalne, używane gdy oba powyższe nie działają

## Instalacja

Uruchom instalator z uprawnieniami administratora:

```bash
sudo bash install.sh
```

Instalator przeprowadzi Cię przez konfigurację krok po kroku:

- **Krok 1** — wybierz interfejsy sieciowe (główny i zapasowe)
- **Krok 2** — podaj adresy bram (gateway) dla każdego łącza
- **Krok 3** — skonfiguruj testowanie (adresy IP do pingowania, progi dostępności)
- **Krok 4** — opcjonalnie skonfiguruj powiadomienia Matrix

Po instalacji system uruchomi się automatycznie i będzie działał w tle.

## Zarządzanie systemem

| Akcja | Komenda |
|---|---|
| Sprawdź status | `systemctl status ip-monitor.timer` |
| Zatrzymaj monitoring | `systemctl stop ip-monitor.timer` |
| Włącz ponownie | `systemctl start ip-monitor.timer` |
| Przeglądaj logi | `journalctl -u ip-monitor.service -f` |
| Uruchom test ręcznie | `bash main.sh` |

## Konfiguracja

Wszystkie ustawienia znajdują się w pliku `environments.txt`. Edycja tego pliku pozwala zmienić zachowanie systemu bez modyfikowania kodu.

### Kluczowe ustawienia

- **IP_LIST** — lista adresów IP testowanych przez system (1–10 adresów). System pinguje je wszystkie równocześnie i oblicza średnią dostępność.
- **PACKETS_COUNT** — liczba pakietów wysyłanych do każdego adresu podczas testu.
- **THRESHOLD_AVAIL** — próg dostępności w procentach. Jeśli średnia dostępność spadnie poniżej tej wartości, łącze jest uznawane za niedziałające. Domyślnie 60%.

### Przykład zmiany progu dostępności

Jeśli chcesz, aby system był bardziej lub mniej czuły na straty pakietów, zmień wartość `THRESHOLD_AVAIL` w `environments.txt`:

- **Wyższy próg** (np. 80%) — system szybciej wykrywa problemy, ale może reagować na chwilowe spadki jakości
- **Niższy próg** (np. 40%) — system toleruje większe straty przed przełączeniem

## Ponowna konfiguracja

Jeśli chcesz zmienić ustawienia po instalacji, uruchom ponownie:

```bash
sudo bash install.sh
```

Skrypt wczyta aktualne wartości jako domyślne. Możesz nacisnąć Enter, aby zachować istniejącą wartość, lub wpisać nową.

## Jak często system testuje łączność?

Domyślnie skrypt uruchamia się co 10 sekund. Czas ten można zmienić podczas instalacji lub edytując plik timera systemd:

```bash
sudo nano /etc/systemd/system/ip-monitor.timer
# Zmień OnUnitActiveSec=<sekundy>
sudo systemctl daemon-reload
sudo systemctl restart ip-monitor.timer
```

## Pliki systemowe

| Plik | Opis |
|---|---|
| `main.sh` | Główny skrypt monitorujący |
| `install.sh` | Interaktywny instalator |
| `environments.txt` | Konfiguracja (tworzona przez instalator) |
| `powiadomienie.py` | Wysyłanie powiadomień Matrix |
| `asterisk_reload.sh` | Przeładowanie Asteriska po zmianie łącza |
