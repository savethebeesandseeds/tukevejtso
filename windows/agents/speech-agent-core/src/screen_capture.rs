//! Explicit, in-memory screen capture with the terminal temporarily removed.
use anyhow::{anyhow, bail, Context, Result};
use std::{
    ffi::c_void,
    io::{self, Write},
    mem::{size_of, zeroed},
    ptr,
    sync::mpsc,
    thread,
    time::{Duration, Instant},
};
use windows_sys::Win32::{
    Foundation::{HWND, RECT},
    Graphics::{
        Dwm::DwmFlush,
        Gdi::{
            BitBlt, CreateCompatibleDC, CreateDIBSection, DeleteDC, DeleteObject, GdiFlush, GetDC,
            GetMonitorInfoW, MonitorFromWindow, ReleaseDC, SelectObject, BITMAPINFO, BI_RGB,
            CAPTUREBLT, DIB_RGB_COLORS, HBITMAP, HDC, HGDIOBJ, MONITORINFO,
            MONITOR_DEFAULTTONEAREST, NOMIRRORBITMAP, SRCCOPY,
        },
    },
    UI::{
        HiDpi::{
            SetThreadDpiAwarenessContext, DPI_AWARENESS_CONTEXT,
            DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2,
        },
        WindowsAndMessaging::{
            GetAncestor, GetClassNameW, GetForegroundWindow, GetWindowPlacement,
            GetWindowThreadProcessId, IsIconic, IsWindow, IsWindowVisible, IsZoomed,
            SetForegroundWindow, SetWindowPlacement, ShowWindowAsync, GA_ROOT, SW_HIDE, SW_SHOWNA,
            WINDOWPLACEMENT, WPF_ASYNCWINDOWPLACEMENT,
        },
    },
};

const WINDOW_WAIT: Duration = Duration::from_millis(750);
const COMPOSITOR_WAIT: Duration = Duration::from_millis(300);
const MAX_DIMENSION: i32 = 16_384;
const MAX_PIXELS: usize = 40_000_000;
const MAX_PNG_BYTES: usize = 12 * 1024 * 1024;

/// Capture only in response to the explicit screenshot command. The caller must
/// supply the terminal's top-level HWND; arbitrary windows and children are rejected.
pub(crate) fn capture_screen_below_terminal(terminal_hwnd: Option<isize>) -> Result<Vec<u8>> {
    let hwnd = terminal_hwnd
        .map(|handle| handle as HWND)
        .ok_or_else(|| anyhow!("the terminal window is unavailable for screen capture"))?;
    // Use physical monitor pixels independently of the console process's default
    // awareness. Declare this first so terminal restoration runs before DPI reset.
    let _dpi = ThreadDpiGuard::per_monitor_v2()?;
    let mut terminal = TerminalVisibilityGuard::new(hwnd)?;
    // Resolve the target before hiding: foreground focus changes when a window disappears.
    let rect = terminal_monitor_rect(hwnd)?;
    let (width, height, byte_count) = checked_dimensions(&rect)?;

    let capture = (|| {
        terminal.hide()?;
        wait_for_compositor()?;
        capture_monitor_rgba(&terminal, &rect, width, height, byte_count)
    })();
    // Restore before PNG encoding, including when capture failed. Drop retries restoration
    // if this explicit attempt fails or an earlier operation unwinds.
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

/// Only this calling thread changes awareness, for the duration of one capture.
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
        // The prior context is returned by Windows specifically for restoration.
        unsafe { SetThreadDpiAwarenessContext(self.original) };
    }
}

fn checked_dimensions(rect: &RECT) -> Result<(i32, i32, usize)> {
    let width = rect.right.checked_sub(rect.left).unwrap_or(0);
    let height = rect.bottom.checked_sub(rect.top).unwrap_or(0);
    if width <= 0 || height <= 0 || width > MAX_DIMENSION || height > MAX_DIMENSION {
        bail!("screen capture monitor dimensions are unsupported: {width} x {height}");
    }
    let pixels = (width as usize)
        .checked_mul(height as usize)
        .filter(|count| *count <= MAX_PIXELS)
        .ok_or_else(|| anyhow!("screen capture monitor exceeds the pixel limit"))?;
    let byte_count = pixels
        .checked_mul(4)
        .ok_or_else(|| anyhow!("screen capture buffer dimensions overflow"))?;
    Ok((width, height, byte_count))
}

