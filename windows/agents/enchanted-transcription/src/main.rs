use anyhow::{anyhow, Context, Result};
use crossterm::{
    cursor,
    event::{self, Event, KeyCode, KeyModifiers},
    execute, queue,
    style::{Color, Print, ResetColor, SetForegroundColor},
    terminal,
};
use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::{
    collections::{HashMap, VecDeque},
    env, fs,
    io::{self, Write},
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        mpsc::{self, Receiver, Sender},
        Arc,
    },
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use wasapi::{initialize_mta, DeviceEnumerator, Direction, SampleType, StreamMode, WaveFormat};
use whisper_rs::{
    install_logging_hooks, FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters,
};

const SAMPLE_RATE: usize = 16_000;
const CAPTURE_FRAMES_PER_PACKET: usize = 1_600;
const DEFAULT_CHUNK_SECONDS: usize = 12;
const SILENCE_RMS: f32 = 0.0005;
const RENDER_INTERVAL: Duration = Duration::from_millis(250);
const STREAM_PARTIAL_INTERVAL: Duration = Duration::from_secs(2);
const STREAM_COMMIT_INTERVAL: Duration = Duration::from_secs(5);
const MIN_STREAM_AUDIO_SECONDS: usize = 2;
const SILENCE_BREAK_AFTER: Duration = Duration::from_millis(1200);
const DEFAULT_LANGUAGE: &str = "en";
const COLUMN_GAP: u16 = 6;
const MIN_RESTART_PREFIX_WORDS: usize = 4;
const TEMP_RETENTION: Duration = Duration::from_secs(7 * 24 * 60 * 60);
const TEXT_FULL_INTENSITY: Duration = Duration::from_secs(8);
const DEFAULT_TEXT_FADE_SECONDS: u64 = 70;
const TEXT_MIN_INTENSITY: f32 = 0.60;
const FADE_RENDER_INTERVAL: Duration = Duration::from_secs(2);
const DEFAULT_AGENT_MODEL: &str = "gpt-5.4-nano";
const AGENT_INSTRUCTIONS_FILE: &str = "agent-instructions.md";
const AGENT_REFRESH_INTERVAL: Duration = Duration::from_secs(6);
const AGENT_HTTP_TIMEOUT: Duration = Duration::from_secs(14);
const AGENT_CONTEXT_CHARS: usize = 3500;

#[derive(Clone, Copy, Debug, Eq, PartialEq, Hash)]
enum SourceKind {
    Microphone,
    SystemOutput,
}

impl SourceKind {
    fn label(self) -> &'static str {
        match self {
            SourceKind::Microphone => "mic",
            SourceKind::SystemOutput => "system",
        }
    }

    fn display_name(self) -> &'static str {
        match self {
            SourceKind::Microphone => "Microphone",
            SourceKind::SystemOutput => "System output",
        }
    }

    fn endpoint_direction(self) -> Direction {
        match self {
            SourceKind::Microphone => Direction::Capture,
            SourceKind::SystemOutput => Direction::Render,
        }
    }
}

#[derive(Clone)]
struct AppConfig {
    model_path: PathBuf,
    temp_dir: PathBuf,
    sources: Vec<SourceKind>,
    chunk_seconds: usize,
    language: Option<String>,
    fade_duration: Duration,
    agent: AgentConfig,
}

struct CliArgs {
    model_path: PathBuf,
    temp_dir: PathBuf,
    fade_seconds: u64,
    agent_model: String,
    agent_disabled: bool,
}

#[derive(Clone)]
struct AgentConfig {
    enabled: bool,
    model: String,
    api_key: Option<String>,
    include_microphone: bool,
    instructions: String,
    response_schema: Value,
    max_output_tokens: u64,
    fields: Vec<AgentFieldConfig>,
    microphone_delta_gate_field: Option<String>,
}

impl AgentConfig {
    fn disabled(model: impl Into<String>) -> Self {
        Self {
            enabled: false,
            model: model.into(),
            api_key: None,
            include_microphone: false,
            instructions: String::new(),
            response_schema: json!({}),
            max_output_tokens: 220,
            fields: Vec::new(),
            microphone_delta_gate_field: None,
        }
    }
}

#[derive(Clone)]
struct AgentFieldConfig {
    key: String,
    title: String,
    render: AgentFieldRender,
    empty: String,
    title_rgb: (u8, u8, u8),
    value_rgb: (u8, u8, u8),
    min_display: Duration,
    schema: Value,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum AgentFieldRender {
    Text,
    List,
}

#[derive(Deserialize)]
struct RawAgentInstructionsConfig {
    max_output_tokens: Option<u64>,
    microphone_delta_gate_field: Option<String>,
    fields: Vec<RawAgentFieldConfig>,
}

#[derive(Deserialize)]
struct RawAgentFieldConfig {
    key: String,
    title: String,
    render: Option<String>,
    empty: Option<String>,
    title_color: String,
    value_color: String,
    min_display_seconds: Option<u64>,
    schema: Value,
}

#[derive(Clone)]
struct AudioFrame {
    source: SourceKind,
    samples: Vec<f32>,
}

enum UiEvent {
    Status(String),
    Transcript {
        source: SourceKind,
        text: String,
        elapsed_ms: u128,
        rms: f32,
    },
    PartialTranscript {
        source: SourceKind,
        text: String,
        elapsed_ms: u128,
        rms: f32,
    },
    TranscriptBreak {
        source: SourceKind,
    },
    SourceError {
        source: SourceKind,
        message: String,
    },
    SourceActivity {
        source: SourceKind,
        active: bool,
    },
    AgentStatus(String),
    AgentRequestStarted {
        query_bytes: usize,
    },
    AgentRequestFailed {
        message: String,
    },
    AgentOutput {
        result: Value,
        usage: Option<AgentUsage>,
        force_hints: bool,
        elapsed_ms: u128,
    },
}

#[derive(Clone)]
struct AgentInput {
    system_transcript: String,
    microphone_transcript: Option<String>,
    force: bool,
}

struct StreamingSourceState {
    samples: Vec<f32>,
    prompt: String,
    history: Vec<String>,
    best_text: String,
    pending_commit: String,
    agent_update_pending: bool,
    voice_active: bool,
    last_pass: Instant,
    last_commit: Instant,
    last_voice_at: Option<Instant>,
}

impl StreamingSourceState {
    fn new(window_samples: usize) -> Self {
        Self {
            samples: Vec::with_capacity(window_samples),
            prompt: String::new(),
            history: Vec::new(),
            best_text: String::new(),
            pending_commit: String::new(),
            agent_update_pending: false,
            voice_active: false,
            last_pass: Instant::now() - STREAM_PARTIAL_INTERVAL,
            last_commit: Instant::now() - STREAM_COMMIT_INTERVAL,
            last_voice_at: None,
        }
    }

    fn reset(&mut self) {
        self.samples.clear();
        self.prompt.clear();
        self.history.clear();
        self.best_text.clear();
        self.pending_commit.clear();
        self.agent_update_pending = false;
        self.voice_active = false;
        self.last_pass = Instant::now() - STREAM_PARTIAL_INTERVAL;
        self.last_commit = Instant::now() - STREAM_COMMIT_INTERVAL;
        self.last_voice_at = None;
    }

    fn full_text(&self) -> String {
        let mut parts = self
            .history
            .iter()
            .map(|value| value.trim())
            .filter(|value| !value.is_empty())
            .map(ToOwned::to_owned)
            .collect::<Vec<_>>();
        let current = self.best_text.trim();
        if !current.is_empty() {
            parts.push(current.to_string());
        }
        parts.join("\n\n")
    }

    fn finish_current_block(&mut self) -> bool {
        let current = self.best_text.trim().to_string();
        self.samples.clear();
        self.pending_commit.clear();
        self.last_pass = Instant::now() - STREAM_PARTIAL_INTERVAL;
        self.last_commit = Instant::now() - STREAM_COMMIT_INTERVAL;
        self.last_voice_at = None;

        if current.is_empty() {
            return false;
        }

        self.history.push(current);
        self.best_text.clear();
        let history_text = self.history.join("\n\n");
        set_prompt(&mut self.prompt, &history_text);
        true
    }
}

struct AppState {
    model_path: PathBuf,
    dump_path: PathBuf,
    cuda_enabled: bool,
    sources: Vec<SourceKind>,
    language: Option<String>,
    fade_duration: Duration,
    agent: AgentPaneState,
    transcripts: HashMap<SourceKind, TranscriptState>,
    status: String,
}

struct AgentPaneState {
    enabled: bool,
    model: String,
    fields: Vec<AgentFieldState>,
    status: String,
    microphone_active: bool,
    system_output_active: bool,
    request_in_flight: bool,
    request_count: u64,
    input_tokens: u64,
    output_tokens: u64,
    total_tokens: u64,
    last_total_tokens: Option<u64>,
    last_query_bytes: Option<usize>,
    last_error: Option<String>,
}

struct AgentFieldState {
    config: AgentFieldConfig,
    lines: Vec<String>,
    pending_lines: Option<Vec<String>>,
    updated_at: Option<Instant>,
}

#[derive(Clone, Default)]
struct TranscriptState {
    blocks: Vec<TranscriptBlock>,
}

#[derive(Clone, Default)]
struct TranscriptBlock {
    text: String,
    words: Vec<TranscriptWord>,
}

impl TranscriptState {
    fn current_block_mut(&mut self) -> &mut TranscriptBlock {
        if self.blocks.is_empty() {
            self.blocks.push(TranscriptBlock::default());
        }
        self.blocks
            .last_mut()
            .expect("current block should exist after initialization")
    }

    fn add_break(&mut self) -> bool {
        if !self.has_content()
            || self
                .blocks
                .last()
                .is_some_and(|block| block.text.trim().is_empty())
        {
            return false;
        }

        self.blocks.push(TranscriptBlock::default());
        true
    }

    fn text(&self) -> String {
        self.blocks
            .iter()
            .map(|block| block.text.trim())
            .filter(|text| !text.is_empty())
            .map(ToOwned::to_owned)
            .collect::<Vec<_>>()
            .join("\n\n")
    }

    fn has_content(&self) -> bool {
        self.blocks
            .iter()
            .any(|block| !block.text.trim().is_empty())
    }
}

#[derive(Clone)]
struct TranscriptWord {
    text: String,
    first_seen: Instant,
}

impl AppState {
    fn new(config: &AppConfig) -> Self {
        Self {
            model_path: config.model_path.clone(),
            dump_path: session_dump_path(&config.temp_dir),
            cuda_enabled: cfg!(feature = "cuda"),
            sources: config.sources.clone(),
            language: config.language.clone(),
            fade_duration: config.fade_duration,
            agent: AgentPaneState {
                enabled: config.agent.enabled,
                model: config.agent.model.clone(),
                fields: default_agent_fields(&config.agent.fields),
                status: if config.agent.enabled {
                    "waiting for system output".to_string()
                } else {
                    "off".to_string()
                },
                microphone_active: false,
                system_output_active: false,
                request_in_flight: false,
                request_count: 0,
                input_tokens: 0,
                output_tokens: 0,
                total_tokens: 0,
                last_total_tokens: None,
                last_query_bytes: None,
                last_error: None,
            },
            transcripts: HashMap::new(),
            status: "Starting".to_string(),
        }
    }

    fn update_transcript(&mut self, source: SourceKind, text: &str) -> bool {
        let text = text.trim();
        if text.is_empty() {
            return false;
        }

        let transcript = self.transcripts.entry(source).or_default();
        let block = transcript.current_block_mut();
        let merged = merge_transcript_estimate(&block.text, text);
        if block.text.trim() == merged.trim() {
            return false;
        }

        block.words = align_transcript_words(&block.words, &merged, Instant::now());
        block.text = merged;
        if let Err(err) = self.dump_transcripts() {
            self.status = format!("transcript dump failed: {err}");
        }
        true
    }

    fn add_transcript_break(&mut self, source: SourceKind) -> bool {
        let Some(transcript) = self.transcripts.get_mut(&source) else {
            return false;
        };
        if !transcript.add_break() {
            return false;
        }
        if let Err(err) = self.dump_transcripts() {
            self.status = format!("transcript dump failed: {err}");
        }
        true
    }

    fn refresh_session(&mut self) {
        self.transcripts.clear();
        let field_configs = self
            .agent
            .fields
            .iter()
            .map(|field| field.config.clone())
            .collect::<Vec<_>>();
        self.agent.fields = default_agent_fields(&field_configs);
        self.agent.status = if self.agent.enabled {
            "refreshed".to_string()
        } else {
            "off".to_string()
        };
        self.agent.microphone_active = false;
        self.agent.system_output_active = false;
        self.agent.request_in_flight = false;
        self.agent.request_count = 0;
        self.agent.input_tokens = 0;
        self.agent.output_tokens = 0;
        self.agent.total_tokens = 0;
        self.agent.last_total_tokens = None;
        self.agent.last_query_bytes = None;
        self.agent.clear_error();
        self.status = "Refreshed".to_string();
        if let Err(err) = self.dump_transcripts() {
            self.status = format!("transcript dump failed: {err}");
        }
    }

    fn dump_transcripts(&self) -> Result<()> {
        let mut content = String::new();
        for source in &self.sources {
            content.push_str(source.label());
            content.push('\n');
            let text = self
                .transcripts
                .get(source)
                .map(TranscriptState::text)
                .filter(|value| !value.is_empty())
                .unwrap_or_default();
            for line in wrap_plain_text(&text, 100) {
                content.push_str("    ");
                content.push_str(&line);
                content.push('\n');
            }
            content.push('\n');
        }

        fs::write(&self.dump_path, content)
            .with_context(|| format!("failed to write {}", self.dump_path.display()))
    }

