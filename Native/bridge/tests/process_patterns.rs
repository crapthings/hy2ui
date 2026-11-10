//! Pins the supported process-pattern syntax independently from kernel metadata availability.
use hysteria_cli::desktop_routing::matches;
// Links the native shim used by the adapted core on macOS.
extern crate hy2_bridge;

/// Checks application prefixes, executable globs and case sensitivity against concrete paths.
#[test]
fn supported_process_pattern_shapes() {
    assert!(matches("Chrome*", "/Applications/Google Chrome.app/Contents/MacOS/Chrome Helper"));
    assert!(matches("/Applications/Google Chrome.app/", "/Applications/Google Chrome.app/Contents/MacOS/Chrome Helper"));
    assert!(!matches("/Applications/Google Chrome.app/", "/Applications/Google Chrome.app.fake/bin"));
    assert!(matches("/usr/*/p?ng", "/usr/bin/ping"));
    assert!(!matches("chrome", "/usr/bin/Chrome"));
    assert!(!matches("curl", "/usr/bin/curl-helper"));
}


/// Compiles mixed rules and preserves filename, prefix, Unicode and wildcard matching semantics.
#[test]
fn indexed_patterns_cover_mixed_rules() {
    use rule_index::RuleIndex;
    let index = RuleIndex::new(&["curl", "/usr/bin/ping", "/Applications/Example.app/", "Chrome*", "/opt/*/代理?"]
        .map(str::to_owned));
    for path in ["/bin/curl", "/usr/bin/ping", "/Applications/Example.app/Contents/MacOS/Helper", "/tmp/Chrome Helper", "/opt/bin/代理甲"] {
        assert!(index.matches(path), "{path}");
    }
    for path in ["/bin/Curl", "/usr/bin/ping-other", "/Applications/Example.app.bad/Helper", "/opt/bin/代理甲乙"] {
        assert!(!index.matches(path), "{path}");
    }
}

/// Includes the first-party compiled matcher without relying on private core exports.
#[path = "../../../Patches/desktop-rule-index.rs"]
mod rule_index;
