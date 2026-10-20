#!/usr/bin/env bash
# =============================================================================
# setup.sh - Setup e disinstallazione di Podman / Docker in modalita' ROOTLESS
#
# Distribuzioni supportate:
#   - Ubuntu 24.04 e successive          (APT)
#   - Debian 13 "Trixie" e successive    (APT)
#   - AlmaLinux / RHEL (anche Rocky) 9 e 10 (DNF)
#
# Va eseguito da utente NON root: sudo viene usato solo per i singoli comandi
# amministrativi (pacchetti, /etc/subuid, sysctl, SELinux, firewalld, ...).
# Tutto cio' che viene modificato a livello di sistema e' registrato in un file
# di stato per utente, cosi' la disinstallazione ripristina solo cio' che lo
# script ha effettivamente cambiato.
#
# Uso: ./setup.sh --help
# =============================================================================
set -Eeuo pipefail

readonly SCRIPT_NAME="${0##*/}"
readonly SCRIPT_VERSION="1.0.0"

# --- Valori di default (sovrascrivibili da CLI) ------------------------------
MODE="install"
ENGINE=""            # vuoto = scelta automatica per famiglia di distro (vedi resolve_default_engine)
NEED_REBOOT=0        # impostato quando manca un prerequisito del kernel in esecuzione
DRY_RUN=0
PURGE=0
REMOVE_PACKAGES=0
ASSUME_YES=0
FORCE_DISTRO=0
KEEP_SYSTEM_DOCKER=0
NO_SELINUX=0
LOW_PORTS=0
USE_COLOR=1
RC_FILE="${HOME:-}/.bashrc"
FW_PORTS=()

# Range subuid/subgid richiesto
readonly SUBID_MIN_START=100000
readonly SUBID_COUNT=65536

# File di override per i test (permette di simulare altre distro in --dry-run)
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

# Marker del blocco gestito in .bashrc
readonly MARK_BEGIN="# >>> rootless-container-setup >>>"
readonly MARK_END="# <<< rootless-container-setup <<<"

# File di stato
STATE_DIR="${XDG_STATE_HOME:-${HOME:-}/.local/state}/rootless-container-setup"
STATE_FILE="$STATE_DIR/state"

# Variabili popolate da detect_os
OS_ID="" OS_LIKE="" OS_VER="" OS_NAME="" OS_CODENAME=""
PKG=""            # apt | dnf
DOCKER_REPO_OS="" # ubuntu | debian | centos | rhel
APT_UPDATED=0
FAILURES=0
SUDO_READY=0

# =============================================================================
# Logging
# =============================================================================
C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_DIM=""

setup_colors() {
  if (( USE_COLOR )) && [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'; C_RED=$'\033[1;31m'; C_GREEN=$'\033[1;32m'
    C_YELLOW=$'\033[1;33m'; C_BLUE=$'\033[1;34m'; C_DIM=$'\033[2m'
  fi
}

log_info()    { printf '%s[INFO]%s    %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_success() { printf '%s[SUCCESS]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()    { printf '%s[WARNING]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error()   { printf '%s[ERROR]%s   %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
log_step()    { printf '\n%s==> %s%s\n' "$C_BLUE" "$*" "$C_RESET"; }
die()         { log_error "$*"; exit 1; }

on_error() {
  local rc=$? line=$1
  log_error "Errore inatteso (exit $rc) alla riga $line: ${BASH_COMMAND:-?}"
  exit "$rc"
}
trap 'on_error $LINENO' ERR

# =============================================================================
# Helper di esecuzione (supporto --dry-run)
# =============================================================================
# run CMD...: esegue il comando, oppure lo stampa soltanto in modalita' dry-run.
run() {
  if (( DRY_RUN )); then
    printf '%s[dry-run]%s + ' "$C_DIM" "$C_RESET"
    printf '%q ' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

# run_try CMD...: come run, ma un fallimento e' solo un avviso.
run_try() {
  run "$@" || log_warn "Comando non riuscito (ignorato): $*"
}

# ensure_sudo: richiede la password una sola volta, solo se serve davvero.
ensure_sudo() {
  (( DRY_RUN )) && return 0
  (( SUDO_READY )) && return 0
  command -v sudo >/dev/null 2>&1 || die "sudo non trovato: installalo o chiedi all'amministratore di eseguire i passi privilegiati."
  if ! sudo -n true 2>/dev/null; then
    log_info "Servono privilegi amministrativi (sudo) per alcuni passi."
    sudo -v || die "sudo non disponibile per l'utente $USER."
  fi
  SUDO_READY=1
}

# run_sudo CMD...: comando con sudo (solo puntuale).
run_sudo() {
  ensure_sudo
  run sudo "$@"
}

# write_root_file PATH MODE CONTENT: scrive un file di sistema con sudo.
write_root_file() {
  local path=$1 mode=$2 content=$3
  if (( DRY_RUN )); then
    printf '%s[dry-run]%s + scrittura di %s (modo %s):\n' "$C_DIM" "$C_RESET" "$path" "$mode"
    printf '%s\n' "$content" | sed 's/^/             | /'
    return 0
  fi
  ensure_sudo
  printf '%s\n' "$content" | sudo tee "$path" >/dev/null
  sudo chmod "$mode" "$path"
}

confirm() {
  local prompt=$1 reply
  (( ASSUME_YES || DRY_RUN )) && return 0
  [[ -t 0 ]] || die "Operazione distruttiva senza terminale interattivo: usa --yes per confermare."
  read -r -p "$prompt [s/N] " reply
  [[ $reply =~ ^[sSyY]$ ]]
}

# =============================================================================
# File di stato (cosa abbiamo modificato noi)
# =============================================================================
state_get() {
  [[ -f $STATE_FILE ]] || return 0
  { grep -E "^$1=" "$STATE_FILE" || true; } | tail -n1 | cut -d= -f2-
}

state_set() {
  local key=$1 val=$2 tmp
  (( DRY_RUN )) && return 0
  mkdir -p "$STATE_DIR"
  tmp=$(mktemp)
  [[ -f $STATE_FILE ]] && { grep -v -E "^$key=" "$STATE_FILE" >"$tmp" || true; }
  printf '%s=%s\n' "$key" "$val" >>"$tmp"
  cat "$tmp" >"$STATE_FILE"
  rm -f "$tmp"
}

state_del() {
  local tmp
  (( DRY_RUN )) && return 0
  [[ -f $STATE_FILE ]] || return 0
  tmp=$(mktemp)
  { grep -v -E "^$1=" "$STATE_FILE" >"$tmp" || true; }
  cat "$tmp" >"$STATE_FILE"
  rm -f "$tmp"
}

# state_add KEY WORD: aggiunge una parola a una lista (senza duplicati).
state_add() {
  local key=$1 word=$2 cur
  cur=$(state_get "$key")
  case " $cur " in *" $word "*) return 0 ;; esac
  state_set "$key" "${cur:+$cur }$word"
}

# state_remove_word KEY WORD
state_remove_word() {
  local key=$1 word=$2 cur new="" w
  cur=$(state_get "$key")
  for w in $cur; do [[ $w == "$word" ]] || new+="${new:+ }$w"; done
  if [[ -n $new ]]; then state_set "$key" "$new"; else state_del "$key"; fi
}

has_engine() { [[ $ENGINE == both || $ENGINE == "$1" ]]; }

# =============================================================================
# Rilevamento distribuzione
# =============================================================================
# shellcheck disable=SC1090  # il file os-release e' scelto a runtime
os_get() { ( . "$OS_RELEASE_FILE" 2>/dev/null; printf '%s' "${!1-}" ); }

ver_ge() { printf '%s\n%s\n' "$2" "$1" | sort -V -C; }   # $1 >= $2

detect_os() {
  log_step "Rilevamento distribuzione"
  [[ -r $OS_RELEASE_FILE ]] || die "Impossibile leggere $OS_RELEASE_FILE."
  OS_ID=$(os_get ID); OS_LIKE=$(os_get ID_LIKE); OS_VER=$(os_get VERSION_ID)
  OS_NAME=$(os_get PRETTY_NAME)
  OS_CODENAME=$(os_get VERSION_CODENAME)
  local major=${OS_VER%%.*}

  case $OS_ID in
    ubuntu)
      PKG=apt; DOCKER_REPO_OS=ubuntu
      OS_CODENAME=$(os_get UBUNTU_CODENAME); [[ -n $OS_CODENAME ]] || OS_CODENAME=$(os_get VERSION_CODENAME)
      ver_ge "${OS_VER:-0}" 24.04 || die "Ubuntu $OS_VER non supportata (minimo 24.04). Usa --force-distro per ignorare."
      ;;
    debian)
      PKG=apt; DOCKER_REPO_OS=debian
      if [[ -z $OS_VER ]]; then
        log_warn "VERSION_ID assente (Debian testing/sid?): procedo come Debian >= 13."
      else
        ver_ge "$OS_VER" 13 || die "Debian $OS_VER non supportata (minimo 13 Trixie). Usa --force-distro per ignorare."
      fi
      ;;
    almalinux|rhel|rocky|centos|ol)
      PKG=dnf; DOCKER_REPO_OS=centos; [[ $OS_ID == rhel ]] && DOCKER_REPO_OS=rhel
      [[ $major =~ ^[0-9]+$ ]] || die "VERSION_ID non valido: '$OS_VER'."
      (( major >= 9 )) || die "$OS_NAME non supportata (minimo 9). Usa --force-distro per ignorare."
      (( major <= 10 )) || log_warn "Versione $OS_VER piu' recente di quelle testate (9/10): procedo comunque."
      ;;
    *)
      (( FORCE_DISTRO )) || die "Distribuzione '$OS_ID' non supportata. Supportate: Ubuntu >= 24.04, Debian >= 13, AlmaLinux/RHEL 9-10 (--force-distro per tentare comunque)."
      case " $OS_LIKE " in
        *" ubuntu "*) PKG=apt; DOCKER_REPO_OS=ubuntu ;;
        *" debian "*) PKG=apt; DOCKER_REPO_OS=debian ;;
        *" rhel "*)   PKG=dnf; DOCKER_REPO_OS=centos ;;
        *) die "Impossibile dedurre la famiglia da ID_LIKE='$OS_LIKE'." ;;
      esac
      log_warn "Distribuzione non ufficialmente supportata ($OS_ID): uso la famiglia '$PKG'."
      ;;
  esac
  log_info "Distribuzione: ${OS_NAME:-$OS_ID} (famiglia pacchetti: $PKG)"
}

