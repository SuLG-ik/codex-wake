use std::sync::Arc;

use codex_protocol::models::FunctionCallOutputPayload;
use codex_protocol::models::ResponseItem;
use tokio::sync::Mutex;
use tokio::sync::Notify;
use tokio_util::sync::CancellationToken;

use super::TurnInput;
use super::session::Session;
use super::turn_context::TurnContext;

const BACKGROUND_COMMAND_INSTRUCTIONS: &str = r#"

## Waiting for long shell commands

When a long-running shell command is a prerequisite for the next step and both
`exec_command` and `write_stdin` support Wake, use the following sequence even
if the user has not explicitly asked you to resume.

- Start the command with `exec_command` and a short initial wait such as
  `yield_time_ms: 1000`. Leave `on_exit` unset on this first call so you can see
  whether the command is still running.
- If the tool returns a live session ID, send a brief commentary message to the
  user in their language. Say that the command is running and that you will pause
  here and continue when its result arrives. Send this update after the launch
  and before requesting the pause. If the command has already exited, proceed
  directly with its result.
- Call `write_stdin` for that session ID with empty `chars` and `on_exit: "wake"`.
  This parks the current turn. There is no need to poll or ask the user to
  send another message.
- When the runtime delivers the result, use the output and exit status to
  continue the original task from where you left off. Carry out any remaining
  steps before reporting the final outcome.

Honor the user's explicit preferences for a foreground wait or silent handling.
"#;

pub(super) fn with_background_command_instructions(mut instructions: String) -> String {
    instructions.push_str(BACKGROUND_COMMAND_INSTRUCTIONS);
    instructions
}

/// Finish foreground sampling after the current tool outputs have been recorded.
pub(crate) struct BackgroundHandoff;

/// Admit ready results in a synthetic wake after the new turn has been registered.
pub(crate) struct ReceiveBackgroundResults;

#[derive(Default)]
struct BackgroundResults {
    pending: Mutex<Vec<TurnInput>>,
    ready: Notify,
}

impl Session {
    fn background_results(&self) -> Arc<BackgroundResults> {
        self.services
            .thread_extension_data
            .get_or_init(BackgroundResults::default)
    }

    pub(crate) async fn has_background_results(&self) -> bool {
        let Some(results) = self
            .services
            .thread_extension_data
            .get::<BackgroundResults>()
        else {
            return false;
        };
        !results.pending.lock().await.is_empty()
    }

    pub(crate) async fn take_background_results(&self) -> Vec<TurnInput> {
        let Some(results) = self
            .services
            .thread_extension_data
            .get::<BackgroundResults>()
        else {
            return Vec::new();
        };
        std::mem::take(&mut *results.pending.lock().await)
    }

    pub(crate) async fn publish_background_result(self: &Arc<Self>, text: String) {
        let results = self.background_results();
        let mut item = ResponseItem::FunctionCallOutput {
            id: None,
            call_id: None,
            name: Some("background_command_completed".into()),
            namespace: None,
            output: FunctionCallOutputPayload::from_text(text),
            internal_chat_message_metadata_passthrough: None,
        };
        self.assign_missing_response_item_id(&mut item);
        results
            .pending
            .lock()
            .await
            .push(TurnInput::FunctionCallOutput(item.into()));
        results.ready.notify_one();
        self.maybe_start_turn_for_pending_work().await;
    }

    /// Keep child agents running in the registry while they await their own jobs.
    /// The wait uses a runtime notification and can be interrupted by new input.
    pub(super) async fn wait_for_background_result(
        &self,
        turn: &TurnContext,
        cancel: &CancellationToken,
    ) -> Vec<TurnInput> {
        let results = self.background_results();
        let (mut activity, pending) =
            crate::thread_input::subscribe_input_activity(self, &turn.sub_id).await;
        loop {
            let ready = results.ready.notified();
            let input = self.take_background_results().await;
            if !input.is_empty() || pending.is_some() {
                return input;
            }
            tokio::select! {
                _ = ready => {}
                _ = activity.changed() => return self.take_background_results().await,
                _ = cancel.cancelled() => return Vec::new(),
            }
        }
    }
}
