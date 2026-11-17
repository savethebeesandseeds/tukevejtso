//! In-memory screen capture for Enchanted Reader.
//! The terminal is concealed in place for the capture, then revealed before PNG
//! encoding and before any network call. Image bytes are not written to disk.

use anyhow::{anyhow, bail, Context, Result};
use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};
use enchanted_reader::{
    capture_dimensions, clip_capture_rect, intersection, Gesture, MonitorInfo, PixelRect,
    MAX_PIXELS,
};
use png::Encoder;
use std::{
    cell::Cell,
    ffi::c_void,
    io::{self, Write},
    mem::{size_of, zeroed},
    os::windows::{ffi::OsStrExt, io::AsRawHandle},
    ptr,
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};
use windows_sys::Win32::{
    Foundation::{
        GlobalFree, ERROR_CLASS_ALREADY_EXISTS, HANDLE, HWND, INVALID_HANDLE_VALUE, LPARAM, POINT, RECT,
        WPARAM,
    },
    Graphics::{
        Dwm::{
            DwmFlush, DwmGetWindowAttribute, DwmSetWindowAttribute, DWMWA_CLOAK, DWMWA_CLOAKED,
        },
        Gdi::{
            BeginPaint, BitBlt, ClientToScreen, CreateCompatibleDC, CreateDIBSection, CreatePen,
            CreateSolidBrush, DeleteDC, DeleteObject, EndPaint, EnumDisplayMonitors, FillRect,
            GdiFlush, GetDC, GetMonitorInfoW, GetStockObject, InvalidateRect, MonitorFromWindow,
            Rectangle, ReleaseDC, SelectObject, SetBkMode, SetTextColor, TextOutW, BITMAPINFO,
            BI_RGB, BLACK_BRUSH, CAPTUREBLT, DIB_RGB_COLORS, HBITMAP, HBRUSH, HDC, HGDIOBJ,
            HOLLOW_BRUSH, MONITORINFO, MONITORINFOEXW, MONITOR_DEFAULTTONEAREST, NOMIRRORBITMAP,
            PAINTSTRUCT, PS_SOLID, SRCCOPY, TRANSPARENT as BK_TRANSPARENT,
        },
    },
    System::{
        Console::GetConsoleWindow,
        DataExchange::{CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData},
        LibraryLoader::GetModuleHandleW,
        Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE},
        Threading::{AttachThreadInput, GetCurrentThreadId},
    },
    UI::{
        HiDpi::{
            SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT,
            DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        },
        Input::KeyboardAndMouse::{
            GetAsyncKeyState, RegisterHotKey, ReleaseCapture, SetCapture, SetFocus, UnregisterHotKey,
            VkKeyScanW, MOD_ALT, MOD_CONTROL, MOD_NOREPEAT, MOD_SHIFT, MOD_WIN, VK_CONTROL,
            VK_ESCAPE, VK_F8, VK_LCONTROL, VK_LMENU, VK_LSHIFT, VK_LWIN, VK_MENU, VK_RCONTROL,
            VK_RETURN, VK_RMENU, VK_RSHIFT, VK_RWIN, VK_SHIFT,
        },
        WindowsAndMessaging::{
            BringWindowToTop, CreateWindowExW, DefWindowProcW, DestroyWindow, DispatchMessageW,
            GetAncestor, GetClassNameW, GetClientRect, GetForegroundWindow, GetSystemMetrics,
            GetWindowPlacement, GetWindowRect, GetWindowThreadProcessId, IsIconic,
            IsWindow, IsWindowVisible, IsZoomed, LoadCursorW, MsgWaitForMultipleObjects,
            PeekMessageW, PostQuitMessage, RegisterClassW, SetCursor, SetForegroundWindow,
            SetLayeredWindowAttributes, SetWindowPlacement, SetWindowPos, ShowWindow,
            TranslateMessage, GA_ROOT, HWND_TOPMOST, IDC_CROSS, LWA_ALPHA, MSG, PM_REMOVE,
            QS_ALLINPUT, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN,
            SM_YVIRTUALSCREEN, SW_HIDE, SW_MAXIMIZE, SW_SHOWMAXIMIZED, SW_SHOWNA, SWP_NOACTIVATE,
            SWP_NOMOVE, SWP_NOSIZE, SWP_NOZORDER, SWP_SHOWWINDOW,
            WINDOWPLACEMENT, WM_CLOSE, WM_DESTROY, WM_ERASEBKGND, WM_HOTKEY, WM_KEYDOWN,
            WM_LBUTTONDOWN, WM_LBUTTONUP, WM_MOUSEMOVE, WM_PAINT, WM_QUIT, WM_RBUTTONDOWN,
            WM_SETCURSOR, WNDCLASSW, WPF_ASYNCWINDOWPLACEMENT, WS_EX_LAYERED, WS_EX_TOPMOST,
            WS_POPUP, WS_VISIBLE,
        },
    },
};

const WINDOW_WAIT: Duration = Duration::from_millis(750);
const COMPOSITOR_WAIT: Duration = Duration::from_millis(300);
const MAX_PNG_BYTES: usize = 12 * 1024 * 1024;
const CF_UNICODETEXT: u32 = 13;
const F8_HOTKEY_ID: i32 = 1;
const GESTURE_HOTKEY_ID: i32 = 2;
const MIN_PICK: i32 = 8;

pub struct Hotkey {
    id: i32,
}

impl Hotkey {
    /// Plain F8, no modifiers. `RegisterHotKey` consumes the key, so the
    /// focused window does not receive its keydown or keyup.
    pub fn register_f8() -> Result<Self> {
        Self::register_key(
            F8_HOTKEY_ID,
            u32::from(VK_F8),
            MOD_NOREPEAT,
            "Windows did not register F8. It may already be in use.",
        )
    }

    pub fn register(gesture: &Gesture) -> Result<Self> {
        let mut modifiers = MOD_NOREPEAT;
        if gesture.alt {
            modifiers |= MOD_ALT;
        }
        if gesture.control {
            modifiers |= MOD_CONTROL;
        }
        if gesture.shift {
            modifiers |= MOD_SHIFT;
        }
        if gesture.win {
            modifiers |= MOD_WIN;
        }
        Self::register_key(
            GESTURE_HOTKEY_ID,
            u32::from(gesture.virtual_key),
            modifiers,
            "Windows did not register that shortcut. It may already be in use.",
        )
    }

    pub fn id(&self) -> i32 {
        self.id
    }

