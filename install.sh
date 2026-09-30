#!/usr/bin/env bash
#
# fedora-dotfile installer — reproduce this Sway desktop on Fedora.
#
# Usage:
#   git clone https://github.com/rajan9884/fedora-dotfile.git ~/fedora-dotfile
#   cd ~/fedora-dotfile
#   ./install.sh [options]
#
# Options:
#   --packages-only   install dnf packages and enable services, skip dotfile links
#   --links-only      only (re)create ~/.config ~/ ~/.local/bin symlinks
#   --no-fonts        skip the Nerd Font download
#   --no-wallpapers   skip the wallpaper collection download
#   --no-external     skip COPR repos and out-of-tree binaries (starship, …)
#   -h, --help        show this help and exit
#
# The script is idempotent: re-running it repairs missing links/packages.
# Files that would be replaced are backed up to
# ~/.config-backup-fedora-<timestamp>/ first, never deleted.

set -euo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PACKAGES_FILE="$REPO_DIR/packages.txt"
BACKUP_DIR="$HOME/.config-backup-fedora-$(date +%Y%m%d-%H%M%S)"

DO_PACKAGES=1
DO_LINKS=1
DO_FONTS=1
DO_WALLPAPERS=1
DO_EXTERNAL=1

for arg in "$@"; do
    case "$arg" in
        --packages-only) DO_LINKS=0 ;;
        --links-only) DO_PACKAGES=0; DO_FONTS=0; DO_WALLPAPERS=0; DO_EXTERNAL=0 ;;
        --no-fonts) DO_FONTS=0 ;;
        --no-wallpapers) DO_WALLPAPERS=0 ;;
        --no-external) DO_EXTERNAL=0 ;;
        -h|--help)
            sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Unknown option: $arg (see --help)" >&2; exit 1 ;;
    esac
done

log()  { printf '[install] %s\n' "$*"; }
warn() { printf '[install] WARNING: %s\n' "$*" >&2; }

# ---------------------------------------------------------------- guards ---
if [ -f /etc/os-release ]; then
    # shellcheck disable=SC1091
    . /etc/os-release
fi
if [ "${ID:-}" != "fedora" ]; then
    echo "This installer targets Fedora (not detected via /etc/os-release)." >&2
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    echo "Run as your normal user (with sudo rights), not as root." >&2
    exit 1
fi

command -v sudo >/dev/null 2>&1 || { echo "sudo not found; install it first." >&2; exit 1; }

if [ "$DO_PACKAGES" -eq 1 ]; then
    PRIV="sudo"
    log "Privilege escalation via sudo (credentials requested once, then cached)"
    if ! "$PRIV" -n true 2>/dev/null; then
        if [ -n "${SUDO_ASKPASS:-}" ]; then
            "$PRIV" -A -v
        else
            "$PRIV" -v
        fi
    fi
fi

# --------------------------------------------------------- external repos ---
# Third-party packages this desktop needs that Fedora does not package.
# Kept in one place so `--no-external` can opt out cleanly.
enable_copr() { # enable_copr <owner/project> <human name>
    local proj="$1" name="$2"
    local fedver repo_file
    fedver="$(rpm -E %fedora)"
    repo_file="/etc/yum.repos.d/_copr:copr.fedorainfracloud.org:${proj//\//_}.repo"

    if "$PRIV" test -f "$repo_file"; then
        log "  $name: COPR repo already enabled"
        return 0
    fi

    log "  $name: enabling COPR repo ${proj}"
    if ! "$PRIV" curl -fsSL -o "$repo_file" \
            "https://copr.fedorainfracloud.org/coprs/${proj}/repo/fedora-${fedver}/${proj//\//_}-fedora-${fedver}.repo"; then
        "$PRIV" rm -f "$repo_file"
        warn "$name: could not fetch COPR repo definition for ${proj}"
        return 1
    fi
}

if [ "$DO_EXTERNAL" -eq 1 ]; then
    log "Enabling third-party repositories"
    # swayfx: the compositor this config targets (blur, shadows, rounded corners).
    #         Official COPR: https://github.com/WillPower3309/swayfx
    enable_copr mochaa/swayfx swayfx || warn "swayfx unavailable; compositor will not be installed"
    # swayosd: volume/brightness OSD (swayosd-server + swayosd-client).
    #          Upstream author's COPR: https://github.com/ErikReider/SwayOSD
    enable_copr erikreider/swayosd swayosd || warn "swayosd unavailable; volume/brightness OSD will not work"
    # hyprpicker: Wayland colour picker. Orphaned from Fedora after F41;
    #             F44 build lives in the nett00n/hyprland COPR.
    enable_copr nett00n/hyprland hyprpicker || warn "hyprpicker COPR unavailable; colour picker will not work"
