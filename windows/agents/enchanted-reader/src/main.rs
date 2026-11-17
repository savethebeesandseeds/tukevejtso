use anyhow::{anyhow, Context, Result};
use crossterm::{
    cursor,
    event::{self, Event, KeyCode, KeyEvent, KeyEventKind, KeyModifiers},
    execute, queue,
    style::{Color, Print, ResetColor, SetForegroundColor},
    terminal,
};
use enchanted_reader::{
    build_reader_request, default_settings_path, f8_gesture, gesture_label, gesture_warning,
    is_f8_gesture, list_instruction_files, load_instruction, load_settings, save_settings,
    send_reader_request, validate_gesture, validate_rectangle, wrap_text, Gesture, PixelRect,
    Portion, ReaderSettings, DEFAULT_MODEL, HTTP_TIMEOUT, MODELS,
};
use std::{
    collections::VecDeque,
    env,
    io::{self, Write},
    path::PathBuf,
    time::Duration,
};

#[cfg(windows)]
mod capture;

fn main() {
    let result = {
        #[cfg(windows)]
        {
            run_windows()
        }
        #[cfg(not(windows))]
        {
            Err(anyhow!("Enchanted Reader runs on Windows."))
        }
    };
    if let Err(err) = result {
        let _ = terminal::disable_raw_mode();
        let _ = execute!(io::stdout(), cursor::Show, terminal::LeaveAlternateScreen);
        eprintln!("Enchanted Reader: {err:#}");
        std::process::exit(1);
    }
}

#[cfg(windows)]
struct Cli {
    agent_root: Option<PathBuf>,
    terminal_hwnd: Option<isize>,
}

#[cfg(windows)]
fn parse_cli() -> Result<Cli> {
    let mut cli = Cli {
        agent_root: None,
        terminal_hwnd: None,
    };
    let mut args = env::args().skip(1);
    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--agent-root" => {
                cli.agent_root = Some(PathBuf::from(
                    args.next().ok_or_else(|| anyhow!("--agent-root needs a path"))?,
                ));
            }
            "--terminal-window-handle" => {
                let raw = args
                    .next()
                    .ok_or_else(|| anyhow!("--terminal-window-handle needs a number"))?;
                let handle = raw
                    .parse::<isize>()
                    .with_context(|| format!("invalid terminal window handle {raw}"))?;
                if handle != 0 {
                    cli.terminal_hwnd = Some(handle);
                }
            }
            other => bail_arg(other)?,
        }
    }
    Ok(cli)
}

fn bail_arg(arg: &str) -> Result<()> {
    Err(anyhow!("unknown argument {arg}"))
}

#[cfg(windows)]
fn run_windows() -> Result<()> {
    let cli = parse_cli()?;
    let agent_root = cli.agent_root.or_else(|| {
        let exe = env::current_exe().ok()?;
        exe.ancestors().skip(1).take(3)
            .find(|path| path.join("instructions").is_dir() && path.join("Cargo.toml").is_file())
            .map(|path| path.to_owned())
    }).unwrap_or(env::current_dir()?);
    let instructions_dir = agent_root.join("instructions");
    let settings_path = default_settings_path().unwrap_or_else(|| {
        agent_root.join("enchanted-reader-settings.json")
    });
    let (settings, settings_warning) = load_settings(&settings_path);
    let api_key = env::var("OPENAI_API_KEY").unwrap_or_default();
    let api_key = api_key.trim().to_string();
    let hwnd = cli
        .terminal_hwnd
        .filter(|hwnd| capture::terminal_hwnd_usable(*hwnd))
        .or_else(capture::attached_terminal);
    let mut app = App::new(
        instructions_dir,
        settings_path,
        settings,
        api_key,
        hwnd,
        settings_warning,
    )?;
    app.run()
}

#[cfg(windows)]
struct App {
    instructions_dir: PathBuf,
    settings_path: PathBuf,
    api_key: String,
    hwnd: Option<isize>,
    files: Vec<PathBuf>,
    file_index: usize,
    path_entry: Option<String>,
    portion_index: usize,
    rectangle: Option<(String, PixelRect)>,
    gesture: Option<Gesture>,
    gesture_index: usize,
    model_index: usize,
    copy_answer: bool,
    notice: String,
    confirm_ready: bool,
    screen: Screen,
    f8_hotkey: Option<capture::Hotkey>,
    hotkey: Option<capture::Hotkey>,
    pending_keys: VecDeque<KeyEvent>,
    answers: Vec<String>,
    selection: usize,
    follow: bool,
    scroll: usize,
    requests: u32,
    status: String,
    client: reqwest::blocking::Client,
}

#[cfg(windows)]
#[derive(Clone, Copy)]
enum Screen {
    Blocked,
    Connect,
    Instruction,
    Portion,
    Gesture,
    Confirm(Gesture),
    Model,
    Clipboard,
    Review,
    Armed,
}

