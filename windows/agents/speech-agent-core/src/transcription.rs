use super::{run, AppResult, ProductMode};

pub fn run_app() -> AppResult<()> {
    run(ProductMode::Transcription)
}