fn terminal_monitor_rect(hwnd: HWND) -> Result<RECT> {
    let monitor = unsafe { MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST) };
    if monitor.is_null() {
        bail!("could not locate the terminal's screen capture monitor");
    }
    let mut info: MONITORINFO = unsafe { zeroed() };
    info.cbSize = size_of::<MONITORINFO>() as u32;
    if unsafe { GetMonitorInfoW(monitor, &mut info) } == 0 {
        return Err(io::Error::last_os_error()).context("could not inspect screen capture monitor");
    }
    Ok(info.rcMonitor)
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
    let foreground = unsafe { GetForegroundWindow() };
    if foreground.is_null() {
        foreground
    } else {
        unsafe { GetAncestor(foreground, GA_ROOT) }
    }
}

struct TerminalVisibilityGuard {
    hwnd: HWND,
    placement: WINDOWPLACEMENT,
    visible: bool,
    minimized: bool,
    maximized: bool,
    was_foreground: bool,
    thread_id: u32,
    process_id: u32,
    restore_needed: bool,
}

impl TerminalVisibilityGuard {
    fn new(hwnd: HWND) -> Result<Self> {
        if hwnd.is_null()
            || unsafe { IsWindow(hwnd) } == 0
            || unsafe { GetAncestor(hwnd, GA_ROOT) } != hwnd
            || !terminal_class(hwnd)
        {
            bail!("screen capture requires a valid top-level terminal window");
        }
        let mut process_id = 0;
        let thread_id = unsafe { GetWindowThreadProcessId(hwnd, &mut process_id) };
        if thread_id == 0 || process_id == 0 {
            bail!("could not verify the screen capture terminal owner");
        }
        let mut placement: WINDOWPLACEMENT = unsafe { zeroed() };
        placement.length = size_of::<WINDOWPLACEMENT>() as u32;
        if unsafe { GetWindowPlacement(hwnd, &mut placement) } == 0 {
            return Err(io::Error::last_os_error()).context("could not save terminal placement");
        }
        Ok(Self {
            hwnd,
            placement,
            visible: unsafe { IsWindowVisible(hwnd) } != 0,
            minimized: unsafe { IsIconic(hwnd) } != 0,
            maximized: unsafe { IsZoomed(hwnd) } != 0,
            was_foreground: foreground_root() == hwnd,
            thread_id,
            process_id,
            restore_needed: false,
        })
    }

    fn same_window(&self) -> bool {
        if unsafe { IsWindow(self.hwnd) } == 0
            || unsafe { GetAncestor(self.hwnd, GA_ROOT) } != self.hwnd
            || !terminal_class(self.hwnd)
        {
            return false;
        }
        let mut process_id = 0;
        let thread_id = unsafe { GetWindowThreadProcessId(self.hwnd, &mut process_id) };
        thread_id == self.thread_id && process_id == self.process_id
    }

    fn hide(&mut self) -> Result<()> {
        if !self.same_window() {
            bail!("the screen capture terminal is no longer available");
        }
        // Already hidden or minimized terminals have no pixels to remove. Preserve them.
        if !self.visible || self.minimized {
            return Ok(());
        }
        self.was_foreground = foreground_root() == self.hwnd;
        self.restore_needed = true;
        if unsafe { ShowWindowAsync(self.hwnd, SW_HIDE) } == 0 {
            return Err(io::Error::last_os_error())
                .context("could not hide terminal for screen capture");
        }
        let deadline = Instant::now() + WINDOW_WAIT;
        loop {
            if !self.same_window() {
                bail!("the terminal closed while preparing screen capture");
            }
            if unsafe { IsWindowVisible(self.hwnd) } == 0 {
                return Ok(());
            }
            if Instant::now() >= deadline {
                bail!("the terminal did not hide before the screen capture deadline");
            }
            thread::sleep(Duration::from_millis(10));
        }
    }

