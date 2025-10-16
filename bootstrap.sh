#!/usr/bin/env bash
set -Eeuo pipefail

APP_NAME="mischa-bootstrap"
CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/${APP_NAME}"
LOG_FILE="${CONF_DIR}/run.log"
PW_FILE="/etc/p.txt"   # plain text for now, per spec
PW_CACHE=""            # in-memory cache so you only type once

mkdir -p "$CONF_DIR"
touch "$LOG_FILE" || true

log(){ printf "[%s] %s\n" "$(date +'%F %T')" "$*" | tee -a "$LOG_FILE"; }

trap 'log "Error on line $LINENO. Exit status $?"' ERR

# ---------- sudo helpers (Debian, Ubuntu, Mint) ----------
_have_pw(){ [[ -f "$PW_FILE" ]] ; }

_prompt_pw_and_store(){
  local PW
  read -rsp "Enter your sudo password: " PW < /dev/tty
echo
  if echo "$PW" | sudo -S -k true >/dev/null 2>&1; then
    printf "%s" "$PW" | sudo -S tee "$PW_FILE" >/dev/null
    sudo chmod 600 "$PW_FILE"
    sudo chown root:root "$PW_FILE"
    PW_CACHE="$PW"
  else
    echo "Password failed. Try again."
    _prompt_pw_and_store
  fi
}

_get_pw(){
  if [[ -n "${PW_CACHE}" ]]; then
    printf "%s" "$PW_CACHE"
    return
  fi
  if _have_pw; then
    if sudo -n true >/dev/null 2>&1; then
      PW_CACHE="$(sudo -n cat "$PW_FILE" 2>/dev/null || true)"
    fi
    if [[ -z "${PW_CACHE}" ]]; then
      PW_CACHE="$(sudo cat "$PW_FILE")"
    fi
    printf "%s" "$PW_CACHE"
    return
  fi
  _prompt_pw_and_store
  printf "%s" "$PW_CACHE"
}

run_root(){
  if [[ $EUID -eq 0 ]]; then bash -lc "$*"; return; fi
  if sudo -n true >/dev/null 2>&1; then sudo bash -lc "$*"; return; fi
  local PW; PW="$(_get_pw)"
  printf "%s" "$PW" | sudo -S bash -lc "$*"
}

apt_update(){ run_root "DEBIAN_FRONTEND=noninteractive apt update"; }
apt_install(){ run_root "DEBIAN_FRONTEND=noninteractive apt install -y $*"; }

# ---------- items ----------
RECOMMENDED=(neofetch neovim btop git libreoffice nmap openssh-server)

install_docker(){
  if command -v docker >/dev/null 2>&1; then
    log "Docker already installed"
    return
  fi
  log "Installing Docker Engine and Compose on Debian, Ubuntu, Mint"

  local BASE="debian" CODENAME=""
  if [ -r /etc/os-release ]; then
    . /etc/os-release
    if [ -n "${UBUNTU_CODENAME:-}" ]; then
      BASE="ubuntu"
      CODENAME="$UBUNTU_CODENAME"
    else
      BASE="${ID:-debian}"
      CODENAME="${VERSION_CODENAME:-bookworm}"
      case "$BASE" in
        debian|raspbian|kali|lmde) BASE="debian" ;;
        ubuntu|linuxmint|elementary|neon) BASE="ubuntu" ;;
        *) BASE="debian" ;;
      esac
    fi
  fi
  case "${CODENAME}" in
    vanessa|vera|victoria) CODENAME="jammy" ;;
    virginia) CODENAME="noble" ;;
  esac
  log "Docker apt repo base=$BASE codename=$CODENAME"

  run_root "apt remove -y docker docker-engine docker.io containerd runc || true"
  apt_update
  apt_install ca-certificates curl gnupg

  run_root "install -m 0755 -d /etc/apt/keyrings"
  run_root "curl -fsSL https://download.docker.com/linux/${BASE}/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg"
  run_root "chmod a+r /etc/apt/keyrings/docker.gpg"
  run_root "bash -lc 'echo \"deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${BASE} ${CODENAME} stable\" > /etc/apt/sources.list.d/docker.list'"
  apt_update
  apt_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  run_root "systemctl enable --now docker"
  run_root "usermod -aG docker ${SUDO_USER:-$USER} || true"
  log "Docker installed. Log out and back in to use docker without sudo."
}