is_rhel_family() { [[ $PKG == dnf ]]; }

# Default dell'engine quando --engine non e' passato: su RHEL/Alma solo Podman
# (percorso supportato dalla distro), su Debian/Ubuntu Podman e Docker insieme.
resolve_default_engine() {
  [[ -n $ENGINE ]] && return 0
  if is_rhel_family; then ENGINE=podman; else ENGINE=both; fi
  log_info "Engine non specificato: uso '$ENGINE' (default per $OS_ID). Cambialo con --engine podman|docker|both."
}

preflight() {
  log_step "Controlli preliminari"
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    die "Non eseguire come root: la modalita' rootless richiede un utente standard (sudo viene usato solo dove serve)."
  fi
  [[ -n ${HOME:-} && -d $HOME ]] || die "HOME non valida."
  USER_NAME=$(id -un); USER_ID=$(id -u)
  readonly USER_NAME USER_ID
  command -v systemctl >/dev/null 2>&1 || die "systemd non trovato: richiesto per i servizi utente."
  log_info "Utente: $USER_NAME (uid $USER_ID) | modo: $MODE | engine: $ENGINE | dry-run: $DRY_RUN"
}

# =============================================================================
# Gestione pacchetti
# =============================================================================
pkg_installed() {
  case $PKG in
    apt) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
    dnf) rpm -q "$1" >/dev/null 2>&1 ;;
  esac
}

pkg_available() {
  local c
  # Su un host di altra famiglia (es. test --dry-run con OS_RELEASE_FILE) non si puo' verificare: assumo disponibile.
  case $PKG in apt) command -v apt-cache >/dev/null 2>&1 || return 0 ;; dnf) command -v dnf >/dev/null 2>&1 || return 0 ;; esac
  case $PKG in
    apt) c=$(apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ {print $2}')
         [[ -n $c && $c != "(none)" ]] ;;
    dnf) dnf -q list --available "$1" >/dev/null 2>&1 || rpm -q "$1" >/dev/null 2>&1 ;;
  esac
}

pkg_refresh() {
  [[ $PKG == apt ]] || return 0
  (( APT_UPDATED )) && return 0
  run_sudo apt-get update
  APT_UPDATED=1
}

# pkgs_install OWNER PKG... : installa i mancanti e li registra come "nostri".
pkgs_install() {
  local owner=$1; shift
  local p missing=()
  for p in "$@"; do pkg_installed "$p" || missing+=("$p"); done
  if (( ${#missing[@]} == 0 )); then
    log_info "Pacchetti gia' presenti: $*"
    return 0
  fi
  log_info "Installo: ${missing[*]}"
  pkg_refresh
  case $PKG in
    apt) run_sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}" ;;
    dnf) run_sudo dnf install -y "${missing[@]}" ;;
  esac
  for p in "${missing[@]}"; do state_add "PKGS_$owner" "$p"; done
}

