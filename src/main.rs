use crate::proxmox::setup_proxmox;

mod proxmox;
mod utils;

fn main() {
    if std::env::consts::OS != "linux" {
        panic!("This program is only meant for linux");
    }

    colog::init();

    let result = setup_proxmox();

    match result {
        Ok(_) => {
            log::info!("Successfully set up server")
        }
        Err(e) => {
            log::error!("Proxmox was unable to be installed: {e}")
        }
    }
}