install_n8n_docker(){
  log "Deploying n8n in Docker"
  local dir="/opt/n8n"
  run_root "mkdir -p $dir/n8n_data && chown -R 1000:1000 $dir/n8n_data"
  run_root "bash -lc 'cat > $dir/docker-compose.yml <<EOF
services:
  n8n:
    image: n8nio/n8n:latest
    restart: unless-stopped
    ports:
      - \"5678:5678\"
    environment:
      - N8N_HOST=localhost
      - N8N_PROTOCOL=http
      - N8N_PORT=5678
    volumes:
      - ./n8n_data:/home/node/.n8n
EOF'"
  run_root "bash -lc 'cd $dir && docker compose up -d'"
  run_root "docker ps --format 'table {{'\"'\"'Names'\"'\"'}}\t{{'\"'\"'Status'\"'\"'}}\t{{'\"'\"'Ports'\"'\"'}}' | sed -n '1,5p'"
  log "n8n is starting on port 5678"
}

install_wazuh_docker(){
  log "Deploying Wazuh manager in Docker"
  local dir="/opt/wazuh"
  run_root "mkdir -p $dir"
  run_root "bash -lc 'cat > $dir/docker-compose.yml <<EOF
services:
  wazuh-manager:
    image: wazuh/wazuh-manager:latest
    restart: unless-stopped
    ports:
      - \"1514:1514/udp\"
      - \"1515:1515\"
      - \"55000:55000\"
    volumes:
      - ./wazuh_data:/var/ossec/data
EOF'"
  run_root "bash -lc 'cd $dir && docker compose up -d'"
  run_root "docker ps --format 'table {{'\"'\"'Names'\"'\"'}}\t{{'\"'\"'Status'\"'\"'}}\t{{'\"'\"'Ports'\"'\"'}}' | sed -n '1,5p'"
  log "Wazuh manager is starting. API will be on 55000 when ready. Dashboard is not included in this minimal setup."
}

install_recommended(){
  log "Installing recommended set"
  apt_update
  apt_install "${RECOMMENDED[*]}"
  run_root "systemctl enable --now ssh || systemctl enable --now sshd || true"
  install_docker
  log "Recommended install complete"
}

install_all(){
  install_recommended
  install_n8n_docker
  install_wazuh_docker
  log "All installs complete"
}

install_custom(){
  echo "Pick what you want, space separated."
  echo "Options: neofetch neovim btop git libreoffice nmap openssh-server docker n8n-docker wazuh-docker"
  read -rp "Your list: " -a CHOICES < /dev/tty
  apt_update
  local pkgs=()
  for item in "${CHOICES[@]}"; do
    case "$item" in
      docker) install_docker ;;
      n8n-docker) install_n8n_docker ;;
      wazuh-docker) install_wazuh_docker ;;
      *) pkgs+=("$item") ;;
    esac
  done
  if [[ ${#pkgs[@]} -gt 0 ]]; then
    apt_install "${pkgs[*]}"
  fi
  log "Custom install complete"
}

add_custom_bashrc(){
  log "Patching .bashrc"
  local target="/home/${SUDO_USER:-$USER}/.bashrc"
  local stamp="# >>> ${APP_NAME} >>>"
  if grep -q "$stamp" "$target" 2>/dev/null; then
    log ".bashrc already patched. Skipping"
    return
  fi
  cat >> "$target" <<'EOF'
# >>> mischa-bootstrap >>>
alias ll='ls -alF'
alias gs='git status'
alias venv='python3 -m venv .venv && source .venv/bin/activate'
export EDITOR=nvim
parse_git_branch() { git branch 2>/dev/null | sed -n '/\* /s///p'; }
PS1='\u@\h \W $(parse_git_branch) \$ '
# <<< mischa-bootstrap <<<
EOF
  run_root "chown ${SUDO_USER:-$USER}:${SUDO_USER:-$USER} $target" || true
  log ".bashrc updated"
}

# ---------- Learn Linux, Debian-focused ----------
learn_linux(){
  while true; do
    clear
    cat <<'MENU'
Learn Linux, pick a chapter
  1) Terminal 101, what this thing is
  2) Files and navigation, ls cd mkdir
  3) Core commands, sudo nano rm pwd
  4) Viewing and editing files, cat less head tail
  5) Packages on Debian, apt basics
  6) Processes and services, top btop systemctl
  7) Permissions and ownership, chmod chown
  8) Networking basics, ip ping curl ss
  9) Search and find, grep find locate
  10) Disks and space, df du lsblk
  11) Shell superpowers, pipes redirects quoting
  12) Back
MENU
    read -rp "Choose 1-12: " L < /dev/tty
    case "$L" in
      1) _lesson_terminal ;;
      2) _lesson_files_nav ;;
      3) _lesson_core_commands ;;
      4) _lesson_view_edit ;;
      5) _lesson_apt ;;
      6) _lesson_processes ;;
      7) _lesson_permissions ;;
      8) _lesson_networking ;;
      9) _lesson_search ;;
      10) _lesson_disks ;;
      11) _lesson_shell_power ;;
      12) return ;;
      *) echo "Invalid choice" ; sleep 1 ;;
    esac
  done
}

