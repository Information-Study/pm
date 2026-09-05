# 本機驗證用的 Ansible 目標主機

跑真正 systemd 的 Ubuntu 容器，讓 `cx deploy apply` 可以在 WSL 內完整驗證，
不需要真的雲主機。

## 為什麼要有它

`cx deploy check`（`--check`）驗不到的東西很多：會寫入的 `command`/`shell`
在 check 模式一律被跳過，`systemd_service` 的 enable/start/restart 也不會真的發生。
「乾跑通過」不等於「實際跑一定會過」—— 這一句寫在 `cx deploy check` 的輸出裡，
而這個容器就是用來補上那個差距的。

## 建置

```bash
# 沒有金鑰就先產一把（只給這個容器用）
[ -f ~/.ssh/pm_target_ed25519 ] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/pm_target_ed25519

cp ~/.ssh/pm_target_ed25519.pub env/docker/ansible-target/authorized_keys

# 24.04（noble，走 ondrej PPA）
docker build --build-arg UBUNTU_VERSION=24.04 \
             -t pm/ansible-target:24.04 docker/ansible-target

# 26.04（resolute，走發行版官方倉庫 —— PPA 沒有發佈這個 codename）
docker build --build-arg UBUNTU_VERSION=26.04 \
             -t pm/ansible-target:26.04 docker/ansible-target
```

## 啟動

systemd 需要 cgroup 與幾個 tmpfs，缺一不可：

```bash
docker run -d --name pm-target \
  --privileged --cgroupns=host \
  -v /sys/fs/cgroup:/sys/fs/cgroup \
  --tmpfs /run --tmpfs /run/lock --tmpfs /tmp \
  -p 127.0.0.1:2222:22 \
  pm/ansible-target:24.04
```

| 選項 | 少了會怎樣 |
|---|---|
| `--privileged --cgroupns=host` + cgroup 掛載 | systemd 起不來，PID 1 直接退出 |
| `--tmpfs /run` | `Failed to create /run/systemd`，服務全部啟動失敗 |
| `-p 127.0.0.1:2222` | 只綁 loopback —— 這台機器有 sudo NOPASSWD，不要對 LAN 開放 |

`env/ansible/inventory/hosts.yml` 的 `pm-staging-1` 就指向 `127.0.0.1:2222`。

## 換版本測試

```bash
docker rm -f pm-target
docker run -d --name pm-target ... pm/ansible-target:26.04    # 選項同上
cx deploy ping && cx deploy check
```

`php` role 的 `php_repo_source=auto` 會依 codename 自己選來源，
所以同一份 playbook 在 24.04 與 26.04 上跑出來的來源不同 ——
這正是需要兩個容器各跑一次的理由。

## 這個容器不是什麼

它不驗證 TLS（沒有真實網域）、不驗證多主機的 `serial`／`any_errors_fatal`、
也不驗證雲端的網路與防火牆。那些只能在真的主機上驗。
