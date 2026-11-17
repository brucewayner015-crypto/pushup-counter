#!/usr/bin/env bash
# Связка — объединение VPN-подписок в одну ссылку. Установка, обновление и удаление.
#
#   curl -fsSL https://raw.githubusercontent.com/brucewayner015-crypto/pushup-counter/svyazka/install.sh | sudo bash
#   ... | sudo bash -s -- uninstall          удалить службу (данные останутся)
#   ... | sudo bash -s -- uninstall --purge  удалить вместе с данными
#
# Можно задать заранее: SVYAZKA_IP=1.2.3.4 SVYAZKA_PORT=8443
set -euo pipefail

VERSION="0.1.0"
BASE_URL="${SVYAZKA_BASE_URL:-https://raw.githubusercontent.com/brucewayner015-crypto/pushup-counter/svyazka}"
SHA_AMD64="992dda25f1c5a879ac1d57219a2de51bfd083c18db4e748cacbc7433b72d11b1"
SHA_ARM64="e7ad091ccf75593c054a3a075dfc641bbfef6bd492cc2b654f2d0d86542e9f5a"

BIN=/usr/local/bin/svyazka
DATA=/var/lib/svyazka
UNIT=/etc/systemd/system/svyazka.service
ACCOUNT=svyazka

say() { printf '%s\n' "$*"; }
warn() { # first line, then more lines
	printf '\n!  %s\n' "$1" >&2
	shift
	for line in "$@"; do printf '   %s\n' "$line" >&2; done
}
die() { printf '\nОшибка: %s\n' "$*" >&2; exit 1; }


download() { # url file
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --retry 3 --connect-timeout 20 -o "$2" "$1"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -T 30 -t 3 -O "$2" "$1"
	else
		die "нужен curl или wget: apt install curl"
	fi
}

http_text() { # url -> stdout (IPv4)
	if command -v curl >/dev/null 2>&1; then
		curl -4 -fsS --max-time 8 "$1" 2>/dev/null
	else
		wget -4 -q -T 8 -O - "$1" 2>/dev/null
	fi
}

uninstall() {
	systemctl disable --now svyazka >/dev/null 2>&1 || true
	rm -f "$UNIT" "$BIN"
	systemctl daemon-reload
	if [ "${1:-}" = "--purge" ]; then
		rm -rf "$DATA"
		userdel "$ACCOUNT" >/dev/null 2>&1 || true
		say "Связка удалена вместе с данными."
	else
		say "Служба Связки удалена. Данные (источники, правила, ссылка) остались в $DATA —"
		say "при повторной установке всё вернётся. Удалить и их:"
		say "  curl -fsSL $BASE_URL/install.sh | sudo bash -s -- uninstall --purge"
	fi
}


public_ipv4() {
	local ip=$1 a b
	[[ $ip =~ ^([0-9]{1,3})\.([0-9]{1,3})\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
	a=${BASH_REMATCH[1]} b=${BASH_REMATCH[2]}
	((a == 0 || a == 10 || a == 127 || a >= 224)) && return 1
	((a == 100 && b >= 64 && b <= 127)) && return 1
	((a == 169 && b == 254)) && return 1
	((a == 172 && b >= 16 && b <= 31)) && return 1
	((a == 192 && b == 168)) && return 1
	return 0
}

detect_ip() {
	local ip
	ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i < NF; i++) if ($i == "src") { print $(i + 1); exit }}')
	if public_ipv4 "${ip:-}"; then
		echo "$ip"
		return 0
	fi
	# behind NAT (some clouds): ask outside
	for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me/ip; do
		ip=$(http_text "$url" | tr -d '[:space:]') || true
		if public_ipv4 "${ip:-}"; then
			echo "$ip"
			return 0
		fi
	done
	return 1
}