#[cfg(windows)]
impl App {
    fn new(
        instructions_dir: PathBuf,
        settings_path: PathBuf,
        settings: ReaderSettings,
        api_key: String,
        hwnd: Option<isize>,
        settings_warning: Option<String>,
    ) -> Result<Self> {
        let model_index = MODELS
            .iter()
            .position(|model| *model == settings.model)
            .unwrap_or(1);
        let portion_index = match &settings.portion {
            Portion::Monitor => 0,
            Portion::Rectangle { .. } => 1,
            Portion::ForegroundWindow => 2,
        };
        let rectangle = match settings.portion {
            Portion::Rectangle {
                monitor_device,
                rect,
            } => Some((monitor_device, rect)),
            _ => None,
        };
        let screen = if api_key.is_empty() {
            Screen::Blocked
        } else if hwnd.is_none() {
            Screen::Connect
        } else {
            Screen::Instruction
        };
        let mut app = Self {
            instructions_dir,
            settings_path,
            api_key,
            hwnd,
            files: Vec::new(),
            file_index: 0,
            path_entry: None,
            portion_index,
            rectangle,
            gesture: settings.gesture,
            gesture_index: usize::from(
                settings
                    .gesture
                    .is_some_and(|gesture| !is_f8_gesture(&gesture)),
            ),
            model_index,
            copy_answer: settings.copy_answer,
            notice: settings_warning.unwrap_or_default(),
            confirm_ready: false,
            screen,
            f8_hotkey: None,
            hotkey: None,
            pending_keys: VecDeque::new(),
            answers: Vec::new(),
            selection: 0,
            follow: true,
            scroll: 0,
            requests: 0,
            status: "armed".to_string(),
            client: reqwest::blocking::Client::builder()
                .timeout(HTTP_TIMEOUT)
                .build()
                .context("could not prepare the OpenAI client")?,
        };
        app.refresh_files(settings.instruction_path);
        Ok(app)
    }

    fn refresh_files(&mut self, preferred: Option<PathBuf>) {
        self.files = list_instruction_files(&self.instructions_dir).unwrap_or_default();
        if let Some(path) = preferred {
            if !self.files.iter().any(|candidate| candidate == &path) && path.is_file() {
                self.files.push(path.clone());
            }
            if let Some(index) = self.files.iter().position(|candidate| candidate == &path) {
                self.file_index = index;
            }
        }
        if self.file_index >= self.files.len() {
            self.file_index = 0;
        }
    }

    fn run(&mut self) -> Result<()> {
        if matches!(self.screen, Screen::Instruction) {
            self.register_f8();
        }
        terminal::enable_raw_mode()?;
        if let Err(err) = execute!(io::stdout(), terminal::EnterAlternateScreen, cursor::Hide) {
            let _ = terminal::disable_raw_mode();
            return Err(err.into());
        }
        let _ui = UiGuard;
        self.draw()?;
        loop {
            self.note_shortcut_release();
            // WM_HOTKEY arrives on this thread even when the terminal is not
            // focused. Wait on the console and the thread queue together, and
            // do not activate the terminal to hear the shortcut.
            let key = if let Some(key) = self.pending_keys.pop_front() {
                key
            } else {
                let triggers = self.armed_trigger_ids();
                if capture::wait_for_console_or_messages(Duration::from_millis(30), &triggers) {
                    self.capture_and_send()?;
                    continue;
                }
                if !event::poll(Duration::ZERO)? {
                    continue;
                }
                match event::read()? {
                    Event::Key(key) => key,
                    Event::Resize(_, _) => { self.draw()?; continue; }
                    _ => continue,
                }
            };
            if key.kind != KeyEventKind::Press {
                continue;
            }
            if key.modifiers.contains(KeyModifiers::CONTROL)
                && matches!(key.code, KeyCode::Char('c') | KeyCode::Char('C'))
            {
                break;
            }
            if self.confirm_waiting(&key) {
                continue;
            }
            if self.handle_key(key)? {
                break;
            }
        }
        Ok(())
    }

