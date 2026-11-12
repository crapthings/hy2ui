import Foundation

/// Generates cached PAC decisions from enabled rules and the explicitly selected FINAL action.
public enum PACScript {
    public static func generate(configuration savedConfiguration: RoutingConfiguration, httpPort: Int) throws -> String {
        var validated = savedConfiguration
        if validated.finalAction == .direct { validated.mode = .generatedPAC }
        try validated.validate()
        let configuration = validated.activeRules
        guard (1024...65535).contains(httpPort) else { throw ConfigurationError.invalid("本地代理端口无效。") }
        let finalRoute = configuration.finalAction == .direct ? "DIRECT" : "PROXY 127.0.0.1:\(httpPort)"
        func route(_ action: AddressRuleAction) -> String { action == .direct ? "DIRECT" : finalRoute }
        let domains = try configuration.directDomains.map(RoutingConfiguration.domain)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(Dictionary(domains.map { ($0, true) }, uniquingKeysWith: { _, value in value }))
        let list = String(decoding: data, as: UTF8.self)
        let ipRules = configuration.addressRules.compactMap { rule -> [String: Any]? in
            guard let net = rule.network else { return nil }
            return ["bytes": net.bytes.map { Int($0) }, "prefix": net.prefix, "action": route(rule.action)]
        }.sorted { ($0["prefix"] as! Int) > ($1["prefix"] as! Int) }
        let domainRules = Dictionary(uniqueKeysWithValues: configuration.addressRules.filter { $0.isDomain && $0.domainMatch == .suffix }.map { ($0.target, route($0.action)) })
        let exactDomains = Dictionary(uniqueKeysWithValues: configuration.addressRules.filter { $0.isDomain && $0.domainMatch == .exact }.map { ($0.target, route($0.action)) })
        let keywordDomains = configuration.addressRules.filter { $0.isDomain && $0.domainMatch == .keyword }.map {
            ["value": $0.target, "action": route($0.action)]
        }
        let networks = (LocalNetworkPolicy.ipv4 + LocalNetworkPolicy.ipv6).compactMap { try? IPNetwork($0) }.map { ["bytes": $0.bytes.map { Int($0) }, "prefix": $0.prefix] as [String: Any] }
        func json(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self) }
        return """
        var hy2DirectDomains = \(list);
        var hy2Domains = \(try json(domainRules));
        var hy2ExactDomains = \(try json(exactDomains));
        var hy2Keywords = \(try json(keywordDomains));
        var hy2Networks = \(try json(ipRules));
        var hy2Local = \(try json(networks));
        function hy2V4(host) {
          var p = host.split('.'); if (p.length !== 4) return null;
          for (var i=0;i<4;i++) { if (!/^\\d+$/.test(p[i]) || +p[i]>255) return null; p[i]=+p[i]; } return p;
        }
        function hy2IP(host) {
          if (host.indexOf(':')<0) return hy2V4(host);
          host=host.split('%')[0];
          if (host.indexOf('.')>=0) {
            var last=host.lastIndexOf(':'), p=hy2V4(host.slice(last+1)); if (!p) return null;
            host=host.slice(0,last+1)+((p[0]<<8)|p[1]).toString(16)+':'+((p[2]<<8)|p[3]).toString(16);
          }
          var halves=host.split('::'), left=halves[0]?halves[0].split(':'):[], right=halves.length===2&&halves[1]?halves[1].split(':'):[];
          if (halves.length>2 || (halves.length===1 && left.length!==8) || (halves.length===2 && left.length+right.length>=8)) return null;
          var words=left.slice(); if(halves.length===2) { while(words.length<8-right.length) words.push('0'); words=words.concat(right); }
          var bytes=[];
          for(var j=0;j<8;j++) { if(!/^[0-9a-f]{1,4}$/.test(words[j])) return null; var word=parseInt(words[j],16); bytes.push(word>>8,word&255); }
          return bytes;
        }
        function hy2Contains(net, bytes) {
          if(!bytes || net.bytes.length!==bytes.length) return false;
          for(var i=0;i<bytes.length;i++) { var mask=(255<<Math.max(0,Math.min(8,8-(net.prefix-i*8))))&255; if(net.bytes[i] !== (bytes[i]&mask)) return false; } return true;
        }
        function hy2Lookup(host) {
          host=host.toLowerCase(); if(host.charAt(0)==='[' && host.charAt(host.length-1)===']') host=host.slice(1,-1);
          if(host.charAt(host.length-1)==='.') host=host.slice(0,-1);
          var bytes=hy2IP(host), candidate=host;
          if(\(configuration.bypassLocalNetworks ? "true" : "false")) {
            if(!bytes && (host.indexOf('.')<0 || host==='local' || host.slice(-6)==='.local' || host==='home.arpa' || host.slice(-10)==='.home.arpa' || host.slice(-10)==='.localhost')) return 'DIRECT';
            for(var k=0;k<hy2Local.length;k++) if(hy2Contains(hy2Local[k],bytes)) return 'DIRECT';
            if(bytes && bytes.length===16 && bytes.slice(0,10).every(function(b){return b===0;}) && bytes[10]===255 && bytes[11]===255) {
              for(var m=0;m<hy2Local.length;m++) if(hy2Contains(hy2Local[m],bytes.slice(12))) return 'DIRECT';
            }
          }
          if(bytes) {
            for(var i=0;i<hy2Networks.length;i++) if(hy2Contains(hy2Networks[i],bytes)) return hy2Networks[i].action;
          } else {
            if(Object.prototype.hasOwnProperty.call(hy2ExactDomains,host)) return hy2ExactDomains[host];
            for(var n=0;n<hy2Keywords.length;n++) if(host.indexOf(hy2Keywords[n].value)>=0) return hy2Keywords[n].action;
            while(candidate) {
              if(Object.prototype.hasOwnProperty.call(hy2Domains,candidate)) return hy2Domains[candidate];
              if(Object.prototype.hasOwnProperty.call(hy2DirectDomains,candidate)) return 'DIRECT';
              var dot=candidate.indexOf('.'); if(dot<0) break; candidate=candidate.slice(dot+1);
            }
          }
          return '\(finalRoute)';
        }
        var hy2Cache = Object.create(null), hy2CacheSize = 0;
        function FindProxyForURL(url, host) {
          host=host.toLowerCase();
          if(Object.prototype.hasOwnProperty.call(hy2Cache,host)) return hy2Cache[host];
          var action=hy2Lookup(host);
          if(hy2CacheSize>=512) { hy2Cache=Object.create(null); hy2CacheSize=0; }
          hy2Cache[host]=action; hy2CacheSize++; return action;
        }
        """
    }
}

/// Builds complete owned proxy groups so enable, URL and endpoint restoration cannot mix with external edits.
public enum SystemProxyConfiguration {
    public static func manual(httpPort: Int, socksPort: Int, bypassLocalNetworks: Bool = true) -> [String: Any] {
        ["ExceptionsList": bypassLocalNetworks ? LocalNetworkPolicy.proxyExceptions : [],
         "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": httpPort,
         "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": httpPort,
         "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": socksPort,
         "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
    }
    public static func pac(url: String) -> [String: Any] {
        ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
         "ProxyAutoConfigEnable": 1, "ProxyAutoConfigURLString": url, "ProxyAutoDiscoveryEnable": 0]
    }
}
