@echo off
rem 带启动画面启动 DeepSeek Harness
rem 进度来源：装在 profile 里的启动观察者（真实插件激活计数）
rem 关闭信号：host stdout 的 `dsh web:` 真信号
rem 用 %~dp0 定位脚本目录，不写死绝对路径
start "" pwsh -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "%~dp0splash.ps1"