    fn register_key(id: i32, virtual_key: u32, modifiers: u32, failure: &str) -> Result<Self> {
        let registered = unsafe { RegisterHotKey(ptr::null_mut(), id, modifiers, virtual_key) };
        if registered == 0 {
            bail!("{failure}");
        }
        Ok(Self { id })
    }
}

pub fn drain_hotkeys(ids: &[i32]) -> bool {
    let mut any = false;
    unsafe {
        let mut message: MSG = zeroed();
        while PeekMessageW(
            &mut message,
            ptr::null_mut(),
            WM_HOTKEY,
            WM_HOTKEY,
            PM_REMOVE,
        ) != 0
        {
            if hotkey_matches(message.wParam, ids) {
                any = true;
            }
        }
    }
    any
}

fn hotkey_matches(param: usize, ids: &[i32]) -> bool {
    ids.iter().any(|id| param == *id as usize)
}

/// Wake for console input or a thread message such as `WM_HOTKEY`.
/// The terminal does not need to be in front. Queued messages are removed so
/// the wait cannot spin, and a matching hotkey is reported once.
pub fn wait_for_console_or_messages(timeout: Duration, hotkey_ids: &[i32]) -> bool {
    if pump_messages(hotkey_ids) {
        return true;
    }
    let handle = io::stdin().as_raw_handle() as HANDLE;
    let millis = u32::try_from(timeout.as_millis()).unwrap_or(u32::MAX);
    unsafe {
        if handle.is_null() || handle == INVALID_HANDLE_VALUE {
            thread::sleep(timeout);
        } else {
            let wake = MsgWaitForMultipleObjects(1, &handle, 0, millis, QS_ALLINPUT);
            if wake == u32::MAX {
                thread::sleep(timeout);
            }
        }
    }
    pump_messages(hotkey_ids)
}

fn pump_messages(hotkey_ids: &[i32]) -> bool {
    let mut fired = false;
    unsafe {
        let mut message: MSG = zeroed();
        while PeekMessageW(&mut message, ptr::null_mut(), 0, 0, PM_REMOVE) != 0 {
            if message.message == WM_HOTKEY {
                // Do not translate this message. RegisterHotKey already kept
                // the key from the focused window.
                if hotkey_matches(message.wParam, hotkey_ids) {
                    fired = true;
                }
                continue;
            }
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
    }
    fired
}

impl Drop for Hotkey {
    fn drop(&mut self) {
        unsafe {
            UnregisterHotKey(ptr::null_mut(), self.id);
        }
    }
}

pub fn virtual_key_is_down(virtual_key: u16) -> bool {
    unsafe { GetAsyncKeyState(i32::from(virtual_key)) < 0 }
}

/// The virtual key Windows will match in `RegisterHotKey`, sampled while it is down.
/// Crossterm reports a character, and on a non-US layout that character is not the virtual key.
pub fn gesture_from_key(key: &KeyEvent) -> Option<Gesture> {
    if !shortcut_event(key) {
        return None;
    }
    let fallback = fallback_virtual_key(key);
    let down = down_recordable_keys();
    let virtual_key = match down.as_slice() {
        [only] => *only,
        [] => fallback?,
        many => {
            let fallback = fallback?;
            if many.contains(&fallback) {
                fallback
            } else {
                return None;
            }
        }
    };
    Some(Gesture {
        control: key.modifiers.contains(KeyModifiers::CONTROL)
            || modifier_down(&[VK_CONTROL, VK_LCONTROL, VK_RCONTROL]),
        alt: key.modifiers.contains(KeyModifiers::ALT)
            || modifier_down(&[VK_MENU, VK_LMENU, VK_RMENU]),
        shift: key.modifiers.contains(KeyModifiers::SHIFT)
            || modifier_down(&[VK_SHIFT, VK_LSHIFT, VK_RSHIFT]),
        win: modifier_down(&[VK_LWIN, VK_RWIN]),
        virtual_key,
    })
}

fn shortcut_event(key: &KeyEvent) -> bool {
    match key.code {
        KeyCode::F(number) => (1..=24).contains(&number),
        KeyCode::Char(ch) => !ch.is_ascii() || ch.is_ascii_alphanumeric() || ch.is_ascii_control(),
        _ => false,
    }
}

fn fallback_virtual_key(key: &KeyEvent) -> Option<u16> {
    let virtual_key = match key.code {
        KeyCode::F(number) if (1..=24).contains(&number) => 0x70 + u16::from(number) - 1,
        KeyCode::Char(ch) => character_virtual_key(ch)?,
        _ => return None,
    };
    recordable_virtual_key(virtual_key)
}

fn character_virtual_key(ch: char) -> Option<u16> {
    let unit = u16::try_from(u32::from(ch)).ok()?;
    let scanned = unsafe { VkKeyScanW(unit) };
    if scanned < 0 {
        return None;
    }
    recordable_virtual_key(scanned as u16 & 0xff)
}

fn recordable_virtual_key(virtual_key: u16) -> Option<u16> {
    if (0x30..=0x39).contains(&virtual_key)
        || (0x41..=0x5A).contains(&virtual_key)
        || (0x70..=0x87).contains(&virtual_key)
    {
        Some(virtual_key)
    } else {
        None
    }
}

fn modifier_down(keys: &[u16]) -> bool {
    keys.iter().copied().any(virtual_key_is_down)
}

fn down_recordable_keys() -> Vec<u16> {
    let mut keys = Vec::new();
    for virtual_key in (0x30..=0x39).chain(0x41..=0x5A).chain(0x70..=0x87) {
        if virtual_key_is_down(virtual_key) {
            keys.push(virtual_key);
        }
    }
    keys
}

pub fn terminal_hwnd_usable(hwnd: isize) -> bool {
    if hwnd == 0 {
        return false;
    }
    let hwnd = hwnd as HWND;
    !hwnd.is_null()
        && unsafe { IsWindow(hwnd) } != 0
        && unsafe { GetAncestor(hwnd, GA_ROOT) } == hwnd
        && terminal_class(hwnd)
}

pub fn attached_terminal() -> Option<isize> {
    let window = root_window(unsafe { GetConsoleWindow() });
    visible_terminal(window)
}

pub fn terminal_on_setup_key() -> Option<isize> {
    attached_terminal().or_else(|| visible_terminal(foreground_root()))
}

fn visible_terminal(window: HWND) -> Option<isize> {
    let handle = window as isize;
    (terminal_hwnd_usable(handle) && unsafe { IsWindowVisible(window) } != 0).then_some(handle)
}

pub fn monitors() -> Result<Vec<MonitorInfo>> {
    let _dpi = ThreadDpiGuard::per_monitor_v2()?;
    let mut found = Vec::new();
    let ok = unsafe {
        EnumDisplayMonitors(
            ptr::null_mut(),
            ptr::null(),
            Some(enum_monitor),
            &mut found as *mut Vec<MonitorInfo> as isize,
        )
    };
    if ok == 0 {
        bail!("could not list monitors");
    }
    if found.is_empty() {
        bail!("no monitors were found");
    }
    Ok(found)
}

pub fn monitor_for_window(hwnd: isize) -> Result<MonitorInfo> {
    let _dpi = ThreadDpiGuard::per_monitor_v2()?;
    let hwnd = hwnd as HWND;
    let monitor = unsafe { MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST) };
    read_monitor(monitor).ok_or_else(|| anyhow!("could not locate the terminal monitor"))
}