    fn verify_unobscured(&self) -> Result<()> {
        if !self.same_window() {
            bail!("the terminal closed during screen capture");
        }
        if unsafe { IsWindowVisible(self.hwnd) } != 0 && unsafe { IsIconic(self.hwnd) } == 0 {
            bail!("the terminal became visible before screen capture");
        }
        Ok(())
    }

    fn restore(&mut self) -> Result<()> {
        if !self.restore_needed {
            return Ok(());
        }
        if !self.same_window() {
            self.restore_needed = false;
            bail!("the original terminal no longer exists; its placement could not be restored");
        }
        let mut placement = self.placement;
        placement.flags |= WPF_ASYNCWINDOWPLACEMENT;
        if !self.was_foreground {
            // SW_HIDE preserves the existing normal/maximized size. Show that saved
            // placement without activating a terminal that was behind another app.
            placement.showCmd = SW_SHOWNA as u32;
        }
        if unsafe { SetWindowPlacement(self.hwnd, &placement) } == 0 {
            // Hiding does not move the window. A show-state fallback can still make
            // it visible if restoring its saved placement was rejected.
            let restore_error = io::Error::last_os_error();
            unsafe { ShowWindowAsync(self.hwnd, placement.showCmd as i32) };
            return Err(restore_error).context("could not restore terminal placement");
        }
        let deadline = Instant::now() + WINDOW_WAIT;
        loop {
            if !self.same_window() {
                self.restore_needed = false;
                bail!("the terminal closed while restoring its placement");
            }
            let visible = unsafe { IsWindowVisible(self.hwnd) } != 0;
            let minimized = unsafe { IsIconic(self.hwnd) } != 0;
            let maximized = unsafe { IsZoomed(self.hwnd) } != 0;
            let mut restored: WINDOWPLACEMENT = unsafe { zeroed() };
            restored.length = size_of::<WINDOWPLACEMENT>() as u32;
            if unsafe { GetWindowPlacement(self.hwnd, &mut restored) } == 0 {
                return Err(io::Error::last_os_error())
                    .context("could not verify restored terminal placement");
            }
            let original = self.placement.rcNormalPosition;
            let current = restored.rcNormalPosition;
            let position_restored = original.left == current.left
                && original.top == current.top
                && original.right == current.right
                && original.bottom == current.bottom;
            if visible == self.visible
                && minimized == self.minimized
                && maximized == self.maximized
                && position_restored
            {
                if self.was_foreground && foreground_root() != self.hwnd {
                    // Placement restores visibility; explicitly restore input focus
                    // only when this terminal owned it immediately before hiding.
                    unsafe { SetForegroundWindow(self.hwnd) };
                }
                if !self.was_foreground || foreground_root() == self.hwnd {
                    self.restore_needed = false;
                    return Ok(());
                }
            }
            if Instant::now() >= deadline {
                if self.was_foreground && foreground_root() != self.hwnd {
                    bail!(
                        "terminal visibility restored, but Windows did not restore its input focus"
                    );
                }
                bail!("the terminal did not restore before the screen capture deadline");
            }
            thread::sleep(Duration::from_millis(10));
        }
    }
}

impl Drop for TerminalVisibilityGuard {
    fn drop(&mut self) {
        let _ = self.restore();
    }
}

fn wait_for_compositor() -> Result<()> {
    // DwmFlush can wait for Present. Bound the caller's wait even if the compositor
    // stalls; this helper owns no window, graphics handles, or captured pixels.
    let (tx, rx) = mpsc::sync_channel(1);
    thread::Builder::new()
        .name("screen-capture-compositor".into())
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
    // The terminal belongs to its host process. Allow its hide event's composition
    // to settle too; DwmFlush alone only flushes this calling application's work.
    thread::sleep(Duration::from_millis(50));
    Ok(())
}

struct ScreenDc(HDC);
impl Drop for ScreenDc {
    fn drop(&mut self) {
        unsafe { ReleaseDC(ptr::null_mut(), self.0) };
    }
}

