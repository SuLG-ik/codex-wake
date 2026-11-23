use std::io::Write;
use std::path::PathBuf;
use std::sync::Mutex;
use std::time::SystemTime;
use std::time::UNIX_EPOCH;

use serde::Serialize;

/// A live Wake command shared with the local Desktop launcher.
pub(super) struct DesktopTask {
    path: PathBuf,
    details: TaskDetails,
    published: Mutex<bool>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct TaskDetails {
    thread_id: String,
    process_id: i32,
    command: String,
    server_pid: u32,
    started_at_ms: u64,
}

impl DesktopTask {
    pub(super) fn new(thread_id: String, process_id: i32, command: &str) -> Option<Self> {
        let directory = PathBuf::from(std::env::var_os("CODEX_WAKE_SOCKET")?);
        let server_pid = std::process::id();
        let path = directory.join(format!("wake-task-{server_pid}-{}.json", uuid::Uuid::new_v4()));
        let started_at_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_millis()
            .try_into()
            .unwrap_or(u64::MAX);
        Some(Self {
            path,
            details: TaskDetails {
                thread_id,
                process_id,
                command: command.to_owned(),
                server_pid,
                started_at_ms,
            },
            published: Mutex::new(false),
        })
    }

    pub(super) fn publish_if(&self, is_running: impl FnOnce() -> bool) {
        let mut published = self.published.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if *published || !is_running() {
            return;
        }
        let result = (|| -> std::io::Result<()> {
            let Some(directory) = self.path.parent() else {
                return Ok(());
            };
            let mut file = tempfile::NamedTempFile::new_in(directory)?;
            let contents = serde_json::to_vec(&self.details)?;
            file.write_all(&contents)?;
            file.persist(&self.path)?;
            Ok(())
        })();
        match result {
            Ok(()) => *published = true,
            Err(error) => tracing::debug!(%error, "could not publish Wake command status"),
        }
    }

    fn stop_path(&self) -> PathBuf {
        self.path.with_extension("json.stop")
    }

    pub(super) fn take_stop_request(&self) -> bool {
        std::fs::remove_file(self.stop_path()).is_ok()
    }

    pub(super) fn clear(&self) {
        let mut published = self.published.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if *published {
            let _ = std::fs::remove_file(&self.path);
            let _ = std::fs::remove_file(self.stop_path());
            *published = false;
        }
    }
}

impl Drop for DesktopTask {
    fn drop(&mut self) {
        self.clear();
    }
}