pub fn foreground_window_rect(terminal_hwnd: isize) -> Result<(PixelRect, isize)> {
    let _dpi = ThreadDpiGuard::per_monitor_v2()?;
    let terminal = terminal_hwnd as HWND;
    let target = foreground_root();
    if target == terminal {
        bail!("Focus the window you want to read, then press the capture shortcut.");
    }
    if target.is_null() || unsafe { IsWindowVisible(target) } == 0 || unsafe { IsIconic(target) } != 0 {
        bail!("no foreground window is available to capture");
    }
    let mut rect: RECT = unsafe { zeroed() };
    if unsafe { GetWindowRect(target, &mut rect) } == 0 {
        return Err(io::Error::last_os_error()).context("could not read the foreground window");
    }
    let window = pixel_rect(&rect);
    let visible = intersection(window, virtual_screen())
        .ok_or_else(|| anyhow!("the foreground window is outside the visible screen"))?;
    capture_dimensions(visible).map_err(|err| anyhow!(err))?;
    Ok((visible, target as isize))
}

pub fn capture_png(terminal_hwnd: isize, rect: PixelRect, foreground: Option<isize>) -> Result<Vec<u8>> {
    let _dpi = ThreadDpiGuard::per_monitor_v2()?;
    let (width, height) = capture_dimensions(rect).map_err(|err| anyhow!(err))?;
    let byte_count = (width as usize)
        .checked_mul(height as usize)
        .and_then(|pixels| pixels.checked_mul(4))
        .filter(|bytes| *bytes <= MAX_PIXELS.saturating_mul(4))
        .ok_or_else(|| anyhow!("screen portion exceeds the pixel limit"))?;
    let mut terminal = TerminalVisibilityGuard::new(terminal_hwnd)?;
    terminal.return_terminal_focus = false;
    let capture = (|| -> Result<Vec<u8>> {
        if !terminal.clear_of(rect)? {
            terminal.hide()?;
        }
        wait_for_compositor()?;
        let check_target = || -> Result<()> {
            if let Some(target) = foreground {
                if foreground_window_rect(terminal_hwnd)? != (rect, target) {
                    bail!("the foreground window changed during capture; press the shortcut again");
                }
            }
            Ok(())
        };
        check_target()?;
        let pixels = capture_rgba(&terminal, &rect, width, height, byte_count)?;
        check_target()?;
        Ok(pixels)
    })();
    let restoration = terminal.restore();
    let mut pixels = match (capture, restoration) {
        (Ok(pixels), Ok(())) => pixels,
        (Err(capture), Ok(())) => return Err(capture),
        (Ok(_), Err(restore)) => return Err(restore),
        (Err(capture), Err(restore)) => {
            return Err(capture.context(format!("terminal restoration also failed: {restore:#}")));
        }
    };
    let encoded = encode_png(&pixels, width as u32, height as u32);
    pixels.fill(0);
    encoded
}

pub fn pick_rectangle(terminal_hwnd: isize, monitor: &MonitorInfo) -> Result<Option<PixelRect>> {
    let _dpi = ThreadDpiGuard::per_monitor_v2()?;
    capture_dimensions(monitor.bounds).map_err(|err| anyhow!(err))?;
    let mut terminal = TerminalVisibilityGuard::new(terminal_hwnd)?;
    terminal.hide()?;
    let picked = picker_loop(monitor);
    let restoration = terminal.restore();
    match (picked, restoration) {
        (Ok(rect), Ok(())) => Ok(rect),
        (Err(pick), Ok(())) => Err(pick),
        (Ok(_), Err(restore)) => Err(restore),
        (Err(pick), Err(restore)) => {
            Err(pick.context(format!("terminal restoration also failed: {restore:#}")))
        }
    }
}

pub fn copy_answer(owner: isize, text: &str) -> Result<()> {
    let mut wide = text.encode_utf16().collect::<Vec<_>>();
    wide.push(0);
    let bytes = wide
        .len()
        .checked_mul(size_of::<u16>())
        .ok_or_else(|| anyhow!("clipboard text is too large"))?;
    unsafe {
        let owner = owner as HWND;
        if owner.is_null() || IsWindow(owner) == 0 {
            bail!("the reader window is unavailable for clipboard ownership");
        }
        let handle = GlobalAlloc(GMEM_MOVEABLE, bytes);
        if handle.is_null() {
            bail!("GlobalAlloc failed");
        }
        let locked = GlobalLock(handle) as *mut u16;
        if locked.is_null() {
            GlobalFree(handle);
            bail!("GlobalLock failed");
        }
        ptr::copy_nonoverlapping(wide.as_ptr(), locked, wide.len());
        GlobalUnlock(handle);
        if OpenClipboard(owner) == 0 {
            GlobalFree(handle);
            bail!("OpenClipboard failed");
        }
        let _guard = ClipboardGuard;
        if EmptyClipboard() == 0 {
            GlobalFree(handle);
            bail!("EmptyClipboard failed");
        }
        if SetClipboardData(CF_UNICODETEXT, handle).is_null() {
            GlobalFree(handle);
            bail!("SetClipboardData failed");
        }
    }
    Ok(())
}

struct ClipboardGuard;

impl Drop for ClipboardGuard {
    fn drop(&mut self) {
        unsafe {
            CloseClipboard();
        }
    }
}

struct ThreadDpiGuard {
    original: DPI_AWARENESS_CONTEXT,
}