# pkgs_install_optional OWNER PKG... : come sopra ma salta quelli non disponibili.
pkgs_install_optional() {
  local owner=$1; shift
  local p ok=()
  pkg_refresh
  for p in "$@"; do
    if pkg_installed "$p" || pkg_available "$p"; then ok+=("$p")
    else log_warn "Pacchetto opzionale non disponibile su questa distro, salto: $p"; fi
  done
  (( ${#ok[@]} )) && pkgs_install "$owner" "${ok[@]}"
  return 0
}

# pkgs_remove_owner OWNER: rimuove solo i pacchetti che abbiamo installato noi.
pkgs_remove_owner() {
  local owner=$1 list
  list=$(state_get "PKGS_$owner")
  if [[ -z $list ]]; then
    log_info "Nessun pacchetto '$owner' installato dallo script: niente da rimuovere."
    return 0
  fi
  log_info "Rimuovo i pacchetti ($owner): $list"
  # shellcheck disable=SC2086  # word splitting voluto sulla lista
  case $PKG in
    apt) run_sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y $list ;;
    dnf) run_sudo dnf remove -y $list ;;
  esac
  state_del "PKGS_$owner"
}

# =============================================================================
# Registrazione / rimozione file di sistema creati da noi
# =============================================================================
sysfile_register() { state_add "FILES_$1" "$2"; }

sysfiles_remove_owner() {
  local owner=$1 f list
  list=$(state_get "FILES_$owner")
  [[ -n $list ]] || return 0
  for f in $list; do
    log_info "Rimuovo file di sistema creato dallo script: $f"
    run_sudo rm -f "$f"
  done
  state_del "FILES_$owner"
}

# =============================================================================
# Fase: pacchetti
# =============================================================================
install_common_packages() {
  log_step "Pacchetti di base"
  case $PKG in
    apt) pkgs_install common uidmap dbus-user-session curl ca-certificates ;;
    dnf) pkgs_install common shadow-utils curl ca-certificates ;;
  esac
}

install_podman_packages() {
  log_step "Installazione Podman"
  case $PKG in
    apt)
      pkgs_install podman podman
      pkgs_install_optional podman slirp4netns fuse-overlayfs passt
      ;;
    dnf)
      pkgs_install podman podman container-selinux
      pkgs_install_optional podman slirp4netns fuse-overlayfs passt
      ;;
  esac
}

# "podman compose" non ha un provider di serie: serve il plugin Docker Compose (v2+), che usa tramite il
# socket di Podman. Non si usa podman-compose (EPEL): concatena le liste dei file -f e rifiuta gli overlay
# che ridefiniscono un elenco (es. healthcheck.test: "'CMD_SHELL' takes a single string after it").
# Con --engine docker/both il plugin arriva gia' con docker-compose-plugin.
install_podman_compose_provider() {
  has_engine podman || return 0
  has_engine docker && return 0
  log_step "Provider compose per Podman"
  case $PKG in
    apt)
      if pkg_available docker-compose-v2; then
        pkgs_install podman docker-compose-v2
      else
        setup_docker_repo
        pkgs_install podman docker-compose-plugin
      fi
      ;;
    dnf)
      setup_docker_repo
      pkgs_install podman docker-compose-plugin
      ;;
  esac
}

setup_docker_repo() {
  log_info "Configuro il repository ufficiale Docker ($DOCKER_REPO_OS)"
  case $PKG in
    apt)
      if [[ -f /etc/apt/sources.list.d/docker.sources || -f /etc/apt/sources.list.d/docker.list ]]; then
        log_info "Repository Docker gia' configurato."
        return 0
      fi
      [[ -n $OS_CODENAME ]] || die "Codename della distribuzione non rilevato: impossibile configurare il repo Docker."
      run_sudo install -m 0755 -d /etc/apt/keyrings
      run_sudo curl -fsSL "https://download.docker.com/linux/$DOCKER_REPO_OS/gpg" -o /etc/apt/keyrings/docker.asc
      run_sudo chmod a+r /etc/apt/keyrings/docker.asc
      write_root_file /etc/apt/sources.list.d/docker.sources 0644 "Types: deb
URIs: https://download.docker.com/linux/$DOCKER_REPO_OS
Suites: $OS_CODENAME
Components: stable
Architectures: $(dpkg --print-architecture 2>/dev/null || echo amd64)
Signed-By: /etc/apt/keyrings/docker.asc"
      sysfile_register docker-repo /etc/apt/sources.list.d/docker.sources
      sysfile_register docker-repo /etc/apt/keyrings/docker.asc
      APT_UPDATED=0
      pkg_refresh
      ;;
    dnf)
      if [[ -f /etc/yum.repos.d/docker-ce.repo ]]; then
        log_info "Repository Docker gia' configurato."
        return 0
      fi
      run_sudo curl -fsSL "https://download.docker.com/linux/$DOCKER_REPO_OS/docker-ce.repo" -o /etc/yum.repos.d/docker-ce.repo
      sysfile_register docker-repo /etc/yum.repos.d/docker-ce.repo
      ;;
  esac
}

