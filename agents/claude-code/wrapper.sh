#!/bin/bash
# Security-aware Claude wrapper script
# This script enhances Claude with security tool awareness when running in the security container

# Check for VPN configuration and auto-connect
if [[ -f "/vpn/configs/client.ovpn" ]]; then
    echo "🔒 VPN configuration detected, attempting connection..."
    /app/vpn-startup.sh start
    sleep 3
    /app/vpn-startup.sh status
    echo ""
fi

# Check if we're in security mode
if [[ -d "/security" && -f "/usr/local/go/bin/go" ]]; then
    # Create a temporary file with security context
    SECURITY_CONTEXT=$(cat << 'EOF'
# Security Research Environment Active

You are running in a specialized security research container with advanced reconnaissance and vulnerability analysis tools. When asked to perform security-related tasks, prioritize using these specialized tools over generic approaches like curl or basic bash scripts.

## Available Security Tools by Category

### Reconnaissance & Subdomain Discovery
- **subfinder**: Fast subdomain discovery (`subfinder -d example.com`)
- **assetfinder**: Find related domains (`assetfinder example.com`)
- **httpx**: Probe HTTP services (`httpx -l subdomains.txt`)

### Port Scanning & Network Discovery
- **nmap**: Comprehensive network scanning (`nmap -sC -sV target`)
- **masscan**: High-speed port scanning (`masscan -p1-65535 --rate=1000 target`)
- **naabu**: Fast port discovery (`naabu -host example.com`)

### Web Application Testing
- **gobuster**: Directory/file brute-forcing (`gobuster dir -u http://example.com -w /security/wordlists/common.txt`)
- **ffuf**: Fast web fuzzer (`ffuf -w wordlist.txt -u http://example.com/FUZZ`)
- **nikto**: Web vulnerability scanner (`nikto -h example.com`)
- **nuclei**: Vulnerability scanner with templates (`nuclei -u example.com`)

### OSINT & Information Gathering
- **whois**: Domain registration info (`whois example.com`)
- **dig**: DNS enumeration (`dig @8.8.8.8 example.com any`)
- **waybackurls**: Historical URL discovery (`waybackurls example.com`)

### Network Analysis
- **tshark**: Packet analysis (`tshark -i eth0 -f "host example.com"`)
- **tcpdump**: Network monitoring (`tcpdump -i eth0 host example.com`)
- **netcat**: Network utility (`nc -nv target 80`)

## Tool Usage Guidelines
1. **Always use appropriate tools**: Don't use curl when httpx or subfinder would be more effective
2. **Leverage specialized capabilities**: These tools are designed for security research
3. **Use wordlists**: Available at `/security/wordlists/` (common.txt, subdomains.txt)
4. **Save results**: Use `/security/results/` with organized subdirectories
5. **Chain tools**: Use output from one tool as input to another

## Example Workflows

**Subdomain Enumeration:**
```bash
subfinder -d example.com -o subdomains.txt
httpx -l subdomains.txt -o live-hosts.txt
nuclei -l live-hosts.txt
```

**Web Application Testing:**
```bash
gobuster dir -u http://example.com -w /security/wordlists/common.txt
nikto -h example.com
```

Always ensure you have proper authorization before using these tools.
EOF
)

    # Export as environment variable for Claude to potentially pick up
    export CLAUDE_SECURITY_CONTEXT="$SECURITY_CONTEXT"

    # Create a .claude-security file in the working directory
    echo "$SECURITY_CONTEXT" > /app/.claude-security-context

    echo "🔒 Security tools context loaded. Claude is now aware of specialized security tools."
    echo "📁 Context saved to /app/.claude-security-context"
    echo "🛠️  Use tools like subfinder, nmap, gobuster, nuclei instead of generic approaches."
    echo ""
fi

# Execute Claude with all original arguments
exec claude "$@"