impl ThreadDpiGuard {
    fn per_monitor_v2() -> Result<Self> {
        let original =
            unsafe { SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
        if original.is_null() {
            return Err(io::Error::last_os_error())
                .context("could not select physical-pixel screen capture coordinates");
        }
        Ok(Self { original })
    }
}

impl Drop for ThreadDpiGuard {
    fn drop(&mut self) {
        unsafe {
            SetThreadDpiAwarenessContext(self.original);
        }
    }
}

unsafe extern "system" fn enum_monitor(
    monitor: windows_sys::Win32::Graphics::Gdi::HMONITOR,
    _: HDC,
    _: *mut RECT,
    data: LPARAM,
) -> i32 {
    if let Some(info) = read_monitor(monitor) {
        let found = &mut *(data as *mut Vec<MonitorInfo>);
        found.push(info);
    }
    1
}

fn read_monitor(monitor: windows_sys::Win32::Graphics::Gdi::HMONITOR) -> Option<MonitorInfo> {
    if monitor.is_null() {
        return None;
    }
    let mut info: MONITORINFOEXW = unsafe { zeroed() };
    info.monitorInfo.cbSize = size_of::<MONITORINFOEXW>() as u32;
    let ok = unsafe { GetMonitorInfoW(monitor, &mut info as *mut MONITORINFOEXW as *mut MONITORINFO) };
    if ok == 0 {
        return None;
    }
    let device = wide_to_string(&info.szDevice);
    if device.is_empty() {
        return None;
    }
    Some(MonitorInfo {
        device,
        bounds: pixel_rect(&info.monitorInfo.rcMonitor),
    })
}

fn wide_to_string(value: &[u16]) -> String {
    let end = value.iter().position(|unit| *unit == 0).unwrap_or(value.len());
    String::from_utf16_lossy(&value[..end])
}

fn pixel_rect(rect: &RECT) -> PixelRect {
    PixelRect {
        left: rect.left,
        top: rect.top,
        right: rect.right,
        bottom: rect.bottom,
    }
}

fn virtual_screen() -> PixelRect {
    let left = unsafe { GetSystemMetrics(SM_XVIRTUALSCREEN) };
    let top = unsafe { GetSystemMetrics(SM_YVIRTUALSCREEN) };
    let width = unsafe { GetSystemMetrics(SM_CXVIRTUALSCREEN) };
    let height = unsafe { GetSystemMetrics(SM_CYVIRTUALSCREEN) };
    PixelRect {
        left,
        top,
        right: left.saturating_add(width),
        bottom: top.saturating_add(height),
    }
}

fn root_window(hwnd: HWND) -> HWND {
    if hwnd.is_null() {
        return hwnd;
    }
    let root = unsafe { GetAncestor(hwnd, GA_ROOT) };
    if root.is_null() {
        hwnd
    } else {
        root
    }
}

fn terminal_class(hwnd: HWND) -> bool {
    let mut name = [0u16; 256];
    let length = unsafe { GetClassNameW(hwnd, name.as_mut_ptr(), name.len() as i32) };
    if length <= 0 {
        return false;
    }
    matches!(
        String::from_utf16_lossy(&name[..length as usize]).as_str(),
        "ConsoleWindowClass" | "CASCADIA_HOSTING_WINDOW_CLASS"
    )
}

fn foreground_root() -> HWND {
    root_window(unsafe { GetForegroundWindow() })
}

struct TerminalVisibilityGuard {
    hwnd: HWND,
    placement: WINDOWPLACEMENT,
    screen: RECT,
    visible: bool,
    minimized: bool,
    maximized: bool,
    was_foreground: bool,
    /// The rectangle picker returns focus to this terminal. A capture does not.
    return_terminal_focus: bool,
    thread_id: u32,
    process_id: u32,
    restore_needed: bool,
    cloaked: bool,
}

impl TerminalVisibilityGuard {
    fn new(hwnd: isize) -> Result<Self> {
        let hwnd = hwnd as HWND;
        if !terminal_hwnd_usable(hwnd as isize) {
            bail!("screen capture requires the Enchanted Reader terminal window");
        }
        let mut process_id = 0;
        let thread_id = unsafe {
            windows_sys::Win32::UI::WindowsAndMessaging::GetWindowThreadProcessId(
                hwnd,
                &mut process_id,
            )
        };
        if thread_id == 0 || process_id == 0 {
            bail!("could not verify the screen capture terminal owner");
        }
        let mut guard = Self {
            hwnd,
            placement: unsafe { zeroed() },
            screen: unsafe { zeroed() },
            visible: false,
            minimized: false,
            maximized: false,
            was_foreground: foreground_root() == hwnd,
            return_terminal_focus: true,
            thread_id,
            process_id,
            restore_needed: false,
            cloaked: false,
        };
        guard.capture_geometry()?;
        Ok(guard)
    }

    fn same_window(&self) -> bool {
        if unsafe { IsWindow(self.hwnd) } == 0
            || unsafe { GetAncestor(self.hwnd, GA_ROOT) } != self.hwnd
            || !terminal_class(self.hwnd)
        {
            return false;
        }
        let mut process_id = 0;
        let thread_id = unsafe {
            windows_sys::Win32::UI::WindowsAndMessaging::GetWindowThreadProcessId(
                self.hwnd,
                &mut process_id,
            )
        };
        thread_id == self.thread_id && process_id == self.process_id
    }

    fn capture_geometry(&mut self) -> Result<()> {
        self.visible = unsafe { IsWindowVisible(self.hwnd) } != 0;
        self.minimized = unsafe { IsIconic(self.hwnd) } != 0;
        self.maximized = unsafe { IsZoomed(self.hwnd) } != 0;
        if unsafe { GetWindowRect(self.hwnd, &mut self.screen) } == 0 {
            return Err(io::Error::last_os_error()).context("could not read the terminal bounds");
        }
        self.placement = unsafe { zeroed() };
        self.placement.length = size_of::<WINDOWPLACEMENT>() as u32;
        if unsafe { GetWindowPlacement(self.hwnd, &mut self.placement) } == 0 {
            return Err(io::Error::last_os_error()).context("could not save terminal placement");
        }
        Ok(())
    }