struct MemoryDc(HDC);
impl Drop for MemoryDc {
    fn drop(&mut self) {
        unsafe { DeleteDC(self.0) };
    }
}

struct Bitmap(HBITMAP);
impl Drop for Bitmap {
    fn drop(&mut self) {
        unsafe { DeleteObject(self.0 as HGDIOBJ) };
    }
}

struct SelectedBitmap {
    dc: HDC,
    previous: HGDIOBJ,
}
impl Drop for SelectedBitmap {
    fn drop(&mut self) {
        unsafe { SelectObject(self.dc, self.previous) };
    }
}

fn capture_monitor_rgba(
    terminal: &TerminalVisibilityGuard,
    rect: &RECT,
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
    info.bmiHeader.biHeight = -height; // Top-down rows, matching PNG order.
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
    // Reverse declaration order guarantees deselection before DeleteObject, then
    // DeleteDC, then ReleaseDC on every success/error path.
    let _selected = SelectedBitmap {
        dc: memory.0,
        previous,
    };
    terminal.verify_unobscured()?;
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
    // Synchronize GDI before dereferencing the DIB section's backing memory.
    if unsafe { GdiFlush() } == 0 {
        bail!("screen capture drawing could not be synchronized");
    }
    let mut rgba = Vec::new();
    rgba.try_reserve_exact(byte_count)
        .context("could not allocate screen capture pixel buffer")?;
    rgba.extend_from_slice(unsafe { std::slice::from_raw_parts(bits.cast::<u8>(), byte_count) });
    bgra_to_opaque_rgba(&mut rgba);
    Ok(rgba)
}

fn bgra_to_opaque_rgba(pixels: &mut [u8]) {
    for pixel in pixels.chunks_exact_mut(4) {
        pixel.swap(0, 2); // GDI BGRA -> PNG RGBA.
        pixel[3] = 255; // GDI's reserved alpha byte is not meaningful.
    }
}

#[derive(Default)]
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
    let mut output = PngBuffer::default();
    {
        let mut encoder = png::Encoder::new(&mut output, width, height);
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn png_preserves_screen_rows_colors_and_opaque_alpha() {
        // Two top-down GDI rows, with deliberately unusable reserved alpha bytes.
        let mut pixels = vec![
            0, 0, 255, 0, 255, 0, 0, 127, 0, 255, 0, 1, 255, 255, 255, 254,
        ];
        bgra_to_opaque_rgba(&mut pixels);
        let encoded = encode_png(&pixels, 2, 2).expect("screen pixels should encode");
        let decoder = png::Decoder::new(std::io::Cursor::new(encoded));
        let mut reader = decoder.read_info().expect("PNG header should decode");
        let mut decoded = vec![0; reader.output_buffer_size()];
        let frame = reader
            .next_frame(&mut decoded)
            .expect("PNG pixels should decode");
        assert_eq!((frame.width, frame.height), (2, 2));
        assert_eq!(frame.color_type, png::ColorType::Rgba);
        assert_eq!(frame.bit_depth, png::BitDepth::Eight);
        assert_eq!(
            &decoded[..frame.buffer_size()],
            &[255, 0, 0, 255, 0, 0, 255, 255, 0, 255, 0, 255, 255, 255, 255, 255,],
        );
    }

    #[test]
    fn monitor_layout_accepts_negative_origins_and_bounds_allocations() {
        let secondary = RECT {
            left: -1920,
            top: -200,
            right: 0,
            bottom: 880,
        };
        assert_eq!(
            checked_dimensions(&secondary).unwrap(),
            (1920, 1080, 8_294_400)
        );
        let enormous = RECT {
            left: i32::MIN,
            top: 0,
            right: i32::MAX,
            bottom: 1080,
        };
        assert!(checked_dimensions(&enormous).is_err());
        let excessive_pixels = RECT {
            left: 0,
            top: 0,
            right: 10_000,
            bottom: 10_000,
        };
        assert!(checked_dimensions(&excessive_pixels).is_err());
        let empty = RECT {
            left: 0,
            top: 10,
            right: 1920,
            bottom: 10,
        };
        assert!(checked_dimensions(&empty).is_err());
    }
}