    fn handle_key(&mut self, key: KeyEvent) -> Result<bool> {
        if let Some(entry) = self.path_entry.as_mut() {
            match key.code {
                KeyCode::Esc => self.path_entry = None,
                KeyCode::Backspace => {
                    entry.pop();
                }
                KeyCode::Enter => {
                    let path = PathBuf::from(entry.trim().trim_matches('"'));
                    self.path_entry = None;
                    match load_instruction(&path) {
                        Ok(_) => {
                            if !self.files.iter().any(|candidate| candidate == &path) {
                                self.files.push(path.clone());
                            }
                            self.file_index = self
                                .files
                                .iter()
                                .position(|candidate| candidate == &path)
                                .unwrap_or(0);
                            self.notice.clear();
                        }
                        Err(err) => self.notice = err.to_string(),
                    }
                }
                KeyCode::Char(ch) => entry.push(ch),
                _ => {}
            }
            self.draw()?;
            return Ok(false);
        }

        match self.screen {
            Screen::Blocked => {
                if key.code == KeyCode::Esc {
                    return Ok(true);
                }
            }
            Screen::Connect => match key.code {
                KeyCode::Esc => return Ok(true),
                KeyCode::Enter => {
                    if let Some(hwnd) = capture::terminal_on_setup_key() {
                        self.hwnd = Some(hwnd);
                        self.screen = Screen::Instruction;
                        self.notice.clear();
                        self.register_f8();
                    } else if env::var_os("ENCHANTED_READER_DEDICATED_CONSOLE").is_none() {
                        let host = PathBuf::from(env::var_os("SystemRoot").context("Windows directory unavailable")?)
                            .join("System32").join("conhost.exe");
                        let root = self.instructions_dir.parent().context("missing reader directory")?;
                        match std::process::Command::new(host).arg(env::current_exe()?)
                            .arg("--agent-root").arg(root)
                            .env("ENCHANTED_READER_DEDICATED_CONSOLE", "1").spawn() {
                            Ok(_) => return Ok(true),
                            Err(err) => self.notice = format!("Could not open Console Host: {err}"),
                        }
                    } else {
                        self.notice = "Click this Console Host window and press Enter to retry.".into();
                    }
                }
                _ => {}
            },
            Screen::Instruction => match key.code {
                KeyCode::Esc => return Ok(true),
                KeyCode::Up => self.move_file(-1),
                KeyCode::Down => self.move_file(1),
                KeyCode::Char('p') | KeyCode::Char('P') => self.path_entry = Some(String::new()),
                KeyCode::Enter => match self.files.get(self.file_index).cloned() {
                    Some(path) => match load_instruction(&path) {
                        Ok(_) => {
                            self.screen = Screen::Portion;
                            self.notice.clear();
                            self.refresh_rectangle();
                        }
                        Err(err) => self.notice = err.to_string(),
                    },
                    None => {
                        self.notice =
                            "Choose an instruction file, or press P and type a path.".to_string();
                    }
                },
                _ => {}
            },
            Screen::Portion => match key.code {
                KeyCode::Esc => self.screen = Screen::Instruction,
                KeyCode::Up => self.portion_index = (self.portion_index + 2) % 3,
                KeyCode::Down => self.portion_index = (self.portion_index + 1) % 3,
                KeyCode::Char('r') | KeyCode::Char('R') if self.portion_index == 1 => {
                    self.pick_rectangle()?;
                }
                KeyCode::Char('c') | KeyCode::Char('C')
                    if !key.modifiers.contains(KeyModifiers::CONTROL)
                        && self.portion_index == 1
                        && self.rectangle.is_some() =>
                {
                    self.screen = Screen::Gesture;
                    self.notice.clear();
                }
                KeyCode::Enter => self.advance_portion()?,
                _ => {}
            },
            Screen::Gesture => match key.code {
                KeyCode::Esc => self.screen = Screen::Portion,
                KeyCode::Up | KeyCode::Down if self.extra_gesture().is_some() => {
                    self.gesture_index ^= 1;
                }
                KeyCode::Enter => {
                    if self.gesture_index == 0 || self.extra_gesture().is_none() {
                        self.gesture = Some(f8_gesture());
                        self.gesture_index = 0;
                    }
                    self.screen = Screen::Model;
                    self.notice.clear();
                }
                _ => {
                    if let Some(gesture) = capture::gesture_from_key(&key) {
                        match validate_gesture(&gesture) {
                            Ok(()) => {
                                self.notice = gesture_warning(&gesture).unwrap_or("").to_string();
                                self.confirm_ready = false;
                                self.screen = Screen::Confirm(gesture);
                            }
                            Err(err) => self.notice = err.to_string(),
                        }
                    }
                }
            },
            Screen::Confirm(pending) => match key.code {
                KeyCode::Esc => {
                    self.confirm_ready = false;
                    self.screen = Screen::Gesture;
                }
                _ => {
                    if let Some(gesture) = capture::gesture_from_key(&key) {
                        // Ignore presses still queued from the key that was just released.
                        if capture::virtual_key_is_down(gesture.virtual_key) {
                            if gesture == pending && validate_gesture(&gesture).is_ok() {
                                self.gesture_index = usize::from(!is_f8_gesture(&gesture));
                                self.gesture = Some(gesture);
                                self.confirm_ready = false;
                                self.screen = Screen::Model;
                                self.notice.clear();
                            } else {
                                self.notice =
                                    "Press the same shortcut again to confirm it.".to_string();
                            }
                        }
                    }
                }
            },
            Screen::Model => match key.code {
                KeyCode::Esc => self.screen = Screen::Gesture,
                KeyCode::Up => {
                    self.model_index = (self.model_index + MODELS.len() - 1) % MODELS.len();
                }
                KeyCode::Down => self.model_index = (self.model_index + 1) % MODELS.len(),
                KeyCode::Enter => {
                    self.screen = Screen::Clipboard;
                    self.notice.clear();
                }
                _ => {}
            },
            Screen::Clipboard => match key.code {
                KeyCode::Esc => self.screen = Screen::Model,
                KeyCode::Up | KeyCode::Down | KeyCode::Left | KeyCode::Right | KeyCode::Char(' ') => {
                    self.copy_answer = !self.copy_answer;
                }
                KeyCode::Enter => {
                    self.screen = Screen::Review;
                    self.notice.clear();
                }
                _ => {}
            },
            Screen::Review => match key.code {
                KeyCode::Esc => self.screen = Screen::Clipboard,
                KeyCode::Enter => self.arm()?,
                _ => {}
            },
            Screen::Armed => match key.code {
                KeyCode::Esc => return Ok(true),
                KeyCode::Char('s') | KeyCode::Char('S') => {
                    self.hotkey = None;
                    self.screen = Screen::Instruction;
                    self.notice.clear();
                }
                KeyCode::Up => self.history_step(-1),
                KeyCode::Down => self.history_step(1),
                KeyCode::Home => {
                    self.selection = 0;
                    self.follow = self.answers.is_empty();
                    self.scroll = 0;
                }
                KeyCode::End => self.follow_latest(),
                KeyCode::PageUp => self.scroll = self.scroll.saturating_sub(8),
                KeyCode::PageDown => self.scroll = self.scroll.saturating_add(8),
                KeyCode::Enter => self.capture_and_send()?,
                _ => {}
            },
        }
        self.draw()?;
        Ok(false)
    }

    fn move_file(&mut self, delta: isize) {
        if self.files.is_empty() {
            return;
        }
        let len = self.files.len() as isize;
        self.file_index = ((self.file_index as isize + delta).rem_euclid(len)) as usize;
    }

    fn selected_instruction(&self) -> Option<PathBuf> {
        let path = self.files.get(self.file_index)?.clone();
        load_instruction(&path).ok()?;
        Some(path)
    }

    fn refresh_rectangle(&mut self) {
        let Some((device, rect)) = self.rectangle.clone() else {
            return;
        };
        let monitors = capture::monitors().unwrap_or_default();
        if let Err(err) = validate_rectangle(&device, rect, &monitors) {
            self.rectangle = None;
            self.notice = err.to_string();
        }
    }

    fn advance_portion(&mut self) -> Result<()> {
        if self.portion_index == 1 && !self.pick_rectangle()? {
            return Ok(());
        }
        self.screen = Screen::Gesture;
        self.notice.clear();
        Ok(())
    }