port_owner() { # who listens on a TCP port; nothing when it is free
	local p=$1 line name
	if command -v ss >/dev/null 2>&1; then
		line=$(ss -Htlnp "sport = :$p" 2>/dev/null | head -n 1)
		if [ -n "$line" ]; then
			name=$(printf '%s' "$line" | sed -n 's/.*users:(("\([^"]*\)".*/\1/p')
			echo "${name:-занят}"
			return 0
		fi
	fi
	if command -v docker >/dev/null 2>&1; then
		name=$(docker ps --format '{{.Names}} {{.Ports}}' 2>/dev/null | grep -E "(0\.0\.0\.0|\[::\]|::):$p->" | head -n 1 | cut -d' ' -f1 || true)
		if [ -n "$name" ]; then
			echo "docker: $name"
		fi
	fi
	return 0
}

main() {
	[ "$(id -u)" -eq 0 ] || die "запустите от root: curl -fsSL $BASE_URL/install.sh | sudo bash"
	command -v systemctl >/dev/null 2>&1 || die "нужен Linux с systemd (Ubuntu, Debian, AlmaLinux и т. п.)"
	if [ "${1:-}" = "uninstall" ]; then
		uninstall "${2:-}"
		return 0
	fi
	case "$(uname -m)" in
	x86_64 | amd64) ARCH=amd64 SHA=$SHA_AMD64 ;;
	aarch64 | arm64) ARCH=arm64 SHA=$SHA_ARM64 ;;
	*) die "процессор $(uname -m) не поддерживается (нужен x86_64 или arm64)" ;;
	esac

	say "Связка $VERSION: установка"

	TMP=$(mktemp -d)
	trap 'rm -rf "$TMP"' EXIT
	say "— скачиваю программу ($ARCH)…"
	download "$BASE_URL/svyazka-linux-$ARCH" "$TMP/svyazka" || die "не удалось скачать $BASE_URL/svyazka-linux-$ARCH"
	echo "$SHA  $TMP/svyazka" | sha256sum -c --quiet - >/dev/null 2>&1 || die "скачанный файл повреждён (не совпала контрольная сумма), запустите установку ещё раз"
	chmod 0755 "$TMP/svyazka"
	"$TMP/svyazka" version >/dev/null || die "программа не запускается на этом сервере"

	FIRST=1
	[ -f "$DATA/state.json" ] && FIRST=0

	if ! id -u "$ACCOUNT" >/dev/null 2>&1; then
		NOLOGIN=$(command -v nologin || echo /bin/false)
		useradd --system --user-group --home-dir "$DATA" --no-create-home --shell "$NOLOGIN" "$ACCOUNT"
	fi
	install -d -m 0700 -o "$ACCOUNT" -g "$ACCOUNT" "$DATA"
	chown -R "$ACCOUNT:$ACCOUNT" "$DATA"

	INIT_ARGS=(--data "$DATA" --machine)
	if [ "$FIRST" = 1 ] || [ -n "${SVYAZKA_IP:-}" ]; then
		IP=${SVYAZKA_IP:-}
		if [ -z "$IP" ]; then
			say "— определяю внешний адрес сервера…"
			IP=$(detect_ip) || die "не удалось определить внешний IPv4-адрес. Укажите его сами: SVYAZKA_IP=1.2.3.4 перед командой установки"
		fi
		INIT_ARGS+=(--ip "$IP")
	fi

	if systemctl is-active --quiet svyazka; then
		systemctl stop svyazka
	fi

	if [ "$FIRST" = 1 ] || [ -n "${SVYAZKA_PORT:-}" ]; then
		PORT=${SVYAZKA_PORT:-}
		if [ -z "$PORT" ]; then
			for p in 443 8443 9443 10443 18443; do
				if [ -z "$(port_owner "$p")" ]; then
					PORT=$p
					break
				fi
			done
			[ -n "$PORT" ] || die "порты 443, 8443, 9443, 10443 и 18443 заняты. Укажите свободный: SVYAZKA_PORT=… перед командой установки"
			[ "$PORT" = 443 ] || say "— порт 443 занят ($(port_owner 443)), Связка будет на порту $PORT"
		else
			OWNER=$(port_owner "$PORT")
			[ -z "$OWNER" ] || die "порт $PORT занят ($OWNER)"
		fi
		INIT_ARGS+=(--port "$PORT")
	fi

	mv -f "$TMP/svyazka" "$BIN.new"
	mv -f "$BIN.new" "$BIN"

	OUT=$("$BIN" init "${INIT_ARGS[@]}") || die "не удалось подготовить данные"
	PASSWORD=$(printf '%s\n' "$OUT" | sed -n 's/^password=//p')
	PORT=$(printf '%s\n' "$OUT" | sed -n 's/^port=//p')
	IP=$(printf '%s\n' "$OUT" | sed -n 's/^ip=//p')
	chown -R "$ACCOUNT:$ACCOUNT" "$DATA"

	PORT80=$(port_owner 80)
	if [ -n "$PORT80" ]; then
		warn "Порт 80 занят ($PORT80)." \
			"Let's Encrypt проверяет сервер через порт 80, поэтому настоящий сертификат не выдадут," \
			"пока порт занят. Освободите его: Связке он нужен на минуту раз в несколько дней."
	fi

	cat >"$UNIT" <<EOF
