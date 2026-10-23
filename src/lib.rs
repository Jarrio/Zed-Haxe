//! Zed side of the Haxe extension.
//!
//! This only starts processes: everything Haxe-specific (finding the project, running `lime display`,
//! picking the Haxe version, fixing up LSP messages) lives in the bridge, written in Haxe under `bridge/`.
//! Zed runs `node bridge.js --server <server.js>`, and the bridge starts haxe-language-server itself.

use std::{env, fs};

use zed_extension_api::{
    self as zed, CodeLabel, CodeLabelSpan, LanguageServerId, LanguageServerInstallationStatus,
    Result, Worktree,
    lsp::{Completion, CompletionKind, Symbol, SymbolKind},
    serde_json::{Map, Value},
    settings::LspSettings,
};

/// Name of the language server in extension.toml and in users' `lsp` settings.
const SERVER_ID: &str = "haxe-language-server";

/// Fork of vshaxe/haxe-language-server whose releases hold unmodified builds (see scripts/release-server.sh).
const SERVER_REPO: &str = "Jarrio/haxe-language-server";
/// Upstream commit of vshaxe/haxe-language-server that the release was built from.
const SERVER_VERSION: &str = "e865ce6";
const SERVER_ASSET: &str = "haxe-language-server.js";

/// Built by `haxe build.hxml` in `bridge/`.
const BRIDGE_JS: &str = include_str!("../bridge/bin/bridge.js");

struct HaxeExtension {
    server_path: Option<String>,
}

impl zed::Extension for HaxeExtension {
    fn new() -> Self {
        HaxeExtension { server_path: None }
    }

    fn language_server_command(
        &mut self,
        id: &LanguageServerId,
        worktree: &Worktree,
    ) -> Result<zed::Command> {
        let settings = user_settings(worktree);
        // `"server": {"path": "/path/to/server.js"}` uses a local build of the server.
        let server = match settings.pointer("/server/path").and_then(Value::as_str) {
            Some(path) => path.to_string(),
            None => self.server_js(id)?,
        };
        Ok(zed::Command {
            command: zed::node_binary_path()?,
            args: vec![write_bridge()?, "--server".to_string(), server],
            // The user's shell environment, so the bridge finds haxe, haxelib, lime, ceramic, hx...
            env: worktree.shell_env(),
        })
    }

    fn language_server_initialization_options(
        &mut self,
        _id: &LanguageServerId,
        worktree: &Worktree,
    ) -> Result<Option<Value>> {
        let mut options = LspSettings::for_worktree(SERVER_ID, worktree)
            .ok()
            .and_then(|s| s.initialization_options)
            .and_then(|o| o.as_object().cloned())
            .unwrap_or_default();
        // The bridge needs the project settings before the server starts, so they travel here too.
        if let Some(project) = user_settings(worktree).get("project") {
            options.insert("project".to_string(), project.clone());
        }
        Ok(Some(Value::Object(options)))
    }

    fn language_server_workspace_configuration(
        &mut self,
        _id: &LanguageServerId,
        worktree: &Worktree,
    ) -> Result<Option<Value>> {
        Ok(Some(user_settings(worktree)))
    }

    fn label_for_completion(
        &self,
        _: &LanguageServerId,
        completion: Completion,
    ) -> Option<CodeLabel> {
        let wrapper = match completion.kind? {
            CompletionKind::Function => FUNCTION,
            CompletionKind::Method => METHOD,
            CompletionKind::Class => CLASS,
            CompletionKind::Interface => INTERFACE,
            CompletionKind::Variable => VARIABLE,
            CompletionKind::Constant => CONSTANT,
            CompletionKind::Field => FIELD,
            CompletionKind::Property => PROPERTY,
            CompletionKind::Enum => ENUM,
            CompletionKind::EnumMember => ENUM_MEMBER,
            CompletionKind::Constructor => CONSTRUCTOR,
            CompletionKind::TypeParameter => TYPE_PARAMETER,
            CompletionKind::Keyword => ("", ""),
            _ => return None,
        };
        Some(highlighted_label(completion.label.trim(), wrapper))
    }

    fn label_for_symbol(&self, _: &LanguageServerId, symbol: Symbol) -> Option<CodeLabel> {
        let wrapper = match symbol.kind {
            SymbolKind::Function => FUNCTION,
            SymbolKind::Method => METHOD,
            SymbolKind::Class => CLASS,
            SymbolKind::Interface => INTERFACE,
            SymbolKind::Variable => VARIABLE,
            SymbolKind::Constant => CONSTANT,
            SymbolKind::Field => FIELD,
            SymbolKind::Property => PROPERTY,
            SymbolKind::Enum => ENUM,
            SymbolKind::EnumMember => ENUM_MEMBER,
            SymbolKind::Constructor => CONSTRUCTOR,
            SymbolKind::TypeParameter => TYPE_PARAMETER,
            _ => return None,
        };
        Some(highlighted_label(symbol.name.trim(), wrapper))
    }
}