    fn hide(&mut self) -> Result<()> {
        if !self.same_window() {
            bail!("the screen capture terminal is no longer available");
        }
        if !self.visible || self.minimized {
            return Ok(());
        }
        self.was_foreground = foreground_root() == self.hwnd;
        self.capture_geometry()?;
        // Cloaking leaves the window's size, snap, and maximized state untouched.
        // ShowWindow(SW_HIDE) makes Windows Terminal come back at its restored rect.
        if self.set_cloak(true) {
            self.cloaked = true;
            self.restore_needed = true;
            let deadline = Instant::now() + WINDOW_WAIT;
            loop {
                if !self.same_window() {
                    bail!("the terminal closed while preparing screen capture");
                }
                if self.is_cloaked() {
                    let _ = unsafe { DwmFlush() };
                    return Ok(());
                }
                if Instant::now() >= deadline {
                    break;
                }
                thread::sleep(Duration::from_millis(10));
            }
            if !self.set_cloak(false) {
                bail!("Windows could not release the terminal cloak");
            }
        }
        self.cloaked = false;
        self.restore_needed = false;
        if !self.return_terminal_focus {
            bail!("Minimize the reader or move it outside the capture area, then press the shortcut again.");
        }
        unsafe { ShowWindow(self.hwnd, SW_HIDE) };
        self.restore_needed = true;
        self.wait_until(false)
    }

    fn clear_of(&self, rect: PixelRect) -> Result<bool> {
        if !self.same_window() {
            bail!("the terminal closed during screen capture");
        }
        if unsafe { IsWindowVisible(self.hwnd) } == 0 || unsafe { IsIconic(self.hwnd) } != 0 || self.is_cloaked() {
            return Ok(true);
        }
        let mut bounds: RECT = unsafe { zeroed() };
        if unsafe { GetWindowRect(self.hwnd, &mut bounds) } == 0 {
            return Err(io::Error::last_os_error()).context("could not check the terminal bounds");
        }
        Ok(intersection(pixel_rect(&bounds), rect).is_none())
    }

    fn restore(&mut self) -> Result<()> {
        if !self.restore_needed {
            return Ok(());
        }
        if !self.same_window() {
            self.restore_needed = false;
            bail!("the original terminal no longer exists; its placement could not be restored");
        }
        if self.cloaked {
            if !self.set_cloak(false) {
                bail!("Windows could not reveal the reader terminal");
            }
            let _ = unsafe { DwmFlush() };
            let deadline = Instant::now() + Duration::from_millis(200);
            while self.is_cloaked() && Instant::now() < deadline {
                thread::sleep(Duration::from_millis(10));
            }
            if self.is_cloaked() {
                bail!("the terminal is still cloaked after capture");
            }
            self.cloaked = false;
        }
        // Only the interactive picker owns a focus transition. A capture may
        // finish after the user has switched apps, moved a window, or minimized it.
        if self.return_terminal_focus {
            if self.needs_geometry_restore() {
                self.restore_geometry()?;
            }
            self.finish_focus();
        }
        self.restore_needed = false;
        Ok(())
    }

    fn set_cloak(&self, cloak: bool) -> bool {
        let value: i32 = if cloak { 1 } else { 0 };
        let result = unsafe {
            DwmSetWindowAttribute(
                self.hwnd,
                DWMWA_CLOAK as u32,
                &value as *const i32 as *const c_void,
                size_of::<i32>() as u32,
            )
        };
        result >= 0
    }

    fn is_cloaked(&self) -> bool {
        let mut cloaked = 0u32;
        let result = unsafe {
            DwmGetWindowAttribute(
                self.hwnd,
                DWMWA_CLOAKED as u32,
                &mut cloaked as *mut u32 as *mut c_void,
                size_of::<u32>() as u32,
            )
        };
        result >= 0 && cloaked != 0
    }

