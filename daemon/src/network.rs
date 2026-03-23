//! Network domain filtering — MITM proxy concept.
//!
//! In production (vm.md §9.3, §6.5), sdk-daemon runs a MITM proxy at
//! /var/run/mitm-proxy.sock that:
//!   - Enforces domain allowlist from srt-settings.json
//!   - Intercepts *.anthropic.com to inject OAuth tokens
//!   - Blocks requests with disallowed beta features in headers
//!
//! This module implements the domain filtering logic.

use tracing::{info, warn};

/// Default allowed domains from srt-settings.json (vm.md §6.5).
const DEFAULT_ALLOWED_DOMAINS: &[&str] = &[
    "registry.npmjs.org",
    "npmjs.com",
    "www.npmjs.com",
    "yarnpkg.com",
    "registry.yarnpkg.com",
    "pypi.org",
    "files.pythonhosted.org",
    "github.com",
    "archive.ubuntu.com",
    "security.ubuntu.com",
    "api.anthropic.com",
    "*.anthropic.com",
    "anthropic.com",
    "crates.io",
    "index.crates.io",
    "static.crates.io",
    "statsig.anthropic.com",
    "sentry.io",
    "*.sentry.io",
];

/// Check if a domain is allowed by the allowlist.
///
/// Supports wildcard patterns like `*.anthropic.com`.
pub fn is_domain_allowed(domain: &str, extra_allowed: &[String]) -> bool {
    let check = |pattern: &str| -> bool {
        if pattern.starts_with("*.") {
            let suffix = &pattern[1..]; // ".anthropic.com"
            domain.ends_with(suffix) || domain == &pattern[2..]
        } else {
            domain == pattern
        }
    };

    for pattern in DEFAULT_ALLOWED_DOMAINS {
        if check(pattern) {
            return true;
        }
    }

    for pattern in extra_allowed {
        if check(pattern) {
            return true;
        }
    }

    false
}

/// Check if a request should be proxied (for OAuth token injection).
///
/// All *.anthropic.com traffic goes through the MITM proxy.
pub fn needs_mitm_proxy(domain: &str) -> bool {
    domain == "anthropic.com" || domain.ends_with(".anthropic.com")
}

/// Log a domain check result (matches production log format).
pub fn check_and_log(domain: &str, extra_allowed: &[String]) -> bool {
    let allowed = is_domain_allowed(domain, extra_allowed);
    if allowed {
        if needs_mitm_proxy(domain) {
            info!("[proxy] allowing {domain} (via MITM proxy)");
        } else {
            info!("[proxy] allowing {domain}");
        }
    } else {
        warn!("[proxy] blocking request to {domain} - not in allowed domains");
    }
    allowed
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_allowed_domains() {
        assert!(is_domain_allowed("github.com", &[]));
        assert!(is_domain_allowed("registry.npmjs.org", &[]));
        assert!(is_domain_allowed("api.anthropic.com", &[]));
        assert!(is_domain_allowed("statsig.anthropic.com", &[]));
        assert!(is_domain_allowed("crates.io", &[]));

        // Wildcard match
        assert!(is_domain_allowed("foo.anthropic.com", &[]));
        assert!(is_domain_allowed("abc.sentry.io", &[]));

        // Not allowed
        assert!(!is_domain_allowed("evil.com", &[]));
        assert!(!is_domain_allowed("google.com", &[]));
    }

    #[test]
    fn test_extra_allowed() {
        assert!(!is_domain_allowed("internal.corp.com", &[]));
        assert!(is_domain_allowed(
            "internal.corp.com",
            &["internal.corp.com".to_string()]
        ));
    }

    #[test]
    fn test_mitm_proxy() {
        assert!(needs_mitm_proxy("anthropic.com"));
        assert!(needs_mitm_proxy("api.anthropic.com"));
        assert!(needs_mitm_proxy("statsig.anthropic.com"));
        assert!(!needs_mitm_proxy("github.com"));
    }
}
