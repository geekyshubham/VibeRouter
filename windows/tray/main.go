//go:build windows

// VibeRouter.exe is the Windows taskbar app. It starts the proxy hidden and
// stays on the taskbar. The management console opens in the browser.
package main

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"syscall"
	"unsafe"
)

const (
	consoleURL = "http://127.0.0.1:8318/management.html"

	wsCaption     = 0x00C00000
	wsSysMenu     = 0x00080000
	wsMinimizeBox = 0x00020000
	wsVisible     = 0x10000000
	wsChild       = 0x40000000
	wsTabStop     = 0x00010000
	wsExAppWindow = 0x00040000
	cwUseDefault  = 0x80000000

	wmCreate   = 0x0001
	wmDestroy  = 0x0002
	wmClose    = 0x0010
	wmSetFont  = 0x0030
	wmSetIcon  = 0x0080
	wmCommand  = 0x0111
	wmNull     = 0x0000
	wmLButton  = 0x0202
	wmRButton  = 0x0205
	wmUser     = 0x0400
	wmTray     = wmUser + 1
	wmShow     = wmUser + 2
	wmProxyEnd = wmUser + 3

	nimAdd        = 0
	nimDelete     = 2
	nifMessage    = 1
	nifIcon       = 2
	nifTip        = 4
	idiApp        = 32512
	imageIcon     = 1
	lrLoadFile    = 0x0010
	lrShared      = 0x8000
	defaultGUI    = 17
	swRestore     = 9
	swShow        = 5
	mbIconError   = 0x10
	mfString      = 0
	tpmRightAlign = 0x0008
	tpmNonotify   = 0x0080

	idOpen = 1
	idQuit = 2
	idShow = 3

	createNoWindow     = 0x08000000
	errorAlreadyExists = 183
)

var (
	user32   = syscall.NewLazyDLL("user32.dll")
	shell32  = syscall.NewLazyDLL("shell32.dll")
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	gdi32    = syscall.NewLazyDLL("gdi32.dll")

	pRegisterClass = user32.NewProc("RegisterClassExW")
	pCreateWindow  = user32.NewProc("CreateWindowExW")
	pDefWindowProc = user32.NewProc("DefWindowProcW")
	pGetMessage    = user32.NewProc("GetMessageW")
	pTranslate     = user32.NewProc("TranslateMessage")
	pDispatch      = user32.NewProc("DispatchMessageW")
	pPostQuit      = user32.NewProc("PostQuitMessage")
	pPostMessage   = user32.NewProc("PostMessageW")
	pLoadImage     = user32.NewProc("LoadImageW")
	pLoadIcon      = user32.NewProc("LoadIconW")
	pSendMessage   = user32.NewProc("SendMessageW")
	pSetWindowText = user32.NewProc("SetWindowTextW")
	pMessageBox    = user32.NewProc("MessageBoxW")
	pCreateMenu    = user32.NewProc("CreatePopupMenu")
	pAppendMenu    = user32.NewProc("AppendMenuW")
	pTrackMenu     = user32.NewProc("TrackPopupMenu")
	pSetForeground = user32.NewProc("SetForegroundWindow")
	pDestroyWindow = user32.NewProc("DestroyWindow")
	pGetCursorPos  = user32.NewProc("GetCursorPos")
	pShowWindow    = user32.NewProc("ShowWindow")
	pFindWindow    = user32.NewProc("FindWindowW")
	pDestroyMenu   = user32.NewProc("DestroyMenu")

	pNotifyIcon = shell32.NewProc("Shell_NotifyIconW")
	pShellExec  = shell32.NewProc("ShellExecuteW")
	pSetAppID   = shell32.NewProc("SetCurrentProcessExplicitAppUserModelID")

	pModule      = kernel32.NewProc("GetModuleHandleW")
	pCreateMutex = kernel32.NewProc("CreateMutexW")
	pStock       = gdi32.NewProc("GetStockObject")
)

