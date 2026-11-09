#!/usr/bin/env python3
"""SMITE 2 Ping Overlay: F8 показывает/прячет пинг до игрового сервера.
Отдельная программа, в игру ничего не встраивает. Плашку можно двигать мышкой."""
import os, sys, signal, subprocess, re, json, threading
import psutil

RUNTIME = os.environ.get("XDG_RUNTIME_DIR", "/tmp")
PIDFILE = os.path.join(RUNTIME, "smite2_ping.pid")
CONFIG = os.path.expanduser("~/.config/smite2_ping.json")
GAME_LOG = ("/mnt/games/SteamLibrary/steamapps/compatdata/2437170/pfx/drive_c/users/"
            "steamuser/AppData/Local/SMITE2Alpha/Saved/Logs/Hemingway.log")
BROWSE_RE = re.compile(r"LogNet: Browse: (\S+)")
IP_RE = re.compile(r"^(\d{1,3}(?:\.\d{1,3}){3})(?::\d+)?")


def toggle_existing():
    """Если плашка уже открыта, закрываем её и выходим."""
    try:
        pid = int(open(PIDFILE).read().strip())
        p = psutil.Process(pid)
        if "smite2_ping" in " ".join(p.cmdline()):
            p.terminate()
            return True
    except (FileNotFoundError, ValueError, psutil.Error):
        pass
    return False


def game_running():
    for p in psutil.process_iter(["cmdline"]):
        if "Hemingway" in " ".join(p.info["cmdline"] or []):
            return True
    return False


_log = {"ino": None, "pos": 0, "last": None, "rest": ""}


def find_server():
    """Берём адрес сервера матча из последнего Browse в логе игры."""
    if not game_running():
        return None, "игра не запущена"
    # читаем лог по кусочкам с места, где остановились в прошлый раз, и помним последний Browse
    try:
        st = os.stat(GAME_LOG)
        if st.st_ino != _log["ino"] or st.st_size < _log["pos"]:
            _log.update(ino=st.st_ino, pos=0, last=None, rest="")
        with open(GAME_LOG, "rb") as f:
            f.seek(_log["pos"])
            chunk = f.read()
            _log["pos"] = f.tell()
    except OSError:
        return None, "нет лога игры"
    text = _log["rest"] + chunk.decode("utf-8", "ignore")
    text, _, _log["rest"] = text.rpartition("\n")
    for m in BROWSE_RE.finditer(text):
        _log["last"] = m.group(1)
    last = _log["last"]
    if not last:
        return None, "нет матча"
    ip = IP_RE.match(last)
    if ip:
        return ip.group(1), None
    if "Standalone" in last:
        return None, "оффлайн-режим"
    return None, "нет матча"


def physical_iface():
    """Сетевая карта с обычным маршрутом в интернет (не VPN)."""
    out = subprocess.run(["ip", "route", "show", "default"], capture_output=True, text=True).stdout
    for line in out.splitlines():
        m = re.search(r"via \S+ dev (\S+)", line)
        if m:
            return m.group(1)
    return None


def vpn_active():
    out = subprocess.run(["ip", "route", "show", "default"], capture_output=True, text=True).stdout
    first = out.splitlines()[0] if out else ""
    return "via" not in first


_hop_cache = {}


def target_for(ip, iface):
    """Azure не отвечает на ping, поэтому ищем последний отвечающий узел перед сервером."""
    if ip in _hop_cache:
        return _hop_cache[ip]
    hop = [ip]
    try:
        out = subprocess.run(["traceroute", "-n", "-q1", "-w1", "-m30", "-i", iface, ip],
                             capture_output=True, text=True, timeout=40).stdout
        hops = re.findall(r"^\s*\d+\s+(\d+\.\d+\.\d+\.\d+)", out, re.M)
        if hops:
            hop = list(reversed(hops[-4:]))  # несколько последних узлов: если один молчит, берём соседний
    except Exception:
        pass
    _hop_cache[ip] = hop
    return hop


def ping(ip, iface=None):
    cmd = ["ping", "-c", "1", "-W", "1"] + (["-I", iface] if iface else []) + [ip]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=2).stdout
        m = re.search(r"time=([\d.]+)", out)
        return float(m.group(1)) if m else None
    except Exception:
        return None


def load_pos():
    try:
        d = json.load(open(CONFIG)); return int(d["x"]), int(d["y"])
    except Exception:
        return 20, 20


def save_pos(x, y):
    os.makedirs(os.path.dirname(CONFIG), exist_ok=True)
    json.dump({"x": x, "y": y}, open(CONFIG, "w"))


def send_move():
    try:
        pid = int(open(PIDFILE).read().strip())
        os.kill(pid, signal.SIGUSR1)
    except Exception:
        pass


