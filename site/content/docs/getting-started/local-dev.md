---
title: "本地开发"
weight: 2
description: "启动前后端并完成本地联调。"
---

## Windows 一键启动

在仓库根目录执行：

```powershell
.\start-dev.bat
```

该脚本会自动完成这些准备工作：

- 不存在 `backend/.env` 时，自动从 `.env.example` 复制
- 执行 `backend/` 下的 `uv sync`
- 启动前自动执行 `backend/init_db.py` 初始化数据库表结构
- 以不改写锁文件的方式执行 `front/` 下的 `pnpm install`
- 分别在独立 PowerShell 窗口中启动后端和前端

常用可选参数：

```powershell
.\start-dev.ps1 -SkipInstall
.\start-dev.ps1 -IncludeSite
```

- `-SkipInstall`：首次安装完成后，后续启动时跳过依赖安装
- `-IncludeSite`：同时启动 `site/` 的 Hugo 本地预览

关闭这一组本地开发窗口时，在仓库根目录执行：

```powershell
.\stop-dev.bat
```

## 启动后端

```bash
cd backend
cp .env.example .env
uv sync
uv run uvicorn app.main:app --reload --host 0.0.0.0 --port 8000
```

## 启动前端

```bash
cd front
pnpm install
pnpm dev
```

## 默认端口

- 前端：`http://localhost:7788`
- 后端：`http://localhost:8000`
- Swagger：`http://localhost:8000/docs`

## OpenAPI 更新

```bash
cd front
pnpm run openapi:update
```

## 官网与文档站本地预览

```bash
cd site
hugo mod tidy
hugo server --buildDrafts --disableFastRender
```

## 推荐的联调顺序

1. 启动后端，确认 `/docs` 和 `/health` 正常。
2. 启动前端，确认页面能访问并能请求后端。
3. 如果修改了接口定义，再执行 `openapi:update`。
4. 如果同时在维护官网，再单独启动 `site/` 预览。
