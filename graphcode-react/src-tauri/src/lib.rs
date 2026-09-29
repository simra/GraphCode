mod connection;
mod endpoint;
mod navigation_history;
mod protocol;
mod settings;
mod terminal;
mod transport;
mod ui_layout;
mod workspace;

use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc, Mutex,
};

use connection::ConnectionHandle;
use endpoint::discover;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tauri::{
    menu::{MenuBuilder, MenuItemBuilder, SubmenuBuilder},
    Emitter, Manager, RunEvent, State,
};
use thiserror::Error;

struct BridgeState {
    connection: Mutex<Option<ConnectionHandle>>,
    native_menu_revision: Mutex<u64>,
    navigation_history: Mutex<()>,
    settings: Mutex<()>,
    terminal: terminal::TerminalManager,
    ui_layout: Mutex<()>,
    _workspace_guard: workspace::WorkspaceGuard,
}

impl BridgeState {
    fn new() -> Result<Self, workspace::WorkspaceError> {
        Ok(Self {
            connection: Mutex::new(None),
            native_menu_revision: Mutex::new(0),
            navigation_history: Mutex::new(()),
            settings: Mutex::new(()),
            terminal: terminal::TerminalManager::default(),
            ui_layout: Mutex::new(()),
            _workspace_guard: workspace::WorkspaceGuard::acquire()?,
        })
    }
}

