#!/bin/zsh
set -euo pipefail

PROXY_HOST="127.0.0.1"
PROXY_PORT="10808"
CHATGPT_APP="/Applications/ChatGPT.app"
TARGET_APP="/Applications/ChatGPT Proxy.app"
LAUNCHER_SCRIPT="$HOME/Desktop/chatgpt-proxy.applescript"

if [[ ! -d "$CHATGPT_APP" ]]; then
  echo "未找到 $CHATGPT_APP" >&2
  exit 1
fi

cat > "$LAUNCHER_SCRIPT" <<EOF
on run
	set proxyHost to "${PROXY_HOST}"
	set proxyPort to "${PROXY_PORT}"
	set proxyURL to "http://" & proxyHost & ":" & proxyPort
	set chatGPTApp to "${CHATGPT_APP}"
	set mainExecutable to chatGPTApp & "/Contents/MacOS/ChatGPT"

	try
		do shell script "/usr/bin/nc -z " & quoted form of proxyHost & " " & quoted form of proxyPort
	on error
		display dialog "Clash 代理 " & proxyHost & ":" & proxyPort & " 未启动。" buttons {"好"} default button 1 with icon stop
		return
	end try

	set chatGPTRunning to false
	try
		do shell script "/usr/bin/pgrep -f " & quoted form of ("^" & mainExecutable)
		set chatGPTRunning to true
	end try

	if chatGPTRunning then
		display dialog "请先退出正在运行的 ChatGPT，再打开 ChatGPT Proxy。" buttons {"好"} default button 1 with icon caution
		return
	end if

	do shell script "/usr/bin/open -na " & quoted form of chatGPTApp & ¬
		" --env " & quoted form of ("HTTP_PROXY=" & proxyURL) & ¬
		" --env " & quoted form of ("HTTPS_PROXY=" & proxyURL) & ¬
		" --env " & quoted form of ("ALL_PROXY=socks5://" & proxyHost & ":" & proxyPort) & ¬
		" --env " & quoted form of "NO_PROXY=localhost,127.0.0.1,::1" & ¬
		" --args " & quoted form of ("--proxy-server=" & proxyURL) & ¬
		" " & quoted form of "--proxy-bypass-list=localhost;127.0.0.1;[::1]"
end run
EOF

rm -rf -- "$TARGET_APP"
/usr/bin/osacompile -o "$TARGET_APP" "$LAUNCHER_SCRIPT"

ICON_FILE="$CHATGPT_APP/Contents/Resources/icon-chatgpt.icns"
if [[ -f "$ICON_FILE" ]]; then
  /bin/cp "$ICON_FILE" "$TARGET_APP/Contents/Resources/applet.icns"
fi

/usr/bin/codesign --force --deep --sign - "$TARGET_APP"
/usr/bin/touch "$TARGET_APP"

echo "已生成 $TARGET_APP"