    fn pick_rectangle(&mut self) -> Result<bool> {
        let Some(hwnd) = self.hwnd else {
            self.notice = "The terminal window is not available for a rectangle.".to_string();
            return Ok(false);
        };
        let monitor = match capture::monitor_for_window(hwnd) {
            Ok(monitor) => monitor,
            Err(err) => {
                self.notice = err.to_string();
                return Ok(false);
            }
        };
        let accepted = match capture::pick_rectangle(hwnd, &monitor) {
            Ok(Some(rect)) => {
                self.rectangle = Some((monitor.device, rect));
                self.portion_index = 1;
                self.notice.clear();
                true
            }
            Ok(None) => {
                self.notice = if self.rectangle.is_some() {
                    "Rectangle selection was cancelled. The previous rectangle is unchanged."
                        .to_string()
                } else {
                    "Rectangle selection was cancelled.".to_string()
                };
                false
            }
            Err(err) => {
                self.notice = err.to_string();
                false
            }
        };
        Ok(accepted)
    }

    fn current_portion(&self) -> Result<Portion> {
        match self.portion_index {
            0 => Ok(Portion::Monitor),
            2 => Ok(Portion::ForegroundWindow),
            _ => {
                let (monitor_device, rect) = self
                    .rectangle
                    .clone()
                    .ok_or_else(|| anyhow!("choose a rectangle before arming"))?;
                let monitors = capture::monitors()?;
                validate_rectangle(&monitor_device, rect, &monitors)
                    .map_err(|err| anyhow!(err))?;
                Ok(Portion::Rectangle {
                    monitor_device,
                    rect,
                })
            }
        }
    }

    fn note_shortcut_release(&mut self) {
        let Screen::Confirm(pending) = self.screen else {
            return;
        };
        if !self.confirm_ready && !capture::virtual_key_is_down(pending.virtual_key) {
            self.confirm_ready = true;
        }
    }

    fn confirm_waiting(&self, key: &KeyEvent) -> bool {
        matches!(self.screen, Screen::Confirm(_))
            && !self.confirm_ready
            && !matches!(key.code, KeyCode::Esc)
    }

    fn arm(&mut self) -> Result<()> {
        let Some(instruction) = self.selected_instruction() else {
            self.notice = "Choose an instruction file before arming.".to_string();
            self.screen = Screen::Instruction;
            self.draw()?;
            return Ok(());
        };
        let portion = match self.current_portion() {
            Ok(portion) => portion,
            Err(err) => {
                self.notice = err.to_string();
                self.screen = Screen::Portion;
                self.draw()?;
                return Ok(());
            }
        };
        let Some(gesture) = self.gesture else {
            self.notice = "Press a shortcut before arming.".to_string();
            self.screen = Screen::Gesture;
            self.draw()?;
            return Ok(());
        };
        if let Err(err) = validate_gesture(&gesture) {
            self.notice = err.to_string();
            self.screen = Screen::Gesture;
            self.draw()?;
            return Ok(());
        }
        let settings = ReaderSettings {
            instruction_path: Some(instruction),
            portion,
            gesture: Some(gesture),
            model: MODELS[self.model_index].to_string(),
            copy_answer: self.copy_answer,
        };
        let extra = if is_f8_gesture(&gesture) {
            if self.f8_hotkey.is_none() {
                match capture::Hotkey::register_f8() {
                    Ok(hotkey) => self.f8_hotkey = Some(hotkey),
                    Err(err) => {
                        self.notice = err.to_string();
                        self.screen = Screen::Gesture;
                        self.draw()?;
                        return Ok(());
                    }
                }
            }
            None
        } else {
            match capture::Hotkey::register(&gesture) {
                Ok(hotkey) => Some(hotkey),
                Err(err) => {
                    self.notice = err.to_string();
                    self.screen = Screen::Gesture;
                    self.draw()?;
                    return Ok(());
                }
            }
        };
        if let Err(err) = save_settings(&self.settings_path, &settings) {
            self.notice = err.to_string();
            self.draw()?;
            return Ok(());
        }
        self.hotkey = extra;
        self.screen = Screen::Armed;
        self.status = if self.f8_hotkey.is_some() { "armed" } else { "F8 unavailable" }.into();
        self.notice.clear();
        self.draw()?;
        Ok(())
    }

    fn register_f8(&mut self) {
        if self.f8_hotkey.is_some() {
            return;
        }
        match capture::Hotkey::register_f8() {
            Ok(hotkey) => self.f8_hotkey = Some(hotkey),
            Err(err) => {
                let message = err.to_string();
                if self.notice.is_empty() {
                    self.notice = message;
                } else {
                    self.notice = format!("{message} {}", self.notice);
                }
            }
        }
    }

    fn armed_trigger_ids(&self) -> Vec<i32> {
        let mut ids = Vec::with_capacity(2);
        if matches!(self.screen, Screen::Armed) {
            if let Some(hotkey) = &self.f8_hotkey {
                ids.push(hotkey.id());
            }
            if let Some(hotkey) = &self.hotkey {
                ids.push(hotkey.id());
            }
        }
        ids
    }

    fn extra_gesture(&self) -> Option<Gesture> {
        self.gesture
            .filter(|gesture| !is_f8_gesture(gesture))
    }

    fn shortcut_label(&self) -> String {
        match self.extra_gesture() {
            Some(gesture) if self.f8_hotkey.is_some() => {
                format!("F8 and {}", gesture_label(&gesture))
            }
            Some(gesture) => gesture_label(&gesture),
            None if self.f8_hotkey.is_some() || self.gesture.is_some_and(|gesture| is_f8_gesture(&gesture)) => {
                "F8".to_string()
            }
            None => "none".to_string(),
        }
    }

