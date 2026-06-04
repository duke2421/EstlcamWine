# Estlcam Linux Control Workaround

Experimenteller Workaround, um die Estlcam-Steuerungsfunktion unter Wine auf
Linux mit einem Arduino-basierten Controller nutzen zu koennen.

Entstanden ist das Projekt beim Debugging von Estlcam 11.245 mit einem Arduino
Nano / CH340-USB-Seriell-Adapter. In diesem Setup konnte Estlcam die Firmware
unter Wine auf den Controller flashen, meldete danach aber, dass die Steuerung
nicht antwortet. Derselbe Controller funktionierte unter Windows.

Der Workaround vermeidet den direkten Zugriff von Wine auf das physische
serielle Geraet. Estlcam spricht stattdessen mit einem Pseudo-Terminal
(`/dev/pts/...`), das als Wine-COM-Port eingebunden wird. Ein Python-Proxy
leitet die Daten zwischen diesem Pseudo-Terminal und dem echten Controller-Port
wie `/dev/ttyUSB0` weiter. Ein kleiner `LD_PRELOAD`-Shim emuliert
Modem-Control-ioctls auf dem Pseudo-Terminal, weil Wine dort `TIOCMGET` und
`TIOCMSET` erwartet.

## Status

Das ist kein offizielles Estlcam-Feature und kein Wine-Patch. Es ist ein
pragmatischer Workaround zum Testen. Bitte vorsichtig verwenden, besonders bevor
Motoren, Spindeln, Relais oder andere CNC-Hardware verbunden werden, die sich
unerwartet bewegen kann.

Getestetes Setup:

- Estlcam 11.245 64-bit
- Wine 11.10
- Arduino Nano mit Estlcam-Firmware `Estlcam V11.004 E_328`
- CH340-USB-Seriell-Adapter mit Linux-Kernel-Treiber `ch341`
- CachyOS / Arch-artiges System mit seriellem Zugriff ueber Gruppe `uucp`

Andere Estlcam-Versionen, Wine-Versionen, USB-Seriell-Chips und Distributionen
koennen funktionieren, muessen aber nicht.

## Voraussetzungen

Zur Laufzeit:

- Linux
- Wine
- Python 3
- Zugriff auf das serielle Controller-Geraet, zum Beispiel `/dev/ttyUSB0`
- Ein funktionierender Kernel-Treiber fuer den USB-Seriell-Adapter, zum Beispiel
  `ch341` fuer CH340-basierte Arduino-Nano-Clones

Zum Bauen:

- `gcc`
- `make`
- glibc-Entwicklungsheader

Nuetzlich zur Diagnose, aber nicht zwingend noetig:

- `lsusb`
- `dmesg`
- `strace`
- `lsof` oder `fuser`, damit das Startskript erkennen kann, ob der serielle
  Port bereits von einem anderen Prozess verwendet wird

## Abhaengigkeiten Installieren

### Arch Linux / CachyOS / Manjaro

```bash
sudo pacman -S wine python gcc make lsof psmisc
```

Der Benutzer muss den seriellen Port oeffnen duerfen. Auf Arch-artigen Systemen
ist das normalerweise die Gruppe `uucp`:

```bash
sudo usermod -aG uucp "$USER"
```

Danach abmelden und wieder anmelden, damit die neue Gruppenmitgliedschaft aktiv
wird.

### Debian / Ubuntu

```bash
sudo apt update
sudo apt install wine python3 gcc make libc6-dev lsof psmisc
```

Auf Debian-artigen Systemen ist serieller Zugriff oft ueber die Gruppe `dialout`
geregelt:

```bash
sudo usermod -aG dialout "$USER"
```

Danach abmelden und wieder anmelden.

### Fedora

```bash
sudo dnf install wine python3 gcc make glibc-devel lsof psmisc
```

Die Gruppe fuer seriellen Zugriff unterscheidet sich je nach Distribution.
Pruefe Besitzer und Gruppe des Geraets:

```bash
ls -l /dev/ttyUSB0
```

Falls noetig, fuege Deinen Benutzer der dort angezeigten Gruppe hinzu und melde
Dich danach neu an.

## Bauen

Repository klonen oder diesen Ordner kopieren und dann ausfuehren:

```bash
make
```

Dadurch wird die Datei gebaut:

```text
wine_tiocm_pty_shim.so
```

## Estlcam In Wine Vorbereiten

Installiere Estlcam in einen Wine-Prefix. Du kannst einen bestehenden Prefix
verwenden oder einen dedizierten Prefix erstellen.

