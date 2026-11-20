use std::sync::Arc;

use codex_protocol::models::FunctionCallOutputPayload;
use codex_protocol::models::ResponseItem;
use tokio::sync::Mutex;
use tokio::sync::Notify;
use tokio_util::sync::CancellationToken;

use super::TurnInput;
use super::session::Session;
use super::turn_context::TurnContext;

/// Finish foreground sampling after the current tool outputs have been recorded.
pub(crate) struct BackgroundHandoff;

/// Admit ready results in a synthetic wake after the new turn has been registered.
pub(crate) struct ReceiveBackgroundResults;

struct BackgroundAgentMailWait;

#[derive(Default)]
struct BackgroundResults {
    pending: Mutex<Vec<TurnInput>>,
    ready: Notify,
}

impl Session {
    pub(crate) fn arm_background_agent_mail_wait(&self, turn: &TurnContext) {
        self.services
            .thread_extension_data
            .insert(BackgroundAgentMailWait);
        turn.extension_data.insert(BackgroundHandoff);
    }

    pub(crate) fn has_background_agent_mail_wait(&self) -> bool {
        self.services
            .thread_extension_data
            .get::<BackgroundAgentMailWait>()
            .is_some()
    }

    pub(crate) fn clear_background_agent_mail_wait(&self) {
        self.services
            .thread_extension_data
            .remove::<BackgroundAgentMailWait>();
    }

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
