# AIVISE - AIHOT 精选站

AIHOT Public API 驱动，彩虹玻璃主题。部署在 GitHub Pages 上，每 30 分钟自动更新数据。

## 本地构建

```bash
node build.js
```

构建后输出到 `docs/index.html`，可直接用浏览器打开查看。

## GitHub Pages 部署步骤

1. **创建 GitHub 仓库**
   - 在 GitHub 上创建新仓库（如 `aihot-website`）
   - 将本项目文件推送到 `main` 分支

2. **启用 GitHub Pages**
   - 进入仓库 Settings → Pages
   - Source 选择 **GitHub Actions**
   - 保存设置

3. **配置仓库 Secret（可选）**
   - 如需修改 User-Agent，可编辑 `build.js` 中的 `USER_AGENT` 常量
   - 建议将 `USER_AGENT` 中的 URL 替换为你的实际 GitHub 仓库地址

4. **首次部署**
   - 推送代码到 main 分支，Actions 将自动运行构建和部署
   - 首次部署后，后续每 30 分钟自动更新数据

5. **绑定自定义域名（可选）**
   - 在仓库根目录创建 `CNAME` 文件，写入你的域名（如 `aihot.yourdomain.com`）
   - 在域名提供商处添加 CNAME 记录指向 `你的用户名.github.io`

## 数据更新机制

GitHub Actions 每 30 分钟运行一次：
1. 从 AIHOT Public API 拉取最近 7 天的精选数据
2. 注入到 index.html 模板中，生成静态 HTML
3. 部署到 GitHub Pages

## 项目结构

```
.
├── .github/workflows/
│   └── deploy.yml          # GitHub Actions 定时构建 + 部署
├── docs/                   # 构建输出（GitHub Pages 根目录）
├── index.html              # 网站模板（含彩虹玻璃主题 + 客户端逻辑）
├── build.js                # Node.js 构建脚本
├── package.json
├── .gitignore
└── README.md
```

## API 数据源

[AIHOT Public API](https://aihot.virxact.com/api/public/items) - OpenAPI 3.1 规范

## License

MIT