Beispiel fuer einen eigenen Prefix:

```bash
export WINEPREFIX="$HOME/.wine-estlcam"
wineboot -u
wine /pfad/zu/Estlcam_64_11245.exe
```

Starte Estlcam einmal normal, konfiguriere die CNC-Steuerung und lasse Estlcam
seine Einstellungsdateien anlegen.

Wenn Estlcam den Arduino flashen kann, danach aber meldet, dass die Steuerung
nicht antwortet, schliesse Estlcam und teste den Workaround.

## Starten

Einfacher Start:

```bash
./run-estlcam-proxy.sh --wineprefix "$HOME/.wine-estlcam" --device /dev/ttyUSB0
```

Im normalen `stable`-Modus erledigt das Skript diese Schritte:

1. Startet `serial_proxy.py` auf dem echten seriellen Geraet.
2. Erstellt ein Pseudo-Terminal wie `/dev/pts/3`.
3. Mappt Wine `COM4` auf dieses Pseudo-Terminal.
4. Setzt in Estlcams CNC-Einstellungsdatei `Enabled=yes` und `Port=COM4`,
   sofern die Datei existiert.
5. Startet Estlcam mit `LD_PRELOAD=wine_tiocm_pty_shim.so`.
6. Beendet den Proxy automatisch, wenn Estlcam geschlossen wird.

Beim Start sollte eine Ausgabe in dieser Form erscheinen:

```text
Using COM4 -> /dev/pts/3 -> /dev/ttyUSB0
Wine dosdevice: .../dosdevices/com4 -> /dev/pts/3
Modem lines: stable
```

Der Proxy-Log wird hier geschrieben:

```text
serial-proxy.log
```

Das Skript setzt standardmaessig `WINEDEBUG=-comm`, damit Wines serielle
FIXME-Meldungen wie `fixme:comm:wait_on EV_RXFLAG not handled` die Konsole
nicht fluten. Fuer Debugging kann `WINEDEBUG` explizit gesetzt werden, zum
Beispiel:

```bash
WINEDEBUG=+comm ./run-estlcam-proxy.sh --wineprefix "$HOME/.wine-estlcam"
```

Wenn der Controller antwortet, enthaelt der Log Daten in beide Richtungen. Bei
einem Nano mit Estlcam-Firmware kann zum Beispiel eine Firmwarekennung wie diese
auftauchen:

```text
Estlcam V11.004 E_328
```

## Optionen

Hilfe anzeigen:

```bash
./run-estlcam-proxy.sh --help
```

Typischer Aufruf:

```bash
./run-estlcam-proxy.sh \
  --wineprefix "$HOME/.wine-estlcam" \
  --device /dev/ttyUSB0 \
  --com-port COM4 \
  --baud 115200
```

### Firmware Flashen

Fuer den normalen Steuerbetrieb nutzt das Skript den Proxy und haelt DTR/RTS auf
der echten Arduino-Seite stabil. Das verhindert unbeabsichtigte Resets.

Zum Flashen der Estlcam-Firmware muss Estlcam den Arduino Nano aber ueber
DTR/RTS direkt resetten koennen, damit der Bootloader startet. Starte Estlcam
fuer ein Firmware-Update deshalb so:

```bash
./run-estlcam-proxy.sh \
  --wineprefix "$HOME/.wine-estlcam" \
  --device /dev/ttyUSB0 \
  --modem-lines forward
```

In diesem Modus wird der Proxy komplett deaktiviert. Das Skript mappt den
gewaehlten COM-Port direkt auf das echte serielle Geraet, zum Beispiel:

```text
COM4 -> /dev/ttyUSB0
```

Beim Start sollte eine Ausgabe in dieser Form erscheinen:

```text
Using COM4 -> /dev/ttyUSB0 directly
Wine dosdevice: .../dosdevices/com4 -> /dev/ttyUSB0
Proxy: disabled for firmware flashing
```

Nach dem Firmware-Update Estlcam schliessen und fuer den normalen Steuerbetrieb
wieder ohne `--modem-lines forward` starten:

```bash
./run-estlcam-proxy.sh --wineprefix "$HOME/.wine-estlcam" --device /dev/ttyUSB0
```

Falls Estlcam nach dem Flashen die Steuerung deaktiviert hat, setzt das Skript
beim Start automatisch wieder `Enabled=yes`. Dieses automatische Bearbeiten der
Einstellungsdatei kann mit `--no-settings-update` deaktiviert werden.

