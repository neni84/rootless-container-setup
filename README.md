# rootless-container-setup

Script Bash unico (`setup.sh`) per installare, configurare e rimuovere **Podman** e
**Docker** in modalita' **rootless**.

Distribuzioni supportate: Ubuntu 24.04+, Debian 13 (Trixie)+, AlmaLinux / RHEL 9 e 10.

Va eseguito da **utente normale** (non root): `sudo` viene usato solo per i singoli passi
amministrativi (pacchetti, `/etc/subuid`, sysctl, SELinux, firewalld, ...).

## Uso

```bash
chmod +x setup.sh
./setup.sh [opzioni]
```

| Opzione | Descrizione |
|---|---|
| `--mode install\|uninstall` | Operazione (default `install`). Scorciatoie: `--install`, `--uninstall` |
| `--engine podman\|docker\|both` | Engine da gestire. Default: `podman` su RHEL/Alma, `both` su Debian/Ubuntu |
| `--dry-run` | Mostra i comandi senza eseguirli |
| `--purge` | (uninstall) elimina anche container, immagini, volumi e i range subuid/subgid aggiunti dallo script |
| `--remove-packages` | (uninstall) rimuove i pacchetti installati dallo script |
| `-y`, `--yes` | Nessuna conferma interattiva |
| `--rc-file FILE` | File per le variabili d'ambiente (default `~/.bashrc`) |
| `--keep-system-docker` | Non disabilita il daemon Docker rootful di sistema |
| `--no-selinux` | (RHEL) non modifica i boolean SELinux |
| `--open-port 8080/tcp` | (RHEL) apre una porta in firewalld, ripetibile |
| `--low-ports` | Consente agli utenti non root di usare le porte < 1024 |
| `--no-shell` | A fine installazione non propone la nuova shell con l'ambiente gia' caricato (da terminale la propone; con `--yes` la apre senza chiedere, `exit` per tornare) |
| `--force-distro` | Tenta su distro/versioni non ufficialmente supportate |
| `--no-color` | Disattiva i colori |

## Esempi

```bash
# Anteprima di tutto cio' che verrebbe fatto
./setup.sh --dry-run

# Solo Podman
./setup.sh --engine podman

# Podman + Docker, con porta 8080 aperta su firewalld (RHEL/Alma)
./setup.sh --open-port 8080/tcp

# Disinstalla Docker rootless conservando immagini e volumi
./setup.sh --uninstall --engine docker

# Ripristino completo: elimina dati, pacchetti, subuid/subgid aggiunti dallo script
./setup.sh --uninstall --purge --remove-packages --yes
```

## Cosa fa in installazione

1. Pacchetti di base (`uidmap`/`shadow-utils`, `dbus-user-session`, ...) e, per Docker,
   configurazione del repository ufficiale (`download.docker.com`: `debian`/`ubuntu`
   per APT, `centos` o `rhel` per DNF).
