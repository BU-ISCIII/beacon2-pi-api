#!/bin/bash

python manage.py migrate --skip-checks
python manage.py runserver 0.0.0.0:3001 --nostatic
