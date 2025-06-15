@ECHO OFF

REM make folder
mkdir projecttitle.koplugin

REM copy everything into the right folder name
copy *.lua projecttitle.koplugin
xcopy fonts projecttitle.koplugin\fonts /s /i
xcopy icons projecttitle.koplugin\icons /s /i
xcopy resources projecttitle.koplugin\resources /s /i

REM cleanup unwanted
del /q projecttitle.koplugin\resources\collage.jpg
del /q projecttitle.koplugin\resources\licenses.txt

REM zip the folder
7z a -tzip projecttitle.zip projecttitle.koplugin

REM delete the folder
rmdir /s /q projecttitle.koplugin

pause