    fn capture_and_send(&mut self) -> Result<()> {
        if !matches!(self.screen, Screen::Armed) {
            return Ok(());
        }
        self.status = "capturing".to_string();
        self.draw()?;
        match self.request_answer() {
            Ok(response) => {
                if self.copy_answer {
                    if let Err(err) = capture::copy_answer(self.hwnd.unwrap_or_default(), &response.text) {
                        self.status = format!("answer ready, clipboard failed: {err:#}");
                    } else {
                        self.status = "armed, answer copied".to_string();
                    }
                } else {
                    self.status = "armed".to_string();
                }
                if let (Some(input), Some(output)) = (response.input_tokens, response.output_tokens)
                {
                    self.status = format!("{}; tokens in {input} / out {output}", self.status);
                }
                self.answers.push(response.text);
                if self.follow {
                    self.follow_latest();
                }
            }
            Err(err) => self.status = err.to_string(),
        }
        let mut ignored = capture::drain_hotkeys(&self.armed_trigger_ids());
        while event::poll(Duration::ZERO)? {
            if let Event::Key(key) = event::read()? {
                if key.kind == KeyEventKind::Press {
                    if key.code == KeyCode::Enter {
                        ignored = true;
                    } else {
                        self.pending_keys.push_back(key);
                    }
                }
            }
        }
        if ignored {
            self.status = format!("ignored a shortcut while busy; {}", self.status);
        }
        self.draw()?;
        Ok(())
    }

    fn request_answer(&mut self) -> Result<enchanted_reader::ReaderResponse> {
        let path = self.files.get(self.file_index).context("choose an instruction file")?;
        let instruction = load_instruction(path)?;
        let hwnd = self.hwnd.context("the terminal window is not available")?;
        let (rect, foreground) = self.capture_rect(hwnd)?;
        let mut png = capture::capture_png(hwnd, rect, foreground)?;
        let request = build_reader_request(MODELS[self.model_index], &instruction, &png);
        png.fill(0);
        drop(png);
        let body = request?;
        self.status = "sending".into();
        self.draw()?;
        self.requests = self.requests.saturating_add(1);
        send_reader_request(&self.client, &self.api_key, &body)
    }

    fn capture_rect(&self, hwnd: isize) -> Result<(PixelRect, Option<isize>)> {
        match self.portion_index {
            0 => Ok((capture::monitor_for_window(hwnd)?.bounds, None)),
            2 => capture::foreground_window_rect(hwnd).map(|(rect, window)| (rect, Some(window))),
            _ => {
                let (device, rect) = self
                    .rectangle
                    .clone()
                    .ok_or_else(|| anyhow!("the saved rectangle is missing"))?;
                let monitors = capture::monitors()?;
                validate_rectangle(&device, rect, &monitors).map_err(|err| anyhow!(err))?;
                Ok((rect, None))
            }
        }
    }

    fn history_step(&mut self, delta: isize) {
        if self.answers.is_empty() {
            return;
        }
        let next = self.selection as isize + delta;
        if next < 0 || next >= self.answers.len() as isize {
            return;
        }
        self.selection = next as usize;
        self.follow = self.selection + 1 == self.answers.len();
        self.scroll = 0;
    }

    fn follow_latest(&mut self) {
        if self.answers.is_empty() {
            self.selection = 0;
            self.follow = true;
            return;
        }
        self.selection = self.answers.len() - 1;
        self.follow = true;
        self.scroll = 0;
    }

    fn draw(&mut self) -> Result<()> {
        let (term_width, term_height) = terminal::size().unwrap_or((80, 24));
        let width = (term_width as usize).saturating_sub(1).max(1);
        let height = usize::from(term_height).max(1);
        let status = self.status_row(width);
        let reserved = 3 + usize::from(status.is_some());
        let body_rows = height.saturating_sub(reserved).max(1);
        let mut rows = vec![self.header(width), StyledLine::plain("", Color::White)];
        self.extend_body(&mut rows, width, body_rows);
        let footer = self.footer();
        self.present(rows, status, &footer, width, height)
    }

    fn header(&self, width: usize) -> StyledLine {
        let title = "Enchanted Reader";
        let (marker, color) = self.header_marker();
        let title_width = title.chars().count();
        let marker_width = marker.chars().count();
        if marker_width == 0 || title_width + 1 + marker_width > width {
            return StyledLine::plain(fit(title, width), Color::DarkGrey);
        }
        StyledLine {
            segments: vec![
                segment(title, Color::DarkGrey),
                segment(" ".repeat(width - title_width - marker_width), Color::DarkGrey),
                segment(marker, color),
            ],
        }
    }

    fn header_marker(&self) -> (&'static str, Color) {
        match self.screen {
            Screen::Blocked => ("\u{25cf} stopped", Color::Red),
            Screen::Connect => ("Setup", Color::Cyan),
            Screen::Armed if self.status.starts_with("capturing") => {
                ("\u{25cf} capturing", Color::Yellow)
            }
            Screen::Armed if self.status.starts_with("sending") => ("\u{25cf} sending", Color::Red),
            Screen::Armed if self.status.starts_with("armed") => ("\u{25cf} armed", Color::Cyan),
            Screen::Armed => ("\u{25cf} check", Color::Yellow),
            Screen::Instruction => ("Instruction", Color::DarkGrey),
            Screen::Portion => ("Portion", Color::DarkGrey),
            Screen::Gesture => ("Shortcut", Color::DarkGrey),
            Screen::Confirm(_) => ("Confirm", Color::DarkGrey),
            Screen::Model => ("Model", Color::DarkGrey),
            Screen::Clipboard => ("Clipboard", Color::DarkGrey),
            Screen::Review => ("Review", Color::DarkGrey),
        }
    }

