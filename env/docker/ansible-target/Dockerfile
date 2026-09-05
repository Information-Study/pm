# 本機驗證用的 Ansible 目標主機。
#
# 這不是玩具：它跑真正的 systemd（PID 1 是 /sbin/init），所以
# systemd_service 模組、handler、服務啟動順序、socket 啟動全部是真的行為，
# 不是「假裝成功」。少了 systemd 的話，nginx / php-fpm / mysql 的
# enable/start/restart 全部驗不到，而那正是部署最容易出錯的地方。
#
# 版本用 ARG 帶進來，因為專案同時要支援 22.04 / 24.04 / 26.04：
#   * 22.04 (jammy)   ondrej PPA
#   * 24.04 (noble)   ondrej PPA
#   * 26.04 (resolute) 發行版官方倉庫（PPA 沒有發佈這個 codename）
# php role 的 php_repo_source=auto 會自己判斷，而這三種都要能實際跑一次。
#
# 建置與啟動見 env/docker/ansible-target/README.md。
ARG UBUNTU_VERSION=24.04
FROM ubuntu:${UBUNTU_VERSION}

ENV DEBIAN_FRONTEND=noninteractive
# systemd 靠這個環境變數判斷自己在容器裡，會跳過一些不適用的單元。
ENV container=docker

# python3-apt 與 python3-debian 是 A6 的前提：
# ansible.builtin.deb822_repository 少了 python-debian 會直接失敗，
# 而錯誤訊息（"Failed to import the required Python library"）不會告訴你套件名。
RUN apt-get update && apt-get install -y --no-install-recommends \
        systemd systemd-sysv dbus dbus-user-session \
        openssh-server sudo \
        python3 python3-apt python3-debian \
        ca-certificates curl gnupg iproute2 \
    && rm -rf /var/lib/apt/lists/*

# 拿掉容器裡不可能成功的單元。留著的話 systemd 會不斷重試並塞滿 journal，
# 而且 `systemctl is-system-running` 永遠是 degraded —— 那會讓
# healthcheck 與人工判斷都失去意義。
RUN find /etc/systemd/system /lib/systemd/system \
        -path '*.wants/*' \
        \( -name '*getty*' -o -name '*udev*' -o -name '*mount*' \
           -o -name '*swap*' -o -name '*resolved*' -o -name '*networkd*' \) \
        -exec rm -f {} + 2>/dev/null || true

RUN mkdir -p /run/sshd \
    && useradd -m -s /bin/bash ansible \
    && echo 'ansible ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/ansible \
    && chmod 0440 /etc/sudoers.d/ansible \
    && mkdir -p /home/ansible/.ssh \
    && chmod 700 /home/ansible/.ssh

# 公鑰由建置腳本從 ~/.ssh/pm_target_ed25519.pub 複製到 build context。
# 不放進版控 —— 每台機器的金鑰不同，而且那是憑證。
COPY authorized_keys /home/ansible/.ssh/authorized_keys

RUN chown -R ansible:ansible /home/ansible/.ssh \
    && chmod 600 /home/ansible/.ssh/authorized_keys \
    && systemctl enable ssh

EXPOSE 22
# systemd 用 SIGRTMIN+3 當作「乾淨關機」的訊號，SIGTERM 它不理。
# 不設的話 docker stop 會等滿 10 秒再 SIGKILL。
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