    fn apply(&mut self, event: UiEvent) -> bool {
        match event {
            UiEvent::Status(message) => {
                if is_noisy_status(&message) || self.status == message {
                    return false;
                }
                self.status = message;
                true
            }
            UiEvent::Transcript {
                source,
                text,
                elapsed_ms,
                rms,
            } => {
                let _ = rms;
                let changed = self.update_transcript(source, &text);
                if changed {
                    self.status =
                        format!("{} committed in {} ms", source.display_name(), elapsed_ms);
                }
                changed
            }
            UiEvent::PartialTranscript {
                source,
                text,
                elapsed_ms,
                rms,
            } => {
                let _ = rms;
                let changed = self.update_transcript(source, &text);
                if changed {
                    self.status =
                        format!("{} live update in {} ms", source.display_name(), elapsed_ms);
                }
                changed
            }
            UiEvent::TranscriptBreak { source } => self.add_transcript_break(source),
            UiEvent::SourceError { source, message } => {
                self.status = format!("{} failed", source.display_name());
                self.agent.set_source_activity(source, false);
                self.update_transcript(source, &format!("error: {}", message.trim()))
            }
            UiEvent::SourceActivity { source, active } => {
                self.agent.set_source_activity(source, active)
            }
            UiEvent::AgentStatus(message) => {
                if self.agent.status == message {
                    return false;
                }
                self.agent.status = message;
                true
            }
            UiEvent::AgentRequestStarted { query_bytes } => {
                self.agent.start_request(query_bytes);
                true
            }
            UiEvent::AgentRequestFailed { message } => {
                self.agent.finish_request();
                self.agent.record_error(message.clone());
                self.agent.status = message;
                true
            }
            UiEvent::AgentOutput {
                result,
                usage,
                force_hints,
                elapsed_ms,
            } => {
                self.agent.apply_result(result, force_hints);
                self.agent.finish_request();
                self.agent.clear_error();
                self.agent.record_usage(usage);
                self.agent.status = format!("updated in {} ms", elapsed_ms);
                true
            }
        }
    }
}

impl AgentPaneState {
    fn set_source_activity(&mut self, source: SourceKind, active: bool) -> bool {
        let current = match source {
            SourceKind::Microphone => &mut self.microphone_active,
            SourceKind::SystemOutput => &mut self.system_output_active,
        };
        if *current == active {
            return false;
        }

        *current = active;
        true
    }

    fn marker(&self) -> Option<(&'static str, Color)> {
        if self.request_in_flight {
            Some(("\u{25cf} waiting", Color::Red))
        } else if self.microphone_active {
            Some(("\u{25cf} hold", Color::Yellow))
        } else if self.system_output_active {
            Some(("\u{25cf} hearing", Color::Cyan))
        } else {
            None
        }
    }

    fn start_request(&mut self, query_bytes: usize) {
        self.request_in_flight = true;
        self.request_count += 1;
        self.last_query_bytes = Some(query_bytes);
        self.status = "waiting for model".to_string();
    }

    fn finish_request(&mut self) {
        self.request_in_flight = false;
    }

    fn record_error(&mut self, message: String) {
        self.last_error = Some(message);
    }

    fn clear_error(&mut self) {
        self.last_error = None;
    }

    fn record_usage(&mut self, usage: Option<AgentUsage>) {
        let Some(usage) = usage else {
            return;
        };

        self.input_tokens += usage.input_tokens;
        self.output_tokens += usage.output_tokens;
        self.total_tokens += usage.total_tokens;
        self.last_total_tokens = Some(usage.total_tokens);
    }

    fn apply_result(&mut self, result: Value, force_delayed_fields: bool) -> bool {
        let mut changed = false;
        for field in &mut self.fields {
            let lines = agent_field_value_lines(&field.config, result.get(&field.config.key));
            changed |= update_agent_field(field, lines, force_delayed_fields);
        }
        changed
    }

    fn promote_pending_fields(&mut self) -> bool {
        let mut changed = false;
        let now = Instant::now();
        for field in &mut self.fields {
            let Some(pending_lines) = field.pending_lines.clone() else {
                continue;
            };
            let ready = field
                .updated_at
                .map(|updated_at| updated_at.elapsed() >= field.config.min_display)
                .unwrap_or(true);
            if ready {
                field.lines = pending_lines;
                field.pending_lines = None;
                field.updated_at = Some(now);
                changed = true;
            }
        }
        changed
    }

    fn has_pending_content(&self) -> bool {
        self.fields.iter().any(|field| {
            field
                .pending_lines
                .as_ref()
                .is_some_and(|lines| !lines.is_empty())
        })
    }

    fn has_content(&self) -> bool {
        self.fields.iter().any(|field| !field.lines.is_empty())
    }
}

fn default_agent_fields(configs: &[AgentFieldConfig]) -> Vec<AgentFieldState> {
    configs
        .iter()
        .cloned()
        .map(|config| AgentFieldState {
            config,
            lines: Vec::new(),
            pending_lines: None,
            updated_at: None,
        })
        .collect()
}

fn update_agent_field(
    field: &mut AgentFieldState,
    lines: Vec<String>,
    force_delayed_fields: bool,
) -> bool {
    if field.lines == lines {
        field.pending_lines = None;
        return false;
    }

    let can_replace = force_delayed_fields
        || field.config.min_display.is_zero()
        || field.lines.is_empty()
        || field
            .updated_at
            .map(|updated_at| updated_at.elapsed() >= field.config.min_display)
            .unwrap_or(true);
    if can_replace {
        field.lines = lines;
        field.pending_lines = None;
        field.updated_at = Some(Instant::now());
        return true;
    }

    if field.pending_lines.as_ref() == Some(&lines) {
        false
    } else {
        field.pending_lines = Some(lines);
        false
    }
}

fn agent_field_value_lines(config: &AgentFieldConfig, value: Option<&Value>) -> Vec<String> {
    match config.render {
        AgentFieldRender::Text => agent_text_lines(config, value),
        AgentFieldRender::List => agent_list_lines(config, value),
    }
}

fn agent_text_lines(config: &AgentFieldConfig, value: Option<&Value>) -> Vec<String> {
    let text = value.and_then(Value::as_str).unwrap_or("").trim();
    if text.is_empty() {
        vec![config.empty.clone()]
    } else {
        vec![text.to_string()]
    }
}

fn agent_list_lines(config: &AgentFieldConfig, value: Option<&Value>) -> Vec<String> {
    let lines = value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::trim)
                .filter(|item| !item.is_empty())
                .map(|item| format!("- {item}"))
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    if lines.is_empty() {
        vec![config.empty.clone()]
    } else {
        lines
    }
}

fn default_agent_result(fields: &[AgentFieldConfig]) -> Value {
    let mut out = Map::new();
    for field in fields {
        let value = match field
            .schema
            .get("type")
            .and_then(Value::as_str)
            .unwrap_or("string")
        {
            "array" => Value::Array(Vec::new()),
            _ => Value::String(String::new()),
        };
        out.insert(field.key.clone(), value);
    }
    Value::Object(out)
}

fn agent_result_has_renderable_fields(result: &Value, fields: &[AgentFieldConfig]) -> bool {
    fields
        .iter()
        .any(|field| result.get(&field.key).is_some_and(value_has_content))
}

fn value_has_content(value: &Value) -> bool {
    match value {
        Value::String(text) => !text.trim().is_empty(),
        Value::Array(items) => items.iter().any(value_has_content),
        Value::Object(map) => map.values().any(value_has_content),
        Value::Null => false,
        Value::Bool(value) => *value,
        Value::Number(_) => true,
    }
}

struct TerminalGuard;

impl TerminalGuard {
    fn enter() -> Result<Self> {
        terminal::enable_raw_mode()?;
        execute!(
            io::stdout(),
            terminal::EnterAlternateScreen,
            terminal::Clear(terminal::ClearType::All),
            cursor::Hide
        )?;
        Ok(Self)
    }
}

impl Drop for TerminalGuard {
    fn drop(&mut self) {
        let _ = execute!(io::stdout(), cursor::Show, terminal::LeaveAlternateScreen);
        let _ = terminal::disable_raw_mode();
    }
}

fn main() -> Result<()> {
    install_logging_hooks();

    let args = parse_args()?;
    initialize_mta()
        .ok()
        .context("failed to initialize WASAPI")?;

    prepare_temp_dir(&args.temp_dir)?;

    let config = prompt_config(args)?;
    if config.sources.is_empty() {
        println!("No audio sources enabled. Nothing to transcribe.");
        return Ok(());
    }

    let stop = Arc::new(AtomicBool::new(false));
    let refresh_generation = Arc::new(AtomicU64::new(0));
    let agent_force_generation = Arc::new(AtomicU64::new(0));
    let (audio_tx, audio_rx) = mpsc::channel::<AudioFrame>();
    let (ui_tx, ui_rx) = mpsc::channel::<UiEvent>();
    let agent_tx = if config.agent.enabled {
        let (agent_tx, agent_rx) = mpsc::channel::<AgentInput>();
        spawn_agent_thread(
            config.agent.clone(),
            agent_rx,
            ui_tx.clone(),
            stop.clone(),
            refresh_generation.clone(),
        );
        Some(agent_tx)
    } else {
        None
    };

    for source in &config.sources {
        spawn_capture_thread(*source, audio_tx.clone(), ui_tx.clone(), stop.clone());
    }
    drop(audio_tx);

    spawn_whisper_thread(
        config.clone(),
        audio_rx,
        ui_tx.clone(),
        agent_tx,
        stop.clone(),
        refresh_generation.clone(),
        agent_force_generation.clone(),
    );

    let _terminal = TerminalGuard::enter()?;
    let mut state = AppState::new(&config);
    render_loop(
        &mut state,
        ui_rx,
        stop,
        refresh_generation,
        agent_force_generation,
    )?;
    Ok(())
}

fn parse_args() -> Result<CliArgs> {
    let mut args = env::args().skip(1);
    let mut model_path = None;
    let mut temp_dir = None;
    let mut fade_seconds = DEFAULT_TEXT_FADE_SECONDS;
    let mut agent_model = DEFAULT_AGENT_MODEL.to_string();
    let mut agent_disabled = false;

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--model" => {
                let path = args
                    .next()
                    .ok_or_else(|| anyhow!("--model requires a model path"))?;
                model_path = Some(PathBuf::from(path));
            }
            "--temp-dir" => {
                let path = args
                    .next()
                    .ok_or_else(|| anyhow!("--temp-dir requires a directory path"))?;
                temp_dir = Some(PathBuf::from(path));
            }
            "--fade-seconds" => {
                let value = args
                    .next()
                    .ok_or_else(|| anyhow!("--fade-seconds requires a number"))?;
                fade_seconds = parse_fade_seconds(&value)?;
            }
            "--agent-model" => {
                agent_model = args
                    .next()
                    .ok_or_else(|| anyhow!("--agent-model requires a model name"))?;
            }
            "--agent-disabled" => {
                agent_disabled = true;
            }
            "--help" | "-h" => {
                println!(
                    "Usage: enchanted-transcription --model <ggml-model.bin> [--temp-dir <dir>] [--fade-seconds <5-180>] [--agent-model <model>] [--agent-disabled]"
                );
                std::process::exit(0);
            }
            other => return Err(anyhow!("unknown argument: {}", other)),
        }
    }

    let model_path = model_path.ok_or_else(|| anyhow!("missing --model <path>"))?;
    let temp_dir = temp_dir.unwrap_or_else(|| default_temp_dir(&model_path));
    Ok(CliArgs {
        model_path,
        temp_dir,
        fade_seconds,
        agent_model,
        agent_disabled,
    })
}

fn parse_fade_seconds(value: &str) -> Result<u64> {
    match value.parse::<u64>() {
        Ok(seconds) if (5..=180).contains(&seconds) => Ok(seconds),
        _ => Err(anyhow!("fade seconds must be a number from 5 to 180")),
    }
}

fn default_temp_dir(model_path: &PathBuf) -> PathBuf {
    model_path
        .parent()
        .and_then(|models_dir| models_dir.parent())
        .map(|agent_root| agent_root.join(".temp"))
        .unwrap_or_else(|| PathBuf::from(".temp"))
}

fn prepare_temp_dir(temp_dir: &PathBuf) -> Result<()> {
    fs::create_dir_all(temp_dir)
        .with_context(|| format!("failed to create {}", temp_dir.display()))?;
    cleanup_old_temp_files(temp_dir)
}

fn cleanup_old_temp_files(temp_dir: &PathBuf) -> Result<()> {
    let now = SystemTime::now();
    for entry in
        fs::read_dir(temp_dir).with_context(|| format!("failed to read {}", temp_dir.display()))?
    {
        let entry = entry?;
        let path = entry.path();
        if !path.is_file() || !is_transcript_dump(&path) {
            continue;
        }

        let Ok(modified) = entry.metadata().and_then(|metadata| metadata.modified()) else {
            continue;
        };
        if now
            .duration_since(modified)
            .map(|age| age > TEMP_RETENTION)
            .unwrap_or(false)
        {
            let _ = fs::remove_file(path);
        }
    }

    Ok(())
}