    fn footer(&self) -> String {
        if self.path_entry.is_some() {
            return "Enter opens the file    Esc cancels".to_string();
        }
        let text = match self.screen {
            Screen::Blocked => "Esc quit",
            Screen::Connect => "Enter connect    Esc quit",
            Screen::Instruction => "Up/Down select    Enter continue    P type a path    Esc quit",
            Screen::Portion if self.portion_index == 1 && self.rectangle.is_some() => {
                "Up/Down select    Enter new rectangle    C keep saved    Esc back"
            }
            Screen::Portion if self.portion_index == 1 => {
                "Up/Down select    Enter draws a rectangle    Esc back"
            }
            Screen::Portion => "Up/Down select    Enter continue    Esc back",
            Screen::Gesture if self.extra_gesture().is_some() => {
                "Up/Down select    Enter continue    press a shortcut to replace    Esc back"
            }
            Screen::Gesture => "Enter uses F8    press a shortcut to add one    Esc back",
            Screen::Confirm(_) => "Esc back",
            Screen::Model => "Up/Down select    Enter continue    Esc back",
            Screen::Clipboard => "Up/Down toggle    Enter continue    Esc back",
            Screen::Review => "Enter arms the reader    Esc back",
            Screen::Armed => {
                "Enter capture    S setup    Up/Down history    PgUp/PgDn scroll    End latest    Esc quit"
            }
        };
        text.to_string()
    }

    fn status_row(&self, width: usize) -> Option<StyledLine> {
        if !self.notice.is_empty() {
            return Some(StyledLine::plain(fit(&self.notice, width), Color::Yellow));
        }
        if matches!(self.screen, Screen::Armed) && !self.status.is_empty() {
            let quiet = self.status.starts_with("armed")
                || self.status == "capturing"
                || self.status == "sending";
            let color = if quiet { Color::DarkGrey } else { Color::Yellow };
            return Some(StyledLine::plain(fit(&self.status, width), color));
        }
        None
    }

    fn extend_body(&mut self, rows: &mut Vec<StyledLine>, width: usize, body_rows: usize) {
        match self.screen {
            Screen::Blocked => self.extend_blocked(rows, width),
            Screen::Connect => push_wrapped(rows, "Press Enter here to connect this terminal. Embedded terminals open a dedicated reader window.", width, Color::White),
            Screen::Instruction => self.extend_instruction(rows, width),
            Screen::Portion => self.extend_portion(rows, width),
            Screen::Gesture => self.extend_gesture(rows, width),
            Screen::Confirm(gesture) => self.extend_confirm(rows, width, gesture),
            Screen::Model => self.extend_model(rows, width),
            Screen::Clipboard => self.extend_clipboard(rows, width),
            Screen::Review => self.extend_review(rows, width),
            Screen::Armed => self.extend_armed(rows, width, body_rows),
        }
    }

    fn extend_blocked(&self, rows: &mut Vec<StyledLine>, width: usize) {
        if self.api_key.is_empty() {
            push_wrapped(
                rows,
                "An OpenAI API key is not available. Run tk openai-key, then start again.",
                width,
                Color::Yellow,
            );
            rows.push(StyledLine::plain("", Color::White));
        }
    }

    fn extend_instruction(&self, rows: &mut Vec<StyledLine>, width: usize) {
        let mut choices = Vec::new();
        if self.files.is_empty() {
            choices.push(StyledLine::plain(
                "No .md files in the instructions folder.",
                Color::DarkGrey,
            ));
        }
        for (index, path) in self.files.iter().enumerate() {
            let name = path
                .file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("instruction.md");
            choices.push(choice(index == self.file_index, name));
        }
        let mut detail = vec![StyledLine::plain("Preview", Color::Yellow)];
        if let Some(entry) = &self.path_entry {
            detail.push(StyledLine {
                segments: vec![
                    segment("Path  ", Color::DarkGrey),
                    segment(entry.clone(), Color::White),
                    segment("\u{258c}", Color::Cyan),
                ],
            });
            detail.push(StyledLine::plain("", Color::White));
        }
        let preview_width = detail_width(width);
        if let Some(path) = self.files.get(self.file_index) {
            match load_instruction(path) {
                Ok(text) => {
                    for line in wrap_text(&text, preview_width.max(1)).into_iter().take(12) {
                        detail.push(StyledLine::plain(line, Color::DarkGrey));
                    }
                }
                Err(_) => detail.push(StyledLine::plain(
                    "The selected file could not be read.",
                    Color::DarkGrey,
                )),
            }
        }
        rows.extend(columns(choices, detail, width));
    }

    fn extend_portion(&self, rows: &mut Vec<StyledLine>, width: usize) {
        let rectangle = self
            .rectangle
            .as_ref()
            .map(|(device, rect)| format!("{}x{} on {device}", rect.width(), rect.height()))
            .unwrap_or_else(|| "not chosen yet".to_string());
        let choices = vec![
            choice_field(self.portion_index == 0, "This monitor", ""),
            choice_field(self.portion_index == 1, "Fixed rectangle", &rectangle),
            choice_field(self.portion_index == 2, "Foreground window", ""),
        ];
        let help = match self.portion_index {
            0 => "Uses the monitor that contains this terminal.",
            1 if self.rectangle.is_some() => {
                "That size is the previous rectangle. Enter draws a different one and replaces it. C keeps it. R draws one and stays on this screen. Cancelling the drag keeps it too."
            }
            1 => {
                "Enter draws a rectangle on this monitor. Release the mouse to keep it. Right-click or Esc cancels."
            }
            _ => "Uses the window in front at the moment of the shortcut.",
        };
        let mut detail = vec![StyledLine::plain("Portion", Color::Yellow)];
        push_wrapped(&mut detail, help, detail_width(width), Color::DarkGrey);
        rows.extend(columns(choices, detail, width));
    }