fi

# --------------------------------------------------------------- packages ---
if [ "$DO_PACKAGES" -eq 1 ]; then
    if [ ! -f "$PACKAGES_FILE" ]; then
        echo "Package list missing: $PACKAGES_FILE" >&2
        exit 1
    fi
    # One package per line; blank lines and # comments ignored. sed runs
    # line-by-line, so stripping in-line whitespace keeps the newlines
    # that mapfile needs to split the list (tr -d would glue them together).
    mapfile -t PKGS < <(sed -e 's/[[:space:]]//g' -e '/^#/d' -e '/^$/d' "$PACKAGES_FILE")
    if [ "${#PKGS[@]}" -eq 0 ]; then
        echo "No packages parsed from $PACKAGES_FILE" >&2
        exit 1
    fi
    log "Installing ${#PKGS[@]} dnf packages (this takes a while)"

    # swayfx Conflicts with the distribution's plain `sway` package, and
    # sway arrives as a dependency of the usual session helpers
    # (sway-config-fedora, sway-systemd, grimshot, sddm-wayland-sway).
    # `dnf swap` is the supported way to hand those over in one step;
    # a plain install would just fail the whole transaction.
    if "$PRIV" rpm -q sway >/dev/null 2>&1; then
        log "  plain sway is installed; swapping it for swayfx"
        "$PRIV" dnf swap -y sway swayfx \
            || warn "dnf swap sway swayfx failed; resolve the conflict manually"
    fi

    # The dotfiles drive profiles through `powerprofilesctl`, the CLI that
    # comes with power-profiles-daemon. Fedora prefers tuned-ppd instead
    # (a D-Bus shim, no CLI, mutually exclusive). Swap it out and let the
    # repo's `power-profiles` watch daemon handle AC/battery memory itself.
    if "$PRIV" rpm -q tuned-ppd >/dev/null 2>&1; then
        log "  tuned-ppd is installed; swapping it for power-profiles-daemon"
        "$PRIV" dnf swap -y tuned-ppd power-profiles-daemon \
            || warn "dnf swap tuned-ppd power-profiles-daemon failed; resolve manually"
    fi

    "$PRIV" dnf install -y "${PKGS[@]}"

    log "Enabling services"
    for svc in NetworkManager bluetooth chronyd crond greetd iwd; do
        if "$PRIV" systemctl list-unit-files "$svc.service" --no-legend 2>/dev/null | grep -q .; then
            if "$PRIV" systemctl is-enabled --quiet "$svc" 2>/dev/null; then
                :
            else
                "$PRIV" systemctl enable "$svc" >/dev/null && log "  enabled $svc"
            fi
        fi
    done

    # power-profiles-daemon and polkit are D-Bus activated on Fedora; enabling
    # the unit is still useful so they come up early at login.
    for svc in power-profiles-daemon polkit; do
        "$PRIV" systemctl enable "$svc" >/dev/null 2>&1 && log "  enabled $svc" || true
    done

    log "Configuring greetd + wheel sudo"
    if command -v tuigreet >/dev/null 2>&1; then
        # Fedora's greetd package ships no greeter user; the daemon refuses
        # to start without one ("configured default session user not found").
        if ! id _greeter >/dev/null 2>&1; then
            "$PRIV" useradd -r -M -d /var/lib/greetd -s /usr/sbin/nologin \
                -c "greetd greeter" _greeter
            log "  created _greeter system user"
        fi
        for grp in video input; do
            if ! id -nG _greeter | grep -qw "$grp"; then
                "$PRIV" usermod -aG "$grp" _greeter
            fi
        done
        "$PRIV" mkdir -p /etc/greetd
        "$PRIV" tee /etc/greetd/config.toml >/dev/null <<'EOF'
