//! Compiles process patterns into exact-key tables, prefix keys and pre-parsed wildcard patterns.
use std::collections::HashSet;

/// Keeps exact lookups separate from the smaller wildcard rule set.
#[derive(Default)]
pub struct RuleIndex {
    paths: HashSet<String>,
    names: HashSet<String>,
    prefixes: HashSet<String>,
    globs: Vec<(bool, Vec<char>)>,
}

/// Builds immutable tables and matches paths without re-parsing configured patterns.
impl RuleIndex {
    pub fn new(patterns: &[String]) -> Self {
        let mut index = Self::default();
        for pattern in patterns {
            if pattern.starts_with('/') && pattern.ends_with('/') { index.prefixes.insert(pattern.clone()); }
            else if pattern.contains(['*', '?']) { index.globs.push((pattern.starts_with('/'), pattern.chars().collect())); }
            else if pattern.starts_with('/') { index.paths.insert(pattern.clone()); }
            else { index.names.insert(pattern.clone()); }
        }
        index
    }
    pub fn matches(&self, path: &str) -> bool {
        let name = path.rsplit('/').next().unwrap_or("");
        if self.paths.contains(path) || self.names.contains(name) { return true; }
        if path.match_indices('/').any(|(offset, _)| self.prefixes.contains(&path[..=offset])) { return true; }
        if self.globs.is_empty() { return false; }
        let full: Vec<_> = path.chars().collect(); let name: Vec<_> = name.chars().collect();
        self.globs.iter().any(|(absolute, pattern)| glob(pattern, if *absolute { &full } else { &name }))
    }
}

/// Matches a pre-parsed case-sensitive wildcard pattern with bounded backtracking storage.
fn glob(pattern: &[char], value: &[char]) -> bool {
    let (mut p, mut v, mut star, mut restart) = (0, 0, None, 0);
    while v < value.len() {
        if p < pattern.len() && (pattern[p] == '?' || pattern[p] == value[v]) { p += 1; v += 1; }
        else if p < pattern.len() && pattern[p] == '*' { star = Some(p); p += 1; restart = v; }
        else if let Some(index) = star { restart += 1; v = restart; p = index + 1; }
        else { return false; }
    }
    while p < pattern.len() && pattern[p] == '*' { p += 1; }
    p == pattern.len()
}
