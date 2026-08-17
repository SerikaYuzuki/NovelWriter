//! Explicit auth integration gate. This is intentionally not part of the
//! production server and never falls back to the LAN development database.
fn main() {
    match std::env::var("AUTH_V2_TEST_DATABASE_URL") {
        Ok(_) => {
            eprintln!("NO-GO: AUTH_V2_TEST_DATABASE_URL is set, but the temporary-PostgreSQL race suite is not wired in this WIP.");
            std::process::exit(2);
        }
        Err(_) => {
            eprintln!("NO-GO: set AUTH_V2_TEST_DATABASE_URL to an isolated temporary PostgreSQL database before running auth_v2_scenario_runner.");
            std::process::exit(2);
        }
    }
}
