@echo off
REM Activate virtual environment and run Django server
call venv\Scripts\activate.bat
python manage.py runserver
pause