[terminal]
vt = 7
[default_session]
command = "tuigreet --time --remember --remember-user-session --sessions /usr/share/wayland-sessions --theme border=blue;text=white;prompt=green;time=gray;action=cyan;button=yellow;container=black;input=red"
user = "_greeter"
EOF
        # SDDM and greetd both grab a VT; leaving SDDM enabled means the
        # machine boots to SDDM and the greetd config is ignored.
        if "$PRIV" systemctl is-enabled --quiet sddm 2>/dev/null; then
            log "  disabling sddm (conflicts with greetd)"
            "$PRIV" systemctl disable --now sddm >/dev/null 2>&1 || true
        fi
        "$PRIV" systemctl enable greetd >/dev/null
    else
        warn "tuigreet not installed; skipping /etc/greetd/config.toml"
    fi

    if [ ! -f /etc/sudoers.d/wheel ]; then
        echo '%wheel ALL=(ALL:ALL) ALL' | "$PRIV" tee /etc/sudoers.d/wheel >/dev/null
        "$PRIV" chmod 440 /etc/sudoers.d/wheel
    fi
    "$PRIV" visudo -c >/dev/null

    # Groups needed for a Wayland session: video + input for DRM/seat access,
    # render for VA-API, wheel for sudo.
    for grp in wheel video input render; do
        if getent group "$grp" >/dev/null 2>&1 && ! id -nG "$USER" | grep -qw "$grp"; then
            "$PRIV" usermod -aG "$grp" "$USER"
            log "  added $USER to $grp (takes effect on next login)"
        fi
    done

    # chsh refuses shells that are not in /etc/shells; add zsh so the
    # login-shell switch below succeeds.
    if command -v zsh >/dev/null 2>&1; then
        ZSH_PATH="$(command -v zsh)"
        if ! grep -qxF "$ZSH_PATH" /etc/shells 2>/dev/null; then
            echo "$ZSH_PATH" | "$PRIV" tee -a /etc/shells >/dev/null
            log "  added $ZSH_PATH to /etc/shells"
        fi
    fi

    # Firewall: Fedora ships firewalld and it conflicts with ufw, so only
    # touch whichever is actually the active backend.
    if systemctl is-active --quiet firewalld; then
        log "firewalld already active; leaving it in place"
    elif command -v ufw >/dev/null 2>&1; then
        "$PRIV" ufw --force enable && log "  enabled ufw"
    fi

    command -v xdg-user-dirs-update >/dev/null 2>&1 && xdg-user-dirs-update || true
fi

# --------------------------------------------------- out-of-tree binaries ---
# These are not packaged anywhere reachable, so install them from upstream
# releases / crates into ~/.local/bin. All are guarded: a failure warns
# instead of aborting the whole install.
if [ "$DO_EXTERNAL" -eq 1 ]; then
    BIN_DIR="$HOME/.local/bin"
    mkdir -p "$BIN_DIR"

    install_starship() {
        command -v starship >/dev/null 2>&1 && { log "starship already installed"; return 0; }
        log "Installing starship from upstream releases"
        local tmp ver url
        tmp="$(mktemp -d)"
        # Write the API response to a file first: piping curl straight into
        # `grep -m1` closes the pipe early (curl exit 23) and trips set -e.
        if ! curl -fsSL -o "$tmp/api.json" \
                https://api.github.com/repos/starship/starship/releases/latest; then
            warn "could not query starship releases"; rm -rf "$tmp"; return 1
        fi
        ver="$(grep -m1 '"tag_name"' "$tmp/api.json" | cut -d'"' -f4)"
        if [ -z "$ver" ]; then
            warn "could not parse starship release tag"; rm -rf "$tmp"; return 1
        fi
        url="https://github.com/starship/starship/releases/download/${ver}/starship-x86_64-unknown-linux-gnu.tar.gz"
        if curl -fsSL -o "$tmp/s.tar.gz" "${url}.sha256" && curl -fsSL -o "$tmp/starship.tar.gz" "$url"; then
            local expected actual
            expected="$(cut -d' ' -f1 < "$tmp/s.tar.gz")"
            actual="$(sha256sum "$tmp/starship.tar.gz" | cut -d' ' -f1)"
            if [ "$expected" != "$actual" ]; then
                warn "starship checksum mismatch; refusing to install"
                rm -rf "$tmp"; return 1
            fi
            tar -xzf "$tmp/starship.tar.gz" -C "$tmp"
            # The tarball holds a single top-level `starship` binary
            # (no enclosing directory).
            if install -m 755 "$tmp/starship" "$BIN_DIR/starship"; then
                log "  starship $ver installed to $BIN_DIR/starship"
            else
                warn "starship install step failed"
                rm -rf "$tmp"; return 1
            fi
        else
            warn "starship download failed; shell will use the default prompt"
        fi
        rm -rf "$tmp"
    }

    install_cargo_bin() { # install_cargo_bin <crate> <binary>
        local crate="$1" binname="$2"
        command -v "$binname" >/dev/null 2>&1 && { log "$binname already installed"; return 0; }
        command -v cargo >/dev/null 2>&1 || { warn "cargo missing; skipping $binname"; return 1; }
        log "Building $binname from crates.io (can take a few minutes)"
        if "$PRIV" cargo install --locked "$crate" >/dev/null 2>&1 \
           || cargo install --locked "$crate" >/dev/null 2>&1; then
            log "  $binname installed"
        else
            warn "$crate build failed; $binname will be unavailable"
        fi
    }

    install_starship || true
    # hyprpicker comes from the COPR enabled above (not on crates.io).
    if ! command -v hyprpicker >/dev/null 2>&1; then
        log "Installing hyprpicker from COPR"
        "$PRIV" dnf install -y hyprpicker \
            || warn "hyprpicker install failed; colour picker will be unavailable"
    else
        log "hyprpicker already installed"
    fi
    # yazi (terminal file manager) is intentionally not installed — unused.
    # The `y` shell helper is still defined but guarded, so shells start
    # clean with or without it.