2. Podman: `podman`, `slirp4netns`, `fuse-overlayfs`, `passt` (se disponibili),
   `container-selinux` su RHEL. Docker: `docker-ce`, `docker-ce-cli`, `containerd.io`,
   buildx/compose, `docker-ce-rootless-extras`. Il daemon Docker rootful di sistema viene
   disabilitato (salvo `--keep-system-docker` o se era gia' in uso).
   Con il **solo Podman** installa anche un provider per `podman compose` (che di serie non ne ha uno):
   il plugin Docker Compose (`docker-compose-v2` da Ubuntu se disponibile, altrimenti
   `docker-compose-plugin` dal repository Docker, che viene configurato e rimosso con
   `--uninstall --remove-packages`). Non si usa `podman-compose` (EPEL): concatena le liste dei file
   `-f` e rifiuta gli overlay che ridefiniscono un elenco come `healthcheck.test`.
   Con `--engine docker|both` il plugin arriva gia' con Docker.
3. Range `/etc/subuid` e `/etc/subgid` (65536 id, a partire da 100000 o dal primo range libero).
4. `loginctl enable-linger $USER`.
5. Servizi utente: `systemctl --user enable --now podman.socket`;
   `dockerd-rootless-setuptool.sh install` + `docker.service` utente.
6. Requisiti Docker rootless: profilo AppArmor per `rootlesskit` su Ubuntu 24.04+
   (se `apparmor_restrict_unprivileged_userns=1`), delega dei cgroup v2, modulo `nf_tables` su Debian/Ubuntu (caricato e reso persistente
   in `/etc/modules-load.d/rootless-docker.conf`), moduli `ip_tables` su RHEL,
   `user.max_user_namespaces` se a 0.
7. RHEL/Alma: `container-selinux`, boolean `container_manage_cgroup`; firewalld solo se
   richiesto con `--open-port` (la rete rootless e' in user-space e di norma non serve nulla).
8. Blocco gestito in `~/.bashrc` (delimitato da marker, idempotente):

   ```bash
   export XDG_RUNTIME_DIR=/run/user/$(id -u)
   export DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock   # solo se Docker e' tra gli engine
   [[ ":$PATH:" == *":$HOME/bin:"* ]] || export PATH=$HOME/bin:$PATH
   ```

9. Test finale senza sudo: `podman info` e/o `docker info` e, per Podman, `podman compose version`.

## Cosa fa in disinstallazione

- Ferma e disabilita `podman.socket`/`docker.service` utente; esegue
  `dockerd-rootless-setuptool.sh uninstall`.
- Salva un backup (`~/rootless-container-setup-config-backup-<data>.tar.gz`) e rimuove
  `~/.config/containers` e `~/.config/docker`.
- Con `--purge`: elimina `~/.local/share/containers` (`podman system reset`) e
  `~/.local/share/docker`, e i range subuid/subgid aggiunti dallo script. Senza `--purge`
  immagini/volumi e subuid/subgid restano.
- Rimuove dal `.bashrc` solo il blocco gestito (se resta un solo engine lo riscrive).
- `loginctl disable-linger` solo se era stato attivato dallo script e non ci sono altri
  servizi utente attivi.
- Con `--remove-packages` rimuove solo i pacchetti che lo script aveva installato.
- Verifica finale del ripristino.

Lo stato di cio' che lo script ha modificato e' in `~/.local/state/rootless-container-setup/state`:
la disinstallazione ripristina solo quelle modifiche.

## Note e limiti

- Su RHEL/Alma `containerd.io` (repo Docker) e i pacchetti runtime di Podman possono
  confliggere (es. `runc`): se `--engine both` fallisce, usa un solo engine per host.
- Su RHEL/Alma 10 Docker rootless richiede i moduli netfilter di `kernel-modules-extra`, che dnf
  installa per il kernel piu' recente: se il kernel in esecuzione e' piu' vecchio, lo script
  prepara tutto, salta l'avvio di Docker e chiede di riavviare e rilanciare (e' idempotente).
  Per questo su RHEL/Alma il default e' solo Podman; Docker va richiesto con `--engine docker|both`.
- La disinstallazione toglie il repo Docker solo con `--remove-packages`.
- Pacchetti distro in conflitto (`docker.io`, `podman-docker`) vanno rimossi a mano.
- La delega cgroup e il profilo AppArmor hanno effetto completo dopo un nuovo login.
- **Riavvio della macchina (Podman):** con linger attivo il manager utente parte al boot, e `podman-restart.service`
  (abilitata dallo script) riavvia i container con restart policy `always`/`unless-stopped`. Con Podman 4.x (Ubuntu 24.04)
  l'unita' filtra solo `restart-policy=always`: un container `unless-stopped` potrebbe non ripartire. Con Docker rootless
  ci pensa il daemon utente (`docker.service`).
- Per testare altre distro in `--dry-run` si puo' usare `OS_RELEASE_FILE=/percorso/os-release`.

## Verifica dello script

```bash
bash -n setup.sh && shellcheck -x setup.sh
```
