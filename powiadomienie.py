# -*- coding: utf-8 -*-
import requests
import sys
import warnings
from urllib3.exceptions import InsecureRequestWarning

warnings.simplefilter('ignore', InsecureRequestWarning)

matrix_url = "https://chat2.nowatel.com/_matrix/client/r0/rooms/!zTZpotRKQaSPnoUAtu:chat2.nowatel.com/send/m.room.message"
access_token = "syt_YWxlcnRib3Q_FtfEPXqdLeXCtoJDZipC_21DXad"
headers = {"Authorization": "Bearer {}".format(access_token)}

def wyslij_powiadomienie(tresc):
    try:
        data = {
            "msgtype": "m.text",
            "body": tresc
        }
        response = requests.post(matrix_url, headers=headers, json=data, verify=False)
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