type wndClassEx struct {
	cbSize        uint32
	style         uint32
	lpfnWndProc   uintptr
	cbClsExtra    int32
	cbWndExtra    int32
	hInstance     syscall.Handle
	hIcon         syscall.Handle
	hCursor       syscall.Handle
	hbrBackground syscall.Handle
	lpszMenuName  *uint16
	lpszClassName *uint16
	hIconSm       syscall.Handle
}

type point struct{ x, y int32 }

type message struct {
	hwnd    syscall.Handle
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	pt      point
}

// Matches NOTIFYICONDATAW on 64-bit Windows. cbSize is set from unsafe.Sizeof.
type notifyIcon struct {
	cbSize           uint32
	hwnd             uintptr
	uid              uint32
	uFlags           uint32
	uCallbackMessage uint32
	hIcon            uintptr
	szTip            [128]uint16
	dwState          uint32
	dwStateMask      uint32
	szInfo           [256]uint16
	uTimeout         uint32
	szInfoTitle      [64]uint16
	dwInfoFlags      uint32
	guidItem         [16]byte
	hBalloonIcon     uintptr
}

var (
	className  = utf16("VibeRouterWindow")
	mainWindow syscall.Handle
	statusText syscall.Handle
	appIcon    uintptr
	proxy      *exec.Cmd
	trayOn     bool
)

func main() {
	runtime.LockOSThread()
	appID := utf16("VibeRouter")
	pSetAppID.Call(uintptr(unsafe.Pointer(appID)))

	if alreadyRunning() {
		if hwnd, _, _ := pFindWindow.Call(uintptr(unsafe.Pointer(className)), 0); hwnd != 0 {
			pShowWindow.Call(hwnd, swRestore)
			pSetForeground.Call(hwnd)
		} else {
			openConsole()
		}
		return
	}

	icon := loadIcon()
	appIcon = icon
	hwnd, err := createMainWindow(icon)
	if err != nil {
		alert(err.Error())
		return
	}
	mainWindow = syscall.Handle(hwnd)
	addTray()
	if err := startProxy(); err != nil {
		alert(err.Error())
		stopProxy()
		removeTray()
		return
	}

	var m message
	for {
		ret, _, _ := pGetMessage.Call(uintptr(unsafe.Pointer(&m)), 0, 0, 0)
		if int32(ret) <= 0 {
			break
		}
		pTranslate.Call(uintptr(unsafe.Pointer(&m)))
		pDispatch.Call(uintptr(unsafe.Pointer(&m)))
	}
	stopProxy()
	removeTray()
}

func alreadyRunning() bool {
	name := utf16(`Local\VibeRouter`)
	handle, _, err := pCreateMutex.Call(0, 0, uintptr(unsafe.Pointer(name)))
	if handle == 0 {
		return false
	}
	// Call reports GetLastError. A live mutex returns a handle and
	// ERROR_ALREADY_EXISTS. Keep the handle open for this process.
	return err == syscall.Errno(errorAlreadyExists)
}

func createMainWindow(icon uintptr) (uintptr, error) {
	inst, _, _ := pModule.Call(0)
	class := wndClassEx{
		cbSize:        uint32(unsafe.Sizeof(wndClassEx{})),
		lpfnWndProc:   syscall.NewCallback(wndProc),
		hInstance:     syscall.Handle(inst),
		hIcon:         syscall.Handle(icon),
		hIconSm:       syscall.Handle(icon),
		lpszClassName: className,
	}
	if atom, _, err := pRegisterClass.Call(uintptr(unsafe.Pointer(&class))); atom == 0 {
		return 0, err
	}
	title := utf16("VibeRouter")
	hwnd, _, err := pCreateWindow.Call(
		wsExAppWindow,
		uintptr(unsafe.Pointer(className)),
		uintptr(unsafe.Pointer(title)),
		wsCaption|wsSysMenu|wsMinimizeBox|wsVisible,
		cwUseDefault, cwUseDefault, 440, 210,
		0, 0, inst, 0,
	)
	if hwnd == 0 {
		return 0, err
	}
	pSendMessage.Call(hwnd, wmSetIcon, 1, icon)
	pSendMessage.Call(hwnd, wmSetIcon, 0, icon)
	return hwnd, nil
}