    fn extend_gesture(&self, rows: &mut Vec<StyledLine>, width: usize) {
        let extra = self.extra_gesture();
        let mut choices = vec![choice_field(
            self.gesture_index == 0 || extra.is_none(),
            "F8",
            "built in",
        )];
        if let Some(gesture) = extra {
            choices.push(choice_field(
                self.gesture_index == 1,
                &gesture_label(&gesture),
                "saved",
            ));
        }
        let mut detail = vec![StyledLine::plain("Shortcut", Color::Yellow)];
        push_wrapped(
            &mut detail,
            "F8 is registered when the reader starts and is not delivered to the window in front. Enter on F8 uses only F8. Enter on a saved shortcut keeps that shortcut as well. Press a shortcut to replace the saved one. Letters and digits need Ctrl, Alt, or the Windows key.",
            detail_width(width),
            Color::DarkGrey,
        );
        rows.extend(columns(choices, detail, width));
    }

    fn extend_confirm(&self, rows: &mut Vec<StyledLine>, width: usize, gesture: Gesture) {
        let label = gesture_label(&gesture);
        push_wrapped(
            rows,
            &format!("Release it, then press {label} again to confirm."),
            width,
            Color::White,
        );
        if let Some(warning) = gesture_warning(&gesture) {
            rows.push(StyledLine::plain("", Color::White));
            push_wrapped(rows, warning, width, Color::Yellow);
        }
    }

    fn extend_model(&self, rows: &mut Vec<StyledLine>, width: usize) {
        let choices = MODELS
            .iter()
            .enumerate()
            .map(|(index, model)| {
                let note = if *model == DEFAULT_MODEL {
                    "default"
                } else {
                    ""
                };
                choice_field(index == self.model_index, model, note)
            })
            .collect();
        let mut detail = vec![StyledLine::plain("Model", Color::Yellow)];
        push_wrapped(
            &mut detail,
            "gpt-5.6-terra is the default. The choice is saved with the other answers.",
            detail_width(width),
            Color::DarkGrey,
        );
        rows.extend(columns(choices, detail, width));
    }

    fn extend_clipboard(&self, rows: &mut Vec<StyledLine>, width: usize) {
        let choices = vec![choice_field(
            true,
            "Copy the answer",
            if self.copy_answer { "on" } else { "off" },
        )];
        let mut detail = vec![StyledLine::plain("Clipboard", Color::Yellow)];
        push_wrapped(
            &mut detail,
            "Only the answer text is copied. The screenshot is never copied or saved.",
            detail_width(width),
            Color::DarkGrey,
        );
        rows.extend(columns(choices, detail, width));
    }

    fn extend_review(&self, rows: &mut Vec<StyledLine>, width: usize) {
        let instruction = self
            .selected_instruction()
            .map(|path| path.display().to_string())
            .unwrap_or_else(|| "none".to_string());
        let portion = self
            .current_portion()
            .map(|portion| portion.label())
            .unwrap_or_else(|err| err.to_string());
        let shortcut = self.shortcut_label();
        rows.push(field("Instruction", &fit(&instruction, width)));
        rows.push(field("Portion", &fit(&portion, width)));
        rows.push(field("Shortcut", &shortcut));
        rows.push(field("Model", MODELS[self.model_index]));
        rows.push(field(
            "Clipboard",
            if self.copy_answer { "on" } else { "off" },
        ));
    }

    fn extend_armed(&mut self, rows: &mut Vec<StyledLine>, width: usize, body_rows: usize) {
        let instruction = self
            .files
            .get(self.file_index)
            .and_then(|path| path.file_name())
            .and_then(|name| name.to_str())
            .unwrap_or("instruction");
        let portion = self
            .current_portion()
            .map(|portion| portion.label())
            .unwrap_or_else(|err| err.to_string());
        let shortcut = self.shortcut_label();
        let history = if self.answers.is_empty() {
            format!("{} requests", self.requests)
        } else {
            format!(
                "{} / {}    {} requests",
                self.selection + 1,
                self.answers.len(),
                self.requests
            )
        };
        rows.push(StyledLine::plain(
            fit(
                &format!(
                    "{instruction}   {portion}   {shortcut}   {}   {history}",
                    MODELS[self.model_index]
                ),
                width,
            ),
            Color::DarkGrey,
        ));
        if self.answers.is_empty() {
            rows.push(StyledLine::plain("", Color::White));
            push_wrapped(
                rows,
                &format!("Press {shortcut} to capture. {}", if self.portion_index == 2 {
                    "Focus the window you want to read first."
                } else {
                    "Enter also captures while the reader is focused."
                }),
                width,
                Color::DarkGrey,
            );
            return;
        }
        let room = body_rows.saturating_sub(1).max(1);
        let wrapped = wrap_text(&self.answers[self.selection], width);
        self.scroll = self.scroll.min(wrapped.len().saturating_sub(room));
        for line in wrapped.into_iter().skip(self.scroll).take(room) {
            rows.push(StyledLine::plain(line, ANSWER_COLOR));
        }
    }

    fn present(
        &self,
        rows: Vec<StyledLine>,
        status: Option<StyledLine>,
        footer: &str,
        width: usize,
        height: usize,
    ) -> Result<()> {
        let footer_row = height.saturating_sub(1);
        let status_row = status.as_ref().map(|_| footer_row.saturating_sub(1));
        let mut out = io::stdout();
        for row in 0..height as u16 {
            queue!(out, cursor::MoveTo(0, row))?;
            if row as usize == footer_row {
                render_plain(&mut out, &fit(footer, width), width, Color::DarkGrey)?;
            } else if Some(row as usize) == status_row {
                if let Some(line) = &status {
                    render_line(&mut out, line, width)?;
                }
            } else if let Some(line) = rows.get(row as usize) {
                render_line(&mut out, line, width)?;
            } else {
                render_plain(&mut out, "", width, Color::White)?;
            }
        }
        out.flush()?;
        Ok(())
    }
}