_pause(){
  read -rp "Press Enter to continue " _ < /dev/tty
}

_lesson_terminal(){ clear; cat <<'TXT'
Terminal 101, what this thing is
The terminal is a text window that talks to your shell. The shell reads a line, runs a program, prints output.
- Prompt shows user and folder. Example: mischa@debian ~/project $
- A command is: program name, then flags, then arguments.
  program -flags arguments
- Flags usually start with single dash or double dash. Example: ls -l or ls --all
- Up and down arrows go through history. Tab completes names. Ctrl C cancels a running command. Ctrl L clears the screen.
- Manual pages help. man ls. Most programs also have --help.
Try these right now
  echo "hello terminal"
  whoami
  date
  man echo       (press q to quit)
  clear
TXT
_pause; }

_lesson_files_nav(){ clear; cat <<'TXT'
Files and navigation, ls cd mkdir
Everything lives in a directory tree that starts at /. Your home is /home/yourname.
Commands
- pwd, print working directory
- ls, list files
- ls -l, long view with permissions
- ls -a, include hidden files that start with .
- ls -lah, long, all, human sizes
- cd /path, go to an absolute path
- cd .., go up one folder
- cd -, jump back to previous folder
- cd, go to your home
- mkdir NAME, make a directory
- mkdir -p a/b/c, make nested directories
TXT
_pause; }

_lesson_core_commands(){ clear; cat <<'TXT'
Core commands, sudo nano rm pwd
sudo lets a trusted user run a command as root. It asks for your password.
nano is a simple text editor in the terminal.
rm removes files. Careful, this is permanent.
pwd shows where you are.
TXT
_pause; }

_lesson_view_edit(){ clear; cat <<'TXT'
Viewing and editing files, cat less head tail
- cat file, print file content
- less file, pager. space to scroll. q to quit.
- head -n 20 file, first 20 lines
- tail -n 20 file, last 20 lines
- tail -f file, follow new lines, like logs
TXT
_pause; }

_lesson_apt(){ clear; cat <<'TXT'
Packages on Debian, apt basics
- sudo apt update
- sudo apt install pkg
- apt search keyword
- apt show pkg
- sudo apt remove pkg
- sudo apt purge pkg
- sudo apt autoremove
TXT
_pause; }

_lesson_processes(){ clear; cat <<'TXT'
Processes and services, top btop systemctl
- ps aux | less, snapshot of processes
- top, live process view
- btop, pretty top
- systemctl status NAME, check a service
- sudo systemctl restart NAME
TXT
_pause; }

_lesson_permissions(){ clear; cat <<'TXT'
Permissions and ownership, chmod chown
- chmod 644 file, rw for user, r for group and others
- chmod 755 script, rwx for user, rx for group and others
- sudo chown user:group file
TXT
_pause; }

_lesson_networking(){ clear; cat <<'TXT'
Networking basics, ip ping curl ss
- ip a
- ip r
- ping -c 4 example.com
- curl -I https://example.com
- ss -tulpn
TXT
_pause; }

_lesson_search(){ clear; cat <<'TXT'
Search and find, grep find locate
- grep -R "needle" .
- find . -name "*.sh"
- locate sshd_config
TXT
_pause; }

_lesson_disks(){ clear; cat <<'TXT'
Disks and space, df du lsblk
- df -h
- du -sh *
- lsblk
TXT
_pause; }

_lesson_shell_power(){ clear; cat <<'TXT'
Shell superpowers, pipes redirects quoting
- cmd1 | cmd2
- cmd > out.txt, cmd >> out.txt
- cmd 2> err.txt, cmd > all.txt 2>&1
- "double" vs 'single' quotes
TXT
_pause; }