    fn wait_until(&self, cloaked: bool) -> Result<()> {
        let deadline = Instant::now() + WINDOW_WAIT;
        loop {
            if !self.same_window() {
                bail!("the terminal closed while preparing screen capture");
            }
            let visible = unsafe { IsWindowVisible(self.hwnd) };
            let ready = if cloaked {
                self.is_cloaked()
            } else {
                visible == 0
            };
            if ready {
                return Ok(());
            }
            if Instant::now() >= deadline {
                bail!("the terminal did not hide before the screen capture deadline");
            }
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn needs_geometry_restore(&self) -> bool {
        if self.is_cloaked() || unsafe { IsWindowVisible(self.hwnd) } == 0 {
            return true;
        }
        if self.maximized {
            return unsafe { IsZoomed(self.hwnd) } == 0;
        }
        !self.rect_matches()
    }

    fn rect_matches(&self) -> bool {
        let mut rect: RECT = unsafe { zeroed() };
        if unsafe { GetWindowRect(self.hwnd, &mut rect) } == 0 {
            return false;
        }
        (rect.left - self.screen.left).abs() <= 2
            && (rect.top - self.screen.top).abs() <= 2
            && (rect.right - self.screen.right).abs() <= 2
            && (rect.bottom - self.screen.bottom).abs() <= 2
    }

    fn restore_geometry(&self) -> Result<()> {
        if self.is_cloaked() {
            let _ = self.set_cloak(false);
        }
        unsafe {
            if self.maximized {
                let mut placement = self.placement;
                placement.length = size_of::<WINDOWPLACEMENT>() as u32;
                placement.flags &= !WPF_ASYNCWINDOWPLACEMENT;
                placement.showCmd = SW_SHOWMAXIMIZED as u32;
                if SetWindowPlacement(self.hwnd, &placement) == 0 || IsZoomed(self.hwnd) == 0 {
                    ShowWindow(self.hwnd, SW_MAXIMIZE);
                }
            } else {
                let width = self.screen.right.saturating_sub(self.screen.left).max(1);
                let height = self.screen.bottom.saturating_sub(self.screen.top).max(1);
                if SetWindowPos(
                    self.hwnd,
                    ptr::null_mut(),
                    self.screen.left,
                    self.screen.top,
                    width,
                    height,
                    SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW,
                ) == 0
                {
                    ShowWindow(self.hwnd, SW_SHOWNA);
                    return Err(io::Error::last_os_error())
                        .context("could not restore terminal placement");
                }
            }
        }
        // Maximized restore can activate the window. Give focus back before waiting.
        self.finish_focus();
        let deadline = Instant::now() + WINDOW_WAIT;
        loop {
            if !self.same_window() {
                bail!("the terminal closed while restoring its placement");
            }
            if !self.needs_geometry_restore() {
                return Ok(());
            }
            if Instant::now() >= deadline {
                bail!("the terminal did not restore before the screen capture deadline");
            }
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn finish_focus(&self) {
        if self.return_terminal_focus && self.was_foreground {
            move_foreground_to(self.hwnd);
        }
    }
}

fn move_foreground_to(hwnd: HWND) {
    if hwnd.is_null() || unsafe { IsWindow(hwnd) } == 0 {
        return;
    }
    unsafe {
        if GetForegroundWindow() == hwnd {
            return;
        }
        let foreground = GetForegroundWindow();
        let foreground_thread = GetWindowThreadProcessId(foreground, ptr::null_mut());
        let target_thread = GetWindowThreadProcessId(hwnd, ptr::null_mut());
        let current_thread = GetCurrentThreadId();
        let attach = |thread: u32| -> bool {
            thread != 0
                && thread != current_thread
                && AttachThreadInput(current_thread, thread, 1) != 0
        };
        let attached_foreground = attach(foreground_thread);
        let attached_target = target_thread != foreground_thread && attach(target_thread);
        SetForegroundWindow(hwnd);
        if attached_target {
            AttachThreadInput(current_thread, target_thread, 0);
        }
        if attached_foreground {
            AttachThreadInput(current_thread, foreground_thread, 0);
        }
    }
}

impl Drop for TerminalVisibilityGuard {
    fn drop(&mut self) {
        let _ = self.restore();
    }
}

fn wait_for_compositor() -> Result<()> {
    let (tx, rx) = mpsc::sync_channel(1);
    thread::Builder::new()
        .name("reader-capture-compositor".into())
        .spawn(move || {
            let _ = tx.send(unsafe { DwmFlush() });
        })
        .context("could not start screen capture compositor wait")?;
    let result = rx
        .recv_timeout(COMPOSITOR_WAIT)
        .context("screen capture compositor did not settle before its deadline")?;
    if result < 0 {
        bail!("screen capture compositor synchronization failed: HRESULT {result:#x}");
    }
    thread::sleep(Duration::from_millis(50));
    Ok(())
}

struct ScreenDc(HDC);
impl Drop for ScreenDc {
    fn drop(&mut self) {
        unsafe {
            ReleaseDC(ptr::null_mut(), self.0);
        }
    }
}

struct MemoryDc(HDC);
impl Drop for MemoryDc {
    fn drop(&mut self) {
        unsafe {
            DeleteDC(self.0);
        }
    }
}

struct Bitmap(HBITMAP);
impl Drop for Bitmap {
    fn drop(&mut self) {
        unsafe {
            DeleteObject(self.0 as HGDIOBJ);
        }
    }
}

struct SelectedBitmap {
    dc: HDC,
    previous: HGDIOBJ,
}
impl Drop for SelectedBitmap {
    fn drop(&mut self) {
        unsafe {
            SelectObject(self.dc, self.previous);
        }
    }
}

fn capture_rgba(
    terminal: &TerminalVisibilityGuard,
    rect: &PixelRect,
    width: i32,
    height: i32,
    byte_count: usize,
) -> Result<Vec<u8>> {
    let screen = ScreenDc(unsafe { GetDC(ptr::null_mut()) });
    if screen.0.is_null() {
        return Err(io::Error::last_os_error())
            .context("could not acquire screen capture device context");
    }
    let memory = MemoryDc(unsafe { CreateCompatibleDC(screen.0) });
    if memory.0.is_null() {
        return Err(io::Error::last_os_error())
            .context("could not create screen capture device context");
    }
    let mut info: BITMAPINFO = unsafe { zeroed() };
    info.bmiHeader.biSize = size_of::<windows_sys::Win32::Graphics::Gdi::BITMAPINFOHEADER>() as u32;
    info.bmiHeader.biWidth = width;
    info.bmiHeader.biHeight = -height;
    info.bmiHeader.biPlanes = 1;
    info.bmiHeader.biBitCount = 32;
    info.bmiHeader.biCompression = BI_RGB;
    info.bmiHeader.biSizeImage = byte_count as u32;
    let mut bits: *mut c_void = ptr::null_mut();
    let bitmap = Bitmap(unsafe {
        CreateDIBSection(
            screen.0,
            &info,
            DIB_RGB_COLORS,
            &mut bits,
            ptr::null_mut(),
            0,
        )
    });
    if bitmap.0.is_null() || bits.is_null() {
        return Err(io::Error::last_os_error()).context("could not allocate screen capture bitmap");
    }
    let previous = unsafe { SelectObject(memory.0, bitmap.0 as HGDIOBJ) };
    if previous.is_null() || previous as isize == -1 {
        return Err(io::Error::last_os_error()).context("could not select screen capture bitmap");
    }
    let _selected = SelectedBitmap {
        dc: memory.0,
        previous,
    };
    if !terminal.clear_of(*rect)? {
        bail!("the terminal became visible inside the selected area");
    }
    if unsafe {
        BitBlt(
            memory.0,
            0,
            0,
            width,
            height,
            screen.0,
            rect.left,
            rect.top,
            SRCCOPY | CAPTUREBLT | NOMIRRORBITMAP,
        )
    } == 0
    {
        return Err(io::Error::last_os_error()).context("could not capture screen pixels");
    }
    if unsafe { GdiFlush() } == 0 {
        bail!("screen capture drawing could not be synchronized");
    }
    let mut rgba = Vec::new();
    rgba.try_reserve_exact(byte_count)
        .context("could not allocate screen capture pixel buffer")?;
    rgba.extend_from_slice(unsafe { std::slice::from_raw_parts(bits.cast::<u8>(), byte_count) });
    for pixel in rgba.chunks_exact_mut(4) {
        pixel.swap(0, 2);
        pixel[3] = 255;
    }
    Ok(rgba)
}

struct PngBuffer {
    bytes: Vec<u8>,
}

impl Write for PngBuffer {
    fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
        let total = self
            .bytes
            .len()
            .checked_add(bytes.len())
            .filter(|total| *total <= MAX_PNG_BYTES)
            .ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidData,
                    "screen capture PNG exceeds its size limit",
                )
            })?;
        self.bytes
            .try_reserve(total - self.bytes.len())
            .map_err(|_| {
                io::Error::new(
                    io::ErrorKind::OutOfMemory,
                    "could not allocate screen capture PNG",
                )
            })?;
        self.bytes.extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> io::Result<()> {
        Ok(())
    }
}

fn encode_png(rgba: &[u8], width: u32, height: u32) -> Result<Vec<u8>> {
    let mut output = PngBuffer { bytes: Vec::new() };
    {
        let mut encoder = Encoder::new(&mut output, width, height);
        encoder.set_color(png::ColorType::Rgba);
        encoder.set_depth(png::BitDepth::Eight);
        let mut writer = encoder
            .write_header()
            .context("could not write screen capture PNG header")?;
        writer
            .write_image_data(rgba)
            .context("could not encode screen capture PNG pixels")?;
        writer
            .finish()
            .context("could not finish screen capture PNG")?;
    }
    Ok(output.bytes)
}

struct PickerState {
    anchor: Option<POINT>,
    current: POINT,
    result: Option<PixelRect>,
    cancelled: bool,
    bounds: PixelRect,
    scrim: HWND,
    banner: HWND,
}

thread_local! {
    static PICKER: Cell<*mut PickerState> = const { Cell::new(ptr::null_mut()) };
    static PICKER_QUIT: Cell<bool> = const { Cell::new(false) };
}

fn picker_loop(monitor: &MonitorInfo) -> Result<Option<PixelRect>> {
    let class_name = wide("EnchantedReaderPicker");
    let instance = unsafe { GetModuleHandleW(ptr::null()) };
    if instance.is_null() {
        bail!("could not identify the reader process");
    }
    let mut window_class: WNDCLASSW = unsafe { zeroed() };
    window_class.lpfnWndProc = Some(picker_wnd_proc);
    window_class.hInstance = instance;
    window_class.lpszClassName = class_name.as_ptr();
    window_class.hbrBackground = unsafe { GetStockObject(BLACK_BRUSH) as HBRUSH };
    let atom = unsafe { RegisterClassW(&window_class) };
    if atom == 0 {
        let error = io::Error::last_os_error();
        if error.raw_os_error() != Some(ERROR_CLASS_ALREADY_EXISTS as i32) {
            return Err(error).context("could not create the rectangle picker");
        }
    }

    let mut state = PickerState {
        anchor: None,
        current: POINT { x: 0, y: 0 },
        result: None,
        cancelled: false,
        bounds: monitor.bounds,
        scrim: ptr::null_mut(),
        banner: ptr::null_mut(),
    };
    PICKER_QUIT.with(|slot| slot.set(false));
    PICKER.with(|slot| slot.set(&mut state));
    let title = wide("Enchanted Reader");
    let hwnd = unsafe {
        CreateWindowExW(
            WS_EX_TOPMOST | WS_EX_LAYERED,
            class_name.as_ptr(),
            title.as_ptr(),
            WS_POPUP | WS_VISIBLE,
            monitor.bounds.left,
            monitor.bounds.top,
            monitor.bounds.width(),
            monitor.bounds.height(),
            ptr::null_mut(),
            ptr::null_mut(),
            instance,
            ptr::null(),
        )
    };
    if hwnd.is_null() {
        PICKER.with(|slot| slot.set(ptr::null_mut()));
        return Err(io::Error::last_os_error()).context("could not open the rectangle picker");
    }
    state.scrim = hwnd;
    unsafe {
        // Uniform alpha keeps every pixel hit-testable. A color key let clicks
        // fall through the dim area, so the drag never started.
        SetLayeredWindowAttributes(hwnd, 0, 96, LWA_ALPHA);
    }
    let banner = unsafe {
        CreateWindowExW(
            WS_EX_TOPMOST,
            class_name.as_ptr(),
            title.as_ptr(),
            WS_POPUP | WS_VISIBLE,
            monitor.bounds.left,
            monitor.bounds.top,
            monitor.bounds.width().max(1),
            96,
            hwnd,
            ptr::null_mut(),
            instance,
            ptr::null(),
        )
    };
    state.banner = banner;
    unsafe {
        claim_picker_foreground(if banner.is_null() { hwnd } else { banner });
        let mut escape_down = virtual_key_is_down(VK_ESCAPE);
        let mut enter_down = virtual_key_is_down(VK_RETURN);
        let mut cancel_key_down = virtual_key_is_down(b'C' as u16);
        let mut message: MSG = zeroed();
        loop {
            let mut saw_quit = false;
            while PeekMessageW(&mut message, ptr::null_mut(), 0, 0, PM_REMOVE) != 0 {
                if message.message == WM_QUIT {
                    saw_quit = true;
                    break;
                }
                TranslateMessage(&message);
                DispatchMessageW(&message);
            }
            if saw_quit || IsWindow(hwnd) == 0 {
                break;
            }
            let escape_pressed = key_pressed(VK_ESCAPE, &mut escape_down);
            let cancel_pressed = key_pressed(b'C' as u16, &mut cancel_key_down)
                && modifier_down(&[VK_CONTROL, VK_LCONTROL, VK_RCONTROL]);
            let enter_pressed = key_pressed(VK_RETURN, &mut enter_down);
            if escape_pressed || cancel_pressed {
                if let Some(picker) = picker_state() {
                    cancel_picker(picker);
                }
                DestroyWindow(hwnd);
                continue;
            }
            if enter_pressed {
                let mut scrim = None;
                if let Some(picker) = picker_state() {
                    if confirm_picker(picker) {
                        scrim = Some(picker.scrim);
                    }
                }
                if let Some(scrim) = scrim {
                    DestroyWindow(scrim);
                }
                continue;
            }
            // The hidden console can keep the keyboard. Poll so Esc still cancels.
            MsgWaitForMultipleObjects(0, ptr::null(), 0, 15, QS_ALLINPUT);
        }
    }
    PICKER.with(|slot| slot.set(ptr::null_mut()));
    if state.cancelled {
        return Ok(None);
    }
    Ok(state.result)
}

fn claim_picker_foreground(hwnd: HWND) {
    unsafe {
        let foreground = GetForegroundWindow();
        let foreground_thread = GetWindowThreadProcessId(foreground, ptr::null_mut());
        let current_thread = GetCurrentThreadId();
        let attached = foreground_thread != 0
            && foreground_thread != current_thread
            && AttachThreadInput(current_thread, foreground_thread, 1) != 0;
        SetWindowPos(
            hwnd,
            HWND_TOPMOST,
            0,
            0,
            0,
            0,
            SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW,
        );
        BringWindowToTop(hwnd);
        SetForegroundWindow(hwnd);
        SetFocus(hwnd);
        if attached {
            AttachThreadInput(current_thread, foreground_thread, 0);
        }
    }
}

fn picker_state() -> Option<&'static mut PickerState> {
    let state = PICKER.with(|slot| slot.get());
    if state.is_null() {
        None
    } else {
        Some(unsafe { &mut *state })
    }
}

fn key_pressed(virtual_key: u16, was_down: &mut bool) -> bool {
    let down = virtual_key_is_down(virtual_key);
    let pressed = down && !*was_down;
    *was_down = down;
    pressed
}

fn confirm_picker(state: &mut PickerState) -> bool {
    let Some(rect) = selected_rect(state) else {
        return false;
    };
    state.result = Some(rect);
    state.cancelled = false;
    true
}

fn cancel_picker(state: &mut PickerState) {
    state.cancelled = true;
    state.result = None;
}

unsafe extern "system" fn picker_wnd_proc(
    hwnd: HWND,
    message: u32,
    wparam: WPARAM,
    lparam: LPARAM,
) -> isize {
    if message == WM_DESTROY {
        let first = PICKER_QUIT.with(|slot| {
            let first = !slot.get();
            slot.set(true);
            first
        });
        if first {
            PostQuitMessage(0);
        }
        return 0;
    }
    if message == WM_SETCURSOR {
        SetCursor(LoadCursorW(ptr::null_mut(), IDC_CROSS));
        return 1;
    }
    let close_scrim = |cancel: bool, confirm: bool| -> Option<HWND> {
        let state = picker_state()?;
        if cancel {
            ReleaseCapture();
            cancel_picker(state);
            return Some(state.scrim);
        }
        if confirm && confirm_picker(state) {
            return Some(state.scrim);
        }
        None
    };
    match message {
        WM_LBUTTONDOWN => {
            let Some(state) = picker_state() else {
                return DefWindowProcW(hwnd, message, wparam, lparam);
            };
            let point = client_point(hwnd, lparam);
            state.anchor = Some(point);
            state.current = point;
            SetCapture(hwnd);
            invalidate_picker(hwnd, state);
            0
        }
        WM_MOUSEMOVE => {
            let Some(state) = picker_state() else {
                return DefWindowProcW(hwnd, message, wparam, lparam);
            };
            if state.anchor.is_some() {
                state.current = client_point(hwnd, lparam);
                invalidate_picker(hwnd, state);
            }
            0
        }
        WM_LBUTTONUP => {
            let scrim = {
                let Some(state) = picker_state() else {
                    return DefWindowProcW(hwnd, message, wparam, lparam);
                };
                state.current = client_point(hwnd, lparam);
                ReleaseCapture();
                if confirm_picker(state) {
                    Some(state.scrim)
                } else {
                    state.anchor = None;
                    invalidate_picker(hwnd, state);
                    None
                }
            };
            if let Some(scrim) = scrim {
                DestroyWindow(scrim);
            }
            0
        }
        WM_RBUTTONDOWN | WM_CLOSE => {
            if let Some(scrim) = close_scrim(true, false) {
                DestroyWindow(scrim);
            }
            0
        }
        WM_KEYDOWN => {
            if wparam == VK_ESCAPE as usize {
                if let Some(scrim) = close_scrim(true, false) {
                    DestroyWindow(scrim);
                }
            } else if wparam == VK_RETURN as usize {
                if let Some(scrim) = close_scrim(false, true) {
                    DestroyWindow(scrim);
                }
            }
            0
        }
        WM_ERASEBKGND => 1,
        WM_PAINT => {
            let Some(state) = picker_state() else {
                return DefWindowProcW(hwnd, message, wparam, lparam);
            };
            paint_picker(hwnd, state);
            0
        }
        _ => DefWindowProcW(hwnd, message, wparam, lparam),
    }
}

fn invalidate_picker(hwnd: HWND, state: &PickerState) {
    unsafe {
        InvalidateRect(hwnd, ptr::null(), 1);
        if !state.scrim.is_null() && state.scrim != hwnd {
            InvalidateRect(state.scrim, ptr::null(), 1);
        }
    }
}

fn client_point(hwnd: HWND, lparam: LPARAM) -> POINT {
    let mut point = POINT {
        x: (lparam & 0xffff) as i16 as i32,
        y: ((lparam >> 16) & 0xffff) as i16 as i32,
    };
    unsafe {
        ClientToScreen(hwnd, &mut point);
    }
    point
}

fn selected_rect(state: &PickerState) -> Option<PixelRect> {
    let anchor = state.anchor?;
    let rect = normalize_point(anchor, state.current);
    clip_capture_rect(rect, state.bounds, MIN_PICK)
}

fn normalize_point(anchor: POINT, current: POINT) -> PixelRect {
    enchanted_reader::normalize_rect(anchor.x, anchor.y, current.x, current.y)
}

fn paint_picker(hwnd: HWND, state: &PickerState) {
    unsafe {
        let mut paint: PAINTSTRUCT = zeroed();
        let hdc = BeginPaint(hwnd, &mut paint);
        if hdc.is_null() {
            return;
        }
        let mut client: RECT = zeroed();
        GetClientRect(hwnd, &mut client);
        let on_banner = !state.banner.is_null() && hwnd == state.banner;
        let brush = CreateSolidBrush(rgb(8, 12, 20));
        FillRect(hdc, &client, brush);
        DeleteObject(brush as HGDIOBJ);
        SetBkMode(hdc, BK_TRANSPARENT as i32);
        SetTextColor(hdc, rgb(255, 210, 60));
        if on_banner || state.banner.is_null() {
            let help = wide("Drag a rectangle and release the mouse.");
            TextOutW(hdc, 24, 18, help.as_ptr(), (help.len() - 1) as i32);
            let cancel = wide("Right-click or Esc cancels and brings the terminal back.");
            TextOutW(hdc, 24, 48, cancel.as_ptr(), (cancel.len() - 1) as i32);
        }
        if on_banner {
            EndPaint(hwnd, &paint);
            return;
        }
        if let Some(rect) = selected_rect(state) {
            let mut origin = POINT { x: 0, y: 0 };
            ClientToScreen(hwnd, &mut origin);
            let pen = CreatePen(PS_SOLID, 6, rgb(255, 210, 60));
            let old_pen = SelectObject(hdc, pen as HGDIOBJ);
            let old_brush = SelectObject(hdc, GetStockObject(HOLLOW_BRUSH));
            Rectangle(
                hdc,
                rect.left - origin.x,
                rect.top - origin.y,
                rect.right - origin.x,
                rect.bottom - origin.y,
            );
            SelectObject(hdc, old_brush);
            SelectObject(hdc, old_pen);
            DeleteObject(pen as HGDIOBJ);
        }
        EndPaint(hwnd, &paint);
    }
}

fn rgb(red: u32, green: u32, blue: u32) -> u32 {
    red | (green << 8) | (blue << 16)
}

fn wide(value: &str) -> Vec<u16> {
    std::ffi::OsStr::new(value)
        .encode_wide()
        .chain(Some(0))
        .collect()
}