fi

# ------------------------------------------------------------------ links ---
link() { # link <source-in-repo> <destination>
    local src="$1" dest="$2"
    # Already pointing at the right source: nothing to do.
    if [ -L "$dest" ] && [ "$(readlink "$dest")" = "$src" ]; then
        return 0
    fi
    # Never write through a parent directory that itself links into the repo
    # (e.g. ~/.config/zsh -> fedora-dotfile/zsh): the file is already deployed
    # via the directory link, and touching it would mutate the repo.
    local parent_real
    parent_real="$(realpath -m "$(dirname "$dest")")"
    case "$parent_real/" in
        "$REPO_DIR/"*)
            log "  already covered by directory link, skipping: $dest"
            return 0
            ;;
    esac
    if [ -e "$dest" ] || [ -L "$dest" ]; then
        mkdir -p "$BACKUP_DIR"
        mv "$dest" "$BACKUP_DIR/$(echo "$dest" | tr '/' '_' | sed 's/^_//')"
        log "  backed up $dest"
    fi
    mkdir -p "$(dirname "$dest")"
    ln -sfn "$src" "$dest"
}

if [ "$DO_LINKS" -eq 1 ]; then
    log "Linking ~/.config directories (backups go to $BACKUP_DIR)"
    for d in btop foot gtk-3.0 gtk-4.0 matugen nvim rofi sway swaync \
             swayosd waybar xdg-desktop-portal zsh; do
        [ -e "$REPO_DIR/$d" ] && link "$REPO_DIR/$d" "$HOME/.config/$d"
    done
    [ -f "$REPO_DIR/starship.toml" ] && link "$REPO_DIR/starship.toml" "$HOME/.config/starship.toml"
    [ -f "$REPO_DIR/mimeapps.list" ] && link "$REPO_DIR/mimeapps.list" "$HOME/.config/mimeapps.list"

    log "Linking shell startup files"
    link "$REPO_DIR/shell/bash_profile" "$HOME/.bash_profile"
    link "$REPO_DIR/shell/bashrc"       "$HOME/.bashrc"
    link "$REPO_DIR/shell/zprofile"     "$HOME/.zprofile"
    link "$REPO_DIR/shell/zshrc"        "$HOME/.zshrc"

    log "Linking helper scripts into ~/.local/bin"
    mkdir -p "$HOME/.local/bin"
    for script in "$REPO_DIR"/bin/*; do
        [ -f "$script" ] || continue
        chmod +x "$script"
        link "$script" "$HOME/.local/bin/$(basename "$script")"
    done

    log "Creating data directories"
    mkdir -p "$HOME/.local/share/wallpapers" "$HOME/.cache" "$HOME/.local/state"

    # Sway aborts if an `include`d file is missing. colors and wallpaper are
    # matugen-generated (gitignored), so a fresh clone has neither yet.
    # Empty files satisfy the include; the first wallpaper switch fills them.
    for gen in "$REPO_DIR/sway/colors" "$REPO_DIR/sway/wallpaper"; do
        if [ ! -f "$gen" ]; then
            : > "$gen"
            log "  created empty $(basename "$gen") (matugen fills it on first switch)"
        fi
    done

    if ! command -v zsh >/dev/null 2>&1; then
        warn "zsh not installed; chsh skipped"
    elif [ "$SHELL" != "$(command -v zsh)" ] && [ "${SKIP_CHSH:-0}" != "1" ]; then
        log "Setting zsh as login shell"
        chsh -s "$(command -v zsh)" || warn "chsh failed; run 'chsh -s \$(which zsh)' manually"
    fi
fi

# ------------------------------------------------------------------ fonts ---
if [ "$DO_FONTS" -eq 1 ]; then
    if fc-list 2>/dev/null | grep -qi "JetBrainsMono Nerd Font"; then
        log "JetBrainsMono Nerd Font already present"
    else
        log "Downloading JetBrainsMono Nerd Font + Symbols (best effort)"
        mkdir -p "$HOME/.local/share/fonts"
        tmp="$(mktemp -d)"
        if curl -fsSL -o "$tmp/JetBrainsMono.tar.xz" \
                "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/JetBrainsMono.tar.xz" \
           && curl -fsSL -o "$tmp/Symbols.tar.xz" \
                "https://github.com/ryanoasis/nerd-fonts/releases/latest/download/NerdFontsSymbolsOnly.tar.xz"; then
            tar -xf "$tmp/JetBrainsMono.tar.xz" -C "$HOME/.local/share/fonts"
            tar -xf "$tmp/Symbols.tar.xz" -C "$HOME/.local/share/fonts"
            fc-cache -f "$HOME/.local/share/fonts" >/dev/null
            log "  fonts installed"
        else
            warn "font download failed; copy .ttf files to ~/.local/share/fonts manually"
        fi
        rm -rf "$tmp"
    fi
fi

# ------------------------------------------------------------- wallpapers ---
if [ "$DO_WALLPAPERS" -eq 1 ]; then
    WALL_DIR="$HOME/.local/share/wallpapers"
    mkdir -p "$WALL_DIR"
    if [ "$(find "$WALL_DIR" -type f | head -1)" ]; then
        log "Wallpapers already present in $WALL_DIR ($(find "$WALL_DIR" -type f | wc -l) files), skipping download"
    else
        log "Fetching wallpaper collection (best effort)"
        tmp="$(mktemp -d)"
        if git clone --depth 1 https://github.com/rajan9884/wallpapers "$tmp/wallpapers" >/dev/null 2>&1; then
            # Flatten: copy every image out of the nested repo layout;
            # -n keeps any user-added file with the same name.
            find "$tmp/wallpapers" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \
                -o -iname "*.png" -o -iname "*.webp" \) \
                -exec cp -n {} "$WALL_DIR/" \;
            log "  $(find "$WALL_DIR" -type f | wc -l) wallpapers in $WALL_DIR"
        else
            warn "wallpaper clone failed; copy images to $WALL_DIR manually"
        fi
        rm -rf "$tmp"
    fi
fi

# ------------------------------------------------------------------- done ---
log "Done."
if [ ! -s "$HOME/.cache/current-wallpaper" ]; then
    # The swayfx build ships as /usr/bin/sway, so match the real process name.
    if pgrep -x sway >/dev/null 2>&1 && [ "$(find "$HOME/.local/share/wallpapers" -type f | head -1)" ]; then
        log "Seeding theme from a random wallpaper"
        "$HOME/.config/sway/scripts/random-wall.sh" >/dev/null 2>&1 \
            || warn "theme seeding failed; run ~/.config/sway/scripts/sway-wall.sh <image> manually"
    else
        warn "No wallpaper selected yet: log into Sway, then run"
        warn "  ~/.config/sway/scripts/sway-wall.sh ~/path/to/wallpaper.jpg"
        warn "to generate the matugen theme (waybar/rofi/foot/starship follow it)."
    fi
fi
cat <<'EOF'
[install] Not covered by this script (see README.md):
[install]   - Zen Browser      : install from upstream tarball / rpm
[install]   - gh auth login + per-repo git-work / git-personal identity
EOF
