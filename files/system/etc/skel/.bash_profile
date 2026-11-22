if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash --shims)"
fi

if [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi

# Avvio automatico di Niri solo dalla tty1 (nessun display manager)
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "${XDG_VTNR:-0}" = 1 ] && command -v niri-session >/dev/null 2>&1; then
    exec niri-session
fi