install_docker_packages() {
  log_step "Installazione Docker (rootless)"
  local conflicts=() p
  for p in docker.io docker-doc podman-docker docker; do
    pkg_installed "$p" && conflicts+=("$p")
  done
  (( ${#conflicts[@]} )) && log_warn "Pacchetti potenzialmente in conflitto con docker-ce gia' installati: ${conflicts[*]} (rimuoverli a mano se l'installazione fallisce)."

  # Lo stato del daemon di sistema va letto PRIMA di installare docker-ce.
  if pkg_installed docker-ce && systemctl is-enabled --quiet docker.service 2>/dev/null; then
    KEEP_SYSTEM_DOCKER=1
    log_info "Docker di sistema (rootful) gia' presente e abilitato: non verra' toccato."
  fi

  setup_docker_repo
  case $PKG in
    apt)
      pkgs_install docker docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
        docker-compose-plugin docker-ce-rootless-extras
      pkgs_install_optional docker slirp4netns fuse-overlayfs
      ;;
    dnf)
      pkgs_install docker docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
        docker-compose-plugin docker-ce-rootless-extras iptables
      pkgs_install_optional docker slirp4netns fuse-overlayfs
      ;;
  esac

  # docker-ce avvia il daemon rootful: per una configurazione rootless pulita lo disabilitiamo.
  if (( KEEP_SYSTEM_DOCKER )); then
    log_info "Lascio attivo il daemon Docker di sistema (--keep-system-docker o gia' in uso)."
  else
    log_info "Disabilito il daemon Docker di sistema (rootful), non serve in modalita' rootless."
    run_sudo systemctl disable --now docker.service docker.socket
    run_sudo rm -f /var/run/docker.sock
  fi
}

# =============================================================================
# Fase: prerequisiti di sistema / sicurezza
# =============================================================================
# Stampa "start end" del primo range libero >= SUBID_MIN_START per il file dato.
next_free_subid_start() {
  awk -F: -v min="$SUBID_MIN_START" '
    BEGIN { m = min }
    { e = $2 + $3; if (e > m) m = e }
    END { print m }' "$1" 2>/dev/null || echo "$SUBID_MIN_START"
}

user_subid_count() {
  local file=$1
  [[ -r $file ]] || { echo 0; return; }
  awk -F: -v u="$USER_NAME" -v id="$USER_ID" '($1==u || $1==id) {s+=$3} END {print s+0}' "$file"
}

setup_subids() {
  log_step "Range UID/GID subordinati (/etc/subuid, /etc/subgid)"
  local sub_cnt gid_cnt start
  sub_cnt=$(user_subid_count /etc/subuid)
  gid_cnt=$(user_subid_count /etc/subgid)
  if (( sub_cnt >= SUBID_COUNT && gid_cnt >= SUBID_COUNT )); then
    log_success "Range gia' sufficienti per $USER_NAME (subuid: $sub_cnt, subgid: $gid_cnt)."
    return 0
  fi
  local add_u=() add_g=()
  if (( sub_cnt < SUBID_COUNT )); then
    start=$(next_free_subid_start /etc/subuid)
    add_u=(--add-subuids "${start}-$((start + SUBID_COUNT - 1))")
    state_set SUBUID_BY_US "${start}-$((start + SUBID_COUNT - 1))"
  fi
  if (( gid_cnt < SUBID_COUNT )); then
    start=$(next_free_subid_start /etc/subgid)
    add_g=(--add-subgids "${start}-$((start + SUBID_COUNT - 1))")
    state_set SUBGID_BY_US "${start}-$((start + SUBID_COUNT - 1))"
  fi
  log_info "Imposto i range subordinati (${SUBID_COUNT} id) per $USER_NAME"
  run_sudo usermod "${add_u[@]}" "${add_g[@]}" "$USER_NAME"
}

setup_userns_sysctl() {
  local cur
  cur=$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo 1)
  if (( cur > 0 )); then
    log_info "user.max_user_namespaces=$cur (ok)."
    return 0
  fi
  log_warn "user.max_user_namespaces=0: i namespace utente sono disabilitati, li abilito."
  write_root_file /etc/sysctl.d/99-rootless-userns.conf 0644 "user.max_user_namespaces=15000"
  sysfile_register common /etc/sysctl.d/99-rootless-userns.conf
  run_sudo sysctl --system
}

setup_low_ports() {
  (( LOW_PORTS )) || return 0
  log_step "Porte privilegiate per utenti non root"
  write_root_file /etc/sysctl.d/99-rootless-low-ports.conf 0644 "net.ipv4.ip_unprivileged_port_start=0"
  sysfile_register common /etc/sysctl.d/99-rootless-low-ports.conf
  run_sudo sysctl --system
}

enable_linger() {
  log_step "Persistenza servizi utente (linger)"
  local cur
  cur=$(loginctl show-user "$USER_NAME" -p Linger --value 2>/dev/null || echo "no")
  if [[ $cur == yes ]]; then
    log_success "Linger gia' attivo per $USER_NAME."
    return 0
  fi
  log_info "Eseguo: loginctl enable-linger $USER_NAME"
  if (( DRY_RUN )); then
    run loginctl enable-linger "$USER_NAME"
  else
    loginctl enable-linger "$USER_NAME" 2>/dev/null || run_sudo loginctl enable-linger "$USER_NAME"
  fi
  state_set LINGER_BY_US yes
}

# Rende utilizzabile "systemctl --user" anche da sessioni su/ssh senza env.
ensure_user_session() {
  local soft=${1:-}
  export XDG_RUNTIME_DIR="/run/user/$USER_ID"
  if (( DRY_RUN )); then return 0; fi
  if [[ ! -S $XDG_RUNTIME_DIR/bus ]]; then
    log_info "Avvio il manager systemd utente (user@$USER_ID.service)"
    run_sudo systemctl start "user@$USER_ID.service" || true
    for _ in $(seq 1 15); do [[ -S $XDG_RUNTIME_DIR/bus ]] && break; sleep 1; done
  fi
  export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=$XDG_RUNTIME_DIR/bus}"
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    [[ $soft == soft ]] && { log_warn "systemd utente non raggiungibile: salto lo stop dei servizi."; return 1; }
    die "systemd utente non raggiungibile. Fai logout/login (o apri una sessione ssh completa) e rilancia lo script."
  fi
}

# --- SELinux / firewalld (famiglia RHEL) --------------------------------------
setup_selinux() {
  is_rhel_family || return 0
  log_step "SELinux"
  if (( NO_SELINUX )); then log_info "Saltato (--no-selinux)."; return 0; fi
  pkgs_install common policycoreutils
  local mode
  mode=$(getenforce 2>/dev/null || echo Disabled)
  if [[ $mode == Disabled ]]; then
    log_info "SELinux disabilitato: niente da configurare."
    return 0
  fi
  log_info "SELinux in modalita': $mode"
  # container_manage_cgroup: necessario per container che eseguono systemd.
  local bool=container_manage_cgroup prev
  prev=$(getsebool "$bool" 2>/dev/null | awk '{print $3}' || true)
  if [[ $prev == off ]]; then
    log_info "Abilito il boolean SELinux $bool (era: off)"
    run_sudo setsebool -P "$bool" on
    state_set "SEBOOL_$bool" off
  else
    log_info "Boolean $bool gia' attivo o non presente."
  fi
  # Etichette corrette sugli storage utente (se esistono gia').
  local d
  for d in "$HOME/.local/share/containers" "$HOME/.local/share/docker"; do
    [[ -d $d ]] && run_sudo restorecon -R "$d"
  done
  return 0
}