Der Modus `forward` ist fuer Bootloader-Resets nuetzlich, kann im Steuerbetrieb
aber wieder zu dem urspruenglichen Problem oder zu unerwuenschten
Controller-Resets fuehren. Deshalb ist `stable` der Standardmodus.

Falls Estlcam in einem anderen Windows-Pfad im Wine-Prefix installiert ist:

```bash
./run-estlcam-proxy.sh \
  --wineprefix "$HOME/.wine-estlcam" \
  --estlcam-path 'C:\Program Files\Estlcam11\Estlcam.exe'
```

Umgebungsvariablen werden ebenfalls unterstuetzt:

```bash
WINEPREFIX="$HOME/.wine-estlcam" \
SERIAL_DEVICE=/dev/ttyUSB0 \
COM_PORT=COM4 \
MODEM_LINES=stable \
./run-estlcam-proxy.sh
```

## Serielles Geraet Finden

Arduino / Controller anschliessen und pruefen, welches Geraet erzeugt wird:

```bash
dmesg -w
```

oder:

```bash
ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
```

Bei einem CH340-Adapter zeigt `lsusb` haeufig Vendor/Product `1a86:7523`, und
der Linux-Kernel erstellt ueber den Treiber `ch341` normalerweise
`/dev/ttyUSB0`.

## Fehlerbehebung

### `Serial device does not exist`

Der Wert fuer `--device` ist falsch oder der USB-Seriell-Adapter wurde nicht
erkannt.

Pruefen:

```bash
ls -l /dev/ttyUSB* /dev/ttyACM* 2>/dev/null
dmesg | tail -n 50
```

### `Permission denied` bei `/dev/ttyUSB0`

Der Benutzer darf das serielle Geraet nicht oeffnen. Besitzer und Gruppe
pruefen:

```bash
ls -l /dev/ttyUSB0
```

Fuege Deinen Benutzer der passenden Gruppe hinzu und melde Dich danach neu an.

### `Missing wine_tiocm_pty_shim.so`

Den Shim bauen:

```bash
make
```

### Estlcam antwortet weiterhin nicht

Pruefe `serial-proxy.log`.

Wenn dort nur die Startzeile steht, hat Estlcam den gemappten COM-Port
wahrscheinlich nicht geoeffnet. Stelle sicher, dass Estlcam denselben COM-Port
nutzt, den das Skript mappt, normalerweise `COM4`.

Wenn dort `wine -> controller`, aber kein `controller -> wine` steht, antwortet
der Controller nicht. Estlcam schliessen, Controller abziehen, wieder anstecken
und erneut starten.

Wenn Daten in beide Richtungen sichtbar sind, Estlcam aber trotzdem einen Fehler
meldet, Log aufheben und wenn moeglich mit einer anderen Wine-Version testen.

### `Serial device appears to be open already`

Das Skript hat erkannt, dass `/dev/ttyUSB0` bereits von einem anderen Prozess
geoeffnet ist. Schliesse andere Estlcam-, Wine-, Proxy- oder
Serial-Monitor-Prozesse und starte erneut.

Falls der Check falsch anschlaegt, kann er uebersprungen werden:

```bash
./run-estlcam-proxy.sh --skip-device-check --wineprefix "$HOME/.wine-estlcam"
```

## Funktionsweise

Direkter Wine-Zugriff auf `/dev/ttyUSB0` kann DTR/RTS und serielle
Modem-Control-ioctls so behandeln, dass die Estlcam-Firmware in manchen Setups
nicht erreichbar bleibt. Der Proxy oeffnet das echte serielle Geraet einmal,
haelt DTR/RTS auf dieser Seite stabil und leitet Bytes ueber ein
Pseudo-Terminal weiter. Wine sieht nur das Pseudo-Terminal als COM-Port.

Linux-Pseudo-Terminals implementieren nicht alle seriellen Modem-Control-ioctls,
die Wine erwartet. `wine_tiocm_pty_shim.so` faengt `ioctl`-Aufrufe fuer
`/dev/pts/*` ab und emuliert diese Modem-Line-Aufrufe:

- `TIOCMGET`
- `TIOCMSET`
- `TIOCMBIS`
- `TIOCMBIC`

Alle anderen ioctls werden unveraendert durchgereicht.

## Sicherheit

- Erst mit deaktivierten Motoren und deaktivierter Spindel testen.
- Nicht fuer unbeaufsichtigten Betrieb verwenden.
- Nach Tests `serial-proxy.log` pruefen.
- Dieses Projekt ist nicht mit Estlcam verbunden.
