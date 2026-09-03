use std::collections::HashMap;
use std::path::{Component, Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::protocol::{Catalog, ConversationKind, ConversationSummary, ProjectSummary, ProviderId};

pub fn build_catalog(
    provider: ProviderId,
    home: impl AsRef<Path>,
    sessions: Vec<ConversationSummary>,
) -> anyhow::Result<Catalog> {
    let home = home.as_ref();
    let mut conversations: Vec<_> = sessions
        .into_iter()
        .filter(|conversation| conversation.provider == provider)
        .collect();
    conversations.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.id.cmp(&right.id))
    });

    let mut projects: HashMap<String, ProjectSummary> = HashMap::new();
    for conversation in &conversations {
        if conversation.kind != ConversationKind::Project {
            continue;
        }
        let Some(path) = conversation.project_path.as_deref() else {
            continue;
        };
        let canonical_path = canonical_or_normalized(Path::new(path));
        let id = project_id(provider, &canonical_path);
        let display_path = friendly_path(Path::new(path), home);
        let available = Path::new(&canonical_path).is_dir();
        projects
            .entry(canonical_path.clone())
            .and_modify(|project| {
                if conversation.updated_at > project.updated_at {
                    project.updated_at = conversation.updated_at;
                }
                project.available |= available;
            })
            .or_insert_with(|| ProjectSummary {
                id,
                provider,
                canonical_path: canonical_path.clone(),
                display_path: display_path.clone(),
                title: Path::new(&canonical_path)
                    .file_name()
                    .and_then(|name| name.to_str())
                    .unwrap_or(&display_path)
                    .to_owned(),
                updated_at: conversation.updated_at,
                available,
            });
    }
    let mut projects: Vec<_> = projects.into_values().collect();
    projects.sort_by(|left, right| {
        right
            .updated_at
            .cmp(&left.updated_at)
            .then_with(|| left.id.cmp(&right.id))
    });

    Ok(Catalog {
        projects,
        conversations,
    })
}

fn project_id(provider: ProviderId, canonical_path: &str) -> String {
    let provider = match provider {
        ProviderId::Codex => "codex",
        ProviderId::Claude => "claude",
    };
    format!("{provider}:{:x}", Sha256::digest(canonical_path.as_bytes()))
}

fn canonical_or_normalized(path: &Path) -> String {
    if let Ok(canonical) = path.canonicalize() {
        return canonical.to_string_lossy().into_owned();
    }
    let mut normalized = PathBuf::new();
    for component in path.components() {
        match component {
            Component::CurDir => {}
            Component::ParentDir => {
                normalized.pop();
            }
            other => normalized.push(other.as_os_str()),
        }
    }
    normalized.to_string_lossy().into_owned()
}

fn friendly_path(path: &Path, home: &Path) -> String {
    if let Ok(relative) = path.strip_prefix(home) {
        if relative.as_os_str().is_empty() {
            "~".into()
        } else {
            format!("~/{}", relative.to_string_lossy())
        }
    } else {
        path.to_string_lossy().into_owned()
    }
}
