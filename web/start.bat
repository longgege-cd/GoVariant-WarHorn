@echo off
chcp 65001 >nul
echo ====== 战争号角 WEB 版启动 ======
echo.

:: 杀掉占用 3000 端口的旧进程
for /f "tokens=5" %%a in ('netstat -ano ^| findstr ":3000" ^| findstr "LISTENING"') do (
  echo [清理] 终止旧服务器进程 PID=%%a
  taskkill /PID %%a /F >nul 2>&1
)

echo [1/2] 启动服务器 (http://localhost:3000)
start "Warhorn-Server" cmd /k "cd /d c:\边境线\web && npm run dev:server"
timeout /t 2 /nobreak >nul
echo [2/2] 启动前端 (http://localhost:5173)
start "Warhorn-Client" cmd /k "cd /d c:\边境线\web && npm run dev:client"
echo.
echo 服务器: http://localhost:3000
echo 前端:   http://localhost:5173
echo.
echo 关闭窗口即可停止服务
