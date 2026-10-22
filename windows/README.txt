VibeRouter for Windows

Double-click VibeRouter.exe. It stays on the taskbar and starts the local
proxy. Close the window, or choose Quit, to stop it.

Open console opens http://127.0.0.1:8318/management.html
API base is http://127.0.0.1:8318/v1

There is no macOS menu bar and no Thinking Proxy on port 8317.

Accounts live in %USERPROFILE%\.cli-proxy-api
The first launch copies config.yaml there. Later edits belong in that copy.

The console asks for a management key. Click Copy key, or choose Copy
management key from the taskbar menu. Each install gets its own random key,
kept in %USERPROFILE%\.cli-proxy-api\management-key.txt. To change it, edit
that file and restart VibeRouter.