func wndProc(hwnd syscall.Handle, msg uint32, wparam, lparam uintptr) uintptr {
	switch msg {
	case wmCreate:
		font, _, _ := pStock.Call(defaultGUI)
		statusText = syscall.Handle(child(hwnd, "STATIC", "Starting the proxy…", 16, 16, 400, 52, 0))
		openBtn := child(hwnd, "BUTTON", "Open console", 16, 84, 140, 32, idOpen)
		quitBtn := child(hwnd, "BUTTON", "Quit", 168, 84, 100, 32, idQuit)
		for _, h := range []uintptr{uintptr(statusText), openBtn, quitBtn} {
			pSendMessage.Call(h, wmSetFont, font, 1)
		}
		return 0
	case wmCommand:
		switch int(wparam & 0xffff) {
		case idOpen:
			openConsole()
		case idShow:
			pShowWindow.Call(uintptr(hwnd), swRestore)
			pSetForeground.Call(uintptr(hwnd))
		case idQuit:
			pDestroyWindow.Call(uintptr(hwnd))
		}
		return 0
	case wmTray:
		switch lparam {
		case wmLButton:
			pShowWindow.Call(uintptr(hwnd), swRestore)
			pSetForeground.Call(uintptr(hwnd))
		case wmRButton:
			showMenu(hwnd)
		}
		return 0
	case wmShow:
		pShowWindow.Call(uintptr(hwnd), swRestore)
		pSetForeground.Call(uintptr(hwnd))
		return 0
	case wmProxyEnd:
		setStatus("The proxy stopped. Quit and open VibeRouter again.")
		return 0
	case wmClose:
		pDestroyWindow.Call(uintptr(hwnd))
		return 0
	case wmDestroy:
		stopProxy()
		removeTray()
		pPostQuit.Call(0)
		return 0
	}
	r, _, _ := pDefWindowProc.Call(uintptr(hwnd), uintptr(msg), wparam, lparam)
	return r
}

func child(parent syscall.Handle, class, text string, x, y, w, h int, id uintptr) uintptr {
	cname, label := utf16(class), utf16(text)
	style := uintptr(wsChild | wsVisible)
	if class == "BUTTON" {
		style |= wsTabStop
	}
	hwnd, _, _ := pCreateWindow.Call(0,
		uintptr(unsafe.Pointer(cname)), uintptr(unsafe.Pointer(label)),
		style, uintptr(x), uintptr(y), uintptr(w), uintptr(h),
		uintptr(parent), id, 0, 0)
	return hwnd
}

func setStatus(text string) {
	if statusText == 0 {
		return
	}
	s := utf16(text)
	pSetWindowText.Call(uintptr(statusText), uintptr(unsafe.Pointer(s)))
}

func addTray() {
	nid := notifyIcon{
		hwnd:             uintptr(mainWindow),
		uid:              1,
		uFlags:           nifMessage | nifIcon | nifTip,
		uCallbackMessage: wmTray,
		hIcon:            appIcon,
	}
	nid.cbSize = uint32(unsafe.Sizeof(nid))
	copyTip(nid.szTip[:], "VibeRouter")
	if r, _, _ := pNotifyIcon.Call(nimAdd, uintptr(unsafe.Pointer(&nid))); r != 0 {
		trayOn = true
	}
}

func removeTray() {
	if !trayOn {
		return
	}
	nid := notifyIcon{hwnd: uintptr(mainWindow), uid: 1}
	nid.cbSize = uint32(unsafe.Sizeof(nid))
	pNotifyIcon.Call(nimDelete, uintptr(unsafe.Pointer(&nid)))
	trayOn = false
}

