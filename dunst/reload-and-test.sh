#!/bin/bash

dunstctl reload

notify-send --urgency=low "测试通知" "Hello (Low)"
notify-send --urgency=normal "测试通知" "Hello (Normal)"
notify-send --urgency=critical "测试通知" "Hello (Critical)"
notify-send --app-name=bilive "测试通知" "Hello from Bilive"