#[cfg(windows)]
const ANSWER_COLOR: Color = Color::Rgb {
    r: 210,
    g: 245,
    b: 255,
};

#[cfg(windows)]
struct StyledLine {
    segments: Vec<StyledSegment>,
}

#[cfg(windows)]
struct StyledSegment {
    text: String,
    color: Color,
}

#[cfg(windows)]
impl StyledLine {
    fn plain(text: impl Into<String>, color: Color) -> Self {
        Self {
            segments: vec![segment(text, color)],
        }
    }
}

#[cfg(windows)]
fn segment(text: impl Into<String>, color: Color) -> StyledSegment {
    StyledSegment {
        text: text.into(),
        color,
    }
}

#[cfg(windows)]
fn choice(selected: bool, text: &str) -> StyledLine {
    StyledLine {
        segments: vec![
            segment(
                if selected { "> " } else { "  " },
                if selected { Color::Cyan } else { Color::DarkGrey },
            ),
            segment(text, if selected { Color::White } else { Color::DarkGrey }),
        ],
    }
}

#[cfg(windows)]
fn choice_field(selected: bool, label: &str, value: &str) -> StyledLine {
    let mut segments = vec![
        segment(
            if selected { "> " } else { "  " },
            if selected { Color::Cyan } else { Color::DarkGrey },
        ),
        segment(
            if value.is_empty() {
                label.to_string()
            } else {
                format!("{label}: ")
            },
            if selected && value.is_empty() {
                Color::White
            } else {
                Color::DarkGrey
            },
        ),
    ];
    if !value.is_empty() {
        segments.push(segment(
            value,
            if selected { Color::White } else { Color::DarkGrey },
        ));
    }
    StyledLine { segments }
}

#[cfg(windows)]
fn field(label: &str, value: &str) -> StyledLine {
    StyledLine {
        segments: vec![
            segment(format!("{label}: "), Color::DarkGrey),
            segment(value, Color::White),
        ],
    }
}

#[cfg(windows)]
fn push_wrapped(rows: &mut Vec<StyledLine>, text: &str, width: usize, color: Color) {
    for line in wrap_text(text, width.max(1)) {
        rows.push(StyledLine::plain(line, color));
    }
}

#[cfg(windows)]
fn detail_width(width: usize) -> usize {
    if width < 72 {
        return width.max(1);
    }
    let columns_width = width.saturating_sub(4);
    let left_width = (columns_width * 45 / 100).clamp(24, columns_width.saturating_sub(20).max(24));
    columns_width.saturating_sub(left_width).max(1)
}

fn columns(left: Vec<StyledLine>, right: Vec<StyledLine>, width: usize) -> Vec<StyledLine> {
    if width < 72 {
        let mut rows = left;
        rows.push(StyledLine::plain("", Color::White));
        rows.extend(right);
        return rows;
    }
    let gap = 4;
    let columns_width = width.saturating_sub(gap);
    let left_width = (columns_width * 45 / 100).clamp(24, columns_width.saturating_sub(20).max(24));
    let right_width = columns_width.saturating_sub(left_width);
    let height = left.len().max(right.len());
    let mut rows = Vec::new();
    for index in 0..height {
        rows.push(combine_columns(
            left.get(index),
            left_width,
            gap,
            right.get(index),
            right_width,
        ));
    }
    rows
}

#[cfg(windows)]
fn combine_columns(
    left: Option<&StyledLine>,
    left_width: usize,
    gap: usize,
    right: Option<&StyledLine>,
    right_width: usize,
) -> StyledLine {
    let mut segments = Vec::new();
    append_fitted(&mut segments, left, left_width);
    if gap > 0 {
        segments.push(segment(" ".repeat(gap), Color::White));
    }
    append_fitted(&mut segments, right, right_width);
    StyledLine { segments }
}

#[cfg(windows)]
fn append_fitted(output: &mut Vec<StyledSegment>, line: Option<&StyledLine>, width: usize) {
    let mut used = 0;
    if let Some(line) = line {
        for part in &line.segments {
            if used >= width {
                break;
            }
            let text = fit(&part.text, width - used);
            used += text.chars().count();
            if !text.is_empty() {
                output.push(segment(text, part.color));
            }
        }
    }
    if used < width {
        output.push(segment(" ".repeat(width - used), Color::White));
    }
}

#[cfg(windows)]
fn render_line(out: &mut io::Stdout, line: &StyledLine, width: usize) -> Result<()> {
    let mut used = 0;
    for part in &line.segments {
        if used >= width {
            break;
        }
        let text = fit(&part.text, width - used);
        used += text.chars().count();
        queue!(
            out,
            SetForegroundColor(part.color),
            Print(text),
            ResetColor
        )?;
    }
    if used < width {
        queue!(out, Print(" ".repeat(width - used)))?;
    }
    Ok(())
}

#[cfg(windows)]
fn render_plain(out: &mut io::Stdout, text: &str, width: usize, color: Color) -> Result<()> {
    render_line(out, &StyledLine::plain(text, color), width)
}

#[cfg(windows)]
fn fit(text: &str, width: usize) -> String {
    let text = enchanted_reader::terminal_line(text);
    let count = text.chars().count();
    if count <= width {
        return text;
    }
    let keep = width.saturating_sub(1);
    format!("{}…", text.chars().take(keep).collect::<String>())
}

#[cfg(windows)]
struct UiGuard;

#[cfg(windows)]
impl Drop for UiGuard {
    fn drop(&mut self) {
        let _ = terminal::disable_raw_mode();
        let _ = execute!(io::stdout(), cursor::Show, terminal::LeaveAlternateScreen);
    }
}

