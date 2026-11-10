import Foundation

/// Generates a deterministic PAC script with explicit direct rules and no automatic direct fallback.
public enum PACScript {
    public static func generate(configuration: RoutingConfiguration, httpPort: Int) throws -> String {
        try configuration.validate()
        guard (1024...65535).contains(httpPort) else { throw ConfigurationError.invalid("本地代理端口无效。") }
        let domains = try configuration.directDomains.map(RoutingConfiguration.domain)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Dictionary(domains.map { ($0, true) }, uniquingKeysWith: { _, value in value }))
        let list = String(decoding: data, as: UTF8.self)
        return """
        var hy2DirectDomains = \(list);
        function hy2PrivateV4(p) {
          if (p.length !== 4) return false;
          for (var i = 0; i < 4; i++) if (!/^\\d+$/.test(p[i]) || +p[i] > 255) return false;
          var a = +p[0], b = +p[1];
          return a === 10 || a === 127 || (a === 172 && b >= 16 && b <= 31) ||
                 (a === 192 && b === 168) || (a === 169 && b === 254);
        }
        function hy2PrivateLiteral(host) {
          if (host.indexOf(':') < 0) return hy2PrivateV4(host.split('.'));
          host = host.split('%')[0];
          if (host.indexOf('.') >= 0) {
            var last = host.lastIndexOf(':'), p = host.slice(last + 1).split('.');
            if (p.length !== 4) return false;
            for (var i = 0; i < 4; i++) if (!/^\\d+$/.test(p[i]) || +p[i] > 255) return false;
            host = host.slice(0, last + 1) + ((+p[0] << 8) | +p[1]).toString(16) + ':' + ((+p[2] << 8) | +p[3]).toString(16);
          }
          var halves = host.split('::'), words = [], left = halves[0] ? halves[0].split(':') : [];
          if (halves.length > 2) return false;
          var right = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
          if (halves.length === 1) { if (left.length !== 8) return false; words = left; }
          else {
            if (left.length + right.length >= 8) return false;
            words = left.slice();
            while (words.length < 8 - right.length) words.push('0');
            words = words.concat(right);
          }
          for (var j = 0; j < 8; j++) {
            if (!/^[0-9a-f]{1,4}$/.test(words[j])) return false;
            words[j] = parseInt(words[j], 16);
          }
          if ((words[0] & 65024) === 64512 || (words[0] & 65472) === 65152) return true;
          var zero = true;
          for (var k = 0; k < 5; k++) if (words[k] !== 0) zero = false;
          if (zero && words[5] === 0 && words[6] === 0 && words[7] === 1) return true;
          return zero && words[5] === 65535 && hy2PrivateV4([String(words[6] >> 8), String(words[6] & 255), String(words[7] >> 8), String(words[7] & 255)]);
        }
        function FindProxyForURL(url, host) {
          host = host.toLowerCase();
          if (host.charAt(0) === '[' && host.charAt(host.length - 1) === ']') host = host.slice(1, -1);
          if (host.charAt(host.length - 1) === '.') host = host.slice(0, -1);
          var candidate = host;
          while (candidate) {
            if (Object.prototype.hasOwnProperty.call(hy2DirectDomains, candidate)) return 'DIRECT';
            var dot = candidate.indexOf('.');
            if (dot < 0) break;
            candidate = candidate.slice(dot + 1);
          }
          if (\(configuration.bypassLocalNetworks ? "true" : "false")) {
            if (host === 'localhost' || host.slice(-6) === '.local' || host.slice(-10) === '.localhost') return 'DIRECT';
            if (host.indexOf(':') < 0 && host.indexOf('.') < 0) return 'DIRECT';
            if (hy2PrivateLiteral(host)) return 'DIRECT';
          }
          return 'PROXY 127.0.0.1:\(httpPort)';
        }
        """
    }
}

/// Builds complete owned proxy groups so enable, URL and endpoint restoration cannot mix with external edits.
public enum SystemProxyConfiguration {
    public static func manual(httpPort: Int, socksPort: Int) -> [String: Any] {
        ["HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": httpPort,
         "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": httpPort,
         "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": socksPort,
         "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
    }
    public static func pac(url: String) -> [String: Any] {
        ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
         "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": url, "ProxyAutoDiscoveryEnable": 0]
    }
}
