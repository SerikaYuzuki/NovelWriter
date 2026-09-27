pub mod account_deletion;
pub mod application;
pub mod auth;
pub mod auth_apple;
pub mod auth_application;
pub mod auth_browser;
pub mod auth_domain;
pub mod auth_google;
pub mod auth_http;
pub mod auth_postgres;
pub mod auth_service;
pub mod auth_vault;
pub mod auth_wire;
pub mod domain;
pub mod http;
pub mod object_store;
pub mod postgres;

pub use auth::RuntimeMode;
pub use domain::{AuthenticatedPrincipal, CommandKind, SealedCommand, SyncError};
pub use http::{router, AppState};
pub use postgres::Repository;

mod work_deletion;

pub mod upload_chunks;

mod protection_http;
pub mod work_recovery;

mod assistant_http;
pub mod assistant_records;