def main():
    if "--move" in sys.argv:
        return send_move()
    if toggle_existing():
        return
    os.environ.setdefault("QT_QPA_PLATFORM", "xcb")  # чтобы окно ставилось куда нужно поверх игры
    from PyQt5.QtCore import Qt, QTimer, QRectF
    from PyQt5.QtGui import QPainterPath, QRegion
    from PyQt5.QtWidgets import QApplication, QLabel
    from PyQt5.QtCore import QObject, pyqtSlot
    from PyQt5.QtDBus import QDBusConnection

    open(PIDFILE, "w").write(str(os.getpid()))
    app = QApplication(sys.argv)
    signal.signal(signal.SIGTERM, lambda *a: app.quit())
    keepalive = QTimer(); keepalive.start(200); keepalive.timeout.connect(lambda: None)

    class Badge(QLabel):
        """Плашка с пингом, которую можно таскать мышкой."""
        def __init__(self):
            super().__init__("Ping: …")
            self._drag = None
            self.setCursor(Qt.OpenHandCursor)

        def mousePressEvent(self, e):
            if e.button() == Qt.LeftButton:
                self._drag = e.globalPos() - self.pos()
                self.setCursor(Qt.ClosedHandCursor)

        def mouseMoveEvent(self, e):
            if self._drag is not None:
                self.move(e.globalPos() - self._drag)

        def mouseReleaseEvent(self, e):
            if self._drag is not None:
                self._drag = None
                self.setCursor(Qt.OpenHandCursor)
                save_pos(self.x(), self.y())

    lbl = Badge()
    lbl.setWindowFlags(Qt.FramelessWindowHint | Qt.WindowStaysOnTopHint | Qt.Tool
                       | Qt.X11BypassWindowManagerHint)
    lbl.setAttribute(Qt.WA_ShowWithoutActivating)
    lbl.setAutoFillBackground(True)
    lbl.setWindowOpacity(0.85)
    style = "QLabel{{color:{};background:#000;font:bold 16px monospace;padding:6px 12px;}}"

    def set_text(text, color="white"):
        lbl.setText(text)
        lbl.setStyleSheet(style.format(color))
        lbl.adjustSize()
        path = QPainterPath(); path.addRoundedRect(QRectF(lbl.rect()), 8, 8)
        lbl.setMask(QRegion(path.toFillPolygon().toPolygon()))

    def update():
        ip, err = find_server()
        if not ip:
            return set_text(f"Ping: — ({err})")
        iface = physical_iface()
        if ip not in _hop_cache:
            set_text("Ping: ищу маршрут…")
            threading.Thread(target=target_for, args=(ip, iface), daemon=True).start()
            return
        ms = None
        for hop in _hop_cache[ip]:
            ms = ping(hop, iface)
            if ms is not None:
                hops = _hop_cache[ip]  # отвечающий узел ставим первым, чтобы не ждать молчащие
                hops.remove(hop); hops.insert(0, hop)
                break
        if ms is None:
            state["miss"] = state.get("miss", 0) + 1
            if state["miss"] < 5 and state.get("last"):
                return  # единичная потеря: оставляем прошлое значение
            return set_text("Ping: нет ответа")
        state["miss"] = 0
        ms = round(ms)
        state["last"] = ms
        color = "#4cff4c" if ms < 60 else "#ffd24c" if ms < 120 else "#ff5c5c"
        set_text(f"Ping: {ms} ms", color)

    def cycle_pos():
        scr = app.primaryScreen().geometry()
        w, h, m = lbl.width(), lbl.height(), 20
        spots = [(m, m), ((scr.width() - w) // 2, m), (scr.width() - w - m, m),
                 (scr.width() - w - m, scr.height() - h - m), (m, scr.height() - h - m)]
        cur = (lbl.x(), lbl.y())
        i = min(range(len(spots)), key=lambda k: abs(spots[k][0]-cur[0]) + abs(spots[k][1]-cur[1]))
        nx, ny = spots[(i + 1) % len(spots)]
        lbl.move(nx, ny); save_pos(nx, ny)

    moves = []
    signal.signal(signal.SIGUSR1, lambda *a: moves.append(1))
    mv = QTimer(); mv.timeout.connect(lambda: (moves.clear(), cycle_pos()) if moves else None); mv.start(100)

    state = {"game": True}

    def is_game_pid(pid):
        try:
            return "Hemingway" in " ".join(psutil.Process(int(pid)).cmdline())
        except Exception:
            return False

    class Focus(QObject):
        """KWin сообщает сюда, какое окно активно; показываем плашку только над игрой."""
        @pyqtSlot(int, bool)
        def activeWindow(self, pid, minimized):
            state["game"] = bool(pid) and not minimized and is_game_pid(pid)
            lbl.setVisible(state["game"])

    focus = Focus()
    bus = QDBusConnection.sessionBus()
    bus.registerService("org.smite2ping")
    bus.registerObject("/", "org.smite2ping", focus, QDBusConnection.ExportAllSlots)

    def load_kwin_script():
        script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "kwin_focus.js")
        q = lambda *a: subprocess.run(["qdbus", "org.kde.KWin", *a], capture_output=True, text=True).stdout.strip()
        q("/Scripting", "org.kde.kwin.Scripting.unloadScript", "smite2ping_focus")
        sid = q("/Scripting", "org.kde.kwin.Scripting.loadScript", script, "smite2ping_focus")
        if sid.lstrip("-").isdigit() and int(sid) >= 0:
            q(f"/Scripting/Script{sid}", "org.kde.kwin.Script.run")

    def unload_kwin_script():
        subprocess.run(["qdbus", "org.kde.KWin", "/Scripting", "org.kde.kwin.Scripting.unloadScript",
                        "smite2ping_focus"], capture_output=True)

    set_text("Ping: …")
    lbl.move(*load_pos())
    lbl.show()
    load_kwin_script()
    t = QTimer(); t.timeout.connect(update); t.start(1000); update()
    try:
        app.exec_()
    finally:
        unload_kwin_script()
        try: os.remove(PIDFILE)
        except OSError: pass


if __name__ == "__main__":
    main()
