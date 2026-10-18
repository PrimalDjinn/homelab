use std::{path::PathBuf, process::Command};
use crate::utils::get_first_occurrence;



const OS_RELEASE: &str = "/etc/os-release";
const OS_RELEASE_VARIABLE_NAME: &str = "VERSION_CODENAME";


pub fn debian_codename() -> Option<String> {
    let os_release = PathBuf::from(OS_RELEASE);
    let exists = os_release.try_exists().unwrap_or(false);

    if exists {
        let codename =  match get_first_occurrence(os_release, OS_RELEASE_VARIABLE_NAME) {
            Ok((_number, line )) => {
                let divider = "=";
                if let Some((_key, value)) = line.split_once(divider) {
                    Some(value.to_owned())
                } else {
                    None
                }
            },
            Err(e) => {
                log::info!("Could not find os release variable {e}");
                None
            }
        };

        if let Some(codename) = codename {
            return Some(codename)
        }
    }

    let output = match Command::new("lsb_release").arg("-sc").output() {
        Ok(out) => {
            Some(String::from_utf8_lossy_owned(out.stdout).trim().to_owned())
        },
        Err(_) => {
            None
        }
    };

    output
}


pub fn setup_proxmox() {
    let codename = match debian_codename() {
        Some(codename) => {
           codename 
        }
        None => {
            return Err("Unable to determine debian version");
        }
    };

    let is_supported = codename == "bookworm" || codename == "trixie";
    if !is_supported {
        return
    }

    
}