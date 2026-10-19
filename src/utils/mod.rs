use std::{
    fs::File,
    io::{BufRead, BufReader},
    net::{Ipv4Addr},
    path::PathBuf,
    process::Command,
};

use regex::Regex;

pub fn get_first_occurrence(path: PathBuf, target: &str) -> Result<(i32, String), String> {
    let file = match File::open(path) {
        Ok(file) => file,
        Err(e) => {
            let msg = format!("An error occurred when opening the file {e}");
            return Err(msg);
        }
    };

    let reader = BufReader::new(&file);

    let mut count: i32 = 0;
    for line in reader.lines().map_while(Result::ok) {
        if line.trim().starts_with(target) {
            return Ok((count, line));
        }

        count += 1;
    }

    Err("Unable to find the signal word".into())
}

pub fn is_external_ip(addr: Ipv4Addr) -> bool {
    let [a, b, c, d] = addr.octets();

    if addr.is_private()
        || addr.is_loopback()
        || addr.is_link_local()
        || addr.is_documentation()
        || a == 0                         // This network
        || a >= 224                       // Multicast, reserved, broadcast
        || (a == 100 && (64..=127).contains(&b)) // CGNAT
        || (a == 198 && (18..=19).contains(&b))  // Benchmarking
        || (a == 192 && b == 0 && c == 0 && d != 9 && d != 10)
    {
        return false;
    }

    true
}

pub fn get_internet_ip() -> Result<Ipv4Addr, String> {
    const IP_CANDIDATES: [&str; 3] = [
        "https://ifconfig.io/ip",
        "https://icanhazip.com",
        "https://ipecho.net/plain",
    ];

    for candidate in IP_CANDIDATES {
        match reqwest::blocking::Client::new().get(candidate).send() {
            Ok(response) => match response.text() {
                Ok(text) => {
                    let ip = text.parse::<Ipv4Addr>();

                    match ip {
                        Ok(addr) => return Ok(addr),
                        Err(e) => {
                            log::warn!("An error occured when trying to parse the IP, {e}")
                        }
                    }
                }
                Err(e) => {
                    log::warn!(
                        "An error occurred when trying to read the resonse from {candidate}: {e}"
                    )
                }
            },
            Err(e) => {
                log::warn!("An error occurred when trying to make a request to {candidate}: {e}")
            }
        };
    }

    Err("Unable to get the ip of the server using the existing candidates".into())
}

pub fn get_host_ipv4() -> Result<Ipv4Addr, String> {
    // 1.1.1.1 via 172.17.0.1 dev eth0 src 172.17.0.2 uid 1000
    const CLOUDFLARE_DNS: &str = "1.1.1.1";
    let output = Command::new("ip")
        .arg("route")
        .arg("get")
        .arg(CLOUDFLARE_DNS)
        .output()
        .ok();

    if let Some(output) = output {
        let line = String::from_utf8_lossy_owned(output.stdout);
        let regex = Regex::new(r"\bsrc\s+(\S+)").ok();

        if let Some(regex) = regex {
            let result = regex.find(line.as_str());

            if let Some(result) = result {
                let ip = result.as_str();
                log::info!("Found the host IP: {ip}");

                let addr = match ip.parse::<Ipv4Addr>() {
                    Ok(addr) => addr,
                    Err(e) => {
                        log::warn!("Encountered a malformed ip address, {e}");
                        Ipv4Addr::UNSPECIFIED
                    }
                };

                if is_external_ip(addr) {
                    return Ok(addr);
                }
            }
        }
    };

    get_internet_ip()
}
