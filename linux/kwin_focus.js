// Сообщает плашке SMITE 2 Ping, какое окно сейчас активно.
function report(w) {
    callDBus("org.smite2ping", "/", "org.smite2ping", "activeWindow",
             w ? w.pid : 0, w ? !!w.minimized : true);
}
workspace.windowActivated.connect(report);
report(workspace.activeWindow);