fn is_transcript_dump(path: &PathBuf) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .map(|name| name.starts_with("transcription-") && name.ends_with(".txt"))
        .unwrap_or(false)
}

fn session_dump_path(temp_dir: &PathBuf) -> PathBuf {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    temp_dir.join(format!("transcription-{seconds}.txt"))
}

fn prompt_config(args: CliArgs) -> Result<AppConfig> {
    let model_path = args.model_path;
    let agent_root = agent_root_from_model_path(&model_path);
    println!("Enchanted transcription");
    println!("Model: {}", model_path.display());
    println!(
        "Backend: {}",
        if cfg!(feature = "cuda") {
            "CUDA"
        } else {
            "CPU"
        }
    );
    println!();

    println!(
        "Default microphone: {}",
        default_device_name(SourceKind::Microphone)
            .unwrap_or_else(|err| format!("unavailable ({err})"))
    );
    println!(
        "Default system output: {}",
        default_device_name(SourceKind::SystemOutput)
            .unwrap_or_else(|err| format!("unavailable ({err})"))
    );
    println!();

    let mut sources = Vec::new();
    if prompt_bool("Enable microphone transcription", true)? {
        sources.push(SourceKind::Microphone);
    }
    if prompt_bool("Enable system-output transcription", true)? {
        sources.push(SourceKind::SystemOutput);
    }

    if sources.is_empty() {
        return Ok(AppConfig {
            model_path,
            temp_dir: args.temp_dir,
            sources,
            chunk_seconds: DEFAULT_CHUNK_SECONDS,
            language: None,
            fade_duration: Duration::from_secs(args.fade_seconds),
            agent: AgentConfig::disabled(args.agent_model),
        });
    }

    let language = prompt_language()?;
    let chunk_seconds = prompt_chunk_seconds(DEFAULT_CHUNK_SECONDS)?;
    let fade_seconds = prompt_fade_seconds(args.fade_seconds)?;
    let agent = prompt_agent_config(
        &sources,
        &args.agent_model,
        args.agent_disabled,
        &agent_root,
    )?;

    Ok(AppConfig {
        model_path,
        temp_dir: args.temp_dir,
        sources,
        chunk_seconds,
        language,
        fade_duration: Duration::from_secs(fade_seconds),
        agent,
    })
}

fn default_device_name(source: SourceKind) -> Result<String> {
    let enumerator = DeviceEnumerator::new()?;
    let device = enumerator.get_default_device(&source.endpoint_direction())?;
    Ok(device.get_friendlyname()?)
}

fn agent_root_from_model_path(model_path: &PathBuf) -> PathBuf {
    model_path
        .parent()
        .and_then(|models_dir| models_dir.parent())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

fn prompt_bool(label: &str, default: bool) -> Result<bool> {
    let suffix = if default { "[Y/n]" } else { "[y/N]" };
    loop {
        print!("{label} {suffix}: ");
        io::stdout().flush()?;
        let mut input = String::new();
        io::stdin().read_line(&mut input)?;
        let trimmed = input.trim().to_ascii_lowercase();
        if trimmed.is_empty() {
            return Ok(default);
        }
        match trimmed.as_str() {
            "y" | "yes" => return Ok(true),
            "n" | "no" => return Ok(false),
            _ => println!("Please answer y or n."),
        }
    }
}

fn prompt_chunk_seconds(default: usize) -> Result<usize> {
    loop {
        print!("Rolling Whisper window seconds [{default}]: ");
        io::stdout().flush()?;
        let mut input = String::new();
        io::stdin().read_line(&mut input)?;
        let trimmed = input.trim();
        if trimmed.is_empty() {
            return Ok(default);
        }
        match trimmed.parse::<usize>() {
            Ok(value) if (6..=30).contains(&value) => return Ok(value),
            _ => println!("Use a number from 6 to 30."),
        }
    }
}

fn prompt_fade_seconds(default: u64) -> Result<u64> {
    loop {
        print!("Transcript fade seconds [{default}]: ");
        io::stdout().flush()?;
        let mut input = String::new();
        io::stdin().read_line(&mut input)?;
        let trimmed = input.trim();
        if trimmed.is_empty() {
            return Ok(default);
        }
        match parse_fade_seconds(trimmed) {
            Ok(value) => return Ok(value),
            Err(_) => println!("Use a number from 5 to 180."),
        }
    }
}

fn prompt_agent_config(
    sources: &[SourceKind],
    default_model: &str,
    disabled: bool,
    agent_root: &PathBuf,
) -> Result<AgentConfig> {
    if disabled || !sources.contains(&SourceKind::SystemOutput) {
        return Ok(AgentConfig::disabled(default_model));
    }

    let api_key = match env::var("OPENAI_API_KEY") {
        Ok(value) if !value.trim().is_empty() => value.trim().to_string(),
        _ => {
            println!("OpenAI agent insights disabled: no API key configured.");
            println!("Run `tk openai-key` before starting transcription.");
            return Ok(AgentConfig::disabled(default_model));
        }
    };

    if !prompt_bool("Enable OpenAI agent insights for system-output audio", true)? {
        return Ok(AgentConfig::disabled(default_model));
    }

    let model = prompt_agent_model(default_model)?;
    let include_microphone = sources.contains(&SourceKind::Microphone)
        && prompt_bool(
            "Send microphone transcript to OpenAI for agent context",
            false,
        )?;
    let agent_context = load_agent_context(agent_root)?;
    Ok(AgentConfig {
        enabled: true,
        model,
        api_key: Some(api_key),
        include_microphone,
        instructions: agent_context.instructions,
        response_schema: agent_context.response_schema,
        max_output_tokens: agent_context.max_output_tokens,
        fields: agent_context.fields,
        microphone_delta_gate_field: agent_context.microphone_delta_gate_field,
    })
}

struct AgentContext {
    instructions: String,
    response_schema: Value,
    max_output_tokens: u64,
    fields: Vec<AgentFieldConfig>,
    microphone_delta_gate_field: Option<String>,
}

fn load_agent_context(agent_root: &PathBuf) -> Result<AgentContext> {
    let path = agent_root.join(AGENT_INSTRUCTIONS_FILE);
    let markdown =
        fs::read_to_string(&path).with_context(|| format!("failed to read {}", path.display()))?;
    let (config_text, instructions) = extract_agent_config_block(&markdown)
        .with_context(|| format!("failed to read agent-config from {}", path.display()))?;
    let agent_config = parse_agent_config(&config_text)
        .with_context(|| format!("invalid agent-config in {}", path.display()))?;
    let response_schema = build_response_schema(&agent_config.fields);
    Ok(AgentContext {
        instructions,
        response_schema,
        max_output_tokens: agent_config.max_output_tokens,
        fields: agent_config.fields,
        microphone_delta_gate_field: agent_config.microphone_delta_gate_field,
    })
}

struct ParsedAgentConfig {
    max_output_tokens: u64,
    microphone_delta_gate_field: Option<String>,
    fields: Vec<AgentFieldConfig>,
}

fn extract_agent_config_block(markdown: &str) -> Result<(String, String)> {
    let mut config_lines = Vec::new();
    let mut instruction_lines = Vec::new();
    let mut in_config = false;
    let mut found = false;
    let mut closed = false;

    for line in markdown.lines() {
        let trimmed = line.trim();
        if !in_config && trimmed == "```agent-config" {
            if found {
                return Err(anyhow!(
                    "{AGENT_INSTRUCTIONS_FILE} contains more than one ```agent-config block"
                ));
            }
            found = true;
            in_config = true;
            continue;
        }

        if in_config {
            if trimmed == "```" {
                in_config = false;
                closed = true;
            } else {
                config_lines.push(line.to_string());
            }
            continue;
        }

        instruction_lines.push(line.to_string());
    }

    if !found {
        return Err(anyhow!(
            "{AGENT_INSTRUCTIONS_FILE} must include one fenced ```agent-config block"
        ));
    }
    if !closed {
        return Err(anyhow!(
            "{AGENT_INSTRUCTIONS_FILE} has an unclosed ```agent-config block"
        ));
    }

    Ok((config_lines.join("\n"), instruction_lines.join("\n")))
}

fn parse_agent_config(config_text: &str) -> Result<ParsedAgentConfig> {
    let raw: RawAgentInstructionsConfig =
        serde_json::from_str(config_text).context("agent-config is not valid JSON")?;
    if raw.fields.is_empty() {
        return Err(anyhow!(
            "agent-config.fields must contain at least one field"
        ));
    }

    let max_output_tokens = raw.max_output_tokens.unwrap_or(220);
    if !(1..=4096).contains(&max_output_tokens) {
        return Err(anyhow!(
            "agent-config.max_output_tokens must be from 1 to 4096, got {max_output_tokens}"
        ));
    }

    let mut seen_keys = Vec::new();
    let mut fields = Vec::new();
    for (index, raw_field) in raw.fields.into_iter().enumerate() {
        let field_number = index + 1;
        let key = raw_field.key.trim().to_string();
        if key.is_empty() {
            return Err(anyhow!(
                "agent-config.fields[{index}].key must not be empty"
            ));
        }
        if !is_agent_config_key(&key) {
            return Err(anyhow!(
                "agent-config.fields[{index}].key must use lowercase letters, digits, and underscores only: {key}"
            ));
        }
        if seen_keys.iter().any(|seen| seen == &key) {
            return Err(anyhow!(
                "agent-config.fields[{index}].key duplicates an earlier field: {key}"
            ));
        }
        seen_keys.push(key.clone());

        let title = raw_field.title.trim().to_string();
        if title.is_empty() {
            return Err(anyhow!(
                "agent-config field {key} must have a non-empty title"
            ));
        }

        let render = parse_agent_field_render(raw_field.render.as_deref(), &key)?;
        validate_agent_field_schema(&raw_field.schema, &key, render)?;
        fields.push(AgentFieldConfig {
            key,
            title,
            render,
            empty: raw_field.empty.unwrap_or_else(|| "none".to_string()),
            title_rgb: parse_hex_color(&raw_field.title_color)
                .with_context(|| format!("invalid title_color for field #{field_number}"))?,
            value_rgb: parse_hex_color(&raw_field.value_color)
                .with_context(|| format!("invalid value_color for field #{field_number}"))?,
            min_display: Duration::from_secs(raw_field.min_display_seconds.unwrap_or(0)),
            schema: raw_field.schema,
        });
    }

    let microphone_delta_gate_field = raw
        .microphone_delta_gate_field
        .map(|field| field.trim().to_string())
        .filter(|field| !field.is_empty());
    if let Some(gate_field) = microphone_delta_gate_field.as_ref() {
        if !is_agent_config_key(gate_field) {
            return Err(anyhow!(
                "agent-config.microphone_delta_gate_field must use lowercase letters, digits, and underscores only: {gate_field}"
            ));
        }
        if !seen_keys.iter().any(|key| key == gate_field) {
            return Err(anyhow!(
                "agent-config.microphone_delta_gate_field references missing field: {gate_field}"
            ));
        }
    }

    Ok(ParsedAgentConfig {
        max_output_tokens,
        microphone_delta_gate_field,
        fields,
    })
}

fn is_agent_config_key(text: &str) -> bool {
    text.chars()
        .all(|value| value.is_ascii_lowercase() || value.is_ascii_digit() || value == '_')
}

fn parse_agent_field_render(value: Option<&str>, key: &str) -> Result<AgentFieldRender> {
    match value.unwrap_or("text").trim().to_ascii_lowercase().as_str() {
        "text" => Ok(AgentFieldRender::Text),
        "list" => Ok(AgentFieldRender::List),
        other => Err(anyhow!(
            "agent-config field {key} has unsupported render value: {other}"
        )),
    }
}

fn validate_agent_field_schema(schema: &Value, key: &str, render: AgentFieldRender) -> Result<()> {
    let schema_type = schema
        .get("type")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("agent-config field {key} schema must include a string type"))?;
    if schema_type != "string" && schema_type != "array" {
        return Err(anyhow!(
            "agent-config field {key} schema type must be string or array, got {schema_type}"
        ));
    }
    match (render, schema_type) {
        (AgentFieldRender::Text, "string") | (AgentFieldRender::List, "array") => {}
        (AgentFieldRender::Text, other) => {
            return Err(anyhow!(
                "agent-config field {key} uses render=text, so schema.type must be string, got {other}"
            ));
        }
        (AgentFieldRender::List, other) => {
            return Err(anyhow!(
                "agent-config field {key} uses render=list, so schema.type must be array, got {other}"
            ));
        }
    }
    if schema_type == "array" {
        let items = schema
            .get("items")
            .ok_or_else(|| anyhow!("agent-config field {key} array schema must include items"))?;
        let item_type = items.get("type").and_then(Value::as_str).ok_or_else(|| {
            anyhow!("agent-config field {key} array schema items must include a string type")
        })?;
        if item_type != "string" {
            return Err(anyhow!(
                "agent-config field {key} array schema items.type must be string, got {item_type}"
            ));
        }
    }
    Ok(())
}

fn build_response_schema(fields: &[AgentFieldConfig]) -> Value {
    let mut properties = Map::new();
    let mut required = Vec::new();
    for field in fields {
        properties.insert(field.key.clone(), field.schema.clone());
        required.push(Value::String(field.key.clone()));
    }

    json!({
        "type": "object",
        "additionalProperties": false,
        "properties": properties,
        "required": required
    })
}