impl HaxeExtension {
    /// Path of the pinned server.js, downloading it on first use.
    fn server_js(&mut self, id: &LanguageServerId) -> Result<String> {
        if let Some(path) = &self.server_path {
            if is_file(path) {
                return Ok(path.clone());
            }
        }
        let dir = format!("{SERVER_ID}-{SERVER_VERSION}");
        let mut path = format!("{dir}/server.js");
        if !is_file(&path) {
            if let Err(error) = download_server(id, &dir, &path) {
                zed::set_language_server_installation_status(
                    id,
                    &LanguageServerInstallationStatus::None,
                );
                // Offline: fall back to a previously downloaded version.
                path = previous_server().ok_or_else(|| {
                    format!(
                        "Could not download haxe-language-server: {error}\n\
                         To use a local build, set lsp.{SERVER_ID}.settings.server.path to its server.js."
                    )
                })?;
                eprintln!("haxe: using previously downloaded {path}; download failed: {error}");
            }
        }
        let absolute = absolute(&path)?;
        self.server_path = Some(absolute.clone());
        Ok(absolute)
    }
}

fn download_server(id: &LanguageServerId, dir: &str, path: &str) -> Result<()> {
    zed::set_language_server_installation_status(
        id,
        &LanguageServerInstallationStatus::Downloading,
    );
    let tag = format!("server-{SERVER_VERSION}");
    let release = zed::github_release_by_tag_name(SERVER_REPO, &tag)?;
    let asset = release
        .assets
        .iter()
        .find(|asset| asset.name == SERVER_ASSET)
        .ok_or_else(|| format!("release {tag} of {SERVER_REPO} has no {SERVER_ASSET}"))?;
    fs::create_dir_all(dir).map_err(|e| format!("could not create {dir}: {e}"))?;
    zed::download_file(
        &asset.download_url,
        path,
        zed::DownloadedFileType::Uncompressed,
    )?;
    zed::set_language_server_installation_status(id, &LanguageServerInstallationStatus::None);

    // Remove older downloads.
    if let Ok(entries) = fs::read_dir(".") {
        for entry in entries.flatten() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.starts_with(&format!("{SERVER_ID}-")) && name != dir {
                fs::remove_dir_all(entry.path()).ok();
            }
        }
    }
    Ok(())
}

fn previous_server() -> Option<String> {
    let mut found: Vec<String> = fs::read_dir(".")
        .ok()?
        .flatten()
        .map(|entry| format!("{}/server.js", entry.file_name().to_string_lossy()))
        .filter(|path| path.starts_with(&format!("{SERVER_ID}-")) && is_file(path))
        .collect();
    found.sort();
    found.pop()
}

/// Writes the embedded bridge into the extension's work directory, if it changed.
fn write_bridge() -> Result<String> {
    let path = "bridge.js";
    if fs::read_to_string(path).ok().as_deref() != Some(BRIDGE_JS) {
        fs::write(path, BRIDGE_JS).map_err(|e| format!("could not write {path}: {e}"))?;
    }
    absolute(path)
}

/// The `settings` object of `lsp.haxe-language-server` (holds `project`, `server` and `haxe`).
fn user_settings(worktree: &Worktree) -> Value {
    LspSettings::for_worktree(SERVER_ID, worktree)
        .ok()
        .and_then(|s| s.settings)
        .unwrap_or_else(|| Value::Object(Map::new()))
}

fn is_file(path: &str) -> bool {
    fs::metadata(path).map(|m| m.is_file()).unwrap_or(false)
}

fn absolute(path: &str) -> Result<String> {
    let dir = env::current_dir().map_err(|e| e.to_string())?;
    Ok(dir.join(path).to_string_lossy().to_string())
}

/// Code placed around a name so tree-sitter can colour completion and symbol labels like Haxe code.
type Wrapper = (&'static str, &'static str);
const FUNCTION: Wrapper = ("function NOT_REAL_", "(){}");
const METHOD: Wrapper = ("class NOT_REAL { public function NOT_REAL_", "(){} }");
const CLASS: Wrapper = ("class NOT_REAL_", "{}");
const INTERFACE: Wrapper = ("interface NOT_REAL_", "{}");
const VARIABLE: Wrapper = ("var NOT_REAL_", ":Any;");
const CONSTANT: Wrapper = ("public static inline final NOT_REAL_", ":Any = null;");
const FIELD: Wrapper = ("class NOT_REAL { var NOT_REAL_", ":Any; }");
const PROPERTY: Wrapper = ("class NOT_REAL { var NOT_REAL_", "(get, set):Any; }");
const ENUM: Wrapper = ("enum NOT_REAL_", "{}");
const ENUM_MEMBER: Wrapper = ("enum NOT_REAL { NOT_REAL_", "; }");
const CONSTRUCTOR: Wrapper = ("enum NOT_REAL { NOT_REAL_", "(foo:Any); }");
const TYPE_PARAMETER: Wrapper = ("class NOT_REAL<", ">{}");

fn highlighted_label(name: &str, (prefix, suffix): Wrapper) -> CodeLabel {
    CodeLabel {
        spans: vec![CodeLabelSpan::code_range(
            prefix.len()..(prefix.len() + name.len()),
        )],
        filter_range: (0..name.len()).into(),
        code: format!("{prefix}{name}{suffix}"),
    }
}

zed::register_extension!(HaxeExtension);
