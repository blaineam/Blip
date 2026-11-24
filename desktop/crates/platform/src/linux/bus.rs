//! Shared D-Bus connections and small helpers. Every call is a plain property read or an
//! unprivileged method (no polkit prompt is ever raised: interactive auth is off).

use std::sync::OnceLock;

use zbus::blocking::{Connection, Proxy};
use zbus::zvariant::{OwnedObjectPath, OwnedValue};

pub fn system() -> Option<&'static Connection> {
    static C: OnceLock<Option<Connection>> = OnceLock::new();
    C.get_or_init(|| Connection::system().ok()).as_ref()
}

pub fn session() -> Option<&'static Connection> {
    static C: OnceLock<Option<Connection>> = OnceLock::new();
    C.get_or_init(|| Connection::session().ok()).as_ref()
}

pub fn proxy<'a>(conn: &'a Connection, dest: &'a str, path: &'a str, iface: &'a str) -> Option<Proxy<'a>> {
    Proxy::new(conn, dest, path.to_string(), iface).ok()
}

pub fn prop<T>(conn: &Connection, dest: &str, path: &str, iface: &str, name: &str) -> Option<T>
where
    T: TryFrom<OwnedValue>,
    T::Error: Into<zbus::Error>,
{
    proxy(conn, dest, path, iface)?.get_property::<T>(name).ok()
}

/// Whether a well-known name currently has an owner on this bus.
pub fn has_owner(conn: &Connection, name: &str) -> bool {
    proxy(
        conn,
        "org.freedesktop.DBus",
        "/org/freedesktop/DBus",
        "org.freedesktop.DBus",
    )
    .and_then(|p| p.call::<_, _, bool>("NameHasOwner", &(name,)).ok())
    .unwrap_or(false)
}

pub fn path_str(p: &OwnedObjectPath) -> String {
    p.as_str().to_string()
}
