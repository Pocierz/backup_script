# -*- coding: utf-8 -*-
import requests
import sys
import os
import warnings
from urllib3.exceptions import InsecureRequestWarning

warnings.simplefilter('ignore', InsecureRequestWarning)

# Wczytaj zmienne z environments.txt (plik konfiguracyjny bash/Python)
def load_env_file(path):
    """Odczytuje plik environments.txt i zwraca słownik zmiennych KEY=VALUE."""
    env = {}
    if not os.path.isfile(path):
        return env
    with open(path, 'r', encoding='utf-8') as f:
        for line in f:
            line = line.strip()
            # Pomiń puste linie i komentarze
            if not line or line.startswith('#'):
                continue
            # Parsuj tylko linie w formacie KEY="VALUE" lub KEY=VALUE
            if '=' in line:
                key, _, value = line.partition('=')
                key = key.strip()
                value = value.strip().strip('"').strip("'")
                env[key] = value
    return env

# Ścieżka do pliku environments.txt (w tym samym katalogu co skrypt)
ENV_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'environments.txt')
env_vars = load_env_file(ENV_FILE)

matrix_url = env_vars.get('MATRIX_URL', '').rstrip('/')
matrix_room_id = env_vars.get('MATRIX_ROOM_ID', '')
access_token = env_vars.get('MATRIX_ACCESS_TOKEN', '')

if not matrix_url or not matrix_room_id or not access_token:
    print("Błąd: brak MATRIX_URL, MATRIX_ROOM_ID lub MATRIX_ACCESS_TOKEN w environments.txt")
    sys.exit(1)

# Zbuduj pełny endpoint Matrix
matrix_endpoint = f"{matrix_url}/_matrix/client/r0/rooms/{matrix_room_id}/send/m.room.message"

headers = {"Authorization": "Bearer {}".format(access_token)}

def wyslij_powiadomienie(tresc):
    try:
        data = {
            "msgtype": "m.text",
            "body": tresc
        }
        response = requests.post(matrix_endpoint, headers=headers, json=data, verify=False)
        response.raise_for_status()
        return response.status_code, response.json()
    except requests.exceptions.RequestException as e:
        return 500, str(e)

def main():
    if len(sys.argv) < 2:
        print("Użycie: powiadomienie.py <wiadomość>")
        sys.exit(1)

    # Połącz wszystkie argumenty w jedną wiadomość
    tresc = ' '.join(sys.argv[1:])

    status, result = wyslij_powiadomienie(tresc)

    if status == 200:
        print("Powiadomienie wysłane pomyślnie.")
    else:
        print(f"Błąd podczas wysyłania powiadomienia (kod: {status}): {result}")
        sys.exit(1)

if __name__ == "__main__":
    main()