# ---------- tailscale access, single clean implementation ----------
tailscale_access(){
  log "Tailscale access setup"
  command -v jq >/dev/null 2>&1 || { apt_update; apt_install jq; }
  command -v curl >/dev/null 2>&1 || { apt_update; apt_install curl; }

  TS_GRANT_EMAIL="mischa.nelson07@gmail.com"

  read -rp "Tailnet name, for example example.com: " TS_TAILNET < /dev/tty
  read -rsp "Tailscale API access token for ${TS_TAILNET}: " TS_API_TOKEN < /dev/tty
echo
  read -rp "Tag to use for this device, default ssh-share: " TS_TAG_RAW < /dev/tty
  TS_TAG_RAW="${TS_TAG_RAW:-ssh-share}"
  TS_TAG="tag:${TS_TAG_RAW}"

  if ! command -v tailscale >/dev/null 2>&1; then
    log "Installing Tailscale"
    run_root "curl -fsSL https://tailscale.com/install.sh | sh"
  fi
  run_root "systemctl enable --now tailscaled"

  log "Creating reusable preauthorized auth key for ${TS_TAG}"
  local AUTH_JSON
  if ! AUTH_JSON="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${TS_API_TOKEN}" \
    -H "Content-Type: application/json" \
    "https://api.tailscale.com/api/v2/tailnet/${TS_TAILNET}/keys" \
    -d "{
      \"capabilities\": { \"devices\": { \"create\": {
          \"reusable\": true, \"ephemeral\": false, \"preauthorized\": true, \"tags\": [\"${TS_TAG}\"]
      } } },
      \"description\": \"${TS_TAG_RAW} reusable auth key\"
    }")"; then
    echo "API error creating key"
    return 1
  fi

  TS_AUTHKEY="$(printf "%s" "$AUTH_JSON" | jq -r '.key')"
  if [[ -z "$TS_AUTHKEY" || "$TS_AUTHKEY" == "null" ]]; then
    echo "Failed to obtain an auth key. Check token privileges."
    return 1
  fi

  if ! tailscale status >/dev/null 2>&1; then
    log "Enrolling device with auth key"
    run_root "tailscale up --auth-key '${TS_AUTHKEY}'"
  fi

  log "Enabling Tailscale SSH on device"
  run_root "tailscale set --ssh"

  if ! tailscale status --json | jq -e --arg t "$TS_TAG" '.Self.Tags[]? | select(. == $t)' >/dev/null; then
    log "Advertising ${TS_TAG} on this device"
    run_root "tailscale up --advertise-tags='${TS_TAG}'"
  fi

  local ACL_URL="https://api.tailscale.com/api/v2/tailnet/${TS_TAILNET}/acl"
  log "Fetching tailnet policy"
  local POLICY
  if ! POLICY="$(curl -fsS -u "${TS_API_TOKEN}:" "$ACL_URL")"; then
    echo "Failed to fetch ACL"
    return 1
  fi

  local UPDATED
  UPDATED="$(jq --arg tag "${TS_TAG_RAW}" '
    .tagOwners = (if .tagOwners then .tagOwners else {} end)
    | if (.tagOwners["tag:\($tag)"] // null) == null
      then .tagOwners["tag:\($tag)"] = ["autogroup:admin"]
      else . end
  ' <<<"$POLICY")"

  UPDATED="$(jq --arg tag "${TS_TAG_RAW}" --arg user "${TS_GRANT_EMAIL}" '
    .ssh = (
      (.ssh // [])
      | if any(.[]; .action=="accept" and .src==[$user] and .dst==["tag:\($tag)"] and .users==["autogroup:nonroot"]) then .
        else . + [{
          "action": "accept",
          "src": [ $user ],
          "dst": [ "tag:\($tag)" ],
          "users": [ "autogroup:nonroot" ]
        }]
      end
    )
  ' <<<"$UPDATED")"

  log "Pushing updated policy"
  curl -fsS -u "${TS_API_TOKEN}:" \
    -H "Content-Type: application/json" -X POST \
    --data-binary @- "$ACL_URL" <<<"$UPDATED" >/dev/null

  log "Done. ${TS_GRANT_EMAIL} can Tailscale SSH to devices with ${TS_TAG} in ${TS_TAILNET}."
}

# ---------- menus ----------
menu_install(){
  clear
  cat <<MENU
Install options
  1) Recommended
  2) All
  3) Custom
  4) Back
MENU
  read -rp "Choose 1-4: " c < /dev/tty
  case "$c" in
    1) install_recommended ;;
    2) install_all ;;
    3) install_custom ;;
    4) return ;;
    *) echo "Bad choice" ;;
  esac
}

main_menu(){
  while true; do
    clear
    cat <<MENU
What would you like to do
  1) Install tools
  2) Add custom .bashrc
  3) Tailscale access
  4) Other hardening, coming later
  5) Learn Linux commands
  6) Exit
MENU
    read -rp "Choose 1-6: " choice < /dev/tty
    case "$choice" in
      1) menu_install ;;
      2) add_custom_bashrc ;;
      3) tailscale_access ;;
      4) echo "Hardening will be added later." ; read -rp "Press Enter" _ < /dev/tty ;;
      5) learn_linux ;;
      6) exit 0 ;;
      *) echo "Invalid choice" ; sleep 1 ;;
    esac
  done
}

main_menu
