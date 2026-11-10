//! Checks scoped-route planning and ownership against synthetic tables without modifying host routes.
#![cfg(target_os = "macos")]
use route_manager::Route;
use hysteria_cli::desktop_direct_routes::{plan, still_owned};

/// Constructs a physical IPv4 default used only as in-memory route data.
fn v4(index: u32) -> Route {
    Route::new("0.0.0.0".parse().unwrap(), 0).with_gateway("192.168.50.1".parse().unwrap()).with_if_index(index).with_if_name("en1".into())
}

/// Adds scoped defaults without replacing the unscoped route or taking ownership of existing scoped routes.
#[test]
fn plans_only_missing_selected_defaults() {
    let base = v4(19);
    let tunnel = Route::new("0.0.0.0".parse().unwrap(), 1).with_if_index(26);
    let original = vec![base.clone(), v4(20), tunnel];
    let planned = plan(&original, 19, 0);
    assert_eq!(planned, vec![base.clone().with_if_scope(true)]);
    assert!(!original[0].if_scope());
    assert!(plan(&[base.with_if_scope(true)], 19, 0).is_empty());
}

/// Keeps absent IPv6, unrelated interfaces and split TUN routes out of the bypass plan.
#[test]
fn missing_families_never_borrow_other_defaults() {
    assert!(plan(&[v4(20)], 19, 0).is_empty());
    let ipv6 = Route::new("::".parse().unwrap(), 0).with_gateway("fe80::1".parse().unwrap()).with_if_index(19);
    assert!(plan(&[v4(19), ipv6.clone()], 0, 0).is_empty());
    assert_eq!(plan(&[v4(19), ipv6.clone()], 0, 19), vec![ipv6.with_if_scope(true)]);
}

/// Preserves a replacement gateway or interface during cleanup instead of deleting another owner's route.
#[test]
fn cleanup_requires_exact_current_identity() {
    let ours = v4(19).with_if_scope(true);
    assert!(still_owned(&ours, &[ours.clone()]));
    assert!(!still_owned(&ours, &[ours.clone().with_gateway("192.168.50.254".parse().unwrap())]));
    assert!(!still_owned(&ours, &[ours.clone().with_if_index(20)]));
    assert!(!still_owned(&ours, &[v4(19)]));
}

/// Includes the first-party journal model's pure validation tests without invoking its privileged operations.
#[allow(dead_code)]
#[path = "../../../Patches/desktop-direct-routes.rs"]
mod journal_model;