setup_firewall() {
  is_rhel_family || return 0
  log_step "Firewalld"
  if ! command -v firewall-cmd >/dev/null 2>&1 || ! systemctl is-active --quiet firewalld 2>/dev/null; then
    log_info "firewalld non attivo: niente da fare."
    return 0
  fi
  if (( ${#FW_PORTS[@]} == 0 )); then
    log_info "La rete rootless (slirp4netns/pasta/rootlesskit) e' interamente in user-space: nessuna regola firewalld necessaria."
    log_info "Per pubblicare porte verso l'esterno usa: --open-port 8080/tcp (ripetibile)."
    return 0
  fi
  local p
  for p in "${FW_PORTS[@]}"; do
    if firewall-cmd --query-port="$p" >/dev/null 2>&1; then
      log_info "Porta $p gia' aperta."
    else
      run_sudo firewall-cmd --permanent --add-port="$p"
      state_add FW_PORTS "$p"
    fi
  done
  run_sudo firewall-cmd --reload
}

# --- Docker: requisiti specifici ---------------------------------------------
setup_docker_prereqs() {
  # Ubuntu 24.04+: AppArmor blocca i user namespace non confinati -> profilo per rootlesskit.
  if [[ $OS_ID == ubuntu ]] &&
     [[ $(cat /proc/sys/kernel/apparmor_restrict_unprivileged_userns 2>/dev/null || echo 0) == 1 ]]; then
    local prof=/etc/apparmor.d/usr.bin.rootlesskit
    if [[ -f $prof ]]; then
      log_info "Profilo AppArmor per rootlesskit gia' presente."
    else
      log_info "Creo il profilo AppArmor per rootlesskit (apparmor_restrict_unprivileged_userns=1)"
      write_root_file "$prof" 0644 "abi <abi/4.0>,
include <tunables/global>

/usr/bin/rootlesskit flags=(unconfined) {
  userns,

  # Site-specific additions and overrides. See local/README for details.
  include if exists <local/usr.bin.rootlesskit>
}"
      sysfile_register docker "$prof"
      run_sudo systemctl restart apparmor.service
    fi
  fi

  # Delega cgroup v2 (limiti di risorse nei container rootless).
  local deleg=/etc/systemd/system/user@.service.d/delegate.conf
  if [[ -f $deleg ]]; then
    log_info "Delega cgroup gia' configurata."
  else
    log_info "Abilito la delega dei controller cgroup v2 agli utenti"
    run_sudo mkdir -p /etc/systemd/system/user@.service.d
    write_root_file "$deleg" 0644 "[Service]
Delegate=cpu cpuset io memory pids"
    sysfile_register docker "$deleg"
    run_sudo systemctl daemon-reload
    log_warn "La delega cgroup ha effetto dopo un nuovo login dell'utente."
  fi

  # Debian/Ubuntu: dockerd-rootless-setuptool.sh (Docker 29+) rifiuta di installare se il
  # modulo nf_tables non e' caricato (su un'installazione pulita di solito non lo e').
  if ! is_rhel_family; then
    local nft_mods=/etc/modules-load.d/rootless-docker.conf
    if [[ ! -f $nft_mods ]]; then
      write_root_file "$nft_mods" 0644 "nf_tables"
      sysfile_register docker "$nft_mods"
    fi
    run sudo modprobe nf_tables || die "Impossibile caricare il modulo kernel nf_tables, richiesto da Docker rootless."
  fi

  # RHEL: moduli netfilter necessari al rootless networking di Docker. Sono in
  # kernel-modules-extra, che dnf installa per il kernel PIU' RECENTE: se il kernel
  # in esecuzione e' piu' vecchio i moduli non si caricano e serve un reboot.
  if is_rhel_family; then
    local mods=/etc/modules-load.d/rootless-docker.conf
    if [[ ! -f $mods ]]; then
      write_root_file "$mods" 0644 "ip_tables
ip6_tables
iptable_nat
ip6table_nat"
      sysfile_register docker "$mods"
    fi
    if ! run sudo modprobe -a ip_tables ip6_tables iptable_nat ip6table_nat 2>/dev/null; then
      NEED_REBOOT=1
      log_warn "Moduli netfilter non caricabili per il kernel in esecuzione ($(uname -r)): riavvia l'host sul kernel piu' recente e rilancia lo script per completare Docker."
    fi
  fi
}

# =============================================================================
# Fase: servizi utente
# =============================================================================
setup_podman_services() {
  log_step "Servizi utente Podman"
  run systemctl --user enable --now podman.socket
  state_add ENGINES podman
}

setup_docker_services() {
  log_step "Servizi utente Docker (rootless)"
  local unit="$HOME/.config/systemd/user/docker.service"
  if [[ -f $unit ]]; then
    log_info "docker.service utente gia' configurato: lo riabilito."
    run systemctl --user enable --now docker.service
  else
    local tool
    tool=$(command -v dockerd-rootless-setuptool.sh 2>/dev/null || echo /usr/bin/dockerd-rootless-setuptool.sh)
    if (( ! DRY_RUN )) && [[ ! -x $tool ]]; then
      die "dockerd-rootless-setuptool.sh non trovato: verifica che docker-ce-rootless-extras sia installato."
    fi
    run "$tool" install
    run systemctl --user enable --now docker.service
  fi
  state_add ENGINES docker
}

# =============================================================================
# Fase: variabili d'ambiente in .bashrc (blocco gestito, idempotente)
# =============================================================================
# shellcheck disable=SC2016  # le variabili vanno scritte letterali nel .bashrc
render_env_block() {
  local with_docker=$1
  printf '%s\n' "$MARK_BEGIN"
  printf '%s\n' 'export XDG_RUNTIME_DIR=/run/user/$(id -u)'
  [[ $with_docker == 1 ]] && printf '%s\n' 'export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock'
  printf '%s\n' '[[ ":$PATH:" == *":$HOME/bin:"* ]] || export PATH=$HOME/bin:$PATH'
  printf '%s\n' "$MARK_END"
}

# Stampa il file senza il blocco gestito.
rc_without_block() {
  awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b { skip = 1; next }
    $0 == e { skip = 0; next }
    !skip { print }' "$1"
}

# Filtro: elimina le righe vuote finali (evita che si accumulino a ogni riscrittura).
strip_trailing_blanks() {
  awk '/^[[:space:]]*$/ { n++; next } { while (n > 0) { print ""; n-- } print }'
}

rc_backup_once() {
  local bak="$RC_FILE.pre-rootless-setup"
  [[ -f $RC_FILE && ! -e $bak ]] || return 0
  run cp -p "$RC_FILE" "$bak"
}

# apply_env_block WITH_DOCKER: (ri)scrive il blocco; idempotente.
apply_env_block() {
  local with_docker=$1 new cur
  new=$(render_env_block "$with_docker")
  cur=""
  [[ -f $RC_FILE ]] && cur=$(awk -v b="$MARK_BEGIN" -v e="$MARK_END" '
    $0 == b { f = 1 } f { print } $0 == e { f = 0 }' "$RC_FILE")
  if [[ $cur == "$new" ]]; then
    log_success "Variabili d'ambiente gia' presenti in $RC_FILE."
    return 0
  fi
  log_info "Aggiorno il blocco di variabili d'ambiente in $RC_FILE"
  if (( DRY_RUN )); then
    printf '%s[dry-run]%s + blocco scritto in %s:\n' "$C_DIM" "$C_RESET" "$RC_FILE"
    printf '%s\n' "$new" | sed 's/^/             | /'
    return 0
  fi
  rc_backup_once
  local tmp; tmp=$(mktemp)
  [[ -f $RC_FILE ]] && rc_without_block "$RC_FILE" | strip_trailing_blanks >"$tmp"
  { [[ -s $tmp ]] && printf '\n'; printf '%s\n' "$new"; } >>"$tmp"
  [[ -f $RC_FILE ]] || : >"$RC_FILE"
  cat "$tmp" >"$RC_FILE"
  rm -f "$tmp"
}

remove_env_block() {
  if [[ ! -f $RC_FILE ]] || ! grep -qxF "$MARK_BEGIN" "$RC_FILE"; then
    log_info "Nessun blocco gestito in $RC_FILE."
    return 0
  fi
  log_info "Rimuovo il blocco di variabili d'ambiente da $RC_FILE"
  if (( DRY_RUN )); then
    printf '%s[dry-run]%s + rimozione del blocco %s .. %s da %s\n' "$C_DIM" "$C_RESET" "$MARK_BEGIN" "$MARK_END" "$RC_FILE"
    return 0
  fi
  local tmp; tmp=$(mktemp)
  rc_without_block "$RC_FILE" | strip_trailing_blanks >"$tmp"
  cat "$tmp" >"$RC_FILE"
  rm -f "$tmp"
}

setup_env() {
  log_step "Variabili d'ambiente ($RC_FILE)"
  local w=0
  [[ " $(state_get ENGINES) " == *" docker "* ]] && w=1
  has_engine docker && w=1
  apply_env_block "$w"
  # Esportate anche nel processo corrente per i test finali.
  export XDG_RUNTIME_DIR="/run/user/$USER_ID"
  (( w )) && export DOCKER_HOST="unix://$XDG_RUNTIME_DIR/docker.sock"
  case ":$PATH:" in *":$HOME/bin:"*) ;; *) export PATH="$HOME/bin:$PATH" ;; esac
  return 0
}

# =============================================================================
# Test finale
# =============================================================================
test_engine() {
  local name=$1 out
  if (( DRY_RUN )); then
    run "$name" info
    return 0
  fi
  command -v "$name" >/dev/null 2>&1 || { log_error "$name non trovato nel PATH."; FAILURES=$((FAILURES + 1)); return 0; }
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if out=$("$name" info 2>&1); then
      log_success "$name info OK (senza sudo)."
      printf '%s\n' "$out" | grep -i -E 'rootless|server version|^ *version:' | head -n4 | sed 's/^/             /' || true
      return 0
    fi
    sleep 1
  done
  log_error "'$name info' non riuscito:"
  printf '%s\n' "$out" | tail -n 8 | sed 's/^/             /' >&2
  FAILURES=$((FAILURES + 1))
}

test_podman_compose() {
  if (( DRY_RUN )); then
    run podman compose version
    return 0
  fi
  command -v podman >/dev/null 2>&1 || return 0
  if PODMAN_COMPOSE_WARNING_LOGS=false podman compose version >/dev/null 2>&1; then
    log_success "podman compose OK (provider compose trovato)."
  else
    log_warn "podman compose non ha un provider compose: installa il plugin Docker Compose (docker-compose-plugin)."
  fi
}

run_post_install_tests() {
  log_step "Test di funzionamento (senza sudo)"
  has_engine podman && test_engine podman
  has_engine podman && test_podman_compose
  if has_engine docker; then
    if (( NEED_REBOOT )); then log_warn "Test di docker saltato (reboot necessario)."
    else test_engine docker; fi
  fi
  return 0
}

# =============================================================================
# Flusso di INSTALLAZIONE
# =============================================================================
do_install() {
  install_common_packages
  has_engine podman && install_podman_packages
  has_engine docker && install_docker_packages
  install_podman_compose_provider
  setup_subids
  setup_userns_sysctl
  setup_low_ports
  has_engine docker && { log_step "Prerequisiti Docker rootless"; setup_docker_prereqs; }
  enable_linger
  ensure_user_session
  has_engine podman && setup_podman_services
  if has_engine docker; then
    if (( NEED_REBOOT )); then
      log_warn "Salto l'avvio di Docker rootless: serve prima un reboot (vedi sopra)."
    else
      setup_docker_services
    fi
  fi
  setup_env
  setup_selinux
  setup_firewall
  run_post_install_tests

  log_step "Riepilogo"
  if (( FAILURES )); then
    log_error "Installazione completata con $FAILURES test falliti. Apri una nuova sessione (login) e riprova '$SCRIPT_NAME' o i comandi 'podman info' / 'docker info'."
    return 1
  fi
  if (( DRY_RUN )); then
    log_success "Dry-run completato: nessuna modifica applicata."
  elif (( NEED_REBOOT )); then
    log_warn "Podman e prerequisiti pronti, ma Docker rootless NON e' ancora attivo: riavvia l'host e rilancia '$SCRIPT_NAME --engine ${ENGINE}' (e' idempotente)."
  else
    log_success "Setup rootless completato. Apri una nuova shell (o 'source $RC_FILE') per caricare le variabili."
  fi
}

# =============================================================================
# Flusso di DISINSTALLAZIONE
# =============================================================================
backup_and_remove_config() {
  local dirs=() d ts archive
  for d in "$@"; do [[ -e $HOME/$d ]] && dirs+=("$d"); done
  (( ${#dirs[@]} )) || { log_info "Nessuna directory di configurazione da rimuovere."; return 0; }
  ts=$(date +%Y%m%d-%H%M%S)
  archive="$HOME/rootless-container-setup-config-backup-$ts.tar.gz"
  log_info "Backup della configurazione in $archive"
  run tar -czf "$archive" -C "$HOME" "${dirs[@]}"
  for d in "${dirs[@]}"; do run rm -rf "${HOME:?}/$d"; done
}

uninstall_podman() {
  log_step "Disinstallazione Podman (utente)"
  run_try systemctl --user disable --now podman.socket podman.service
  if (( PURGE )); then
    if command -v podman >/dev/null 2>&1; then
      log_info "Elimino container, immagini e volumi Podman (podman system reset)"
      run_try podman system reset --force
    fi
    run_try rm -rf "${HOME:?}/.local/share/containers"
  else
    log_info "Dati (immagini/volumi/container) conservati in ~/.local/share/containers (usa --purge per rimuoverli)."
  fi
  backup_and_remove_config .config/containers
}

uninstall_docker() {
  log_step "Disinstallazione Docker rootless (utente)"
  run_try systemctl --user disable --now docker.service docker.socket
  local tool
  tool=$(command -v dockerd-rootless-setuptool.sh 2>/dev/null || true)
  if [[ -n $tool ]]; then
    run_try "$tool" uninstall
  else
    log_warn "dockerd-rootless-setuptool.sh non trovato: rimuovo a mano l'unit utente."
  fi
  run rm -f "$HOME/.config/systemd/user/docker.service"
  run_try systemctl --user daemon-reload
  if (( PURGE )); then
    log_info "Elimino container, immagini e volumi Docker rootless"
    if command -v rootlesskit >/dev/null 2>&1; then
      run_try rootlesskit rm -rf "$HOME/.local/share/docker"
    else
      run_try rm -rf "${HOME:?}/.local/share/docker"
    fi
  else
    log_info "Dati conservati in ~/.local/share/docker (usa --purge per rimuoverli)."
  fi
  backup_and_remove_config .config/docker
}

# Residui lasciati da podman/rootlesskit/systemd dopo la disinstallazione.
# Con --purge si eliminano anche le directory di stato degli engine rimossi; in ogni
# caso si tolgono solo directory VUOTE (mai file dell'utente in ~/.config/systemd).
prune_residual_dirs() {
  local d
  if (( PURGE )); then
    has_engine docker && [[ -d $HOME/.local/share/rootlesskit ]] && run_try rm -rf "${HOME:?}/.local/share/rootlesskit"
    has_engine podman && [[ -d $HOME/.config/cni ]] && run_try rm -rf "${HOME:?}/.config/cni"
  fi
  for d in .config/systemd .local/state/rootless-container-setup; do
    [[ -d $HOME/$d ]] && run_try find "$HOME/$d" -depth -type d -empty -delete
  done
  return 0
}

# Altri servizi utente attivi oltre a quelli "di base" del desktop/sessione?
other_user_services_active() {
  local n
  n=$(systemctl --user list-units --type=service --state=running --no-legend --plain 2>/dev/null |
      awk '{print $1}' |
      grep -v -E '^(dbus|dbus-broker|systemd-.*|pipewire.*|wireplumber|pulseaudio|gpg-agent.*|xdg-.*|gvfs-.*|at-spi.*|gnome-.*|dconf.*|ssh-agent)\.service$|^(dbus|dbus-broker)' |
      grep -c . || true)
  (( ${n:-0} > 0 ))
}

restore_linger() {
  log_step "Ripristino linger"
  if [[ $(state_get LINGER_BY_US) != yes ]]; then
    log_info "Il linger non era stato attivato da questo script: lo lascio invariato."
    return 0
  fi
  if other_user_services_active; then
    log_warn "Ci sono altri servizi utente attivi: lascio il linger abilitato."
    return 0
  fi
  log_info "Eseguo: loginctl disable-linger $USER_NAME"
  if (( DRY_RUN )); then
    run loginctl disable-linger "$USER_NAME"
  else
    loginctl disable-linger "$USER_NAME" 2>/dev/null || run_sudo loginctl disable-linger "$USER_NAME"
  fi
  state_del LINGER_BY_US
}

restore_subids() {
  local u g
  u=$(state_get SUBUID_BY_US); g=$(state_get SUBGID_BY_US)
  [[ -n $u || -n $g ]] || { log_info "Range subuid/subgid non aggiunti dallo script: invariati."; return 0; }
  log_info "Rimuovo i range subordinati aggiunti dallo script (${u:-} ${g:-})"
  local args=()
  [[ -n $u ]] && args+=(--del-subuids "$u")
  [[ -n $g ]] && args+=(--del-subgids "$g")
  run_sudo usermod "${args[@]}" "$USER_NAME"
  state_del SUBUID_BY_US; state_del SUBGID_BY_US
}

restore_selinux_firewall() {
  local prev p
  prev=$(state_get SEBOOL_container_manage_cgroup)
  if [[ -n $prev ]]; then
    log_info "Ripristino il boolean SELinux container_manage_cgroup -> $prev"
    run_sudo setsebool -P container_manage_cgroup "$prev"
    state_del SEBOOL_container_manage_cgroup
  fi
  for p in $(state_get FW_PORTS); do
    log_info "Chiudo la porta firewalld $p"
    run_sudo firewall-cmd --permanent --remove-port="$p"
    state_remove_word FW_PORTS "$p"
  done
  [[ -z $(state_get FW_PORTS) ]] || true
  command -v firewall-cmd >/dev/null 2>&1 && ! (( DRY_RUN )) && run_try sudo firewall-cmd --reload
  return 0
}

verify_uninstall() {
  log_step "Verifica ripristino"
  local bad=0 u
  for u in podman.socket podman.service docker.service docker.socket; do
    if systemctl --user is-active --quiet "$u" 2>/dev/null; then
      log_error "Unit ancora attiva: $u"; bad=1
    fi
  done
  if [[ -f $RC_FILE ]] && grep -qxF "$MARK_BEGIN" "$RC_FILE" && [[ -z $(state_get ENGINES) ]]; then
    log_error "Blocco di ambiente ancora presente in $RC_FILE"; bad=1
  fi
  if (( PURGE )); then
    has_engine podman && [[ -d $HOME/.local/share/containers ]] && { log_error "Resta ~/.local/share/containers"; bad=1; }
    has_engine docker && [[ -d $HOME/.local/share/docker ]] && { log_error "Resta ~/.local/share/docker"; bad=1; }
  fi
  (( bad == 0 )) || FAILURES=$((FAILURES + 1))
}

do_uninstall() {
  local remaining="" e
  if (( PURGE )); then
    log_warn "--purge: verranno ELIMINATI container, immagini e volumi dell'utente $USER_NAME."
    confirm "Confermi la rimozione definitiva dei dati?" || die "Operazione annullata."
  fi

  ensure_user_session soft || true

  has_engine docker && uninstall_docker
  has_engine podman && uninstall_podman

  # Engine che restano installati dopo questa operazione.
  for e in $(state_get ENGINES); do has_engine "$e" || remaining+="${remaining:+ }$e"; done
  if (( DRY_RUN )); then
    :
  else
    for e in podman docker; do has_engine "$e" && state_remove_word ENGINES "$e"; done
  fi

  log_step "Ripristino ambiente utente"
  if [[ " $remaining " == *" docker "* ]]; then apply_env_block 1
  elif [[ -n $remaining ]]; then apply_env_block 0
  else remove_env_block; fi

  log_step "Ripristino configurazione di sistema"
  has_engine docker && sysfiles_remove_owner docker
  if [[ -z $remaining ]]; then
    sysfiles_remove_owner common
    restore_selinux_firewall
  fi
  if (( REMOVE_PACKAGES )); then
    has_engine docker && pkgs_remove_owner docker
    has_engine podman && pkgs_remove_owner podman
    [[ -z $remaining ]] && pkgs_remove_owner common
  else
    log_info "Pacchetti lasciati installati (usa --remove-packages per rimuovere quelli installati dallo script)."
  fi
  if has_engine docker && [[ " $(state_get ENGINES) " != *" docker "* ]]; then
    (( REMOVE_PACKAGES )) || log_info "Il repository Docker resta configurato finche' non rimuovi i pacchetti."
  fi
  # Il repository Docker va tolto quando non serve piu': lo aggiunge anche il solo Podman (per il plugin
  # compose), quindi non basta controllare che si stia disinstallando Docker.
  if (( REMOVE_PACKAGES )) && [[ " $remaining " != *" docker "* ]] \
     && { has_engine docker || [[ -n $(state_get FILES_docker-repo) ]]; }; then
    sysfiles_remove_owner docker-repo
    pkg_refresh
    run_try sudo systemctl daemon-reload
  fi

  if [[ -z $remaining ]]; then
    restore_linger
    if (( PURGE )); then restore_subids
    else log_info "Range subuid/subgid conservati (servono per i file dei dati rimasti; --purge li rimuove)."; fi
    # Il file di stato si elimina solo quando e' davvero vuoto: PKGS_*/FILES_* di un engine
    # (es. pacchetti non rimossi senza --remove-packages) servono a un'esecuzione successiva.
    if (( ! DRY_RUN )) && [[ -f $STATE_FILE ]] && ! grep -q . "$STATE_FILE"; then rm -f "$STATE_FILE"; fi
  fi

  prune_residual_dirs

  (( DRY_RUN )) || verify_uninstall
  log_step "Riepilogo"
  if (( FAILURES )); then
    log_error "Disinstallazione terminata con anomalie: controlla i messaggi sopra."
    return 1
  fi
  if (( DRY_RUN )); then
    log_success "Dry-run completato: nessuna modifica applicata."
  else
    log_success "Ripristino completato: servizi fermati, ambiente utente ripulito."
  fi
}

# =============================================================================
# CLI
# =============================================================================
usage() {
  cat <<EOF
$SCRIPT_NAME $SCRIPT_VERSION - setup/ripristino Podman e Docker rootless
(Ubuntu >= 24.04, Debian >= 13, AlmaLinux/RHEL 9-10)

Uso: $SCRIPT_NAME [opzioni]

  --mode install|uninstall   operazione (default: install)
  --install | --uninstall    scorciatoie per --mode
  --engine podman|docker|both  engine da gestire (default: podman su RHEL/Alma,
                             both su Debian/Ubuntu)
  --dry-run                  mostra i comandi senza eseguirli
  --purge                    (uninstall) elimina anche immagini/volumi/container
                             e i range subuid/subgid aggiunti dallo script
  --remove-packages          (uninstall) rimuove i pacchetti installati dallo script
  -y, --yes                  non chiedere conferme
  --rc-file FILE             file in cui scrivere le variabili (default: ~/.bashrc)
  --keep-system-docker       non disabilitare il daemon Docker rootful di sistema
  --no-selinux               (RHEL) non toccare i boolean SELinux
  --open-port PORTA/proto    (RHEL, firewalld) apre una porta, ripetibile
  --low-ports                consente agli utenti non root le porte < 1024 (sysctl)
  --force-distro             tenta anche su distro/versioni non supportate
  --no-color                 disattiva i colori
  -h, --help                 questo aiuto

Esempi:
  $SCRIPT_NAME --dry-run
  $SCRIPT_NAME --engine podman
  $SCRIPT_NAME --uninstall --engine docker --purge --yes
EOF
}

parse_args() {
  while (( $# )); do
    case $1 in
      --mode)
        [[ $# -ge 2 ]] || die "--mode richiede un valore."
        MODE=$2; shift ;;
      --mode=*) MODE=${1#*=} ;;
      --install) MODE=install ;;
      --uninstall) MODE=uninstall ;;
      --engine)
        [[ $# -ge 2 ]] || die "--engine richiede un valore."
        ENGINE=$2; shift ;;
      --engine=*) ENGINE=${1#*=} ;;
      --dry-run) DRY_RUN=1 ;;
      --purge) PURGE=1 ;;
      --remove-packages) REMOVE_PACKAGES=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      --rc-file)
        [[ $# -ge 2 ]] || die "--rc-file richiede un valore."
        RC_FILE=$2; shift ;;
      --keep-system-docker) KEEP_SYSTEM_DOCKER=1 ;;
      --no-selinux) NO_SELINUX=1 ;;
      --open-port)
        [[ $# -ge 2 ]] || die "--open-port richiede un valore (es. 8080/tcp)."
        [[ $2 =~ ^[0-9]+(-[0-9]+)?/(tcp|udp)$ ]] || die "Formato porta non valido: $2 (atteso es. 8080/tcp)."
        FW_PORTS+=("$2"); shift ;;
      --low-ports) LOW_PORTS=1 ;;
      --force-distro) FORCE_DISTRO=1 ;;
      --no-color) USE_COLOR=0 ;;
      -h|--help) usage; exit 0 ;;
      *) usage >&2; die "Opzione sconosciuta: $1" ;;
    esac
    shift
  done
  case $MODE in install|uninstall) ;; *) die "--mode deve essere install o uninstall (ricevuto: '$MODE')." ;; esac
  case $ENGINE in ""|podman|docker|both) ;; *) die "--engine deve essere podman, docker o both (ricevuto: '$ENGINE')." ;; esac
  if [[ $MODE == install ]] && (( PURGE || REMOVE_PACKAGES )); then
    die "--purge e --remove-packages hanno senso solo con --mode uninstall."
  fi
  return 0
}

main() {
  parse_args "$@"
  setup_colors
  (( DRY_RUN )) && log_warn "Modalita' DRY-RUN: nessuna modifica verra' applicata."
  preflight
  detect_os
  resolve_default_engine
  if [[ $MODE == install ]]; then do_install; else do_uninstall; fi
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  main "$@"
fi
