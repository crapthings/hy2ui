import Foundation

/// Generates shell proxy exports from validated loopback ports without embedding server credentials.
public enum ShellProxyCommand {
    public static func make(httpPort: Int, socksPort: Int) -> String? {
        guard (1024...65535).contains(httpPort), (1024...65535).contains(socksPort), httpPort != socksPort else { return nil }
        let http = "http://127.0.0.1:\(httpPort)"
        let socks = "socks5h://127.0.0.1:\(socksPort)"
        return "export http_proxy='\(http)' https_proxy='\(http)' all_proxy='\(socks)' HTTP_PROXY='\(http)' HTTPS_PROXY='\(http)' ALL_PROXY='\(socks)'"
    }
}