func showMenu(hwnd syscall.Handle) {
	menu, _, _ := pCreateMenu.Call()
	if menu == 0 {
		return
	}
	defer pDestroyMenu.Call(menu)
	appendItem(menu, idOpen, "Open console")
	appendItem(menu, idShow, "Show window")
	appendItem(menu, idQuit, "Quit")
	var pt point
	pGetCursorPos.Call(uintptr(unsafe.Pointer(&pt)))
	pSetForeground.Call(uintptr(hwnd))
	pTrackMenu.Call(menu, tpmRightAlign|tpmNonotify, uintptr(pt.x), uintptr(pt.y), 0, uintptr(hwnd), 0)
	pPostMessage.Call(uintptr(hwnd), wmNull, 0, 0)
}

func appendItem(menu uintptr, id uintptr, label string) {
	s := utf16(label)
	pAppendMenu.Call(menu, mfString, id, uintptr(unsafe.Pointer(s)))
}

func loadIcon() uintptr {
	path := utf16(filepath.Join(exeDir(), "icon.ico"))
	if h, _, _ := pLoadImage.Call(0, uintptr(unsafe.Pointer(path)), imageIcon, 32, 32, lrLoadFile|lrShared); h != 0 {
		return h
	}
	h, _, _ := pLoadIcon.Call(0, idiApp)
	return h
}

func startProxy() error {
	cfg, err := ensureConfig()
	if err != nil {
		return err
	}
	bin := filepath.Join(exeDir(), "viberouter-proxy.exe")
	cmd := exec.Command(bin, "-config", cfg)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true, CreationFlags: createNoWindow}
	if err := cmd.Start(); err != nil {
		return err
	}
	proxy = cmd
	setStatus("Proxy is running.\r\nAPI  http://127.0.0.1:8318/v1")
	go func(c *exec.Cmd, hwnd syscall.Handle) {
		_ = c.Wait()
		pPostMessage.Call(uintptr(hwnd), wmProxyEnd, 0, 0)
	}(cmd, mainWindow)
	return nil
}

func stopProxy() {
	if proxy == nil || proxy.Process == nil {
		return
	}
	_ = proxy.Process.Kill()
	proxy = nil
}

func ensureConfig() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	dir := filepath.Join(home, ".cli-proxy-api")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	dst := filepath.Join(dir, "config.yaml")
	if _, err := os.Stat(dst); err == nil {
		return dst, nil
	}
	src, err := os.ReadFile(filepath.Join(exeDir(), "config.yaml"))
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(dst, src, 0o644); err != nil {
		return "", err
	}
	return dst, nil
}

func openConsole() {
	op, target := utf16("open"), utf16(consoleURL)
	pShellExec.Call(0, uintptr(unsafe.Pointer(op)), uintptr(unsafe.Pointer(target)), 0, 0, swShow)
}

func alert(text string) {
	body, title := utf16(text), utf16("VibeRouter")
	pMessageBox.Call(0, uintptr(unsafe.Pointer(body)), uintptr(unsafe.Pointer(title)), mbIconError)
}

func exeDir() string {
	exe, err := os.Executable()
	if err != nil {
		return "."
	}
	return filepath.Dir(exe)
}

func utf16(s string) *uint16 {
	p, err := syscall.UTF16PtrFromString(s)
	if err != nil {
		p, _ = syscall.UTF16PtrFromString("")
	}
	return p
}

func copyTip(dst []uint16, s string) {
	encoded, err := syscall.UTF16FromString(s)
	if err != nil || len(encoded) == 0 {
		return
	}
	if len(encoded) > len(dst) {
		encoded = encoded[:len(dst)]
		encoded[len(dst)-1] = 0
	}
	copy(dst, encoded)
}
