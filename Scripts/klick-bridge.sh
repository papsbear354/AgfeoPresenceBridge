#!/bin/bash
#
# Reicht Anrufereignisse des AGFEO Dashboards an die Presence Bridge weiter.
#
# Im AGFEO Klick als "Auszuführendes Programm" eintragen, mit genau dieser
# Parameterreihenfolge:
#
#   1  %INVOKED_FROM%     Zustand: calling, called, connect, finished, …
#   2  %NUMBER%           Rufnummer der Gegenstelle
#   3  %OUTBOUND%         1 = ausgehend, 0 = eingehend
#   4  %CONNECTION_UID%   bleibt über das ganze Gespräch gleich
#
# Und die Option "Automatisch zur Rufverfolgung aufrufen" einschalten.
#
# Das Skript muss schnell zurückkehren und darf das Dashboard nicht aufhalten.

STATE="$1"
NUMBER="$2"
OUTBOUND="$3"
UID_="$4"

# Prozentkodierung ohne externe Programme — ein Interpreterstart je Ereignis
# wäre für einen Klingelton zu teuer.
urlencode() {
    local text="$1" out="" index char
    for ((index = 0; index < ${#text}; index++)); do
        char="${text:index:1}"
        case "$char" in
            [a-zA-Z0-9.~_-]) out+="$char" ;;
            *) out+=$(printf '%%%02X' "'$char") ;;
        esac
    done
    printf '%s' "$out"
}

URL="de.baz.agfeopresence://call"
URL+="?state=$(urlencode "$STATE")"
URL+="&number=$(urlencode "$NUMBER")"
URL+="&outbound=$(urlencode "$OUTBOUND")"
URL+="&uid=$(urlencode "$UID_")"

# -g: im Hintergrund öffnen. Ohne das würde mitten im Gespräch der Fokus
# springen.
open -g "$URL"

exit 0
