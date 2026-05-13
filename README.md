# Nginx HTTPS 反向代理 + Let's Encrypt 自动续签

一键脚本:为任意域名签发 Let's Encrypt 证书,并把 HTTPS 反向代理到指定后端。

## 支持的系统

| 系统 | 状态 |
| --- | --- |
| Ubuntu / Debian | ✅ |
| RHEL / CentOS Stream / Rocky / AlmaLinux 8+ | ✅ |
| Fedora | ✅ |
| openSUSE / SLES | ✅ |
| Arch / Manjaro | ✅ |

需为 Linux + systemd + root,不支持 Docker / WSL1 等无 systemd 的环境。

## 使用

```bash
chmod +x add-proxy-domain.sh   # 仅在 ZIP 下载等丢失可执行位的情况下需要
sudo ./add-proxy-domain.sh
```

按提示输入:

- **外部域名**(如 `app.example.com`)— 用户访问的域名,需 A 记录指向本机公网 IP。
- **后端地址**(如 `127.0.0.1:3000` 或 `10.0.0.5:8080`)— nginx 反代到的上游。

脚本会:

1. 校验域名格式,做 DNS 解析预检,防止重复配置。
2. 装齐依赖(`nginx`、`certbot`、`dig`、`curl` 等),启用 EPEL(RHEL 系)。
3. 用 `certbot --webroot` 申请证书。
4. 在托管的 nginx 配置 `/etc/nginx/conf.d/proxy-managed.conf` 中追加 443 server 块,并把域名加入 80 → 443 重定向块。
5. `nginx -t && systemctl reload nginx`,失败自动回滚。
6. 兜底启用自动续签(详见下文)。

## 文件结构

- `add-proxy-domain.sh` — 本仓库唯一脚本
- `/etc/nginx/conf.d/proxy-managed.conf` — 脚本托管的 nginx 配置(运行后生成)
- `/etc/letsencrypt/live/<domain>/{fullchain,privkey}.pem` — certbot 签发的证书
- `/etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh` — 续签后自动 `systemctl reload nginx`(脚本自动创建)
- `/var/www/certbot/` — ACME HTTP-01 验证 webroot

## 自动续签

- `certbot.timer`(systemd)每天跑两次 `certbot renew`,剩余有效期 ≤30 天才会真的续签。脚本会确保该 timer enabled & active。
- 续签成功后,deploy hook 自动 reload nginx 加载新证书链。
- 本脚本无需额外的 crontab / 计划任务。

```bash
# 验证 timer 状态
systemctl status certbot.timer

# 手动演练续签流程(不实际更新证书)
sudo certbot renew --dry-run

# 强制立即续签(配额内,慎用)
sudo certbot renew --force-renewal
```

## 排错

```bash
# 配置语法
sudo nginx -t

# 实时日志
sudo tail -f /var/log/nginx/error.log
sudo tail -f /var/log/nginx/access.log
sudo tail -f /var/log/letsencrypt/letsencrypt.log

# 监听端口
sudo ss -tlnp | grep -E ':(80|443)\b'

# 远端连通性
curl -v https://<your.domain>/
```

## 注意事项

1. **DNS**:外部域名必须 A 记录指向本机公网 IP,否则 ACME HTTP-01 验证会失败。
2. **防火墙 / 云安全组**:必须放行 **80**(ACME 验证)和 **443**(HTTPS 流量)入站 TCP。
3. **nginx → 后端为明文 HTTP**。若需加密这一段,需要后端也开 HTTPS,并手动把生成的 `proxy_pass http://...` 改为 `https://...`。
4. 脚本依赖 systemd 管理 nginx,在无 systemd 的容器环境无法使用。