#[derive(Debug, Error)]
enum BridgeError {
    #[error(transparent)]
    Endpoint(#[from] endpoint::EndpointError),
    #[error("failed to resolve Tauri application data directory: {0}")]
    AppData(String),
    #[error("failed to load persistent daemon client identity: {0}")]
    ClientIdentity(String),
    #[error("failed to load persistent daemon replay state: {0}")]
    ReplayState(String),
    #[error("daemon connection has not been started")]
    NotStarted,
    #[error("failed to update native menu: {0}")]
    Menu(String),
    #[error("failed to access persistent navigation history: {0}")]
    NavigationHistory(String),
    #[error("failed to access persistent UI layout: {0}")]
    UiLayout(String),
    #[error("workspace operation failed to finish: {0}")]
    WorkspaceTask(String),
    #[error(transparent)]
    Settings(#[from] settings::SettingsError),
    #[error(transparent)]
    Terminal(#[from] terminal::TerminalError),
    #[error(transparent)]
    Workspace(#[from] workspace::WorkspaceError),
    #[error(transparent)]
    Connection(#[from] connection::ConnectionError),
}

impl Serialize for BridgeError {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.to_string())
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ConnectionStart {
    endpoint: String,
    client_id: String,
    resume_from: Option<u64>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct NativeMenuCommand {
    id: String,
    label: String,
    category: String,
    enabled: bool,
    accelerator: Option<String>,
}

fn should_apply_native_menu_revision(current: u64, incoming: u64) -> bool {
    incoming > current
}

#[tauri::command]
async fn start_daemon_connection(
    app: tauri::AppHandle,
    state: State<'_, BridgeState>,
) -> Result<ConnectionStart, BridgeError> {
    let endpoint = discover()?;
    let endpoint_name = endpoint.display_name();
    let state_directory = app
        .path()
        .app_data_dir()
        .map_err(|error| BridgeError::AppData(error.to_string()))?;
    let client_id = connection::load_or_create_client_id(&state_directory)
        .map_err(|error| BridgeError::ClientIdentity(error.to_string()))?;
    let resume_from = connection::load_replay_cursor(&state_directory)
        .map_err(|error| BridgeError::ReplayState(error.to_string()))?;

    let mut guard = state
        .connection
        .lock()
        .expect("bridge state mutex poisoned");
    if guard.is_none() {
        *guard = Some(connection::spawn(
            app,
            endpoint,
            state_directory,
            client_id,
            resume_from,
        ));
    }

    Ok(ConnectionStart {
        endpoint: endpoint_name,
        client_id: client_id.to_string(),
        resume_from,
    })
}

#[tauri::command]
async fn send_daemon_command(
    state: State<'_, BridgeState>,
    command: Value,
) -> Result<Value, BridgeError> {
    let connection = state
        .connection
        .lock()
        .expect("bridge state mutex poisoned")
        .clone()
        .ok_or(BridgeError::NotStarted)?;
    connection.request(command).await.map_err(Into::into)
}

#[tauri::command]
async fn acknowledge_daemon_sequence(
    state: State<'_, BridgeState>,
    sequence: u64,
) -> Result<(), BridgeError> {
    let connection = state
        .connection
        .lock()
        .expect("bridge state mutex poisoned")
        .clone()
        .ok_or(BridgeError::NotStarted)?;
    connection.acknowledge(sequence).await.map_err(Into::into)
}

#[tauri::command]
async fn open_terminal(
    state: State<'_, BridgeState>,
    target: terminal::TerminalTarget,
    columns: u16,
    rows: u16,
    on_event: tauri::ipc::Channel<terminal::TerminalEvent>,
) -> Result<terminal::TerminalOpenResult, BridgeError> {
    state
        .terminal
        .open(target, columns, rows, on_event)
        .await
        .map_err(Into::into)
}

#[tauri::command]
async fn write_terminal(
    state: State<'_, BridgeState>,
    handle: String,
    data: String,
) -> Result<(), BridgeError> {
    state
        .terminal
        .write(&handle, &data)
        .await
        .map_err(Into::into)
}

#[tauri::command]
async fn resize_terminal(
    state: State<'_, BridgeState>,
    handle: String,
    columns: u16,
    rows: u16,
) -> Result<(), BridgeError> {
    state
        .terminal
        .resize(&handle, columns, rows)
        .await
        .map_err(Into::into)
}

#[tauri::command]
async fn acknowledge_terminal_output(
    state: State<'_, BridgeState>,
    handle: String,
    sequence: u64,
) -> Result<(), BridgeError> {
    state
        .terminal
        .acknowledge(&handle, sequence)
        .await
        .map_err(Into::into)
}

#[tauri::command]
async fn close_terminal(state: State<'_, BridgeState>, handle: String) -> Result<(), BridgeError> {
    state.terminal.close(&handle).await.map_err(Into::into)
}

#[tauri::command]
async fn kill_terminal_session(
    state: State<'_, BridgeState>,
    surface_id: String,
) -> Result<(), BridgeError> {
    state
        .terminal
        .kill_owned_shell(&surface_id)
        .await
        .map_err(Into::into)
}

#[tauri::command]
async fn load_terminal_history(
    node_id: String,
    max_bytes: usize,
) -> Result<terminal::TerminalHistory, BridgeError> {
    terminal::history(&node_id, max_bytes)
        .await
        .map_err(Into::into)
}

#[tauri::command]
fn load_settings(state: State<'_, BridgeState>) -> Result<settings::SettingsSnapshot, BridgeError> {
    let _guard = state.settings.lock().expect("settings mutex poisoned");
    settings::load().map_err(Into::into)
}

#[tauri::command]
fn set_daemon_heartbeat_enabled(
    state: State<'_, BridgeState>,
    expected_revision: String,
    enabled: bool,
) -> Result<settings::SettingsSnapshot, BridgeError> {
    let _guard = state.settings.lock().expect("settings mutex poisoned");
    settings::set_daemon_heartbeat(&expected_revision, enabled).map_err(Into::into)
}

#[tauri::command]
async fn list_workspaces() -> Result<Vec<workspace::WorkspaceSummary>, BridgeError> {
    tauri::async_runtime::spawn_blocking(workspace::list)
        .await
        .map_err(|error| BridgeError::WorkspaceTask(error.to_string()))?
        .map_err(Into::into)
}

#[tauri::command]
async fn create_workspace(name: String) -> Result<workspace::WorkspaceSummary, BridgeError> {
    tauri::async_runtime::spawn_blocking(move || workspace::create(&name))
        .await
        .map_err(|error| BridgeError::WorkspaceTask(error.to_string()))?
        .map_err(Into::into)
}

#[tauri::command]
async fn rename_workspace(
    id: String,
    name: String,
) -> Result<workspace::WorkspaceSummary, BridgeError> {
    tauri::async_runtime::spawn_blocking(move || workspace::rename(&id, &name))
        .await
        .map_err(|error| BridgeError::WorkspaceTask(error.to_string()))?
        .map_err(Into::into)
}

#[tauri::command]
async fn prepare_workspace_deletion(
    id: String,
) -> Result<workspace::WorkspaceDeletionPlan, BridgeError> {
    tauri::async_runtime::spawn_blocking(move || workspace::prepare_delete(&id))
        .await
        .map_err(|error| BridgeError::WorkspaceTask(error.to_string()))?
        .map_err(Into::into)
}

#[tauri::command]
async fn delete_workspace(id: String, expected_path: String) -> Result<(), BridgeError> {
    tauri::async_runtime::spawn_blocking(move || workspace::delete(&id, &expected_path))
        .await
        .map_err(|error| BridgeError::WorkspaceTask(error.to_string()))?
        .map_err(Into::into)
}

#[tauri::command]
async fn open_workspace(id: String) -> Result<(), BridgeError> {
    tauri::async_runtime::spawn_blocking(move || workspace::open(&id))
        .await
        .map_err(|error| BridgeError::WorkspaceTask(error.to_string()))?
        .map_err(Into::into)
}

#[tauri::command]
fn set_native_menu(
    app: tauri::AppHandle,
    state: State<'_, BridgeState>,
    revision: u64,
    commands: Vec<NativeMenuCommand>,
) -> Result<(), BridgeError> {
    let mut current_revision = state
        .native_menu_revision
        .lock()
        .expect("native menu revision mutex poisoned");
    if !should_apply_native_menu_revision(*current_revision, revision) {
        return Ok(());
    }

    let mut menu = MenuBuilder::new(&app);
    for category in [
        "GraphCode",
        "Project",
        "Loop",
        "Terminal",
        "View",
        "Navigation",
    ] {
        let category_commands: Vec<_> = commands
            .iter()
            .filter(|command| command.category == category)
            .collect();
        if category_commands.is_empty() {
            continue;
        }

        let mut submenu = SubmenuBuilder::new(&app, category);
        for command in category_commands {
            let mut item =
                MenuItemBuilder::with_id(&command.id, &command.label).enabled(command.enabled);
            if let Some(accelerator) = &command.accelerator {
                item = item.accelerator(accelerator);
            }
            let item = item
                .build(&app)
                .map_err(|error| BridgeError::Menu(error.to_string()))?;
            submenu = submenu.item(&item);
        }
        let submenu = submenu
            .build()
            .map_err(|error| BridgeError::Menu(error.to_string()))?;
        menu = menu.item(&submenu);
    }
    let menu = menu
        .build()
        .map_err(|error| BridgeError::Menu(error.to_string()))?;
    app.set_menu(menu)
        .map_err(|error| BridgeError::Menu(error.to_string()))?;
    *current_revision = revision;
    Ok(())
}

#[tauri::command]
fn load_ui_layout(
    app: tauri::AppHandle,
    state: State<'_, BridgeState>,
) -> Result<ui_layout::LayoutState, BridgeError> {
    let _guard = state
        .ui_layout
        .lock()
        .expect("UI layout state mutex poisoned");
    let state_directory = app
        .path()
        .app_data_dir()
        .map_err(|error| BridgeError::AppData(error.to_string()))?;
    ui_layout::load(&state_directory).map_err(|error| BridgeError::UiLayout(error.to_string()))
}

#[tauri::command]
fn load_navigation_history(
    app: tauri::AppHandle,
    state: State<'_, BridgeState>,
) -> Result<navigation_history::NavigationHistory, BridgeError> {
    let _guard = state
        .navigation_history
        .lock()
        .expect("navigation history mutex poisoned");
    let state_directory = app
        .path()
        .app_data_dir()
        .map_err(|error| BridgeError::AppData(error.to_string()))?;
    navigation_history::load(&state_directory)
        .map_err(|error| BridgeError::NavigationHistory(error.to_string()))
}

#[tauri::command]
fn save_navigation_history(
    app: tauri::AppHandle,
    state: State<'_, BridgeState>,
    history: navigation_history::NavigationHistory,
) -> Result<(), BridgeError> {
    let _guard = state
        .navigation_history
        .lock()
        .expect("navigation history mutex poisoned");
    let state_directory = app
        .path()
        .app_data_dir()
        .map_err(|error| BridgeError::AppData(error.to_string()))?;
    navigation_history::save(&state_directory, history)
        .map_err(|error| BridgeError::NavigationHistory(error.to_string()))
}

#[tauri::command]
fn save_ui_viewport(
    app: tauri::AppHandle,
    state: State<'_, BridgeState>,
    project_path: String,
    view_key: String,
    viewport: ui_layout::Viewport,
) -> Result<(), BridgeError> {
    let _guard = state
        .ui_layout
        .lock()
        .expect("UI layout state mutex poisoned");
    let state_directory = app
        .path()
        .app_data_dir()
        .map_err(|error| BridgeError::AppData(error.to_string()))?;
    ui_layout::save_viewport(&state_directory, project_path, view_key, viewport)
        .map_err(|error| BridgeError::UiLayout(error.to_string()))
}

#[tauri::command]
fn save_ui_node_positions(
    app: tauri::AppHandle,
    state: State<'_, BridgeState>,
    project_path: String,
    view_key: String,
    positions: std::collections::BTreeMap<String, ui_layout::Position>,
) -> Result<(), BridgeError> {
    let _guard = state
        .ui_layout
        .lock()
        .expect("UI layout state mutex poisoned");
    let state_directory = app
        .path()
        .app_data_dir()
        .map_err(|error| BridgeError::AppData(error.to_string()))?;
    ui_layout::save_node_positions(&state_directory, project_path, view_key, positions)
        .map_err(|error| BridgeError::UiLayout(error.to_string()))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let state = BridgeState::new().expect("failed to initialize GraphCode workspace state");
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .manage(state)
        .on_menu_event(|app, event| {
            let _ = app.emit("menu://command", event.id().as_ref());
        })
        .invoke_handler(tauri::generate_handler![
            start_daemon_connection,
            send_daemon_command,
            acknowledge_daemon_sequence,
            open_terminal,
            write_terminal,
            resize_terminal,
            acknowledge_terminal_output,
            close_terminal,
            kill_terminal_session,
            load_terminal_history,
            load_settings,
            set_daemon_heartbeat_enabled,
            list_workspaces,
            create_workspace,
            rename_workspace,
            prepare_workspace_deletion,
            delete_workspace,
            open_workspace,
            set_native_menu,
            load_navigation_history,
            save_navigation_history,
            load_ui_layout,
            save_ui_viewport,
            save_ui_node_positions
        ])
        .build(tauri::generate_context!())
        .expect("failed to build GraphCode React");
    let exiting = Arc::new(AtomicBool::new(false));
    app.run(move |app_handle, event| {
        if let RunEvent::ExitRequested { api, code, .. } = event {
            if !exiting.swap(true, Ordering::SeqCst) {
                api.prevent_exit();
                let app_handle = app_handle.clone();
                tauri::async_runtime::spawn(async move {
                    if let Err(error) = app_handle.state::<BridgeState>().terminal.shutdown().await
                    {
                        eprintln!("failed to clean up local shell sessions: {error}");
                    }
                    app_handle.exit(code.unwrap_or(0));
                });
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{negotiate, read_frame, request, write_frame};
    use serde_json::json;
    use tokio::time::{timeout, Duration};
    use uuid::Uuid;

    fn response_matches_request(frame: &Value, request_id: Uuid) -> bool {
        frame
            .get("requestID")
            .and_then(Value::as_str)
            .and_then(|value| Uuid::parse_str(value).ok())
            == Some(request_id)
    }

    #[test]
    fn native_menu_revisions_reject_stale_rebuilds() {
        assert!(!should_apply_native_menu_revision(4, 3));
        assert!(!should_apply_native_menu_revision(4, 4));
        assert!(should_apply_native_menu_revision(4, 5));
    }

    #[test]
    fn native_menu_command_preserves_enabled_projection() {
        let command: NativeMenuCommand = serde_json::from_value(json!({
            "id": "loop.new",
            "label": "New Loop",
            "category": "Loop",
            "enabled": true,
            "accelerator": "Ctrl+N"
        }))
        .unwrap();

        assert!(command.enabled);
        assert_eq!(command.id, "loop.new");
    }

    #[test]
    fn request_correlation_accepts_swift_uppercase_uuid_encoding() {
        let request_id = Uuid::parse_str("69ecfae8-e0d0-48f3-ae5c-bba390bd0b30").unwrap();
        let frame = json!({
            "version": 2,
            "kind": "response",
            "requestID": "69ECFAE8-E0D0-48F3-AE5C-BBA390BD0B30",
            "success": true
        });

        assert!(response_matches_request(&frame, request_id));
    }

    #[tokio::test]
    async fn live_daemon_lists_recent_projects_when_requested() {
        if std::env::var_os("GRAPHCODE_RUN_LIVE_DAEMON_TEST").is_none() {
            return;
        }

        let endpoint = discover().unwrap();
        let mut stream = transport::connect(&endpoint).await.unwrap();
        negotiate(&mut stream).await.unwrap();
        let (request_id, request) = request(json!({ "listRecentProjects": {} }));
        write_frame(&mut stream, &request).await.unwrap();
        let response = timeout(Duration::from_secs(15), read_frame(&mut stream))
            .await
            .expect("live daemon response timed out")
            .unwrap();

        assert!(response_matches_request(&response, request_id));
        assert_eq!(
            response.get("kind"),
            Some(&Value::String("response".into()))
        );
        assert!(response["event"].get("recentProjectsListed").is_some());
    }
}
