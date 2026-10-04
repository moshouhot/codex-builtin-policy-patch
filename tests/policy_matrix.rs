//! A/B harness: run the full dangerous-command rule corpus through the two
//! public entry points and report what the classifier decides.
//!
//! Usage: policy_matrix <corpus.json>
//! Reads the corpus, prints one JSON result object per case to stdout.

use codex_shell_command::is_dangerous_command::{
    DangerousCommandPlatform, dangerous_command_match_for_platform,
    dangerous_powershell_words_match,
};
use serde::Deserialize;

#[derive(Deserialize)]
struct Case {
    id: String,
    argv: Vec<String>,
    /// "posix" | "windows"
    platform: String,
}

#[derive(Deserialize)]
struct Corpus {
    cases: Vec<Case>,
}

fn main() {
    let path = std::env::args().nth(1).expect("usage: policy_matrix <corpus.json>");
    let text = std::fs::read_to_string(&path).expect("read corpus");
    let corpus: Corpus = serde_json::from_str(&text).expect("parse corpus");

    let mut out = Vec::new();
    for case in &corpus.cases {
        let platform = match case.platform.as_str() {
            "posix" => DangerousCommandPlatform::Posix,
            _ => DangerousCommandPlatform::Windows,
        };
        let generic = dangerous_command_match_for_platform(&case.argv, platform);
        let ps_words = dangerous_powershell_words_match(&case.argv, platform);
        out.push(serde_json::json!({
            "id": case.id,
            "platform": case.platform,
            "argv": case.argv,
            "generic": generic.map(|m| format!("{m:?}")),
            "powershell_words": ps_words.map(|m| format!("{m:?}")),
            "any_match": generic.is_some() || ps_words.is_some(),
        }));
    }
    println!("{}", serde_json::to_string_pretty(&out).unwrap());
}
