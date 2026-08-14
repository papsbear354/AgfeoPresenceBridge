@echo off
rem
rem Reicht Anrufereignisse des AGFEO Dashboards an die Presence Bridge weiter.
rem
rem Im AGFEO Klick als "Auszufuehrendes Programm" eintragen, mit genau dieser
rem Parameterreihenfolge:
rem
rem   1  %%INVOKED_FROM%%     Zustand: calling, called, connect, finished, ...
rem   2  %%NUMBER%%           Rufnummer der Gegenstelle
rem   3  %%OUTBOUND%%         1 = ausgehend, 0 = eingehend
rem   4  %%CONNECTION_UID%%   bleibt ueber das ganze Gespraech gleich
rem
rem Und die Option "Automatisch zur Rufverfolgung aufrufen" einschalten.
rem
rem Jedes Ereignis bekommt eine eigene Datei: Waehrend eines Anrufs folgen
rem calling, connect und finished binnen Sekunden aufeinander - eine einzelne
rem Datei wuerde ueberschrieben, bevor das Programm sie gelesen hat. Das
rem Programm beobachtet den Ordner, liest die Dateien in ihrer Reihenfolge und
rem raeumt sie weg.
rem
rem Das Skript muss schnell zurueckkehren und darf das Dashboard nicht
rem aufhalten.

set "ORDNER=%LOCALAPPDATA%\AGFEOPresenceBridge\events"
if not exist "%ORDNER%" mkdir "%ORDNER%"

rem Name aus Zeit und Zufall, damit zwei Ereignisse in derselben Sekunde
rem nicht kollidieren.
set "NAME=%DATE:~-4%%DATE:~3,2%%DATE:~0,2%-%TIME:~0,2%%TIME:~3,2%%TIME:~6,2%%TIME:~9,2%-%RANDOM%"
set "NAME=%NAME: =0%"

rem Erst daneben schreiben, dann umbenennen: Das Programm soll keine halb
rem geschriebene Datei zu sehen bekommen.
> "%ORDNER%\%NAME%.tmp" echo %~1^|%~2^|%~3^|%~4
move /y "%ORDNER%\%NAME%.tmp" "%ORDNER%\%NAME%.call" >nul

exit /b 0