[Unit]
Description=Svyazka: VPN subscriptions merged into one link
After=network-online.target
Wants=network-online.target

[Service]
User=$ACCOUNT
Group=$ACCOUNT
ExecStart=$BIN run --data $DATA
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
UMask=0077
ProtectSystem=strict
ReadWritePaths=$DATA
ProtectHome=true
PrivateTmp=true
PrivateDevices=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictNamespaces=true
LockPersonality=true
MemoryDenyWriteExecute=true

[Install]
WantedBy=multi-user.target
EOF

	# firewall: open 80 (certificate checks) and the service port
	if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
		ufw allow 80/tcp >/dev/null
		ufw allow "$PORT/tcp" >/dev/null
		say "— открыл порты 80 и $PORT в ufw"
	elif command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
		firewall-cmd --quiet --permanent --add-port=80/tcp --add-port="$PORT/tcp"
		firewall-cmd --quiet --reload
		say "— открыл порты 80 и $PORT в firewalld"
	elif command -v iptables >/dev/null 2>&1 && iptables -S INPUT 2>/dev/null | grep -qE '^-P INPUT DROP|-j REJECT'; then
		for p in 80 "$PORT"; do
			iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT
		done
		command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
		say "— открыл порты 80 и $PORT в iptables"
	fi

	systemctl daemon-reload
	systemctl enable svyazka >/dev/null 2>&1
	systemctl restart svyazka
	sleep 1
	systemctl is-active --quiet svyazka || die "служба не запустилась. Подробности: journalctl -u svyazka -n 30 --no-pager"

	if ! "$BIN" info --data "$DATA" --cert-ok; then
		printf "— получаю сертификат Let's Encrypt для %s" "$IP"
		for _ in $(seq 1 $((${SVYAZKA_CERT_WAIT:-90} / 2))); do
			"$BIN" info --data "$DATA" --cert-ok && break
			printf '.'
			sleep 2
		done
		say ""
	fi

	say ""
	say "Готово. Связка $VERSION работает."
	say ""
	"$BIN" info --data "$DATA" | sed 's/^/  /'
	if [ -n "$PASSWORD" ]; then
		say "  Пароль панели:   $PASSWORD"
	else
		say "  Пароль панели:   прежний (забыли — выполните: sudo svyazka passwd)"
	fi
	say ""
	if ! "$BIN" info --data "$DATA" --cert-ok; then
		LAST=$(journalctl -u svyazka -n 40 --no-pager -o cat 2>/dev/null | grep "сертификат Let's Encrypt не получен" | tail -n 1 |
			sed -e "s/^сертификат Let's Encrypt не получен: //" -e 's/ (следующая попытка.*//' || true)
		warn "Let's Encrypt пока не выдал сертификат.${LAST:+ Причина: $LAST}" \
			"Чаще всего порт 80 закрыт файрволом в панели хостера (Security Group, Firewall)." \
			"Откройте там TCP 80 и $PORT — Связка сама повторит попытку. Пока сертификат временный," \
			"браузер покажет предупреждение («Дополнительно» → «Перейти на сайт»)."
	fi
	say "Откройте панель в браузере, войдите и добавьте подписки."
	say "Пароль и ссылки никому не пересылайте."
}

# everything above only defines functions, so a cut-off download does nothing
main "$@"