fn parse_hex_color(text: &str) -> Result<(u8, u8, u8)> {
    let value = text.trim();
    let hex = value
        .strip_prefix('#')
        .ok_or_else(|| anyhow!("color must start with #: {value}"))?;
    if hex.len() != 6 || !hex.chars().all(|value| value.is_ascii_hexdigit()) {
        return Err(anyhow!("color must be #RRGGBB: {value}"));
    }

    let channel = |range: std::ops::Range<usize>| {
        u8::from_str_radix(&hex[range], 16).context("invalid hex color channel")
    };
    Ok((channel(0..2)?, channel(2..4)?, channel(4..6)?))
}

fn prompt_agent_model(default: &str) -> Result<String> {
    loop {
        print!("OpenAI agent model [{default}, aliases: nano/mini]: ");
        io::stdout().flush()?;
        let mut input = String::new();
        io::stdin().read_line(&mut input)?;
        let trimmed = input.trim();
        if trimmed.is_empty() {
            return Ok(default.to_string());
        }

        match trimmed.to_ascii_lowercase().as_str() {
            "nano" => return Ok("gpt-5.4-nano".to_string()),
            "mini" => return Ok("gpt-5.4-mini".to_string()),
            _ if !trimmed.contains(char::is_whitespace) => return Ok(trimmed.to_string()),
            _ => println!("Use a model id with no spaces, or nano/mini."),
        }
    }
}

fn prompt_language() -> Result<Option<String>> {
    print!("Language code [{DEFAULT_LANGUAGE}, use auto for auto-detect]: ");
    io::stdout().flush()?;
    let mut input = String::new();
    io::stdin().read_line(&mut input)?;
    let trimmed = input.trim().to_ascii_lowercase();
    if trimmed.is_empty() {
        return Ok(Some(DEFAULT_LANGUAGE.to_string()));
    }
    if trimmed == "auto" {
        return Ok(None);
    }

    Ok(Some(trimmed))
}

fn spawn_capture_thread(
    source: SourceKind,
    tx: Sender<AudioFrame>,
    ui_tx: Sender<UiEvent>,
    stop: Arc<AtomicBool>,
) {
    thread::Builder::new()
        .name(format!("capture-{}", source.label()))
        .spawn(move || {
            if let Err(err) = capture_loop(source, tx, ui_tx.clone(), stop.clone()) {
                let _ = ui_tx.send(UiEvent::SourceError {
                    source,
                    message: err.to_string(),
                });
                stop.store(true, Ordering::SeqCst);
            }
        })
        .expect("failed to spawn capture thread");
}

fn capture_loop(
    source: SourceKind,
    tx: Sender<AudioFrame>,
    ui_tx: Sender<UiEvent>,
    stop: Arc<AtomicBool>,
) -> Result<()> {
    initialize_mta()
        .ok()
        .with_context(|| format!("failed to initialize WASAPI for {}", source.display_name()))?;

    let _ = ui_tx.send(UiEvent::Status(format!(
        "{} capture starting",
        source.display_name()
    )));

    let enumerator = DeviceEnumerator::new()?;
    let device = enumerator.get_default_device(&source.endpoint_direction())?;
    let device_name = device
        .get_friendlyname()
        .unwrap_or_else(|_| "default".to_string());
    let mut audio_client = device.get_iaudioclient()?;
    let desired_format = WaveFormat::new(32, 32, &SampleType::Float, SAMPLE_RATE, 1, None);
    let block_align = desired_format.get_blockalign() as usize;
    let (_, min_time) = audio_client.get_device_period()?;
    let mode = StreamMode::EventsShared {
        autoconvert: true,
        buffer_duration_hns: min_time,
    };

    audio_client.initialize_client(&desired_format, &Direction::Capture, &mode)?;
    let event_handle = audio_client.set_get_eventhandle()?;
    let buffer_frame_count = audio_client.get_buffer_size()? as usize;
    let capture_client = audio_client.get_audiocaptureclient()?;
    let mut sample_queue: VecDeque<u8> = VecDeque::with_capacity(
        100 * block_align * (CAPTURE_FRAMES_PER_PACKET + 2 * buffer_frame_count),
    );

    audio_client.start_stream()?;
    let _ = ui_tx.send(UiEvent::Status(format!(
        "{} capture active: {}",
        source.display_name(),
        device_name
    )));

    while !stop.load(Ordering::SeqCst) {
        capture_client.read_from_device_to_deque(&mut sample_queue)?;

        while sample_queue.len() >= block_align * CAPTURE_FRAMES_PER_PACKET {
            let mut bytes = vec![0u8; block_align * CAPTURE_FRAMES_PER_PACKET];
            for byte in bytes.iter_mut() {
                if let Some(value) = sample_queue.pop_front() {
                    *byte = value;
                }
            }
            let samples = f32_samples_from_bytes(&bytes);
            if !samples.is_empty() {
                if tx.send(AudioFrame { source, samples }).is_err() {
                    stop.store(true, Ordering::SeqCst);
                    break;
                }
            }
        }

        let _ = event_handle.wait_for_event(250);
    }

    let _ = audio_client.stop_stream();
    let _ = ui_tx.send(UiEvent::SourceActivity {
        source,
        active: false,
    });
    let _ = ui_tx.send(UiEvent::Status(format!(
        "{} capture stopped",
        source.display_name()
    )));
    Ok(())
}

fn f32_samples_from_bytes(bytes: &[u8]) -> Vec<f32> {
    bytes
        .chunks_exact(4)
        .map(|chunk| f32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]))
        .filter(|value| value.is_finite())
        .collect()
}

fn spawn_whisper_thread(
    config: AppConfig,
    rx: Receiver<AudioFrame>,
    ui_tx: Sender<UiEvent>,
    agent_tx: Option<Sender<AgentInput>>,
    stop: Arc<AtomicBool>,
    refresh_generation: Arc<AtomicU64>,
    agent_force_generation: Arc<AtomicU64>,
) {
    thread::Builder::new()
        .name("whisper-worker".to_string())
        .spawn(move || {
            if let Err(err) = whisper_loop(
                config,
                rx,
                ui_tx.clone(),
                agent_tx,
                stop.clone(),
                refresh_generation,
                agent_force_generation,
            ) {
                let _ = ui_tx.send(UiEvent::Status(format!("Whisper failed: {err}")));
                stop.store(true, Ordering::SeqCst);
            }
        })
        .expect("failed to spawn Whisper thread");
}

