# Recon_Tools
These tools are only for legal use. Use them as your own risk. I have been doing researches for the tools that could help me for my Bug bounty career and In the way of becoming one I have created for my own use. You can use for your help also to do the recon in Bug hunting 

## Unified recon runner (single tool)
Use `unified_scan.sh` to run all recon tools from one command.  
If a tool is missing on first run, the script will try to install it automatically and then continue scanning.

### Included tools
`x8`, `httpx`, `cloud_enum`, `ffuf`, `parameth`, `waybackurls`, `linkfinder`, `nuclei`, `gospider`, `metabigor`, `sublist3r`, `arjun`, `cewl`, `subfinder`, `dnsx`, `assetfinder`, `github-recon`, `katana`, `subdomainizer`, `shuffledns` (+ nginx server header check).

### Usage
```bash
chmod +x unified_scan.sh
./unified_scan.sh example.com
```

### Useful options
```bash
./unified_scan.sh example.com --output recon_output
./unified_scan.sh https://example.com --wordlist /usr/share/wordlists/dirb/common.txt
./unified_scan.sh example.com --resolvers resolvers.txt
./unified_scan.sh example.com --dry-run
./unified_scan.sh example.com --skip-install
```

### Output
Each run creates a timestamped directory under `scan_results/` with:
- per-tool outputs (`tools/`)
- per-tool logs (`logs/`)
- merged subdomains and live hosts (`subdomains/`)
- DNS + HTTP/HTTPS status report (`dns_http_report.txt`)
- execution summary (`summary.txt`)
- final summarized results (`final_results.txt`)

 # DNS_resolve
   This script is a custom DNS and Web reconnaissance tool designed to validate passive subdomain lists for security analysis. It filters raw subdomain data by performing active DNS lookups     and HTTP requests to determine which targets are truly "live."
  *Key Features
    DNS Resolution: Uses dig to perform standard A-record lookups, identifying the current DNS Status (e.g., NOERROR, NXDOMAIN) and retrieving the specific IP Address.
    Web Probing: Integrates curl to fetch the HTTP Status Code, helping you quickly identify accessible web servers (200 OK), redirects (301/302), or forbidden pages (403).
    Automated Filtering: Automatically extracts and saves only the functional domains into a separate file (live_subdomains.txt) for immediate use in follow-up tools like Nmap or Nuclei.
    Clean Output: Provides a formatted, scannable table in the terminal that simplifies the transition from passive data gathering to active vulnerability assessment.
  *USES
    - Copy the code and save the file name as you want 
    - give the execution permission using : chmod +x {file_name}
    - ./{file_name} {subdomain_file.txt}
