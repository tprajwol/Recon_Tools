# Recon_Tools
These tools are only for legal use. Use them as your own risk. I have been doing researches for the tools that could help me for my Bug bounty career and In the way of becoming one I have created for my own use. You can use for your help also to do the recon in Bug hunting 
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