fn whisper_loop(
    config: AppConfig,
    rx: Receiver<AudioFrame>,
    ui_tx: Sender<UiEvent>,
    agent_tx: Option<Sender<AgentInput>>,
    stop: Arc<AtomicBool>,
    refresh_generation: Arc<AtomicU64>,
    agent_force_generation: Arc<AtomicU64>,
) -> Result<()> {
    let _ = ui_tx.send(UiEvent::Status("Loading Whisper model".to_string()));
    let mut context_params = WhisperContextParameters::default();
    context_params.use_gpu(cfg!(feature = "cuda"));

    let ctx = WhisperContext::new_with_params(&config.model_path, context_params)
        .with_context(|| format!("failed to load model {}", config.model_path.display()))?;

    let _ = ui_tx.send(UiEvent::Status(format!(
        "Whisper ready with {}",
        if cfg!(feature = "cuda") {
            "CUDA"
        } else {
            "CPU"
        }
    )));

    let window_samples = SAMPLE_RATE * config.chunk_seconds;
    let min_stream_samples = SAMPLE_RATE * MIN_STREAM_AUDIO_SECONDS;
    let mut streams: HashMap<SourceKind, StreamingSourceState> = HashMap::new();
    for source in &config.sources {
        streams.insert(*source, StreamingSourceState::new(window_samples));
    }
    let mut seen_refresh_generation = refresh_generation.load(Ordering::SeqCst);
    let mut seen_agent_force_generation = agent_force_generation.load(Ordering::SeqCst);

    while !stop.load(Ordering::SeqCst) {
        let current_refresh_generation = refresh_generation.load(Ordering::SeqCst);
        if current_refresh_generation != seen_refresh_generation {
            for (source, stream) in streams.iter_mut() {
                stream.reset();
                let _ = ui_tx.send(UiEvent::SourceActivity {
                    source: *source,
                    active: false,
                });
            }
            seen_refresh_generation = current_refresh_generation;
            let _ = ui_tx.send(UiEvent::Status("Session refreshed".to_string()));
        }

        let current_agent_force_generation = agent_force_generation.load(Ordering::SeqCst);
        if current_agent_force_generation != seen_agent_force_generation {
            seen_agent_force_generation = current_agent_force_generation;
            send_agent_update(&agent_tx, &streams, config.agent.include_microphone, true);
        }

        match rx.recv_timeout(Duration::from_millis(100)) {
            Ok(frame) => {
                let source = frame.source;
                let frame_energy = rms(&frame.samples);
                let now = Instant::now();
                let mut agent_update_needed = false;
                {
                    let stream = streams
                        .get_mut(&source)
                        .ok_or_else(|| anyhow!("received audio for disabled source"))?;

                    let mut skip_frame = false;
                    if frame_energy >= SILENCE_RMS {
                        if !stream.voice_active {
                            stream.voice_active = true;
                            let _ = ui_tx.send(UiEvent::SourceActivity {
                                source,
                                active: true,
                            });
                        }
                        stream.last_voice_at = Some(now);
                    } else {
                        let silence_elapsed = stream
                            .last_voice_at
                            .map(|last_voice_at| {
                                now.saturating_duration_since(last_voice_at) >= SILENCE_BREAK_AFTER
                            })
                            .unwrap_or(false);

                        if silence_elapsed && stream.voice_active {
                            stream.voice_active = false;
                            let _ = ui_tx.send(UiEvent::SourceActivity {
                                source,
                                active: false,
                            });
                        }

                        let silence_break = silence_elapsed && !stream.best_text.trim().is_empty();

                        if silence_break {
                            let should_send_agent_update =
                                source == SourceKind::SystemOutput && stream.agent_update_pending;
                            if stream.finish_current_block() {
                                let _ = ui_tx.send(UiEvent::TranscriptBreak { source });
                            }
                            stream.agent_update_pending = false;
                            agent_update_needed = should_send_agent_update;
                            skip_frame = true;
                        } else if stream.best_text.trim().is_empty() {
                            skip_frame = true;
                        }
                    }

                    if skip_frame {
                        // Agent updates are sent after the mutable stream borrow ends.
                    } else {
                        stream.samples.extend(frame.samples);

                        if stream.samples.len() > window_samples {
                            let excess = stream.samples.len() - window_samples;
                            stream.samples.drain(..excess);
                        }

                        if stream.samples.len() < min_stream_samples
                            || stream.last_pass.elapsed() < STREAM_PARTIAL_INTERVAL
                        {
                            continue;
                        }

                        let window = stream.samples.clone();
                        let energy = rms(&window);

                        if energy < SILENCE_RMS {
                            stream.last_pass = Instant::now();
                            let _ = ui_tx.send(UiEvent::Status(format!(
                                "{} listening, rms {:.4}",
                                source.display_name(),
                                energy
                            )));
                            continue;
                        }

                        let _ = ui_tx.send(UiEvent::Status(format!(
                            "Refreshing {} live transcript",
                            source.display_name()
                        )));
                        let started = Instant::now();
                        let text = transcribe_chunk(
                            &ctx,
                            &window,
                            config.language.as_deref(),
                            Some(&stream.prompt),
                        )?
                        .trim()
                        .to_string();
                        let elapsed_ms = started.elapsed().as_millis();
                        stream.last_pass = Instant::now();

                        if text.is_empty() {
                            let _ = ui_tx.send(UiEvent::Status(format!(
                                "{} live pass produced no text",
                                source.display_name()
                            )));
                            continue;
                        }

                        let merged_text = merge_transcript_estimate(&stream.best_text, &text);
                        let text_changed = stream.best_text.trim() != merged_text.trim();
                        if text_changed {
                            stream.best_text = merged_text.clone();
                            stream.pending_commit = merged_text.clone();
                            if source == SourceKind::SystemOutput {
                                stream.agent_update_pending = true;
                            }
                        }

                        let _ = ui_tx.send(UiEvent::PartialTranscript {
                            source,
                            text: merged_text,
                            elapsed_ms,
                            rms: energy,
                        });

                        if stream.last_commit.elapsed() >= STREAM_COMMIT_INTERVAL
                            && !stream.pending_commit.trim().is_empty()
                        {
                            let committed = stream.pending_commit.trim().to_string();
                            stream.pending_commit.clear();
                            stream.last_commit = Instant::now();
                            let full_text = stream.full_text();
                            set_prompt(&mut stream.prompt, &full_text);

                            let _ = ui_tx.send(UiEvent::Transcript {
                                source,
                                text: committed,
                                elapsed_ms,
                                rms: energy,
                            });
                            if source == SourceKind::SystemOutput {
                                stream.agent_update_pending = true;
                            }
                        }
                    }
                }

                if agent_update_needed {
                    send_agent_update(&agent_tx, &streams, config.agent.include_microphone, false);
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    Ok(())
}

fn send_agent_update(
    agent_tx: &Option<Sender<AgentInput>>,
    streams: &HashMap<SourceKind, StreamingSourceState>,
    include_microphone: bool,
    force: bool,
) {
    let system_transcript = streams
        .get(&SourceKind::SystemOutput)
        .map(StreamingSourceState::full_text)
        .unwrap_or_default();
    let microphone_transcript = if include_microphone {
        streams
            .get(&SourceKind::Microphone)
            .map(StreamingSourceState::full_text)
            .filter(|text| !text.is_empty())
    } else {
        None
    };

    if system_transcript.is_empty() && microphone_transcript.is_none() {
        return;
    }

    if let Some(agent_tx) = agent_tx {
        let _ = agent_tx.send(AgentInput {
            system_transcript,
            microphone_transcript,
            force,
        });
    }
}

fn spawn_agent_thread(
    config: AgentConfig,
    rx: Receiver<AgentInput>,
    ui_tx: Sender<UiEvent>,
    stop: Arc<AtomicBool>,
    refresh_generation: Arc<AtomicU64>,
) {
    thread::Builder::new()
        .name("agent-insights".to_string())
        .spawn(move || {
            if let Err(err) =
                agent_loop(config, rx, ui_tx.clone(), stop.clone(), refresh_generation)
            {
                let _ = ui_tx.send(UiEvent::AgentRequestFailed {
                    message: format!("agent failed: {err}"),
                });
            }
        })
        .expect("failed to spawn agent thread");
}

fn agent_loop(
    config: AgentConfig,
    rx: Receiver<AgentInput>,
    ui_tx: Sender<UiEvent>,
    stop: Arc<AtomicBool>,
    refresh_generation: Arc<AtomicU64>,
) -> Result<()> {
    let api_key = config
        .api_key
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow!("missing OpenAI API key"))?
        .to_string();
    let client = reqwest::blocking::Client::builder()
        .timeout(AGENT_HTTP_TIMEOUT)
        .build()
        .context("failed to create OpenAI HTTP client")?;

    let mut latest_input: Option<AgentInput> = None;
    let mut last_submitted = String::new();
    let mut last_result = default_agent_result(&config.fields);
    let mut last_successful_input: Option<AgentInput> = None;
    let mut last_request = Instant::now() - AGENT_REFRESH_INTERVAL;
    let mut seen_refresh_generation = refresh_generation.load(Ordering::SeqCst);

    let _ = ui_tx.send(UiEvent::AgentStatus(format!("ready with {}", config.model)));

    while !stop.load(Ordering::SeqCst) {
        let current_refresh_generation = refresh_generation.load(Ordering::SeqCst);
        if current_refresh_generation != seen_refresh_generation {
            latest_input = None;
            last_submitted.clear();
            last_result = default_agent_result(&config.fields);
            last_successful_input = None;
            last_request = Instant::now() - AGENT_REFRESH_INTERVAL;
            seen_refresh_generation = current_refresh_generation;
            let _ = ui_tx.send(UiEvent::AgentStatus("refreshed".to_string()));
            continue;
        }

        match rx.recv_timeout(Duration::from_millis(250)) {
            Ok(input) => {
                latest_input = Some(input);
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }

        let Some(input) = latest_input.as_ref() else {
            continue;
        };
        let force_requested = input.force;
        let input_signature = agent_input_signature(input);
        if input_signature.trim().is_empty() {
            continue;
        };

        if !force_requested {
            if input_signature == last_submitted || last_request.elapsed() < AGENT_REFRESH_INTERVAL
            {
                continue;
            };
            if !agent_input_has_informative_delta(
                input,
                last_successful_input.as_ref(),
                &last_result,
                config.microphone_delta_gate_field.as_deref(),
            ) {
                last_submitted = input_signature;
                continue;
            }
        }
        let force_hints = force_requested
            || has_explicit_system_question_delta(input, last_successful_input.as_ref());
        let request_body =
            build_agent_request_body(&config, input, last_successful_input.as_ref(), &last_result);
        let query_bytes = serialized_json_bytes(&request_body);

        let started = Instant::now();
        let _ = ui_tx.send(UiEvent::AgentRequestStarted { query_bytes });

        match request_agent_result(&client, &api_key, request_body, &config.fields) {
            Ok(call_result) => {
                last_submitted = input_signature;
                last_successful_input = Some(input.clone());
                last_result = call_result.result.clone();
                let _ = ui_tx.send(UiEvent::AgentOutput {
                    result: call_result.result,
                    usage: call_result.usage,
                    force_hints,
                    elapsed_ms: started.elapsed().as_millis(),
                });
            }
            Err(err) => {
                last_submitted = input_signature;
                let _ = ui_tx.send(UiEvent::AgentRequestFailed {
                    message: format!(
                        "OpenAI request failed: {}",
                        compact_error(&err.to_string(), 90)
                    ),
                });
            }
        }

        last_request = Instant::now();
        if force_requested {
            latest_input = None;
        }
    }

    Ok(())
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
struct AgentUsage {
    input_tokens: u64,
    output_tokens: u64,
    total_tokens: u64,
}

struct AgentCallResult {
    result: Value,
    usage: Option<AgentUsage>,
}

fn request_agent_result(
    client: &reqwest::blocking::Client,
    api_key: &str,
    body: Value,
    fields: &[AgentFieldConfig],
) -> Result<AgentCallResult> {
    let response = client
        .post("https://api.openai.com/v1/responses")
        .bearer_auth(api_key)
        .json(&body)
        .send()
        .context("failed to call OpenAI Responses API")?;
    let status = response.status();
    let response_text = response
        .text()
        .context("failed to read OpenAI response body")?;

    if !status.is_success() {
        return Err(anyhow!(
            "OpenAI API returned {status}: {}",
            compact_error(&response_text, 140)
        ));
    }

    let value: Value =
        serde_json::from_str(&response_text).context("OpenAI response was not valid JSON")?;
    let usage = extract_agent_usage(&value);
    let output_text = extract_response_text(&value)
        .ok_or_else(|| anyhow!("OpenAI response did not contain output text"))?;
    let parsed = serde_json::from_str::<Value>(&output_text)
        .context("OpenAI structured output did not match the agent instruction schema")?;
    if !agent_result_has_renderable_fields(&parsed, fields) {
        return Err(anyhow!("OpenAI response had no renderable fields"));
    }

    Ok(AgentCallResult {
        result: parsed,
        usage,
    })
}

fn build_agent_request_body(
    config: &AgentConfig,
    input: &AgentInput,
    previous_input: Option<&AgentInput>,
    current_state: &Value,
) -> Value {
    let system_new = new_text_since(
        previous_input.map(|input| input.system_transcript.as_str()),
        &input.system_transcript,
        AGENT_CONTEXT_CHARS,
    );
    let microphone_new = input.microphone_transcript.as_ref().map(|current| {
        new_text_since(
            previous_input.and_then(|input| input.microphone_transcript.as_deref()),
            current,
            AGENT_CONTEXT_CHARS,
        )
    });

    let payload = json!({
        "current_agent_state": current_state,
        "transcript_context": {
            "system_output_transcript": recent_chars(&input.system_transcript, AGENT_CONTEXT_CHARS),
            "microphone_transcript": input
                .microphone_transcript
                .as_ref()
                .map(|text| recent_chars(text, AGENT_CONTEXT_CHARS)),
        },
        "new_since_last_agent_update": {
            "system_output": system_new,
            "microphone": microphone_new,
        },
    });

    json!({
        "model": config.model.as_str(),
        "input": [
            {
                "role": "developer",
                "content": [
                    {
                        "type": "input_text",
                        "text": config.instructions.as_str()
                    }
                ]
            },
            {
                "role": "user",
                "content": [
                    {
                        "type": "input_text",
                        "text": serde_json::to_string_pretty(&payload)
                            .unwrap_or_else(|_| payload.to_string())
                    }
                ]
            }
        ],
        "max_output_tokens": config.max_output_tokens,
        "text": {
            "format": {
                "type": "json_schema",
                "name": "enchanted_transcription_agent",
                "strict": true,
                "schema": config.response_schema.clone()
            }
        }
    })
}

fn serialized_json_bytes(value: &Value) -> usize {
    serde_json::to_vec(value)
        .map(|bytes| bytes.len())
        .unwrap_or_else(|_| value.to_string().len())
}

fn agent_input_signature(input: &AgentInput) -> String {
    format!(
        "system:{}\nmic:{}",
        input.system_transcript.trim(),
        input.microphone_transcript.as_deref().unwrap_or("").trim()
    )
}

fn agent_input_has_informative_delta(
    input: &AgentInput,
    previous: Option<&AgentInput>,
    current_state: &Value,
    microphone_delta_gate_field: Option<&str>,
) -> bool {
    let system_new = new_text_since(
        previous.map(|input| input.system_transcript.as_str()),
        &input.system_transcript,
        AGENT_CONTEXT_CHARS,
    );
    if is_informative_text(&system_new) {
        return true;
    }

    if !microphone_delta_gate_field
        .and_then(|key| current_state.get(key))
        .is_some_and(value_has_content)
    {
        return false;
    }

    input
        .microphone_transcript
        .as_ref()
        .map(|current| {
            new_text_since(
                previous.and_then(|input| input.microphone_transcript.as_deref()),
                current,
                AGENT_CONTEXT_CHARS,
            )
        })
        .is_some_and(|microphone_new| is_informative_text(&microphone_new))
}

fn has_explicit_system_question_delta(input: &AgentInput, previous: Option<&AgentInput>) -> bool {
    let system_new = new_text_since(
        previous.map(|input| input.system_transcript.as_str()),
        &input.system_transcript,
        AGENT_CONTEXT_CHARS,
    );
    system_new.contains('?')
}

fn is_informative_text(text: &str) -> bool {
    let alnum_count = text.chars().filter(|value| value.is_alphanumeric()).count();
    let word_count = text
        .split_whitespace()
        .filter(|word| word.chars().any(|value| value.is_alphanumeric()))
        .count();

    text.contains('?') || (alnum_count >= 8 && word_count >= 2)
}

fn new_text_since(previous: Option<&str>, current: &str, max_chars: usize) -> String {
    let current = current.trim();
    let Some(previous) = previous.map(str::trim).filter(|value| !value.is_empty()) else {
        return recent_chars(current, max_chars);
    };
    if current.is_empty() {
        return String::new();
    }
    if current == previous {
        return String::new();
    }
    if let Some(new_text) = current.strip_prefix(previous) {
        return recent_chars(new_text.trim(), max_chars);
    }

    let shared_chars = shared_prefix_char_count(previous, current);
    let current_tail = current
        .char_indices()
        .nth(shared_chars)
        .map(|(index, _)| &current[index..])
        .unwrap_or("");
    if current_tail.trim().is_empty() {
        recent_chars(current, max_chars)
    } else {
        recent_chars(current_tail.trim(), max_chars)
    }
}

fn shared_prefix_char_count(left: &str, right: &str) -> usize {
    left.chars()
        .zip(right.chars())
        .take_while(|(left, right)| left == right)
        .count()
}

fn extract_response_text(value: &Value) -> Option<String> {
    if let Some(text) = value.get("output_text").and_then(Value::as_str) {
        let text = text.trim();
        if !text.is_empty() {
            return Some(text.to_string());
        }
    }

    let output = value.get("output")?.as_array()?;
    let mut chunks = Vec::new();
    for item in output {
        let Some(content) = item.get("content").and_then(Value::as_array) else {
            continue;
        };
        for part in content {
            let part_type = part.get("type").and_then(Value::as_str).unwrap_or("");
            if part_type == "output_text" || part_type == "text" {
                if let Some(text) = part.get("text").and_then(Value::as_str) {
                    if !text.trim().is_empty() {
                        chunks.push(text.trim().to_string());
                    }
                }
            }
        }
    }

    if chunks.is_empty() {
        None
    } else {
        Some(chunks.join("\n"))
    }
}

fn extract_agent_usage(value: &Value) -> Option<AgentUsage> {
    let usage = value.get("usage")?;
    let input_tokens = usage
        .get("input_tokens")
        .or_else(|| usage.get("prompt_tokens"))
        .and_then(Value::as_u64);
    let output_tokens = usage
        .get("output_tokens")
        .or_else(|| usage.get("completion_tokens"))
        .and_then(Value::as_u64);
    let total_tokens = usage.get("total_tokens").and_then(Value::as_u64);

    if input_tokens.is_none() && output_tokens.is_none() && total_tokens.is_none() {
        return None;
    }

    let input_tokens = input_tokens.unwrap_or(0);
    let output_tokens = output_tokens.unwrap_or(0);
    let total_tokens = total_tokens.unwrap_or(input_tokens + output_tokens);

    Some(AgentUsage {
        input_tokens,
        output_tokens,
        total_tokens,
    })
}

fn recent_chars(text: &str, max_chars: usize) -> String {
    let chars: Vec<char> = text.chars().collect();
    if chars.len() <= max_chars {
        return text.to_string();
    }

    chars[chars.len() - max_chars..].iter().collect()
}

fn compact_error(text: &str, max_chars: usize) -> String {
    let compact = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if compact.chars().count() <= max_chars {
        compact
    } else {
        format!("{}...", compact.chars().take(max_chars).collect::<String>())
    }
}

fn transcribe_chunk(
    ctx: &WhisperContext,
    samples: &[f32],
    language: Option<&str>,
    prompt: Option<&str>,
) -> Result<String> {
    let mut state = ctx
        .create_state()
        .context("failed to create Whisper state")?;
    let mut params = FullParams::new(SamplingStrategy::BeamSearch {
        beam_size: 5,
        patience: -1.0,
    });
    params.set_n_threads(8);
    if let Some(language) = language {
        params.set_language(Some(language));
    } else {
        params.set_detect_language(true);
    }
    params.set_translate(false);
    params.set_no_context(false);
    params.set_single_segment(false);
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    params.set_suppress_blank(true);
    params.set_suppress_nst(true);
    params.set_temperature(0.0);
    params.set_split_on_word(true);
    if let Some(prompt) = prompt {
        if !prompt.trim().is_empty() {
            params.set_initial_prompt(prompt);
        }
    }

    state
        .full(params, samples)
        .context("Whisper inference failed")?;

    let mut output = String::new();
    for segment in state.as_iter() {
        let text = segment.to_str_lossy()?.trim().to_string();
        if !text.is_empty() {
            if !output.is_empty() {
                output.push(' ');
            }
            output.push_str(&text);
        }
    }
    Ok(output)
}

fn set_prompt(prompt: &mut String, text: &str) {
    let max_chars = 500;
    *prompt = text
        .trim()
        .chars()
        .rev()
        .take(max_chars)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();
}

fn align_transcript_words(
    existing: &[TranscriptWord],
    next_text: &str,
    now: Instant,
) -> Vec<TranscriptWord> {
    let next_words: Vec<&str> = next_text.split_whitespace().collect();
    if next_words.is_empty() {
        return Vec::new();
    }
    if existing.is_empty() {
        return next_words
            .into_iter()
            .map(|word| TranscriptWord {
                text: word.to_string(),
                first_seen: now,
            })
            .collect();
    }

    let existing_cmp: Vec<String> = existing
        .iter()
        .map(|word| compare_token(&word.text))
        .collect();
    let next_cmp: Vec<String> = next_words.iter().map(|word| compare_token(word)).collect();

    let mut prefix = 0;
    while prefix < existing_cmp.len()
        && prefix < next_cmp.len()
        && existing_cmp[prefix] == next_cmp[prefix]
    {
        prefix += 1;
    }

    let mut suffix = 0;
    while suffix < existing_cmp.len().saturating_sub(prefix)
        && suffix < next_cmp.len().saturating_sub(prefix)
        && existing_cmp[existing_cmp.len() - 1 - suffix] == next_cmp[next_cmp.len() - 1 - suffix]
    {
        suffix += 1;
    }

    next_words
        .iter()
        .enumerate()
        .map(|(index, word)| {
            let first_seen = if index < prefix {
                existing[index].first_seen
            } else if suffix > 0 && index >= next_words.len() - suffix {
                let existing_index = existing.len() - (next_words.len() - index);
                existing[existing_index].first_seen
            } else {
                now
            };

            TranscriptWord {
                text: (*word).to_string(),
                first_seen,
            }
        })
        .collect()
}

fn merge_transcript_estimate(existing: &str, current: &str) -> String {
    let existing = compact_restarted_prefix(existing);
    let current = compact_restarted_prefix(current);
    let existing = existing.trim();
    let current = current.trim();
    if existing.is_empty() {
        return current.to_string();
    }
    if current.is_empty() {
        return existing.to_string();
    }

    let existing_words: Vec<&str> = existing.split_whitespace().collect();
    let current_words: Vec<&str> = current.split_whitespace().collect();
    if existing_words.is_empty() {
        return current.to_string();
    }
    if current_words.is_empty() {
        return existing.to_string();
    }

    let existing_cmp: Vec<String> = existing_words
        .iter()
        .map(|word| compare_token(word))
        .collect();
    let current_cmp: Vec<String> = current_words
        .iter()
        .map(|word| compare_token(word))
        .collect();

    if contains_word_sequence(&current_cmp, &existing_cmp) {
        return current.to_string();
    }
    if contains_word_sequence(&existing_cmp, &current_cmp) {
        return existing.to_string();
    }

    let max_overlap = existing_cmp.len().min(current_cmp.len());
    let shared_prefix = shared_prefix_len(&existing_cmp, &current_cmp);
    if shared_prefix >= MIN_RESTART_PREFIX_WORDS && shared_prefix < max_overlap {
        let existing_tail_len = existing_words.len().saturating_sub(shared_prefix);
        let current_tail_len = current_words.len().saturating_sub(shared_prefix);
        if current_tail_len >= existing_tail_len || current_words.len() + 2 >= existing_words.len()
        {
            return current.to_string();
        }
    }

    let min_overlap = if max_overlap <= 2 { 1 } else { 2 };
    for overlap in (min_overlap..=max_overlap).rev() {
        if existing_cmp[existing_cmp.len() - overlap..] == current_cmp[..overlap] {
            let mut words = Vec::with_capacity(existing_words.len() + current_words.len());
            words.extend_from_slice(&existing_words[..existing_words.len() - overlap]);
            words.extend_from_slice(&current_words);
            return words.join(" ");
        }
    }

    for overlap in (min_overlap..=max_overlap).rev() {
        if current_cmp[current_cmp.len() - overlap..] == existing_cmp[..overlap] {
            let mut words = Vec::with_capacity(existing_words.len() + current_words.len());
            words.extend_from_slice(&current_words[..current_words.len() - overlap]);
            words.extend_from_slice(&existing_words);
            return words.join(" ");
        }
    }

    format!("{existing} {current}")
}

fn compact_restarted_prefix(text: &str) -> String {
    let mut words: Vec<&str> = text.split_whitespace().collect();
    if words.len() < MIN_RESTART_PREFIX_WORDS * 2 {
        return text.trim().to_string();
    }

    loop {
        let cmp: Vec<String> = words.iter().map(|word| compare_token(word)).collect();
        let Some((first_start, second_start, _overlap)) = repeated_revision_span(&cmp) else {
            break;
        };

        let mut compacted = Vec::with_capacity(words.len() - (second_start - first_start));
        compacted.extend_from_slice(&words[..first_start]);
        compacted.extend_from_slice(&words[second_start..]);
        words = compacted;

        if words.len() < MIN_RESTART_PREFIX_WORDS * 2 {
            break;
        }
    }

    words.join(" ")
}

fn repeated_revision_span(tokens: &[String]) -> Option<(usize, usize, usize)> {
    let mut best = None;

    for first_start in 0..tokens.len() {
        for second_start in first_start + 1..tokens.len() {
            let max_overlap = (second_start - first_start).min(tokens.len() - second_start);
            let mut overlap = 0;
            while overlap < max_overlap
                && tokens[first_start + overlap] == tokens[second_start + overlap]
            {
                overlap += 1;
            }

            if overlap < MIN_RESTART_PREFIX_WORDS {
                continue;
            }

            let replace = best
                .map(|(_, _, best_overlap)| overlap > best_overlap)
                .unwrap_or(true);
            if replace {
                best = Some((first_start, second_start, overlap));
            }
        }
    }

    best
}

fn contains_word_sequence(haystack: &[String], needle: &[String]) -> bool {
    if needle.is_empty() || needle.len() > haystack.len() {
        return false;
    }

    haystack
        .windows(needle.len())
        .any(|window| window == needle)
}

fn shared_prefix_len(left: &[String], right: &[String]) -> usize {
    left.iter()
        .zip(right.iter())
        .take_while(|(left, right)| left == right)
        .count()
}

fn compare_token(word: &str) -> String {
    word.trim_matches(|value: char| !value.is_alphanumeric())
        .to_ascii_lowercase()
}

fn rms(samples: &[f32]) -> f32 {
    if samples.is_empty() {
        return 0.0;
    }

    let sum = samples
        .iter()
        .map(|value| value.clamp(-1.0, 1.0))
        .map(|value| value * value)
        .sum::<f32>();
    (sum / samples.len() as f32).sqrt()
}

fn render_loop(
    state: &mut AppState,
    rx: Receiver<UiEvent>,
    stop: Arc<AtomicBool>,
    refresh_generation: Arc<AtomicU64>,
    agent_force_generation: Arc<AtomicU64>,
) -> Result<()> {
    let mut dirty = true;
    let mut last_render = Instant::now() - RENDER_INTERVAL;

    loop {
        while let Ok(app_event) = rx.try_recv() {
            dirty |= state.apply(app_event);
        }

        dirty |= state.agent.promote_pending_fields();

        if !dirty && state.has_fading_content() && last_render.elapsed() >= FADE_RENDER_INTERVAL {
            dirty = true;
        }

        if dirty && last_render.elapsed() >= RENDER_INTERVAL {
            render(state)?;
            dirty = false;
            last_render = Instant::now();
        }

        if event::poll(Duration::from_millis(50))? {
            if let Event::Key(key) = event::read()? {
                if key.code == KeyCode::F(1) {
                    agent_force_generation.fetch_add(1, Ordering::SeqCst);
                    state.agent.status = if state.agent.enabled {
                        "agent update requested".to_string()
                    } else {
                        "off".to_string()
                    };
                    dirty = true;
                    continue;
                }

                if key.code == KeyCode::F(5) {
                    state.refresh_session();
                    refresh_generation.fetch_add(1, Ordering::SeqCst);
                    dirty = true;
                    continue;
                }

                let quit = matches!(key.code, KeyCode::Char('q') | KeyCode::Esc)
                    || (key.code == KeyCode::Char('c')
                        && key.modifiers.contains(KeyModifiers::CONTROL));
                if quit {
                    stop.store(true, Ordering::SeqCst);
                    break;
                }
            }
        }

        if stop.load(Ordering::SeqCst) {
            break;
        }
    }

    Ok(())
}

impl AppState {
    fn has_fading_content(&self) -> bool {
        self.agent.has_content()
            || self.agent.has_pending_content()
            || self.transcripts.values().any(TranscriptState::has_content)
    }
}

fn is_noisy_status(message: &str) -> bool {
    message.contains(" listening, rms ")
        || message.starts_with("Refreshing ")
        || message.ends_with(" live pass produced no text")
}

fn render(state: &AppState) -> Result<()> {
    let (width, height) = terminal::size()?;
    let width = width.max(80);
    let height = height.max(24);
    let usable_width = width.saturating_sub(1) as usize;
    let gap_width = COLUMN_GAP as usize;
    let left_width = usable_width.saturating_sub(gap_width) / 2;
    let right_width = usable_width.saturating_sub(left_width + gap_width);
    let footer_row = height.saturating_sub(1);
    let body_rows = footer_row.saturating_sub(2) as usize;
    let transcript_rows = visible_transcript_rows(state, left_width, body_rows);
    let agent_rows = visible_agent_rows(state, right_width, body_rows);
    let mut out = io::stdout();

    for row in 0..height {
        queue!(out, cursor::MoveTo(0, row))?;
        match row {
            0 => {
                render_segment(&mut out, "Transcription", left_width, Color::White)?;
                render_gap(&mut out, gap_width)?;
                render_agent_header(&mut out, state, right_width)?;
            }
            value if value == footer_row => {
                render_segment(
                    &mut out,
                    &build_footer_line(state),
                    usable_width,
                    Color::DarkGrey,
                )?;
            }
            value if value >= 2 && value < footer_row => {
                let index = (value - 2) as usize;
                if let Some(line) = transcript_rows.get(index) {
                    render_styled_segment(&mut out, line, left_width)?;
                } else {
                    render_segment(&mut out, "", left_width, Color::White)?;
                }
                render_gap(&mut out, gap_width)?;
                if let Some(line) = agent_rows.get(index) {
                    render_right_styled_segment(&mut out, line, right_width)?;
                } else {
                    render_segment(&mut out, "", right_width, Color::White)?;
                }
            }
            _ => {
                render_segment(&mut out, "", usable_width, Color::White)?;
            }
        }
    }

    out.flush()?;
    Ok(())
}

fn render_agent_header(out: &mut io::Stdout, state: &AppState, width: usize) -> Result<()> {
    if width == 0 {
        return Ok(());
    }

    let title = "Agent insights";
    let marker = state.agent.marker();
    let title_width = title.chars().count();
    let marker_width = marker
        .map(|(text, _)| text.chars().count())
        .unwrap_or_default();

    let Some((marker_text, marker_color)) = marker else {
        render_segment(out, title, width, Color::DarkGrey)?;
        return Ok(());
    };

    if title_width + 1 + marker_width > width {
        render_segment(out, title, width, Color::DarkGrey)?;
        return Ok(());
    }

    let spacer_width = width.saturating_sub(title_width + marker_width);
    queue!(
        out,
        SetForegroundColor(Color::DarkGrey),
        Print(title),
        ResetColor,
        Print(" ".repeat(spacer_width)),
        SetForegroundColor(marker_color),
        Print(marker_text),
        ResetColor
    )?;
    Ok(())
}

fn render_segment(out: &mut io::Stdout, text: &str, width: usize, color: Color) -> Result<()> {
    if width == 0 {
        return Ok(());
    }

    queue!(
        out,
        SetForegroundColor(color),
        Print(fit_line(text, width)),
        ResetColor
    )?;
    Ok(())
}

fn render_styled_segment(out: &mut io::Stdout, line: &StyledLine, width: usize) -> Result<()> {
    if width == 0 {
        return Ok(());
    }

    let mut used = 0;
    for segment in &line.segments {
        if used >= width {
            break;
        }

        let available = width - used;
        let text = fit_line_fragment(&segment.text, available);
        used += text.chars().count();
        queue!(
            out,
            SetForegroundColor(segment.color),
            Print(text),
            ResetColor
        )?;
    }

    if used < width {
        queue!(out, Print(" ".repeat(width - used)))?;
    }

    Ok(())
}

fn render_right_styled_segment(
    out: &mut io::Stdout,
    line: &StyledLine,
    width: usize,
) -> Result<()> {
    if width == 0 {
        return Ok(());
    }

    let content_width = styled_line_width(line).min(width);
    let pad = width.saturating_sub(content_width);
    if pad > 0 {
        queue!(out, Print(" ".repeat(pad)))?;
    }
    render_styled_segment(out, line, content_width)
}

fn styled_line_width(line: &StyledLine) -> usize {
    line.segments
        .iter()
        .map(|segment| segment.text.chars().count())
        .sum()
}

fn render_gap(out: &mut io::Stdout, width: usize) -> Result<()> {
    if width > 0 {
        queue!(out, Print(" ".repeat(width)))?;
    }
    Ok(())
}

#[derive(Clone)]
struct StyledLine {
    segments: Vec<StyledSegment>,
}

#[derive(Clone)]
struct StyledSegment {
    text: String,
    color: Color,
}

impl StyledLine {
    fn plain(text: impl Into<String>, color: Color) -> Self {
        Self {
            segments: vec![StyledSegment {
                text: text.into(),
                color,
            }],
        }
    }
}

fn visible_transcript_rows(state: &AppState, width: usize, max_lines: usize) -> Vec<StyledLine> {
    let mut lines = Vec::new();
    if max_lines == 0 || state.sources.is_empty() {
        return lines;
    }

    let source_count = state.sources.len();
    let gaps = source_count.saturating_sub(1).min(max_lines);
    let available = max_lines.saturating_sub(gaps);
    if available == 0 {
        return lines;
    }

    let base = (available / source_count).max(1);
    let mut extra = available % source_count;

    for (index, source) in state.sources.iter().enumerate() {
        if index > 0 && lines.len() < max_lines {
            lines.push(StyledLine::plain("", Color::White));
        }

        let mut section_height = base;
        if extra > 0 {
            section_height += 1;
            extra -= 1;
        }
        let remaining = max_lines.saturating_sub(lines.len());
        section_height = section_height.min(remaining);
        if section_height == 0 {
            break;
        }

        lines.extend(source_transcript_rows(
            state,
            *source,
            width,
            section_height,
        ));
    }

    lines
}

fn source_transcript_rows(
    state: &AppState,
    source: SourceKind,
    width: usize,
    max_lines: usize,
) -> Vec<StyledLine> {
    let mut rows = Vec::new();
    if max_lines == 0 {
        return rows;
    }

    rows.push(StyledLine::plain(
        source.label(),
        source_header_color(source),
    ));

    if max_lines == 1 {
        return rows;
    }

    let body_rows = max_lines - 1;
    let wrapped = if let Some(transcript) = state
        .transcripts
        .get(&source)
        .filter(|transcript| transcript.has_content())
    {
        wrap_transcript_blocks(
            source,
            &transcript.blocks,
            width,
            Instant::now(),
            state.fade_duration,
        )
    } else {
        vec![StyledLine::plain(
            "    waiting for transcript",
            Color::DarkGrey,
        )]
    };

    let start = wrapped.len().saturating_sub(body_rows);
    rows.extend_from_slice(&wrapped[start..]);
    rows
}

fn visible_agent_rows(state: &AppState, width: usize, max_lines: usize) -> Vec<StyledLine> {
    if max_lines == 0 || width == 0 || !state.agent.enabled {
        return Vec::new();
    }

    let mut error_rows = state
        .agent
        .last_error
        .as_ref()
        .map(|message| agent_error_rows(message, width, max_lines.min(4)))
        .unwrap_or_default();
    if error_rows.len() > max_lines {
        let start = error_rows.len().saturating_sub(max_lines);
        error_rows = error_rows[start..].to_vec();
    }

    let separator_rows = usize::from(!error_rows.is_empty() && state.agent.has_content());
    let field_max_lines = max_lines.saturating_sub(error_rows.len() + separator_rows);
    let mut rows = visible_agent_field_rows(state, width, field_max_lines);

    if !error_rows.is_empty() {
        let padding = max_lines.saturating_sub(rows.len() + error_rows.len());
        rows.extend((0..padding).map(|_| StyledLine::plain("", Color::White)));
        rows.extend(error_rows);
    }

    rows
}

fn visible_agent_field_rows(state: &AppState, width: usize, max_lines: usize) -> Vec<StyledLine> {
    if max_lines == 0 || !state.agent.has_content() {
        return Vec::new();
    }

    let active_fields = state
        .agent
        .fields
        .iter()
        .filter(|field| !field.lines.is_empty())
        .collect::<Vec<_>>();
    if active_fields.is_empty() {
        return Vec::new();
    }

    let gaps = active_fields.len().saturating_sub(1).min(max_lines);
    let available = max_lines.saturating_sub(gaps);
    if available == 0 {
        return Vec::new();
    }

    let base = (available / active_fields.len()).max(1);
    let mut extra = available % active_fields.len();
    let mut rows = Vec::new();
    for (index, field) in active_fields.iter().enumerate() {
        if index > 0 && rows.len() < max_lines {
            rows.push(StyledLine::plain("", Color::White));
        }

        let mut section_height = base;
        if extra > 0 {
            section_height += 1;
            extra -= 1;
        }
        let remaining = max_lines.saturating_sub(rows.len());
        section_height = section_height.min(remaining);
        if section_height == 0 {
            break;
        }

        rows.extend(agent_field_rows(
            field,
            width,
            section_height,
            Instant::now(),
            state.fade_duration,
        ));
    }
    rows
}

fn agent_error_rows(message: &str, width: usize, max_lines: usize) -> Vec<StyledLine> {
    if max_lines == 0 {
        return Vec::new();
    }

    let mut rows = vec![StyledLine::plain("Agent error", Color::Red)];
    if max_lines == 1 {
        return rows;
    }

    let wrapped = wrap_plain_text(message.trim(), width.min(72).max(1))
        .into_iter()
        .map(|line| {
            StyledLine::plain(
                line.trim().to_string(),
                Color::Rgb {
                    r: 255,
                    g: 120,
                    b: 120,
                },
            )
        })
        .collect::<Vec<_>>();
    let body_rows = max_lines - 1;
    let start = wrapped.len().saturating_sub(body_rows);
    rows.extend_from_slice(&wrapped[start..]);
    rows
}

fn agent_field_rows(
    field: &AgentFieldState,
    width: usize,
    max_lines: usize,
    now: Instant,
    fade_duration: Duration,
) -> Vec<StyledLine> {
    if max_lines == 0 {
        return Vec::new();
    }

    let age = field
        .updated_at
        .map(|updated_at| now.saturating_duration_since(updated_at))
        .unwrap_or(Duration::ZERO);
    let mut rows = vec![StyledLine::plain(
        field.config.title.clone(),
        agent_title_color(field),
    )];
    if max_lines == 1 {
        return rows;
    }

    let body_rows = max_lines - 1;
    let wrapped = wrap_agent_lines(&field.lines, width)
        .into_iter()
        .map(|line| StyledLine::plain(line, agent_value_color(field, age, fade_duration)))
        .collect::<Vec<_>>();
    let start = wrapped.len().saturating_sub(body_rows);
    rows.extend_from_slice(&wrapped[start..]);
    rows
}

fn wrap_agent_lines(values: &[String], width: usize) -> Vec<String> {
    let usable_width = width.min(72).max(1);
    let mut output = Vec::new();
    for line in values {
        for wrapped in wrap_plain_text(line.trim(), usable_width) {
            output.push(wrapped.trim().to_string());
        }
    }

    if output.is_empty() {
        output.push(String::new());
    }
    output
}

fn source_header_color(source: SourceKind) -> Color {
    match source {
        SourceKind::Microphone => Color::Rgb {
            r: 255,
            g: 80,
            b: 80,
        },
        SourceKind::SystemOutput => Color::White,
    }
}

fn agent_title_color(field: &AgentFieldState) -> Color {
    let (r, g, b) = field.config.title_rgb;
    Color::Rgb { r, g, b }
}

fn agent_value_color(field: &AgentFieldState, age: Duration, fade_duration: Duration) -> Color {
    scale_rgb(field.config.value_rgb, fade_intensity(age, fade_duration))
}

fn source_text_color(source: SourceKind, age: Duration, fade_duration: Duration) -> Color {
    let intensity = fade_intensity(age, fade_duration);
    match source {
        SourceKind::Microphone => scale_rgb((255, 56, 56), intensity),
        SourceKind::SystemOutput => scale_rgb((255, 255, 255), intensity),
    }
}

fn fade_intensity(age: Duration, fade_duration: Duration) -> f32 {
    if age <= TEXT_FULL_INTENSITY {
        return 1.0;
    }

    let fade_age = age.saturating_sub(TEXT_FULL_INTENSITY);
    let ratio = (fade_age.as_secs_f32() / fade_duration.as_secs_f32()).clamp(0.0, 1.0);
    1.0 - ratio * (1.0 - TEXT_MIN_INTENSITY)
}

fn scale_rgb(fresh: (u8, u8, u8), intensity: f32) -> Color {
    let channel = |value: u8| ((value as f32) * intensity).round().clamp(0.0, 255.0) as u8;

    Color::Rgb {
        r: channel(fresh.0),
        g: channel(fresh.1),
        b: channel(fresh.2),
    }
}

fn build_footer_line(state: &AppState) -> String {
    let backend = if state.cuda_enabled { "CUDA" } else { "CPU" };
    let model = state
        .model_path
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("model");
    let language = state.language.as_deref().unwrap_or("auto");
    let sources = state
        .sources
        .iter()
        .map(|source| source.label())
        .collect::<Vec<_>>()
        .join(",");
    let fade_seconds = state.fade_duration.as_secs();
    let agent = if state.agent.enabled {
        format!("agent {} ({})", state.agent.model, state.agent.status)
    } else {
        "agent off".to_string()
    };
    let api_usage = build_api_usage_line(&state.agent);

    format!(
        "backend {backend} | model {model} | language {language} | sources {sources} | fade {fade_seconds}s | {agent} | {api_usage} | {} | F1 agent | F5 refresh | q/Ctrl+C exits",
        state.status
    )
}

fn build_api_usage_line(agent: &AgentPaneState) -> String {
    if !agent.enabled {
        return "api off".to_string();
    }

    let in_flight = if agent.request_in_flight {
        " waiting"
    } else {
        ""
    };
    let last = agent
        .last_total_tokens
        .map(|tokens| tokens.to_string())
        .unwrap_or_else(|| "-".to_string());
    let query_size = agent
        .last_query_bytes
        .map(format_byte_size)
        .unwrap_or_else(|| "-".to_string());

    format!(
        "api {} req{in_flight}, query {query_size}, last {last} tok, total {} tok (in {}, out {})",
        agent.request_count, agent.total_tokens, agent.input_tokens, agent.output_tokens
    )
}

fn format_byte_size(bytes: usize) -> String {
    const KB: f64 = 1024.0;
    const MB: f64 = 1024.0 * 1024.0;

    if bytes < 1024 {
        format!("{bytes} B")
    } else if bytes < 1024 * 1024 {
        format!("{:.1} KB", bytes as f64 / KB)
    } else {
        format!("{:.2} MB", bytes as f64 / MB)
    }
}

fn wrap_transcript_words(
    source: SourceKind,
    words: &[TranscriptWord],
    width: usize,
    now: Instant,
    fade_duration: Duration,
) -> Vec<StyledLine> {
    let indent = "    ";
    let indent_width = indent.len().min(width.saturating_sub(1));
    let mut lines = Vec::new();
    let mut current = StyledLine {
        segments: vec![StyledSegment {
            text: indent[..indent_width].to_string(),
            color: Color::DarkGrey,
        }],
    };
    let mut current_width = indent_width;

    for word in words {
        let word_width = word.text.chars().count();
        let separator_width = usize::from(current_width > indent_width);
        if current_width + separator_width + word_width > width && current_width > indent_width {
            lines.push(current);
            current = StyledLine {
                segments: vec![StyledSegment {
                    text: indent[..indent_width].to_string(),
                    color: Color::DarkGrey,
                }],
            };
            current_width = indent_width;
        }

        if current_width > indent_width {
            current.segments.push(StyledSegment {
                text: " ".to_string(),
                color: source_text_color(
                    source,
                    now.saturating_duration_since(word.first_seen),
                    fade_duration,
                ),
            });
            current_width += 1;
        }

        current.segments.push(StyledSegment {
            text: word.text.clone(),
            color: source_text_color(
                source,
                now.saturating_duration_since(word.first_seen),
                fade_duration,
            ),
        });
        current_width += word_width;
    }

    if current_width > indent_width || lines.is_empty() {
        lines.push(current);
    }

    lines
}

fn wrap_transcript_blocks(
    source: SourceKind,
    blocks: &[TranscriptBlock],
    width: usize,
    now: Instant,
    fade_duration: Duration,
) -> Vec<StyledLine> {
    let mut lines = Vec::new();
    let mut rendered_blocks = 0usize;

    for block in blocks.iter().filter(|block| !block.words.is_empty()) {
        if rendered_blocks > 0 {
            lines.push(StyledLine::plain("", Color::White));
        }
        lines.extend(wrap_transcript_words(
            source,
            &block.words,
            width,
            now,
            fade_duration,
        ));
        rendered_blocks += 1;
    }

    if rendered_blocks > 0
        && blocks
            .last()
            .is_some_and(|block| block.text.trim().is_empty())
    {
        lines.push(StyledLine::plain("", Color::White));
    }

    lines
}

fn wrap_line(line: &str, width: usize) -> Vec<String> {
    if width == 0 {
        return Vec::new();
    }
    if line.trim().is_empty() {
        return vec![String::new()];
    }

    let mut out = Vec::new();
    let indent_width = line
        .chars()
        .take_while(|value| value.is_whitespace())
        .map(|value| if value == '\t' { 4 } else { 1 })
        .sum::<usize>()
        .min(width.saturating_sub(1));
    let indent = " ".repeat(indent_width);
    let mut current = indent.clone();

    for word in line.trim_start().split_whitespace() {
        let extra = usize::from(current.len() > indent_width);
        if current.len() + extra + word.len() > width && !current.is_empty() {
            out.push(current);
            current = indent.clone();
        }
        if current.len() > indent_width {
            current.push(' ');
        }
        current.push_str(word);
    }
    if current.len() > indent_width {
        out.push(current);
    } else if out.is_empty() {
        out.push(String::new());
    }
    out
}

fn wrap_plain_text(text: &str, width: usize) -> Vec<String> {
    let mut lines = Vec::new();
    for paragraph in text.lines() {
        lines.extend(wrap_line(paragraph.trim(), width));
    }
    lines
}

fn fit_line(line: &str, width: usize) -> String {
    if line.len() >= width {
        return line.chars().take(width.saturating_sub(1)).collect();
    }

    format!("{line:<width$}")
}

fn fit_line_fragment(text: &str, width: usize) -> String {
    if text.chars().count() <= width {
        return text.to_string();
    }

    text.chars().take(width).collect()
}

#[cfg(test)]
mod tests {
    use super::{
        agent_input_has_informative_delta, agent_input_signature, align_transcript_words,
        build_response_schema, extract_agent_config_block, extract_agent_usage,
        extract_response_text, fade_intensity, format_byte_size, is_informative_text,
        merge_transcript_estimate, new_text_since, parse_agent_config, serialized_json_bytes,
        AgentInput, AgentUsage, TranscriptState, TranscriptWord, TEXT_MIN_INTENSITY,
    };
    use serde_json::json;
    use std::time::{Duration, Instant};

    #[test]
    fn rolling_window_estimates_replace_overlapping_tail() {
        let mut estimate = String::new();
        for current in [
            "Hello.",
            "Yes, very well, how are you?",
            "Hello. Yes, very well, how are you? Well, I was thinking that maybe we can do something about that.",
            "Well, I was thinking that maybe we could do something about it.",
        ] {
            estimate = merge_transcript_estimate(&estimate, current);
        }

        assert!(estimate.starts_with("Hello. Yes, very well, how are you?"));
        assert!(estimate.contains("maybe we could do something about it."));
        assert_eq!(estimate.matches("Hello.").count(), 1);
    }

    #[test]
    fn longer_compound_window_replaces_previous_shorter_estimate() {
        let estimate = merge_transcript_estimate(
            "Hello. Yes, very well, how are you?",
            "Hello. Yes, very well, how are you? Well, I was thinking.",
        );

        assert_eq!(
            estimate,
            "Hello. Yes, very well, how are you? Well, I was thinking."
        );
    }

    #[test]
    fn newer_shared_prefix_replaces_revised_tail() {
        let estimate = merge_transcript_estimate(
            "Hi, hello. How are you? Well, I would just...",
            "Hi, hello. How are you? Well, I was just thinking how to...",
        );

        assert_eq!(
            estimate,
            "Hi, hello. How are you? Well, I was just thinking how to..."
        );
    }

    #[test]
    fn compact_restarted_prefix_inside_single_hypothesis() {
        let estimate = merge_transcript_estimate(
            "",
            "Hi, hello. How are you? Well, I would just... Hi, hello. How are you? Well, I was just thinking how to...",
        );

        assert_eq!(
            estimate,
            "Hi, hello. How are you? Well, I was just thinking how to..."
        );
    }

    #[test]
    fn compact_internal_repeated_revision_inside_single_hypothesis() {
        let estimate = merge_transcript_estimate(
            "",
            "Hey, hello. What were you? I was just looking into it. I was just looking into getting something done.",
        );

        assert_eq!(
            estimate,
            "Hey, hello. What were you? I was just looking into getting something done."
        );
    }

    #[test]
    fn transcript_word_alignment_preserves_stable_prefix_age() {
        let old_time = Instant::now() - Duration::from_secs(90);
        let new_time = Instant::now();
        let existing = vec![
            TranscriptWord {
                text: "Hello".to_string(),
                first_seen: old_time,
            },
            TranscriptWord {
                text: "there".to_string(),
                first_seen: old_time,
            },
        ];

        let aligned = align_transcript_words(&existing, "Hello there again", new_time);

        assert_eq!(aligned[0].first_seen, old_time);
        assert_eq!(aligned[1].first_seen, old_time);
        assert_eq!(aligned[2].first_seen, new_time);
    }

    #[test]
    fn transcript_break_preserves_previous_blocks() {
        let now = Instant::now();
        let mut transcript = TranscriptState::default();
        {
            let block = transcript.current_block_mut();
            block.text = "First speech block.".to_string();
            block.words = align_transcript_words(&[], &block.text, now);
        }

        assert!(transcript.add_break());
        {
            let block = transcript.current_block_mut();
            block.text = "Second speech block.".to_string();
            block.words = align_transcript_words(&[], &block.text, now);
        }

        assert_eq!(
            transcript.text(),
            "First speech block.\n\nSecond speech block."
        );
    }

    #[test]
    fn text_fade_reaches_configured_floor() {
        let intensity = fade_intensity(Duration::from_secs(120), Duration::from_secs(12));
        assert!((intensity - TEXT_MIN_INTENSITY).abs() < f32::EPSILON);
    }

    #[test]
    fn extracts_responses_api_output_text() {
        let value = json!({
            "output": [
                {
                    "type": "message",
                    "content": [
                        {
                            "type": "output_text",
                            "text": "{\"mode\":\"insight\",\"text\":\"Watch the deadline.\"}"
                        }
                    ]
                }
            ]
        });

        assert_eq!(
            extract_response_text(&value).as_deref(),
            Some("{\"mode\":\"insight\",\"text\":\"Watch the deadline.\"}")
        );
    }

    #[test]
    fn extracts_responses_api_usage() {
        let value = json!({
            "usage": {
                "input_tokens": 120,
                "output_tokens": 30,
                "total_tokens": 150
            }
        });

        assert_eq!(
            extract_agent_usage(&value),
            Some(AgentUsage {
                input_tokens: 120,
                output_tokens: 30,
                total_tokens: 150,
            })
        );
    }

    #[test]
    fn tracks_serialized_query_size() {
        let value = json!({ "input": "hello" });

        assert_eq!(serialized_json_bytes(&value), 17);
        assert_eq!(format_byte_size(1536), "1.5 KB");
    }

    #[test]
    fn extracts_agent_config_and_strips_it_from_prompt() {
        let (config_text, instructions) = extract_agent_config_block(
            r##"
Before.

```agent-config
{
  "fields": [
    {
      "key": "critical_hints",
      "title": "Hints",
      "render": "text",
      "title_color": "#FFD85C",
      "value_color": "#FFEEAA",
      "schema": { "type": "string" }
    }
  ]
}
```

After.
"##,
        )
        .expect("config should parse");

        assert!(config_text.contains("critical_hints"));
        assert!(!instructions.contains("agent-config"));
        assert!(instructions.contains("Before."));
        assert!(instructions.contains("After."));
    }

    #[test]
    fn builds_response_schema_from_agent_config() {
        let parsed = parse_agent_config(
            r##"
{
  "max_output_tokens": 220,
  "fields": [
    {
      "key": "critical_hints",
      "title": "Hints",
      "render": "text",
      "empty": "none",
      "title_color": "#FFD85C",
      "value_color": "#FFEEAA",
      "schema": { "type": "string", "maxLength": 240 }
    },
    {
      "key": "unanswered_questions",
      "title": "Unanswered questions",
      "render": "list",
      "title_color": "#70D6FF",
      "value_color": "#C4ECFF",
      "schema": { "type": "array", "items": { "type": "string" } }
    }
  ]
}
"##,
        )
        .expect("agent config should parse");
        let schema = build_response_schema(&parsed.fields);

        assert_eq!(parsed.fields.len(), 2);
        assert_eq!(parsed.fields[0].title_rgb, (255, 216, 92));
        assert_eq!(schema["type"], "object");
        assert_eq!(schema["properties"]["critical_hints"]["type"], "string");
        assert_eq!(schema["required"][0], "critical_hints");
    }

    #[test]
    fn agent_config_rejects_render_schema_mismatch() {
        let error = match parse_agent_config(
            r##"
{
  "fields": [
    {
      "key": "questions",
      "title": "Questions",
      "render": "list",
      "title_color": "#70D6FF",
      "value_color": "#C4ECFF",
      "schema": { "type": "string" }
    }
  ]
}
"##,
        ) {
            Ok(_) => panic!("agent config should reject list render with string schema"),
            Err(error) => error.to_string(),
        };

        assert!(error.contains("render=list"));
        assert!(error.contains("schema.type must be array"));
    }

    #[test]
    fn agent_config_rejects_missing_microphone_gate_field() {
        let error = match parse_agent_config(
            r##"
{
  "microphone_delta_gate_field": "missing_field",
  "fields": [
    {
      "key": "critical_hints",
      "title": "Hints",
      "render": "text",
      "title_color": "#FFD85C",
      "value_color": "#FFEEAA",
      "schema": { "type": "string" }
    }
  ]
}
"##,
        ) {
            Ok(_) => panic!("agent config should reject a missing microphone gate field"),
            Err(error) => error.to_string(),
        };

        assert!(error.contains("microphone_delta_gate_field"));
        assert!(error.contains("references missing field"));
    }

    #[test]
    fn repository_agent_instructions_config_is_valid() {
        let markdown = include_str!("../agent-instructions.md");
        let (config_text, instructions) =
            extract_agent_config_block(markdown).expect("agent-config block should exist");
        let parsed = parse_agent_config(&config_text).expect("agent-config should be valid");
        let schema = build_response_schema(&parsed.fields);

        assert!(!instructions.contains("```agent-config"));
        let required = schema["required"]
            .as_array()
            .expect("schema required fields should be an array");
        assert_eq!(required.len(), parsed.fields.len());
        for field in &parsed.fields {
            assert!(schema["properties"].get(&field.key).is_some());
            assert!(required.iter().any(|value| value == &field.key));
        }
    }

    #[test]
    fn agent_input_signature_labels_sources() {
        let signature = agent_input_signature(&AgentInput {
            system_transcript: "What is the deadline?".to_string(),
            microphone_transcript: Some("I can answer that.".to_string()),
            force: false,
        });

        assert!(signature.contains("system:What is the deadline?"));
        assert!(signature.contains("mic:I can answer that."));
    }

    #[test]
    fn new_text_since_returns_suffix_for_extended_transcript() {
        assert_eq!(
            new_text_since(
                Some("We need the answer"),
                "We need the answer by Friday.",
                100
            ),
            "by Friday."
        );
    }

    #[test]
    fn new_text_since_returns_revised_tail_after_whisper_revision() {
        assert_eq!(
            new_text_since(
                Some("We need the answer by Thursday."),
                "We need the answer by Friday.",
                100
            ),
            "Friday."
        );
    }

    #[test]
    fn informative_text_ignores_tiny_churn() {
        assert!(!is_informative_text("..."));
        assert!(!is_informative_text("uh"));
        assert!(is_informative_text("Any updates?"));
        assert!(is_informative_text("need answer"));
    }

    #[test]
    fn agent_delta_gate_skips_empty_revisions() {
        let previous = AgentInput {
            system_transcript: "We should decide soon.".to_string(),
            microphone_transcript: None,
            force: false,
        };
        let current = AgentInput {
            system_transcript: "We should decide soon...".to_string(),
            microphone_transcript: None,
            force: false,
        };

        assert!(!agent_input_has_informative_delta(
            &current,
            Some(&previous),
            &json!({ "unanswered_questions": [] }),
            Some("unanswered_questions")
        ));
    }

    #[test]
    fn agent_delta_gate_skips_mic_only_changes_without_questions() {
        let previous = AgentInput {
            system_transcript: "Can we discuss the launch?".to_string(),
            microphone_transcript: Some("Yes.".to_string()),
            force: false,
        };
        let current = AgentInput {
            system_transcript: "Can we discuss the launch?".to_string(),
            microphone_transcript: Some("Yes. The launch is on track.".to_string()),
            force: false,
        };

        assert!(!agent_input_has_informative_delta(
            &current,
            Some(&previous),
            &json!({ "unanswered_questions": [] }),
            Some("unanswered_questions")
        ));
    }

    #[test]
    fn agent_delta_gate_allows_mic_only_changes_when_questions_are_open() {
        let previous = AgentInput {
            system_transcript: "When is the launch?".to_string(),
            microphone_transcript: Some("Let me check.".to_string()),
            force: false,
        };
        let current = AgentInput {
            system_transcript: "When is the launch?".to_string(),
            microphone_transcript: Some("Let me check. It is planned for Friday.".to_string()),
            force: false,
        };
        let state = json!({
            "critical_hints": "Answer with the date.",
            "unanswered_questions": ["When is the launch?"],
            "conversation_value": "Useful planning."
        });

        assert!(agent_input_has_informative_delta(
            &current,
            Some(&previous),
            &state,
            Some("unanswered_questions")
        ));
    }
}
